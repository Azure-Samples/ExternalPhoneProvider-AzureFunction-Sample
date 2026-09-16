// <copyright file="dispatch.js" company="Microsoft Corporation">
// Copyright (c) Microsoft Corporation. All rights reserved.
// </copyright>

'use strict';

const crypto = require('crypto');
const { compactDecrypt } = require('jose');
const { ClientAssertionCredential, ManagedIdentityCredential } = require('@azure/identity');
const { SecretClient } = require('@azure/keyvault-secrets');
const { AzureLogger } = require('@azure/logger');
const { AsyncLocalStorage } = require('node:async_hooks');
const { readConfig } = require('./config');
const { DeliveryContext, TextToVoice } = require('./models');

const CHANNEL_BY_CODE = Object.freeze({ 1: 'sms', 2: 'voice' });
const CHANNEL_BY_NAME = Object.freeze({ sms: 1, voice: 2 });
const MODE = Object.freeze({ LIVE: 1, EVALUATION: 2 });
const MODE_BY_NAME = Object.freeze({ live: 1, evaluation: 2 });

function normalizeChannel(channel) {
    if (channel === 1 || channel === 2) return channel;
    if (typeof channel === 'string' && Object.hasOwn(CHANNEL_BY_NAME, channel.toLowerCase())) {
        return CHANNEL_BY_NAME[channel.toLowerCase()];
    }
    return null;
}
function normalizeMode(mode) {
    if (mode === MODE.LIVE || mode === MODE.EVALUATION) return mode;
    if (typeof mode === 'string' && Object.hasOwn(MODE_BY_NAME, mode.toLowerCase())) {
        return MODE_BY_NAME[mode.toLowerCase()];
    }
    return null;
}

/** @returns {{envelope?: import('./models').Envelope, error?: string}} */
function parseEnvelope(payload) {
    if (!payload || typeof payload !== 'object' || Array.isArray(payload)) {
        return { error: 'invalid envelope' };
    }
    const { type, tenantId, correlationId, channel, mode, ttlSeconds, encryptedDeliveryContext } = payload;
    if (type !== 'microsoft.mfa.otpDeliver.v1') {
        return { error: 'unsupported envelope type' };
    }
    if (typeof encryptedDeliveryContext !== 'string' || !encryptedDeliveryContext.trim()) {
        return { error: 'encryptedDeliveryContext is required' };
    }
    const channelCode = normalizeChannel(channel);
    if (!channelCode) {
        return { error: 'unsupported channel' };
    }
    const modeCode = normalizeMode(mode);
    if (!modeCode) {
        return { error: 'unsupported mode' };
    }
    if (Object.hasOwn(payload, 'ttlSeconds')) {
        if (!Number.isInteger(ttlSeconds) || ttlSeconds > 2147483647) {
            return { error: 'invalid ttlSeconds' };
        }
        if (ttlSeconds <= 0) {
            return { error: 'ttlSeconds expired' };
        }
    }
    return { envelope: { type, tenantId, correlationId, channel: channelCode, mode: modeCode, ttlSeconds, encryptedDeliveryContext } };
}

// Reject oversized or structurally invalid JWEs before decoding or allocating buffers.
const MAX_JWE_LENGTH = 16384;

function assertWellFormedJwe(compactJwe) {
    if (typeof compactJwe !== 'string' || compactJwe.length === 0) {
        throw new Error('malformed JWE');
    }
    if (compactJwe.length > MAX_JWE_LENGTH) {
        throw new Error('delivery context exceeds size limit');
    }
    const segments = compactJwe.split('.');
    if (segments.length !== 5 || segments.some((segment) => segment.length === 0)) {
        throw new Error('malformed JWE: expected five non-empty segments');
    }
}

function readProtectedHeader(compactJwe) {
    const protectedSegment = String(compactJwe).split('.')[0] || '';
    return JSON.parse(Buffer.from(protectedSegment, 'base64url').toString('utf8'));
}

let cachedKey;
let cachedKeyPem;

function normalizePem(value) {
    const text = String(value || '');
    if (text.includes('-----BEGIN')) return text;
    return Buffer.from(text, 'base64').toString('utf8');
}

function loadPrivateKey(pem) {
    if (!pem) {
        throw new Error('private key unavailable (EPP_DECRYPTION_KEY_PEM is not set)');
    }
    if (cachedKey && cachedKeyPem === pem) {
        return cachedKey;
    }
    cachedKey = crypto.createPrivateKey(normalizePem(pem));
    cachedKeyPem = pem;
    return cachedKey;
}

