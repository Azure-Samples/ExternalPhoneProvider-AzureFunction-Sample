// <copyright file="providerToken.js" company="Microsoft Corporation">
// Copyright (c) Microsoft Corporation. All rights reserved.
// </copyright>

'use strict';

const { inspect } = require('node:util');
const { AsyncLocalStorage } = require('node:async_hooks');
const { ManagedIdentityCredential, ClientAssertionCredential, ClientSecretCredential, logger } = require('@azure/identity');
const { parseProviderTimeout, isValidProviderUrl } = require('./config');

const TOKEN_EXCHANGE_SCOPE = 'api://AzureADTokenExchange/.default';

class ProviderTokenConfig {
    constructor(config) {
        const env = config.env;
        this.providerName = config.providerName;
        this.endpoint = config.providerEndpoint;
        this.tenantId = env.EPP_PROVIDER_TENANT_ID ?? '';
        this.clientId = env.EPP_PROVIDER_CLIENT_ID ?? '';
        this.scope = env.EPP_PROVIDER_SCOPE ?? '';
        this.miClientId = env.EPP_PROVIDER_MI_CLIENT_ID ?? '';
        this.secretName = env.EPP_PROVIDER_CLIENT_SECRET_NAME ?? '';
        this.keyVaultUrl = config.keyVaultUrl;
        this.vaultIdentityClientId = env.AZURE_CLIENT_ID ?? '';
        this.hasPlaintextSecret = Object.hasOwn(env, 'EPP_PROVIDER_CLIENT_SECRET');
        this.hasExchangeOverride = Object.hasOwn(env, 'EPP_PROVIDER_TOKEN_EXCHANGE_AUDIENCE');
    }

    // Settings checks, not JWT verification; the SDK acquires/caches tokens, and the provider verifies them.
    checkConfiguration() {
        const requiredSettings = [this.tenantId, this.clientId, this.scope, this.miClientId || this.secretName];
        if (this.vaultIdentityClientId) requiredSettings.push(this.vaultIdentityClientId);
        const validSettings = requiredSettings.every(isSafeBearerToken);

        const tenantCharacters = 'abcdefghijklmnopqrstuvwxyz0123456789.-';
        const validAuthority = validSettings
            && !['common', 'organizations', 'consumers', 'adfs'].includes(this.tenantId.toLowerCase())
            && [...this.tenantId.toLowerCase()].every((character) => tenantCharacters.includes(character))
            && this.scope.endsWith('/.default') && this.scope.length > '/.default'.length;

        const validCredentials = Boolean(this.miClientId) !== Boolean(this.secretName)
            && (!this.secretName || isValidProviderUrl(this.keyVaultUrl))
            && !this.hasPlaintextSecret && !this.hasExchangeOverride;

        if (!(validSettings && validAuthority && validCredentials)) {
            throw new Error('provider authentication configuration invalid');
        }
    }

    [inspect.custom]() { return '[ProviderTokenConfig]'; }
}

function isSafeBearerToken(token) {
    return typeof token === 'string' && token.length > 0
        && [...token].every((character) => character.charCodeAt(0) > 32 && character.charCodeAt(0) < 127);
}

function tokenValue(result) {
    if (!result || !isSafeBearerToken(result.token) || !Number.isFinite(result.expiresOnTimestamp)
        || result.expiresOnTimestamp <= Date.now() + 60000) {
        throw new Error('provider token unavailable');
    }
    return result.token;
}

function createCredential(config, secret, getSignal) {
    // Identity's exported logger is package-wide; never emit SDK exception details.
    for (const level of ['error', 'warning', 'info', 'verbose']) logger[level].enabled = false;
    const options = {
        authorityHost: 'https://login.microsoftonline.com',
        retryOptions: { maxRetries: 0 },
        loggingOptions: { logger: Object.assign(() => {}, { enabled: false }),
            allowLoggingAccountIdentifiers: false, enableUnsafeSupportLogging: false },
    };
    if (config.miClientId) {
        const identity = new ManagedIdentityCredential(config.miClientId, options);
        return new ClientAssertionCredential(config.tenantId, config.clientId, async () => {
            const abortSignal = getSignal();
            abortSignal.throwIfAborted();
            return tokenValue(await identity.getToken(TOKEN_EXCHANGE_SCOPE, { abortSignal }));
        }, options);
    }
    return new ClientSecretCredential(config.tenantId, config.clientId, secret, options);
}

class ProviderTokenAcquirer {
    #entry;
    #signals = new AsyncLocalStorage();
    #resolveSecret;
    #credentialFactory;

    constructor({ resolveSecretValue, credentialFactory = createCredential }) {
        this.#resolveSecret = resolveSecretValue;
        this.#credentialFactory = credentialFactory;
    }

    async acquire(config) {
        const controller = new AbortController();
        let timer;
        const deadline = new Promise((_, reject) => {
            timer = setTimeout(() => {
                const error = new Error('provider authentication timed out');
                error.name = 'TimeoutError';
                reject(error);
                controller.abort();
            }, parseProviderTimeout(config.providerTimeoutMs));
        });
        try {
            return await Promise.race([this.#acquire(config, controller.signal), deadline]);
        } catch (error) {
            const failure = new Error('provider token unavailable');
            failure.name = controller.signal.aborted ? 'TimeoutError' : 'Error';
            throw failure;
        } finally {
            clearTimeout(timer);
            controller.abort();
        }
    }

    async #acquire(config, signal) {
        const auth = new ProviderTokenConfig(config);
        auth.checkConfiguration();
        const secret = auth.secretName ? await this.#resolveSecret(auth.secretName, config, { abortSignal: signal }) : '';
        signal.throwIfAborted();
        if (auth.secretName && (typeof secret !== 'string' || !secret.trim())) throw new Error('provider secret unavailable');

        // One credential entry; Azure Identity owns token caching and renewal.
        if (!this.#entry || this.#entry.secret !== secret
            || Object.keys(auth).some((key) => this.#entry.config[key] !== auth[key])) {
            this.#entry = { config: auth, secret,
                credential: this.#credentialFactory(auth, secret, () => this.#signals.getStore()) };
        }
        const credential = this.#entry.credential;
        const result = await this.#signals.run(signal, () => credential.getToken(auth.scope, { abortSignal: signal }));
        signal.throwIfAborted();
        return tokenValue(result);
    }

    [inspect.custom]() { return '[ProviderTokenAcquirer]'; }
}

module.exports = { ProviderTokenConfig, ProviderTokenAcquirer, isSafeBearerToken };