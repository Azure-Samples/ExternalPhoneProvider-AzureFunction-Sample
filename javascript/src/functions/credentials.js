// Copyright (c) Microsoft Corporation. All rights reserved.
'use strict';

const { AsyncLocalStorage } = require('node:async_hooks');
const { inspect } = require('node:util');
const { LRUCache } = require('lru-cache');
const { createDefaultHttpClient } = require('@azure/core-rest-pipeline');
const { AzureAuthorityHosts, ClientAssertionCredential, ManagedIdentityCredential } = require('@azure/identity');
const { SecretClient } = require('@azure/keyvault-secrets');
const { AzureLogger } = require('@azure/logger');

const API_KEY_MODE = 'apiKey';
const OAUTH_MODE = 'oauth';
const BUNDLE_KEY = 'bundle';
const TOKEN_EXCHANGE_SCOPE = 'api://AzureADTokenExchange/.default';
const ACQUISITION_TIMEOUT_MS = 2500;
const REFRESH_POLL_MS = 30000;
const SECRET_TTL_MS = 300000;
const SECRET_REFRESH_MS = 240000;
const TOKEN_SKEW_MS = 30000;
const unavailable = () => new Error('provider credential unavailable');
/** @type {AsyncLocalStorage<AbortSignal>} */
const acquisition = new AsyncLocalStorage();
/** @type {typeof AzureLogger.log | undefined} */
let filteredLogger;

function reportRefreshFailure(cacheKind) {
    console.warn(JSON.stringify({ logType: 'service', eventName: 'credential_refresh_failed',
        cacheKind, failureReason: 'credential_unavailable' }));
}

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
 * @typedef {{now?: () => number, schedule?: typeof setInterval, cancel?: typeof clearInterval}} RefreshOptions
 */

class ApiKeyCache {
    /** @param {AuthConfig} auth @param {AppConfig} config */
    constructor(auth, config, now = Date.now) {
        this.now = now;
        this.auth = { ...auth };
        this.vaultUrl = config.keyVaultUrl;
        this.identityClientId = config.managedIdentityClientId;
        /** @type {SecretClient | undefined} */
        this.client = undefined;
        /** @type {LRUCache<string, {value: ApiKeyCredential, expiresAt: number}>} */
        this.values = new LRUCache({ max: 1, ttlResolution: 0 });
        this.refreshAt = 0;
        this.stage = 'key_vault';
        this.closed = false;
    }
    get() {
        const entry = this.closed ? undefined : this.values.get(BUNDLE_KEY);
        return entry && entry.expiresAt > this.now() ? entry.value : null;
    }
    async refresh(signal) {
        if (this.closed) throw unavailable();
        if (this.get() && this.refreshAt > this.now()) return;
        const { keyVaultSecretName: key, identityKeyVaultSecretName: account } = this.auth;
        if (!key || !this.vaultUrl) throw unavailable();
        this.client ??= new SecretClient(this.vaultUrl,
            new ManagedIdentityCredential({ clientId: this.identityClientId || undefined, ...sdkOptions() }), sdkOptions());
        const [secret, identity] = await Promise.all([
            this.client.getSecret(key, { abortSignal: signal }),
            account ? this.client.getSecret(account, { abortSignal: signal }) : null,
        ]);
        const now = this.now();
        let expiresAt = now + SECRET_TTL_MS;
        for (const item of [secret, identity]) {
            if (!item) continue;
            if (!item.value?.trim() || item.properties?.enabled === false || item.properties?.notBefore?.getTime() > now) throw unavailable();
            if (item.properties?.expiresOn) expiresAt = Math.min(expiresAt, item.properties.expiresOn.getTime());
        }
        if (!secret.value?.trim() || (account && !identity?.value?.trim())
            || !Number.isFinite(expiresAt) || expiresAt <= now || this.closed) throw unavailable();
        signal.throwIfAborted();
        this.values.set(BUNDLE_KEY, { value: Object.freeze({ mode: API_KEY_MODE, secret: secret.value, identity: identity?.value || '' }),
            expiresAt }, { ttl: expiresAt - now });
        this.refreshAt = Math.min(now + SECRET_REFRESH_MS, expiresAt - TOKEN_SKEW_MS);
    }
    stop() { this.closed = true; this.values.clear(); }
    [inspect.custom]() { return '[ApiKeyCache]'; }
    toJSON() { return '[ApiKeyCache]'; }
}

