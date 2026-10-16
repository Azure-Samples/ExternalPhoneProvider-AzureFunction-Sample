// Copyright (c) Microsoft Corporation. All rights reserved.
'use strict';

const { AsyncLocalStorage } = require('node:async_hooks');
const { inspect } = require('node:util');
const { createDefaultHttpClient } = require('@azure/core-rest-pipeline');
const { AzureAuthorityHosts, ClientAssertionCredential, ManagedIdentityCredential } = require('@azure/identity');
const { SecretClient } = require('@azure/keyvault-secrets');
const { AzureLogger } = require('@azure/logger');

const API_KEY_MODE = 'apiKey';
const OAUTH_MODE = 'oauth';
const TOKEN_EXCHANGE_SCOPE = 'api://AzureADTokenExchange/.default';
const ACQUISITION_TIMEOUT_MS = 2500;
const TOKEN_SKEW_MS = 30000;
const unavailable = () => new Error('provider credential unavailable');
/** @type {AsyncLocalStorage<AbortSignal>} */
const acquisition = new AsyncLocalStorage();
/** @type {typeof AzureLogger.log | undefined} */
let filteredLogger;

// The installed identity SDK does not propagate every getToken abort signal to HTTP.
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

const sdkOptions = () => ({ retryOptions: { maxRetries: 0 }, httpClient: credentialHttpClient() });
/** @param {import('@azure/core-auth').AccessToken | null} token */
function checkToken(token, now) {
    if (typeof token?.token !== 'string' || !token.token.trim() || !Number.isFinite(token.expiresOnTimestamp)
        || token.expiresOnTimestamp <= now + TOKEN_SKEW_MS) throw unavailable();
    return token;
}

/**
 * @typedef {{mode: 'apiKey', secret: string, identity: string}} ApiKeyCredential
 * @typedef {{mode: 'oauth', accessToken: string}} OAuthCredential
 * @typedef {ReturnType<typeof import('./config').readConfig>} AppConfig
 * @typedef {{mode?: string, keyVaultSecretName?: string, identityKeyVaultSecretName?: string}} AuthConfig
 */

class CredentialTokenService {
    /** @param {{now?: () => number}} [options] */
    constructor({ now = Date.now } = {}) {
        this.now = now;
        /** @type {SecretClient | undefined} */
        this.secretClient = undefined;
        /** @type {ClientAssertionCredential | undefined} */
        this.tokenCredential = undefined;
        /** @type {Set<AbortController>} */
        this.controllers = new Set();
        this.closed = false;
    }

    /** @param {AuthConfig} auth @param {AppConfig} config @param {AbortSignal} signal */
    async fetchApiKey(auth, config, signal) {
        const { keyVaultSecretName: key, identityKeyVaultSecretName: account } = auth;
        if (!key || !config.keyVaultUrl) throw unavailable();
        this.secretClient ??= new SecretClient(config.keyVaultUrl,
            new ManagedIdentityCredential({ clientId: config.managedIdentityClientId || undefined, ...sdkOptions() }), sdkOptions());
        const [secret, identity] = await Promise.all([
            this.secretClient.getSecret(key, { abortSignal: signal }),
            account ? this.secretClient.getSecret(account, { abortSignal: signal }) : null,
        ]);
        const now = this.now();
        for (const item of [secret, identity]) {
            if (!item) continue;
            if (!item.value?.trim() || item.properties?.enabled === false || item.properties?.notBefore?.getTime() > now) throw unavailable();
            if (item.properties?.expiresOn) {
                const expiresAt = item.properties.expiresOn.getTime();
                if (!Number.isFinite(expiresAt) || expiresAt <= now) throw unavailable();
            }
        }
        if (!secret.value?.trim() || (account && !identity?.value?.trim())) throw unavailable();
        signal.throwIfAborted();
        return Object.freeze({ mode: API_KEY_MODE, secret: secret.value, identity: identity?.value || '' });
    }

    /** @param {AppConfig} config @param {AbortSignal} signal */
    async fetchAccessToken(config, signal) {
        if (!config.providerTenantId || !config.providerScope || !config.outboundClientId
            || !config.outboundManagedIdentityClientId) throw unavailable();
        if (!this.tokenCredential) {
            const identity = new ManagedIdentityCredential({ clientId: config.outboundManagedIdentityClientId, ...sdkOptions() });
            this.tokenCredential = new ClientAssertionCredential(config.providerTenantId, config.outboundClientId,
                async () => checkToken(await identity.getToken(TOKEN_EXCHANGE_SCOPE,
                    { abortSignal: acquisition.getStore() }), this.now()).token,
                { authorityHost: AzureAuthorityHosts.AzurePublicCloud, ...sdkOptions() });
        }
        const token = checkToken(await this.tokenCredential.getToken(config.providerScope,
            { abortSignal: signal }), this.now());
        signal.throwIfAborted();
        /** @type {OAuthCredential} */
        const value = { mode: OAUTH_MODE, accessToken: token.token };
        return Object.defineProperty(value, 'accessToken', { enumerable: false });
    }

    /** @param {AuthConfig} auth @param {AppConfig} config */
    async getCredentials(auth, config) {
        if (this.closed) throw unavailable();
        const controller = new AbortController();
        this.controllers.add(controller);
        if (AzureLogger.log !== filteredLogger) {
            const previous = AzureLogger.log;
            filteredLogger = (...args) => { if (!acquisition.getStore()) previous(...args); };
            AzureLogger.log = filteredLogger;
        }
        const timeout = setTimeout(() => controller.abort(), ACQUISITION_TIMEOUT_MS);
        const interrupted = new Promise((_, reject) =>
            controller.signal.addEventListener('abort', () => reject(unavailable()), { once: true }));
        return acquisition.run(controller.signal, () => Promise.race([
            Promise.resolve().then(() => {
                controller.signal.throwIfAborted();
                const mode = auth.mode || API_KEY_MODE;
                if (mode === API_KEY_MODE) return this.fetchApiKey(auth, config, controller.signal);
                if (mode === OAUTH_MODE) return this.fetchAccessToken(config, controller.signal);
                throw unavailable();
            }),
            interrupted,
        ])).catch(() => {
            controller.abort();
            // The handler logs a request-correlated failure without SDK error details.
            throw unavailable();
        }).finally(() => {
            clearTimeout(timeout);
            this.controllers.delete(controller);
        });
    }
    resolve(auth, config) { return this.getCredentials(auth, config); }
    close() {
        this.closed = true;
        for (const controller of this.controllers) controller.abort();
    }
    [inspect.custom]() { return '[CredentialTokenService]'; }
    toJSON() { return '[CredentialTokenService]'; }
}

const credentialTokenService = new CredentialTokenService();
module.exports = {
    CredentialTokenService,
    credentialTokenService,
};
