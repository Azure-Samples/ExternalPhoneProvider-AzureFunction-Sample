// <copyright file="dispatch.js" company="Microsoft Corporation">
// Copyright (c) Microsoft Corporation. All rights reserved.
// </copyright>

'use strict';

// Delivery pipeline: parse the cleartext SAS envelope, decrypt the JWE that carries the PII, then
// dispatch to the configured provider. Fail-closed — only a Continue outcome is "accepted".

const crypto = require('crypto');
const { compactDecrypt } = require('jose');
const { ManagedIdentityCredential } = require('@azure/identity');
const { SecretClient } = require('@azure/keyvault-secrets');
const { readConfig } = require('./config');

// CyotChannel: 1=Sms, 2=Voice. CyotDeliveryMode: 1=Live, 2=Evaluation (do NOT deliver).
const CHANNEL_BY_CODE = Object.freeze({ 1: 'sms', 2: 'voice' });
const CHANNEL_BY_NAME = Object.freeze({ sms: 1, voice: 2 });
const MODE = Object.freeze({ LIVE: 1, EVALUATION: 2 });
const MODE_BY_NAME = Object.freeze({ live: 1, evaluation: 2 });

// channel/mode accept the int enum (1/2) or the string form ("sms"/"voice", "live"/"evaluation").
function normalizeChannel(channel) {
    if (CHANNEL_BY_CODE[channel]) return Number(channel);
    if (typeof channel === 'string' && CHANNEL_BY_NAME[channel.toLowerCase()]) return CHANNEL_BY_NAME[channel.toLowerCase()];
    return null;
}
function normalizeMode(mode) {
    if (mode === MODE.LIVE || mode === MODE.EVALUATION) return mode;
    if (typeof mode === 'string' && MODE_BY_NAME[mode.toLowerCase()]) return MODE_BY_NAME[mode.toLowerCase()];
    return null;
}