async function decryptDeliveryContext(compactJwe, config = readConfig()) {
    assertWellFormedJwe(compactJwe);
    const header = readProtectedHeader(compactJwe);
    const privateKey = loadPrivateKey(config.decryptionKeyPem);
    // Pin alg/enc so a tampered header can't downgrade the crypto.
    const { plaintext } = await compactDecrypt(compactJwe, privateKey, {
        keyManagementAlgorithms: ['RSA-OAEP-256'],
        contentEncryptionAlgorithms: ['A256GCM'],
    });
    return { header, context: DeliveryContext.fromPayload(JSON.parse(Buffer.from(plaintext).toString('utf8'))) };
}

/**
 * @param {DeliveryContext} context
 * @param {import('./models').Envelope} envelope
 * @param {string} messageId
 * @returns {import('./models').DispatchRequest}
 */
function contextToDispatch(context, envelope, messageId) {
    const channel = CHANNEL_BY_CODE[envelope.channel];
    return {
        destination: context.phoneNumber,
        message: context.message,
        channel,
        messageId,
        correlationId: envelope.correlationId,
        locale: context.locale || undefined,
        textToVoice: context.textToVoice,
    };
}

const OUTCOME = Object.freeze({
    CONTINUE: 'Continue',
    FAIL: 'Fail',
    BLOCK: 'Block',
    STEP_UP: 'StepUp',
});

const SECRET_CACHE_TIME_TO_LIVE_MILLISECONDS = 5 * 60 * 1000; // rotated secrets picked up within this window

const providerRegistry = new Map(
    [
        require('./providers/infobip'),
        require('./providers/sinch'),
        require('./providers/soprano'),
        require('./providers/telesign'),
    ].map((providerModule) => [
        providerModule.manifest.id.toLowerCase(),
        { manifest: providerModule.manifest, adapter: providerModule },
    ]),
);

function getProvider(providerId) {
    return providerId ? providerRegistry.get(String(providerId).trim().toLowerCase()) || null : null;
}

let keyVaultSecretClient = null;
let keyVaultClientConfig;
const secretCache = new Map();
let oauthCredential = null;
let oauthCredentialConfig;
const oauthRequest = new AsyncLocalStorage();
let filteredOAuthLogger;

function usableAccessToken(value) {
    return typeof value?.token === 'string' && value.token.trim()
        && Number.isFinite(value.expiresOnTimestamp) && value.expiresOnTimestamp > Date.now() + 30000;
}

function getKeyVaultSecretClient(config) {
    const cacheKey = JSON.stringify([config.keyVaultUrl, config.managedIdentityClientId]);
    if (!keyVaultSecretClient || keyVaultClientConfig !== cacheKey) {
        const credential = config.managedIdentityClientId
            ? new ManagedIdentityCredential(config.managedIdentityClientId)
            : new ManagedIdentityCredential();
        keyVaultSecretClient = new SecretClient(config.keyVaultUrl, credential);
        keyVaultClientConfig = cacheKey;
    }
    return keyVaultSecretClient;
}

async function resolveSecretValue(keyVaultSecretName, config) {
    if (!keyVaultSecretName) {
        return '';
    }
    const cacheKey = JSON.stringify([config.keyVaultUrl, config.managedIdentityClientId, keyVaultSecretName]);
    const cachedSecret = secretCache.get(cacheKey);
    if (cachedSecret && cachedSecret.expiresAt > Date.now()) {
        return cachedSecret.value;
    }

    const secretValue = (await getKeyVaultSecretClient(config).getSecret(keyVaultSecretName)).value || '';

    secretCache.set(cacheKey, {
        value: secretValue,
        expiresAt: Date.now() + SECRET_CACHE_TIME_TO_LIVE_MILLISECONDS,
    });
    return secretValue;
}

async function resolveProviderCredential(authConfiguration = {}, config) {
    const { mode = 'apiKey' } = authConfiguration;
    if (mode === 'apiKey') {
        const [secret, identity] = await Promise.all([
            resolveSecretValue(authConfiguration.keyVaultSecretName, config),
            authConfiguration.identityKeyVaultSecretName
                ? resolveSecretValue(authConfiguration.identityKeyVaultSecretName, config)
                : Promise.resolve(''),
        ]);
        return { mode: 'apiKey', secret, identity };
    }
    if (mode !== 'oauth' || !config.providerTenantId || !config.providerScope
        || !config.outboundClientId || !config.outboundManagedIdentityClientId) {
        throw new Error('unsupported or incomplete provider authentication');
    }
    if (AzureLogger.log !== filteredOAuthLogger) {
        const log = AzureLogger.log;
        filteredOAuthLogger = (...args) => { if (!oauthRequest.getStore()) log(...args); };
        AzureLogger.log = filteredOAuthLogger;
    }
    return oauthRequest.run(AbortSignal.timeout(2500), async () => {
        try {
            const credentialConfig = JSON.stringify([
                config.providerTenantId, config.outboundClientId, config.outboundManagedIdentityClientId,
            ]);
            if (!oauthCredential || oauthCredentialConfig !== credentialConfig) {
                const assertionIdentity = new ManagedIdentityCredential({
                    clientId: config.outboundManagedIdentityClientId, retryOptions: { maxRetries: 0 },
                });
                oauthCredential = new ClientAssertionCredential(
                    config.providerTenantId,
                    config.outboundClientId,
                    async () => {
                        const assertion = await assertionIdentity.getToken('api://AzureADTokenExchange/.default',
                            { abortSignal: oauthRequest.getStore() });
                        if (!usableAccessToken(assertion)) throw new Error('managed identity assertion unavailable');
                        return assertion.token;
                    },
                    { authorityHost: 'https://login.microsoftonline.com', retryOptions: { maxRetries: 0 } },
                );
                oauthCredentialConfig = credentialConfig;
            }
            const accessToken = await oauthCredential.getToken(config.providerScope, { abortSignal: oauthRequest.getStore() });
            if (!usableAccessToken(accessToken)) throw new Error('provider OAuth token unavailable');
            return Object.defineProperty({ mode: 'oauth' }, 'accessToken', { value: accessToken.token });
        } catch {
            throw new Error('provider OAuth token unavailable');
        }
    });
}

