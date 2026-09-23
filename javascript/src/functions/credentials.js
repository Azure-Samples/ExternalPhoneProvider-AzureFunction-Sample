// Copyright (c) Microsoft Corporation. All rights reserved.
'use strict';

const { AsyncLocalStorage } = require('node:async_hooks');
const { inspect } = require('node:util');
const { ClientAssertionCredential, ManagedIdentityCredential } = require('@azure/identity');
const { SecretClient } = require('@azure/keyvault-secrets');
const { AzureLogger } = require('@azure/logger');
const { RefreshingCache, tokenEntry } = require('./refreshingCache');

const acquisition = new AsyncLocalStorage();
let filteredLogger;

function reportRefreshFailure(cacheKind) {
    console.warn(JSON.stringify({ logType: 'service', eventName: 'credential_refresh_failed',
        cacheKind, failureReason: 'credential_unavailable' }));
}

function cancellationPolicy() {
    return {
        name: 'eppCredentialCancellation',
        async sendRequest(request, next) {
            const signal = acquisition.getStore();
            if (!signal) return next(request);
            const controller = new AbortController();
            const existing = request.abortSignal;
            const abort = () => controller.abort();
            signal.addEventListener('abort', abort, { once: true });
            existing?.addEventListener('abort', abort, { once: true });
            if (signal.aborted || existing?.aborted) controller.abort();
            request.abortSignal = controller.signal;
            try {
                controller.signal.throwIfAborted();
                return await next(request);
            } finally {
                signal.removeEventListener('abort', abort);
                existing?.removeEventListener('abort', abort);
            }
        },
    };
}

async function acquireBounded(signal, load) {
    if (AzureLogger.log !== filteredLogger) {
        const previous = AzureLogger.log;
        filteredLogger = (...args) => { if (!acquisition.getStore()) previous(...args); };
        AzureLogger.log = filteredLogger;
    }
    const controller = new AbortController();
    const abort = () => controller.abort();
    signal.addEventListener('abort', abort, { once: true });
    if (signal.aborted) abort();
    let timeout;
    const interrupted = new Promise((_, reject) => {
        const fail = () => reject(new Error('provider credential unavailable'));
        controller.signal.addEventListener('abort', fail, { once: true });
        if (controller.signal.aborted) fail();
        timeout = setTimeout(abort, 2500);
    });
    try {
        return await acquisition.run(controller.signal, () => Promise.race([
            Promise.resolve().then(() => {
                controller.signal.throwIfAborted();
                return load(controller.signal);
            }),
            interrupted,
        ]));
    } finally {
        clearTimeout(timeout);
        signal.removeEventListener('abort', abort);
    }
}

const sdkOptions = () => ({ retryOptions: { maxRetries: 0 },
    additionalPolicies: [{ policy: cancellationPolicy(), position: 'perCall' }] });

class ProviderCredentials {
    constructor({ cacheOptions = {}, reportFailure = reportRefreshFailure } = {}) {
        this.cacheOptions = cacheOptions;
        this.now = cacheOptions.now || Date.now;
        this.reportFailure = reportFailure;
        this.current = null;
        this.currentKey = null;
    }

    [inspect.custom]() { return '[ProviderCredentials]'; }
    toJSON() { return '[ProviderCredentials]'; }

    cache(kind, load) {
        return new RefreshingCache((signal) => acquireBounded(signal, load),
            { ...this.cacheOptions, onFailure: () => this.reportFailure(kind) });
    }

    resolve(auth, config) {
        const mode = auth?.mode || 'apiKey';
        if (mode === 'oauth' && (!config.providerTenantId || !config.providerScope
            || !config.outboundClientId || !config.outboundManagedIdentityClientId)) {
            this.close();
            return Promise.reject(new Error('provider OAuth token unavailable'));
        }
        if (mode !== 'oauth' && mode !== 'apiKey') {
            this.close();
            return Promise.reject(new Error('provider credential unavailable'));
        }
        const key = JSON.stringify(mode === 'apiKey'
            ? [mode, config.keyVaultUrl, config.managedIdentityClientId, auth.keyVaultSecretName, auth.identityKeyVaultSecretName]
            : [mode, config.providerTenantId, config.outboundClientId, config.outboundManagedIdentityClientId]);
        if (this.currentKey !== key) {
            this.close();
            this.current = mode === 'apiKey' ? this.apiKeyState(auth, config) : this.oauthState(config);
            this.currentKey = key;
        }
        if (mode === 'apiKey') return this.current.bundle.get();
        const state = this.current;
        if (!state.tokens.has(config.providerScope)) {
            const scope = config.providerScope;
            state.tokens.set(scope, this.cache('provider_token', async (signal) =>
                tokenEntry(await state.credential.getToken(scope, { abortSignal: signal }), this.now())));
        }
        return state.tokens.get(config.providerScope).get().then((token) =>
            Object.defineProperty({ mode: 'oauth' }, 'accessToken', { value: token.token }))
            .catch(() => { throw new Error('provider OAuth token unavailable'); });
    }

    apiKeyState(auth, config) {
        let client;
        const bundle = this.cache('key_vault', async (signal) => {
            if (!auth.keyVaultSecretName || !config.keyVaultUrl) throw new Error('provider credential unavailable');
            if (!client) {
                const identity = config.managedIdentityClientId
                    ? new ManagedIdentityCredential(config.managedIdentityClientId, sdkOptions())
                    : new ManagedIdentityCredential(sdkOptions());
                client = new SecretClient(config.keyVaultUrl, identity, sdkOptions());
            }
            const [secret, identity] = await Promise.all([
                client.getSecret(auth.keyVaultSecretName, { abortSignal: signal }),
                auth.identityKeyVaultSecretName ? client.getSecret(auth.identityKeyVaultSecretName, { abortSignal: signal }) : null,
            ]);
            if (!secret.value?.trim() || (auth.identityKeyVaultSecretName && !identity?.value?.trim())) {
                throw new Error('provider credential unavailable');
            }
            const now = this.now();
            let expiresAt = now + 300000;
            for (const item of [secret, identity]) {
                if (!item) continue;
                if (item.properties?.enabled === false
                    || item.properties?.notBefore?.getTime() > now) throw new Error('provider credential unavailable');
                if (item.properties?.expiresOn) expiresAt = Math.min(expiresAt, item.properties.expiresOn.getTime());
            }
            return { value: Object.freeze({ mode: 'apiKey', secret: secret.value, identity: identity?.value || '' }),
                expiresAt, refreshAt: Math.min(now + 240000, expiresAt - 30000) };
        });
        return { bundle };
    }

    oauthState(config) {
        let identity;
        const assertion = this.cache('managed_identity', async (signal) => {
            identity ??= new ManagedIdentityCredential({ clientId: config.outboundManagedIdentityClientId, ...sdkOptions() });
            return tokenEntry(await identity.getToken('api://AzureADTokenExchange/.default', { abortSignal: signal }), this.now());
        });
        const credential = new ClientAssertionCredential(config.providerTenantId, config.outboundClientId,
            async () => {
                const value = await assertion.get();
                acquisition.getStore()?.throwIfAborted();
                return value.token;
            }, { authorityHost: 'https://login.microsoftonline.com', ...sdkOptions() });
        return { assertion, credential, tokens: new Map() };
    }

    close() {
        this.current?.bundle?.close();
        this.current?.assertion?.close();
        if (this.current?.tokens) for (const cache of this.current.tokens.values()) cache.close();
        this.current = null;
        this.currentKey = null;
    }
}

const providerCredentials = new ProviderCredentials();
module.exports = { ProviderCredentials, providerCredentials, reportRefreshFailure };