function parseEnvelope(payload) {
    if (!payload || typeof payload !== 'object') {
        return { error: 'invalid envelope' };
    }
    const { type, tenantId, correlationId, channel, mode, ttlSeconds, encryptedDeliveryContext } = payload;
    if (typeof encryptedDeliveryContext !== 'string' || !encryptedDeliveryContext) {
        return { error: 'encryptedDeliveryContext is required' };
    }
    const channelCode = normalizeChannel(channel);
    if (!channelCode) {
        return { error: `unsupported channel '${channel}'` };
    }
    const modeCode = normalizeMode(mode);
    if (!modeCode) {
        return { error: `unsupported mode '${mode}'` };
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

// Imported once: a per-delivery RSA import would sit inside the response budget.
let cachedKey;
let cachedKeyPem;

// The setup script stores the key as base64 over the PEM so its newlines survive being carried as an
// app setting, so accept either form.
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

// Decrypts the JWE compact serialization. Returns the protected header (for kid/alg logging) alongside
// the CyotDeliveryContext.
async function decryptDeliveryContext(compactJwe, config = readConfig()) {
    assertWellFormedJwe(compactJwe);
    const header = readProtectedHeader(compactJwe);
    const privateKey = loadPrivateKey(config.decryptionKeyPem);
    // Pin alg/enc so a tampered header can't downgrade the crypto.
    const { plaintext } = await compactDecrypt(compactJwe, privateKey, {
        keyManagementAlgorithms: ['RSA-OAEP-256'],
        contentEncryptionAlgorithms: ['A256GCM'],
    });
    return { header, context: JSON.parse(Buffer.from(plaintext).toString('utf8')) };
}

// Left alone, TTS reads 641895 as "six hundred forty-one thousand...", which no user can type.
function spacePasscodeForVoice(message) {
    return String(message || '').replace(/\b\d{4,8}\b/, (digits) => digits.split('').join(' '));
}

// The message is pre-rendered and already contains the passcode, so there is no separate code field.
function contextToDispatch(context, envelope, messageId) {
    const channel = CHANNEL_BY_CODE[envelope.channel];
    return {
        destination: context.phoneNumber,
        message: channel === 'voice' ? spacePasscodeForVoice(context.message) : context.message,
        channel,
        messageId,
        correlationId: envelope.correlationId,
        locale: context.locale || undefined,
    };
}


const OUTCOME = Object.freeze({
    CONTINUE: 'Continue',
    FAIL: 'Fail',
    BLOCK: 'Block',
    STEP_UP: 'StepUp',
});

const HTTP_STATUS = Object.freeze({
    OK: 200,
    BAD_REQUEST: 400,
    UNAUTHORIZED: 401,
    FORBIDDEN: 403,
    CONFLICT: 409,
    TOO_MANY_REQUESTS: 429,
    BAD_GATEWAY: 502,
    GATEWAY_TIMEOUT: 504,
});

const RESPONSE_STATUS = Object.freeze({
    ACCEPTED: 'accepted',
    FAILED: 'failed',
    ERROR: 'error',
});

const DEFAULTS = Object.freeze({
    CHANNEL: 'sms',
    ENDPOINT_TIMEOUT_MILLISECONDS: 1500,
    CHANNELS: ['sms', 'voice'],
});

const SECRET_CACHE_TIME_TO_LIVE_MILLISECONDS = 5 * 60 * 1000; // rotated secrets picked up within this window

// Onboarding a provider is a new file plus one line here — static, so a broken provider fails at load.
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
    return providerId ? providerRegistry.get(String(providerId).toLowerCase()) || null : null;
}

// One provider is active per deployment; the argument is a test override.
function resolveProvider(requestProvider) {
    return getProvider(requestProvider || process.env.EPP_PROVIDER_NAME);
}

// The manifest carries only the secret's name; the value is read just-in-time and never logged.
let keyVaultSecretClient = null;
const secretCache = new Map();

// The identity needs the Key Vault Secrets User role on the vault.
function getKeyVaultSecretClient() {
    if (!keyVaultSecretClient) {
        const credential = process.env.AZURE_CLIENT_ID
            ? new ManagedIdentityCredential(process.env.AZURE_CLIENT_ID)
            : new ManagedIdentityCredential();
        keyVaultSecretClient = new SecretClient(process.env.KEY_VAULT_URL, credential);
    }
    return keyVaultSecretClient;
}

async function resolveSecretValue(keyVaultSecretName) {
    if (!keyVaultSecretName) {
        return '';
    }
    const cachedSecret = secretCache.get(keyVaultSecretName);
    if (cachedSecret && cachedSecret.expiresAt > Date.now()) {
        return cachedSecret.value;
    }

    const secretValue = (await getKeyVaultSecretClient().getSecret(keyVaultSecretName)).value || '';

    secretCache.set(keyVaultSecretName, {
        value: secretValue,
        expiresAt: Date.now() + SECRET_CACHE_TIME_TO_LIVE_MILLISECONDS,
    });
    return secretValue;
}

async function resolveProviderCredential(authConfiguration = {}, acquireProviderToken) {
    if ((authConfiguration.mode || 'apiKey') === 'oauth2') {
        // oauth2 is not wired end-to-end yet: with no injected acquireProviderToken it fails closed.
        const bearerToken = typeof acquireProviderToken === 'function' ? await acquireProviderToken() : null;
        return { mode: 'oauth2', token: bearerToken };
    }

    const [secret, identity] = await Promise.all([
        resolveSecretValue(authConfiguration.keyVaultSecretName),
        authConfiguration.identityKeyVaultSecretName
            ? resolveSecretValue(authConfiguration.identityKeyVaultSecretName)
            : Promise.resolve(''),
    ]);
    return { mode: 'apiKey', secret, identity };
}

// A recognized status wins; an unknown status is fail-closed; only a status-less response trusts HTTP.
function resolveOutcome(manifest, parsedResponse) {
    const responseMapping = manifest.responseMapping || {};
    const providerStatusKey = parsedResponse.providerStatusName || parsedResponse.providerStatusCode;
    if (providerStatusKey) {
        return responseMapping[providerStatusKey] || responseMapping.default || OUTCOME.FAIL;
    }
    return parsedResponse.success ? OUTCOME.CONTINUE : (responseMapping.default || OUTCOME.FAIL);
}

function outcomeToHttpStatus(outcome, providerHttpStatus) {
    switch (outcome) {
        case OUTCOME.CONTINUE:
            return HTTP_STATUS.OK;
        case OUTCOME.BLOCK:
            return HTTP_STATUS.FORBIDDEN;
        case OUTCOME.STEP_UP:
            return HTTP_STATUS.CONFLICT;
        case OUTCOME.FAIL:
            if (providerHttpStatus === HTTP_STATUS.TOO_MANY_REQUESTS) return HTTP_STATUS.TOO_MANY_REQUESTS;
            if (providerHttpStatus === HTTP_STATUS.UNAUTHORIZED || providerHttpStatus === HTTP_STATUS.FORBIDDEN) return HTTP_STATUS.UNAUTHORIZED;
            if (providerHttpStatus >= 400 && providerHttpStatus < 500) return HTTP_STATUS.BAD_REQUEST;
            return HTTP_STATUS.BAD_GATEWAY;
        default:
            return HTTP_STATUS.BAD_GATEWAY;
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
        return await fetch(providerRequest.url, {
            method: providerRequest.method || 'POST',
            headers: providerRequest.headers,
            body: providerRequest.body,
            signal: abortController.signal,
        });
    } catch (error) {
        throw new Error(timedOut ? `endpoint timeout after ${timeoutMilliseconds}ms` : error.message);
    } finally {
        clearTimeout(timeoutTimer);
    }
}

const errorBody = (providerId, reason, requestId) =>
    ({ status: RESPONSE_STATUS.ERROR, provider: providerId, reason, requestId });
const failBody = (providerId, channel, reason, dispatch, requestId) =>
    ({ status: RESPONSE_STATUS.FAILED, outcome: OUTCOME.FAIL, provider: providerId, channel, reason, correlationId: dispatch.correlationId, messageId: dispatch.messageId, requestId });

async function sendViaProvider(providerEntry, dispatch, options) {
    const { shutter, context, requestId } = options;
    const writeLog = (logMessage) => context && context.log(logMessage);

    const { manifest, adapter } = providerEntry;
    const providerId = manifest.id;
    const channel = (dispatch.channel || DEFAULTS.CHANNEL).toLowerCase();

    if (!DEFAULTS.CHANNELS.includes(channel)) {
        writeLog(`[DISPATCH_ERROR] requestId=${requestId} provider=${providerId} channel=${channel} not supported`);
        return { httpStatus: HTTP_STATUS.BAD_REQUEST, body: errorBody(providerId, `channel '${channel}' not supported`, requestId) };
    }

    // Fail closed (502) if the credential is missing — this is our credential, not the caller's token.
    let credential = null;
    try {
        credential = await resolveProviderCredential(manifest.auth, options.acquireProviderToken);
    } catch (error) {
        writeLog(`[DISPATCH_ERROR] requestId=${requestId} provider=${providerId} channel=${channel} credential error=${error.message}`);
    }
    const identityRequired = credential && credential.mode === 'apiKey' && !!manifest.auth.identityKeyVaultSecretName;
    const credentialUnavailable = !credential
        || (credential.mode === 'oauth2' && !credential.token)
        || (credential.mode === 'apiKey' && !credential.secret)
        || (identityRequired && !credential.identity);
    if (credentialUnavailable) {
        writeLog(`[DISPATCH_ERROR] requestId=${requestId} provider=${providerId} channel=${channel} provider credential unavailable`);
        return { httpStatus: HTTP_STATUS.BAD_GATEWAY, body: failBody(providerId, channel, 'provider credential unavailable', dispatch, requestId) };
    }

    const endpointBaseUrl = process.env.EPP_PROVIDER_ENDPOINT;
    if (!endpointBaseUrl) {
        writeLog(`[DISPATCH_ERROR] requestId=${requestId} provider=${providerId} channel=${channel} endpoint not configured`);
        return { httpStatus: HTTP_STATUS.BAD_GATEWAY, body: failBody(providerId, channel, 'provider endpoint not configured', dispatch, requestId) };
    }

    const providerRequest = adapter.buildRequest({
        channel,
        endpoint: endpointBaseUrl,
        dispatch,
        credential,
        env: process.env,
    });

    writeLog(`[DISPATCH] requestId=${requestId} provider=${providerId} channel=${channel} correlationId=${dispatch.correlationId} shutter=${!!shutter}`);

    if (shutter) {
        writeLog(`[SHUTTER] requestId=${requestId} provider=${providerId} channel=${channel} processed but NOT sending`);
        return {
            httpStatus: HTTP_STATUS.OK,
            body: { status: RESPONSE_STATUS.ACCEPTED, shutterProcessed: true, provider: providerId, channel, correlationId: dispatch.correlationId, messageId: dispatch.messageId, requestId },
        };
    }

    const timeoutMilliseconds = Number(process.env.EPP_PROVIDER_TIMEOUT_MS) || DEFAULTS.ENDPOINT_TIMEOUT_MILLISECONDS;
    let providerResponse;
    try {
        providerResponse = await fetchWithTimeout(providerRequest, timeoutMilliseconds);
    } catch (error) {
        const isTimeout = typeof error.message === 'string' && error.message.startsWith('endpoint timeout');
        const httpStatus = isTimeout ? HTTP_STATUS.GATEWAY_TIMEOUT : HTTP_STATUS.BAD_GATEWAY;
        writeLog(`[${isTimeout ? 'DISPATCH_TIMEOUT' : 'DISPATCH_ERROR'}] requestId=${requestId} provider=${providerId} channel=${channel} reason=${error.message}`);
        return { httpStatus, body: failBody(providerId, channel, error.message, dispatch, requestId) };
    }

    const responseText = await providerResponse.text();
    let responseJson;
    try {
        responseJson = JSON.parse(responseText);
    } catch {
        // Keep a non-JSON body raw so the adapter's parseResponse still runs.
        responseJson = { raw: responseText };
    }

    const parsedResponse = adapter.parseResponse({
        httpStatus: providerResponse.status,
        ok: providerResponse.ok,
        json: responseJson,
    });
    const outcome = resolveOutcome(manifest, parsedResponse);
    const httpStatus = outcomeToHttpStatus(outcome, parsedResponse.providerHttpStatus);

    writeLog(`[DISPATCH_RESULT] requestId=${requestId} provider=${providerId} channel=${channel} outcome=${outcome} providerStatus=${parsedResponse.providerStatusName || parsedResponse.providerStatusCode || 'n/a'} httpStatus=${httpStatus} correlationId=${dispatch.correlationId}`);

    return {
        httpStatus,
        body: {
            status: outcome === OUTCOME.CONTINUE ? RESPONSE_STATUS.ACCEPTED : RESPONSE_STATUS.FAILED,
            outcome,
            provider: providerId,
            channel,
            messageId: dispatch.messageId,
            correlationId: dispatch.correlationId,
            providerMessageId: parsedResponse.providerMessageId || null,
            providerStatus: parsedResponse.providerStatusName || parsedResponse.providerStatusCode || null,
            providerStatusDescription: parsedResponse.providerStatusDescription || null,
            requestId,
        },
    };
}

async function dispatchOtp(dispatch, options) {
    const { requestProvider, context, requestId } = options;
    const writeLog = (logMessage) => context && context.log(logMessage);

    const providerEntry = resolveProvider(requestProvider);
    if (!providerEntry) {
        writeLog(`[DISPATCH_ERROR] requestId=${requestId} unknown provider=${requestProvider || 'n/a'}`);
        return {
            httpStatus: HTTP_STATUS.BAD_REQUEST,
            body: { status: RESPONSE_STATUS.ERROR, reason: 'unknown provider', requestId },
        };
    }
    return sendViaProvider(providerEntry, dispatch, options);
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
};
