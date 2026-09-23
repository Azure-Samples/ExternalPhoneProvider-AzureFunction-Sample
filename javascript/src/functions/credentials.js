// Copyright (c) Microsoft Corporation. All rights reserved.
'use strict';

const { AsyncLocalStorage } = require('node:async_hooks');
const { inspect } = require('node:util');
const { createDefaultHttpClient } = require('@azure/core-rest-pipeline');
const { ClientAssertionCredential, ManagedIdentityCredential } = require('@azure/identity');
const { SecretClient } = require('@azure/keyvault-secrets');
const { AzureLogger } = require('@azure/logger');
const { CACHE_POLICY, RefreshingCache, tokenEntry } = require('./refreshingCache');

/**
 * @template T
 * @typedef {InstanceType<typeof RefreshingCache<T>>} CredentialCache
 */

/**
 * @typedef {ReturnType<typeof import('./config').readConfig>} AppConfig
 * @typedef {{mode?: string, keyVaultSecretName?: string, identityKeyVaultSecretName?: string}} AuthConfig
 * @typedef {{mode: 'apiKey', secret: string, identity: string}} ApiKeyCredential
 * @typedef {{mode: 'oauth', accessToken: string}} OAuthCredential
 * @typedef {import('@azure/core-auth').AccessToken} AccessToken
 * @typedef {{mode: 'apiKey', bundle: CredentialCache<ApiKeyCredential>}} ApiKeyState
 * @typedef {object} OAuthState
 * @property {'oauth'} mode
 * @property {CredentialCache<AccessToken>} assertion
 * @property {ClientAssertionCredential} credential
 * @property {Map<string, CredentialCache<AccessToken>>} tokens
 */

/** @type {AsyncLocalStorage<AbortSignal>} */
const acquisition = new AsyncLocalStorage();
/** @type {typeof AzureLogger.log | undefined} */
let filteredLogger;

/** @param {string} cacheKind */
function reportRefreshFailure(cacheKind) {
    console.warn(JSON.stringify({ logType: 'service', eventName: 'credential_refresh_failed',
        cacheKind, failureReason: 'credential_unavailable' }));
}

/** @returns {import('@azure/core-rest-pipeline').HttpClient} */
function credentialHttpClient() {
    const client = createDefaultHttpClient();
    return {
        async sendRequest(request) {
            const signal = acquisition.getStore();
            if (!signal) return client.sendRequest(request);
            const controller = new AbortController();
            const existing = request.abortSignal;
            const abort = () => controller.abort();
            signal.addEventListener('abort', abort, { once: true });
            existing?.addEventListener('abort', abort);
            if (signal.aborted || existing?.aborted) controller.abort();
            request.abortSignal = controller.signal;
            try {
                controller.signal.throwIfAborted();
                return await client.sendRequest(request);
            } finally {
                signal.removeEventListener('abort', abort);
                existing?.removeEventListener('abort', abort);
            }
        },
    };
}

