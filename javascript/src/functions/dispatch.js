// <copyright file="dispatch.js" company="Microsoft Corporation">
// Copyright (c) Microsoft Corporation. All rights reserved.
// </copyright>

'use strict';

const crypto = require('crypto');
const { compactDecrypt } = require('jose');
const { ManagedIdentityCredential } = require('@azure/identity');
const { SecretClient } = require('@azure/keyvault-secrets');
const { readConfig, parseProviderTimeout, isValidProviderUrl } = require('./config');
const { DeliveryContext, TextToVoice } = require('./models');
const { ProviderTokenAcquirer, isSafeBearerToken } = require('./providerToken');

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
        textToVoice: context.textToVoice ?? null,
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

async function resolveSecretValue(keyVaultSecretName, config, options) {
    if (!keyVaultSecretName) {
        return '';
    }
    const cacheKey = JSON.stringify([config.keyVaultUrl, config.managedIdentityClientId, keyVaultSecretName]);
    const cachedSecret = secretCache.get(cacheKey);
    if (cachedSecret && cachedSecret.expiresAt > Date.now()) {
        return cachedSecret.value;
    }

    const secretValue = (await getKeyVaultSecretClient(config).getSecret(keyVaultSecretName, options)).value || '';

    secretCache.set(cacheKey, {
        value: secretValue,
        expiresAt: Date.now() + SECRET_CACHE_TIME_TO_LIVE_MILLISECONDS,
    });
    return secretValue;
}

const providerTokenAcquirer = new ProviderTokenAcquirer({ resolveSecretValue });

async function resolveProviderCredential(manifest, config) {
    const { providerAuthMode: mode = 'apiKey', providerJwtEnabled: jwtEnabled = false } = config;
    if (!['apiKey', 'oauth2'].includes(mode) || typeof jwtEnabled !== 'boolean'
        || (mode === 'oauth2' && !jwtEnabled) || (jwtEnabled && manifest.supportsOAuth !== true)) {
        throw new Error('unsupported provider authentication');
    }

    const credential = { mode, secret: '', identity: '', token: null };
    if (mode === 'apiKey') {
        const auth = manifest.auth || {};
        [credential.secret, credential.identity] = await Promise.all([
            resolveSecretValue(auth.keyVaultSecretName, config),
            resolveSecretValue(auth.identityKeyVaultSecretName, config),
        ]);
        const isValidCredential = manifest.supportsOAuth === true ? isSafeBearerToken : Boolean;
        if (!isValidCredential(credential.secret)
            || (auth.identityKeyVaultSecretName && !isValidCredential(credential.identity))) {
            throw new Error('provider credential unavailable');
        }
    }
    if (jwtEnabled) {
        try {
            const token = await providerTokenAcquirer.acquire(config);
            if (!isSafeBearerToken(token)) throw new Error('provider token unavailable');
            credential.token = token;
        } catch (error) {
            if (mode === 'oauth2') throw error;
            // API-key authentication remains usable; never log token acquisition failures.
        }
    }
    return credential;
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

    if (channel === 'voice' && manifest.requiresTextToVoice === true
        && (!(dispatch.textToVoice instanceof TextToVoice) || !dispatch.textToVoice.isComplete)) {
        return { httpStatus: 400, body: failBody(providerId, channel, 'incomplete voice context', dispatch, requestId) };
    }

    const endpointBaseUrl = config.providerEndpoint;
    if (!isValidProviderUrl(endpointBaseUrl)) {
        return { httpStatus: 502, body: failBody(providerId, channel, 'provider endpoint missing or invalid', dispatch, requestId) };
    }

    let providerRequest;
    try {
        const credential = await resolveProviderCredential(manifest, config);
        providerRequest = adapter.buildRequest({ channel, endpoint: endpointBaseUrl, dispatch, credential, env: config.env });
    } catch (error) {
        if (config.providerAuthMode === 'oauth2' && error?.name === 'TimeoutError') {
            return { httpStatus: 504, body: failBody(providerId, channel, 'provider authentication timed out', dispatch, requestId) };
        }
        // Configuration and secret lookup failures share a generic failure response.
        return { httpStatus: 502, body: failBody(providerId, channel, 'provider credential unavailable', dispatch, requestId) };
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
};