class AccessTokenCache {
    /** @param {AppConfig} config */
    constructor(config, now = Date.now) {
        if (!config.providerTenantId || !config.providerScope || !config.outboundClientId
            || !config.outboundManagedIdentityClientId) throw unavailable();
        this.now = now;
        this.scope = config.providerScope;
        this.identity = new ManagedIdentityCredential({ clientId: config.outboundManagedIdentityClientId, ...sdkOptions() });
        this.credential = new ClientAssertionCredential(config.providerTenantId, config.outboundClientId,
            async () => (await this.assertion(acquisition.getStore())).token,
            { authorityHost: AzureAuthorityHosts.AzurePublicCloud, ...sdkOptions() });
        /** @type {import('@azure/core-auth').AccessToken | null} */
        this.token = null;
        this.stage = 'provider_token';
        this.closed = false;
    }
    get() {
        if (this.closed || !this.token || this.token.expiresOnTimestamp <= this.now() + TOKEN_SKEW_MS) return null;
        /** @type {OAuthCredential} */
        const value = { mode: OAUTH_MODE, accessToken: this.token.token };
        return Object.defineProperty(value, 'accessToken', { enumerable: false });
    }
    async assertion(signal) {
        return checkToken(await this.identity.getToken(TOKEN_EXCHANGE_SCOPE, { abortSignal: signal }), this.now());
    }
    async refresh(signal) {
        if (this.closed) throw unavailable();
        this.stage = 'managed_identity';
        await this.assertion(signal);
        this.stage = 'provider_token';
        const token = checkToken(await this.credential.getToken(this.scope, { abortSignal: signal }), this.now());
        signal.throwIfAborted();
        if (this.closed) throw unavailable();
        this.token = token;
    }
    stop() { this.closed = true; this.token = null; }
    [inspect.custom]() { return '[AccessTokenCache]'; }
    toJSON() { return '[AccessTokenCache]'; }
}

// Owns one selected cache and one periodic refresh; configuration changes require a worker restart.
class ProviderCredentials {
    /** @param {{cacheOptions?: RefreshOptions, reportFailure?: (kind: string) => void}} [options] */
    constructor({ cacheOptions = {}, reportFailure = reportRefreshFailure } = {}) {
        this.now = cacheOptions.now || Date.now;
        this.schedule = cacheOptions.schedule || setInterval;
        this.cancel = cacheOptions.cancel || clearInterval;
        this.reportFailure = reportFailure;
        /** @type {ApiKeyCache | AccessTokenCache | null} */
        this.current = null;
        /** @type {Promise<void> | null} */
        this.pending = null;
        /** @type {ReturnType<typeof setInterval> | null} */
        this.timer = null;
        /** @type {AbortController | null} */
        this.controller = null;
        this.nextAttemptAt = 0;
        this.closed = false;
    }
    /** @param {AuthConfig} auth @param {AppConfig} config */
    async resolve(auth, config) {
        if (this.closed) throw unavailable();
        if (!this.current) {
            try {
                switch (auth.mode || API_KEY_MODE) {
                    case API_KEY_MODE: this.current = new ApiKeyCache(auth, config, this.now); break;
                    case OAUTH_MODE: this.current = new AccessTokenCache(config, this.now); break;
                    default: throw unavailable();
                }
                this.timer = this.schedule(() => { void this.refresh().catch(() => {}); }, REFRESH_POLL_MS);
                this.timer.unref?.();
            } catch { this.reportFailure('configuration'); throw unavailable(); }
        }
        const cached = this.current.get();
        if (cached) return cached;
        await this.refresh();
        const value = this.current.get();
        if (!value) throw unavailable();
        return value;
    }
    refresh() {
        if (this.closed || !this.current) return Promise.reject(unavailable());
        if (this.pending) return this.pending;
        if (this.nextAttemptAt > this.now()) return Promise.reject(unavailable());
        this.nextAttemptAt = this.now() + REFRESH_POLL_MS;
        const cache = this.current;
        const controller = this.controller = new AbortController();
        if (AzureLogger.log !== filteredLogger) {
            const previous = AzureLogger.log;
            filteredLogger = (...args) => { if (!acquisition.getStore()) previous(...args); };
            AzureLogger.log = filteredLogger;
        }
        const timeout = setTimeout(() => controller.abort(), ACQUISITION_TIMEOUT_MS);
        const interrupted = new Promise((_, reject) =>
            controller.signal.addEventListener('abort', () => reject(unavailable()), { once: true }));
        this.pending = acquisition.run(controller.signal, () => Promise.race([
            Promise.resolve().then(() => { controller.signal.throwIfAborted(); return cache.refresh(controller.signal); }), interrupted,
        ])).catch(() => {
            controller.abort();
            if (!this.closed) this.reportFailure(cache.stage);
            throw unavailable();
        }).finally(() => {
            clearTimeout(timeout);
            this.pending = null;
            this.controller = null;
        });
        return this.pending;
    }
    close() {
        this.closed = true;
        if (this.timer) this.cancel(this.timer);
        this.controller?.abort();
        this.current?.stop();
    }
    [inspect.custom]() { return '[ProviderCredentials]'; }
    toJSON() { return '[ProviderCredentials]'; }
}

const providerCredentials = new ProviderCredentials();
module.exports = { ApiKeyCache, AccessTokenCache, ProviderCredentials, providerCredentials, reportRefreshFailure };