// Status mappings may restrict HTTP success, but cannot turn failed HTTP into Continue.
/** @param {import('./models').ParsedResponse} parsedResponse */
function resolveOutcome(manifest, parsedResponse) {
    const responseMapping = manifest.responseMapping || {};
    const providerStatusKey = parsedResponse.providerStatusName || parsedResponse.providerStatusCode;
    const fallback = Object.hasOwn(responseMapping, 'default')
        ? responseMapping.default || OUTCOME.FAIL : OUTCOME.FAIL;
    const hasMapping = (typeof providerStatusKey === 'string' || typeof providerStatusKey === 'number')
        && Object.hasOwn(responseMapping, providerStatusKey);
    const outcome = providerStatusKey
        ? (hasMapping ? responseMapping[providerStatusKey] || fallback : fallback)
        : (parsedResponse.success ? OUTCOME.CONTINUE : fallback);
    return outcome === OUTCOME.CONTINUE && !parsedResponse.success ? OUTCOME.FAIL : outcome;
}

function outcomeToHttpStatus(outcome, providerHttpStatus) {
    switch (outcome) {
        case OUTCOME.CONTINUE:
            return 200;
        case OUTCOME.BLOCK:
            return 403;
        case OUTCOME.STEP_UP:
            return 409;
        case OUTCOME.FAIL:
            if (providerHttpStatus === 429) return 429;
            if (providerHttpStatus === 401 || providerHttpStatus === 403) return 401;
            if (providerHttpStatus >= 400 && providerHttpStatus < 500) return 400;
            return 502;
        default:
            return 502;
    }
}

// App settings use one grammar: trimmed ASCII decimal digits, no sign, exponent, or hex.
function parseProviderTimeout(value) {
    const text = typeof value === 'string' ? value.trim() : '';
    if (!text || [...text].some((character) => character < '0' || character > '9')) return 1500;
    const milliseconds = Number(text);
    return milliseconds > 0 ? Math.min(milliseconds, 2500) : 1500;
}

function isValidProviderUrl(value) {
    if (typeof value !== 'string' || !value.toLowerCase().startsWith('https://')) return false;
    for (const character of value) {
        if (!character.trim() || character.charCodeAt(0) < 32 || character === '\\' || character === '#') return false;
    }
    const authority = value.slice('https://'.length).split('/')[0].split('?')[0];
    // URL normalizes empty userinfo and empty ports away; reject those in the original authority too.
    if (!authority || authority.includes('@') || authority.endsWith(':')) return false;
    try {
        const url = new URL(value);
        return url.protocol === 'https:' && !!url.hostname && !url.username && !url.password && !url.hash
            && (!url.port || (Number(url.port) >= 1 && Number(url.port) <= 65535));
    } catch {
        return false;
    }
}

async function fetchWithTimeout(providerRequest, timeoutMilliseconds) {
    const abortController = new AbortController();
    let timedOut = false;
    const timeoutTimer = setTimeout(() => {
        timedOut = true;
        abortController.abort();
    }, timeoutMilliseconds);

    try {
        const response = await fetch(providerRequest.url, {
            method: providerRequest.method || 'POST',
            headers: providerRequest.headers,
            body: providerRequest.body,
            signal: abortController.signal,
            redirect: 'manual', // Never forward provider credentials to a redirect target.
        });
        const responseText = await response.text();
        return { response, responseText };
    } catch {
        const error = new Error('provider request failed');
        error.name = timedOut ? 'TimeoutError' : 'Error';
        throw error;
    } finally {
        clearTimeout(timeoutTimer);
    }
}