/**
 * @template T
 * @param {AbortSignal} signal
 * @param {(signal: AbortSignal) => Promise<T>} load
 * @returns {Promise<T>}
 */
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
    /** @type {Promise<never>} */
    const interrupted = new Promise((_, reject) => {
        const fail = () => reject(new Error('provider credential unavailable'));
        controller.signal.addEventListener('abort', fail, { once: true });
        if (controller.signal.aborted) fail();
        timeout = setTimeout(abort, CACHE_POLICY.acquisitionTimeoutMs);
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

// ManagedIdentityCredential replaces additionalPolicies, but preserves the supplied HTTP client.
const sdkOptions = () => ({
    retryOptions: { maxRetries: 0 },
    httpClient: credentialHttpClient(),
});

class ProviderCredentials {
    /**
     * @param {{cacheOptions?: import('./refreshingCache').CacheOptions,
     *     reportFailure?: (kind: string) => void}} [options]
     */
    constructor({ cacheOptions = {}, reportFailure = reportRefreshFailure } = {}) {
        this.cacheOptions = cacheOptions;
        this.now = cacheOptions.now || Date.now;
        this.reportFailure = reportFailure;
        /** @type {ApiKeyState | OAuthState | null} */
        this.current = null;
        /** @type {string | null} */
        this.currentKey = null;
        this.closed = false;
    }

    [inspect.custom]() { return '[ProviderCredentials]'; }
    toJSON() { return '[ProviderCredentials]'; }

    /**
     * @template T
     * @param {string} kind
     * @param {(signal: AbortSignal) => Promise<import('./refreshingCache').CacheEntry<T>>} load
     * @returns {CredentialCache<T>}
     */
    cache(kind, load) {
        return new RefreshingCache((signal) => acquireBounded(signal, load),
            { ...this.cacheOptions, onFailure: () => this.reportFailure(kind) });
    }

    /**
     * @param {AuthConfig} auth
     * @param {AppConfig} config
     * @returns {Promise<ApiKeyCredential | OAuthCredential>}
     */
    resolve(auth, config) {
        if (this.closed) return Promise.reject(new Error('provider credential unavailable'));
        const mode = auth?.mode || 'apiKey';
        if (mode === 'oauth' && (!config.providerTenantId || !config.providerScope
            || !config.outboundClientId || !config.outboundManagedIdentityClientId)) {
            this.#clear();
            return Promise.reject(new Error('provider OAuth token unavailable'));
        }
        if (mode !== 'oauth' && mode !== 'apiKey') {
            this.#clear();
            return Promise.reject(new Error('provider credential unavailable'));
        }
        let key;
        if (mode === 'apiKey') {
            key = JSON.stringify([
                mode, config.keyVaultUrl, config.managedIdentityClientId,
                auth.keyVaultSecretName, auth.identityKeyVaultSecretName,
            ]);
        } else {
            key = JSON.stringify([
                mode, config.providerTenantId, config.outboundClientId, config.outboundManagedIdentityClientId,
            ]);
        }
        if (this.currentKey !== key) {
            this.#clear();
            if (mode === 'apiKey') {
                this.current = this.apiKeyState(auth, config);
            } else {
                this.current = this.oauthState(config);
            }
            this.currentKey = key;
        }
        const state = this.current;
        if (!state) return Promise.reject(new Error('provider credential unavailable'));
        if (state.mode === 'apiKey') return state.bundle.get();
        let tokenCache = state.tokens.get(config.providerScope);
        if (!tokenCache) {
            const scope = config.providerScope;
            tokenCache = this.cache('provider_token', async (signal) =>
                tokenEntry(await state.credential.getToken(scope, { abortSignal: signal }), this.now()));
            state.tokens.set(scope, tokenCache);
        }
        return tokenCache.get().then((token) => {
            /** @type {OAuthCredential} */
            const credential = { mode: 'oauth', accessToken: token.token };
            Object.defineProperty(credential, 'accessToken', { enumerable: false, writable: false, configurable: false });
            return credential;
        }).catch(() => { throw new Error('provider OAuth token unavailable'); });
    }

    /**
     * @param {AuthConfig} auth
     * @param {AppConfig} config
     * @returns {ApiKeyState}
     */
    apiKeyState(auth, config) {
        /** @type {SecretClient | undefined} */
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
            let expiresAt = now + CACHE_POLICY.secretTtlMs;
            for (const item of [secret, identity]) {
                if (!item) continue;
                const notBefore = item.properties?.notBefore?.getTime();
                if (item.properties?.enabled === false
                    || (notBefore !== undefined && notBefore > now)) throw new Error('provider credential unavailable');
                if (item.properties?.expiresOn) expiresAt = Math.min(expiresAt, item.properties.expiresOn.getTime());
            }
            /** @type {ApiKeyCredential} */
            const credential = { mode: 'apiKey', secret: secret.value, identity: identity?.value || '' };
            return {
                value: Object.freeze(credential),
                expiresAt,
                refreshAt: Math.min(now + CACHE_POLICY.secretRefreshIntervalMs, expiresAt - CACHE_POLICY.secretExpiryRefreshLeadMs),
            };
        });
        return { mode: 'apiKey', bundle };
    }

    /**
     * @param {AppConfig} config
     * @returns {OAuthState}
     */
    oauthState(config) {
        /** @type {ManagedIdentityCredential | undefined} */
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
        return { mode: 'oauth', assertion, credential, tokens: new Map() };
    }

    #clear() {
        const state = this.current;
        if (state?.mode === 'apiKey') {
            state.bundle.close();
        } else if (state?.mode === 'oauth') {
            state.assertion.close();
            for (const cache of state.tokens.values()) cache.close();
        }
        this.current = null;
        this.currentKey = null;
    }

    close() {
        this.closed = true;
        this.#clear();
    }
}

const providerCredentials = new ProviderCredentials();
module.exports = { ProviderCredentials, providerCredentials, reportRefreshFailure };