const failBody = (providerId, channel, reason, dispatch, requestId) =>
    ({ status: 'failed', outcome: OUTCOME.FAIL, provider: providerId, channel, reason, correlationId: dispatch.correlationId, messageId: dispatch.messageId, requestId });

async function sendViaProvider(providerEntry, dispatch, options) {
    const { requestId, config } = options;
    const { manifest, adapter } = providerEntry;
    const providerId = manifest.id;
    const channel = dispatch.channel === undefined ? 'sms'
        : (typeof dispatch.channel === 'string' ? dispatch.channel.toLowerCase() : null);

    if (!['sms', 'voice'].includes(channel)) {
        return { httpStatus: 400, body: { status: 'error', reason: 'unsupported channel', requestId } };
    }
    if (config.providerChannel && config.providerChannel !== channel) {
        return { httpStatus: 400, body: { status: 'error', provider: providerId, reason: 'channel not configured', requestId } };
    }
    if (config.providerAuthMode && config.providerAuthMode !== manifest.auth?.mode) {
        return { httpStatus: 502, body: failBody(providerId, channel, 'provider authentication mismatch', dispatch, requestId) };
    }

    if (channel === 'voice' && manifest.requiresTextToVoice
        && (!(dispatch.textToVoice instanceof TextToVoice) || !dispatch.textToVoice.isComplete)) {
        return { httpStatus: 400, body: failBody(providerId, channel, 'incomplete voice context', dispatch, requestId) };
    }

    const endpointBaseUrl = config.providerEndpoint;
    if (!isValidProviderUrl(endpointBaseUrl)) {
        return { httpStatus: 502, body: failBody(providerId, channel, 'provider endpoint missing or invalid', dispatch, requestId) };
    }

    let credential = null;
    try {
        credential = await resolveProviderCredential(manifest.auth, config);
    } catch {
        // Configuration and secret lookup failures share a generic failure response.
    }
    const identityRequired = credential?.mode === 'apiKey' && !!manifest.auth?.identityKeyVaultSecretName;
    const credentialUnavailable = !credential
        || (credential.mode === 'apiKey' && (!credential.secret || (identityRequired && !credential.identity)))
        || (credential.mode === 'oauth' && !credential.accessToken);
    if (credentialUnavailable) {
        return { httpStatus: 502, body: failBody(providerId, channel, 'provider credential unavailable', dispatch, requestId) };
    }

    let providerRequest;
    try {
        providerRequest = adapter.buildRequest({
            channel,
            endpoint: endpointBaseUrl,
            dispatch,
            credential,
            env: config.env,
        });
    } catch {
        return { httpStatus: 502, body: failBody(providerId, channel, 'provider request failed', dispatch, requestId) };
    }

    if (!isValidProviderUrl(providerRequest.url)) {
        return { httpStatus: 502, body: failBody(providerId, channel, 'provider request URL invalid', dispatch, requestId) };
    }

    const timeoutMilliseconds = parseProviderTimeout(config.providerTimeoutMs);
    let providerResponse;
    let responseText;
    try {
        ({ response: providerResponse, responseText } = await fetchWithTimeout(providerRequest, timeoutMilliseconds));
    } catch (error) {
        const isTimeout = error.name === 'TimeoutError';
        const httpStatus = isTimeout ? 504 : 502;
        return { httpStatus, body: failBody(providerId, channel, isTimeout ? 'provider request timed out' : 'provider request failed', dispatch, requestId) };
    }

    let responseJson;
    try {
        responseJson = JSON.parse(responseText);
    } catch {
        responseJson = {};
    }

    const parsedResponse = adapter.parseResponse({
        httpStatus: providerResponse.status,
        ok: providerResponse.ok,
        json: responseJson,
    });
    const outcome = resolveOutcome(manifest, parsedResponse);
    const httpStatus = outcomeToHttpStatus(outcome, parsedResponse.providerHttpStatus);

    return {
        httpStatus,
        body: {
            status: outcome === OUTCOME.CONTINUE ? 'accepted' : 'failed',
            outcome,
            provider: providerId,
            channel,
            messageId: dispatch.messageId,
            correlationId: dispatch.correlationId,
            requestId,
        },
    };
}

async function dispatchOtp(dispatch, { config = readConfig(), requestId } = {}) {
    const providerEntry = getProvider(config.providerName);
    if (!providerEntry) {
        return {
            httpStatus: 400,
            body: { status: 'error', reason: 'unknown provider', requestId },
        };
    }
    return sendViaProvider(providerEntry, dispatch, { config, requestId });
}

module.exports = {
    parseEnvelope,
    decryptDeliveryContext,
    contextToDispatch,
    MODE,
    dispatchOtp,
    getProvider,
    resolveOutcome,
    outcomeToHttpStatus,
    parseProviderTimeout,
    isValidProviderUrl,
    resolveProviderCredential,
};
