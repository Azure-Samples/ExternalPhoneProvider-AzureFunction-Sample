// <copyright file="dispatch.js" company="Microsoft Corporation">
// Copyright (c) Microsoft Corporation. All rights reserved.
// </copyright>

'use strict';

// Delivery pipeline for the External Phone Provider sample.
//
// Given a request from Microsoft Entra's SAS service, this module parses the cleartext routing
// envelope, decrypts the JWE that carries the phone number and the rendered passcode message, then
// hands off to the configured SMS/voice provider adapter (Infobip, Telesign, Sinch, or Soprano).
// It is fail-closed: only a provider "Continue" outcome returns success; every other case fails.

const crypto = require('crypto');
const { compactDecrypt } = require('jose');
const { ManagedIdentityCredential, ClientSecretCredential, ClientAssertionCredential } = require('@azure/identity');
const { SecretClient } = require('@azure/keyvault-secrets');
const { readConfig } = require('./config');

const ENVELOPE_TYPE = 'microsoft.mfa.otpDeliver.v1';
// Channel: 1=sms, 2=voice. Mode: 1=live (deliver), 2=evaluation (do not deliver).
const CHANNEL_BY_CODE = Object.freeze({ 1: 'sms', 2: 'voice' });
const CHANNEL_BY_NAME = Object.freeze({ sms: 1, voice: 2 });
const MODE = Object.freeze({ LIVE: 1, EVALUATION: 2 });
const MODE_BY_NAME = Object.freeze({ live: 1, evaluation: 2 });
const MAX_PROVIDER_TIMEOUT_MILLISECONDS = 2500;

function normalizeChannel(channel) {
    if (channel === 1 || channel === 2) return channel;
    if (typeof channel === 'string' && Object.hasOwn(CHANNEL_BY_NAME, channel.toLowerCase())) return CHANNEL_BY_NAME[channel.toLowerCase()];
    return null;
}
function normalizeMode(mode) {
    if (mode === MODE.LIVE || mode === MODE.EVALUATION) return mode;
    if (typeof mode === 'string' && Object.hasOwn(MODE_BY_NAME, mode.toLowerCase())) return MODE_BY_NAME[mode.toLowerCase()];
    return null;
}

function parseEnvelope(payload) {
    if (!payload || typeof payload !== 'object' || Array.isArray(payload)) {
        return { error: 'invalid envelope' };
    }
    const { type, tenantId, correlationId, channel, mode, ttlSeconds, encryptedDeliveryContext } = payload;
    if (type !== ENVELOPE_TYPE) {
        return { error: `unsupported type '${type}'` };
    }
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
    if (ttlSeconds !== undefined && !Number.isInteger(ttlSeconds)) {
        return { error: 'ttlSeconds must be a positive integer' };
    }
    if (ttlSeconds !== undefined && ttlSeconds <= 0) {
        return { error: 'passcode has expired' };
    }
    return { envelope: { type, tenantId, correlationId, channel: channelCode, mode: modeCode, ttlSeconds, encryptedDeliveryContext } };
}

function normalizeProviderTimeoutMilliseconds(value) {
    const parsed = Number(value);
    return Number.isInteger(parsed) && parsed > 0
        ? Math.min(parsed, MAX_PROVIDER_TIMEOUT_MILLISECONDS)
        : DEFAULTS.ENDPOINT_TIMEOUT_MILLISECONDS;
}

function isValidProviderEndpoint(value) {
    try {
        return new URL(value).protocol === 'https:';
    } catch {
        return false;
    }
}


// Reject oversized or malformed input before allocating buffers to decode it.
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

// Cache the imported key: re-importing RSA on every delivery would eat the response budget.
let cachedKey;
let cachedKeyPem;

// The key may arrive as a PEM or as base64 over the PEM (the setup script uses base64 so newlines
// survive being stored as an app setting); accept either form.
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

// Pin alg/enc so a tampered header cannot downgrade the encryption.
async function decryptDeliveryContext(compactJwe, config = readConfig()) {
    assertWellFormedJwe(compactJwe);
    const header = readProtectedHeader(compactJwe);
    const privateKey = loadPrivateKey(config.decryptionKeyPem);
    const { plaintext } = await compactDecrypt(compactJwe, privateKey, {
        keyManagementAlgorithms: ['RSA-OAEP-256'],
        contentEncryptionAlgorithms: ['A256GCM'],
    });
    return { header, context: JSON.parse(Buffer.from(plaintext).toString('utf8')) };
}

// Space out the passcode digits so text-to-speech reads "6 4 1 8 9 5" rather than "641,895".
function spacePasscodeForVoice(message) {
    return String(message || '').replace(/\b\d{4,8}\b/, (digits) => digits.split('').join(' '));
}

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

// Rotated secrets are picked up within this window.
const SECRET_CACHE_TIME_TO_LIVE_MILLISECONDS = 5 * 60 * 1000;

// Add a provider by writing an adapter module and listing it here; a broken adapter fails at load.
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

function resolveProvider(requestProvider) {
    return getProvider(requestProvider || process.env.EPP_PROVIDER_NAME);
}

// Secrets are resolved from Key Vault by name, cached briefly, and never logged.
let keyVaultSecretClient = null;
const secretCache = new Map();

// The function's managed identity needs the Key Vault Secrets User role on the vault.
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

// Provider auth in oauth2 mode: mint our own app-only Entra JWT (client-credentials) for the
// provider's API and send it as a Bearer token, never the caller's inbound token. Issuer is our app,
// audience is the provider's app (the scope).
const OAUTH_TOKEN_EXPIRY_SKEW_MILLISECONDS = 5 * 60 * 1000;
const DEFAULT_TOKEN_EXCHANGE_AUDIENCE = 'api://AzureADTokenExchange';
let cachedProviderToken = null;

function oauthModeEnabled(authConfiguration) {
    const mode = (process.env.EPP_PROVIDER_AUTH_MODE || authConfiguration.mode || 'apiKey').toLowerCase();
    return mode === 'oauth2';
}

// EPP_PROVIDER_MI_CLIENT_ID selects secretless workload-identity federation; else fall back to a secret.
function buildFederatedCredential(tenantId, clientId) {
    const managedIdentityClientId = process.env.EPP_PROVIDER_MI_CLIENT_ID;
    if (!managedIdentityClientId) {
        return null;
    }
    const managedIdentity = new ManagedIdentityCredential(managedIdentityClientId);
    const audience = process.env.EPP_PROVIDER_TOKEN_EXCHANGE_AUDIENCE || DEFAULT_TOKEN_EXCHANGE_AUDIENCE;
    const exchangeScope = audience.endsWith('/.default') ? audience : `${audience}/.default`;
    return new ClientAssertionCredential(tenantId, clientId, async () => {
        const assertion = await managedIdentity.getToken(exchangeScope);
        return assertion.token;
    });
}

async function acquireProviderTokenFromEntra() {
    const tenantId = process.env.EPP_PROVIDER_TENANT_ID;
    const clientId = process.env.EPP_PROVIDER_CLIENT_ID;
    const scope = process.env.EPP_PROVIDER_SCOPE;
    if (!tenantId || !clientId || !scope) {
        throw new Error('oauth2 requires EPP_PROVIDER_TENANT_ID, EPP_PROVIDER_CLIENT_ID and EPP_PROVIDER_SCOPE');
    }
    const cacheKey = `${tenantId}|${clientId}|${scope}`;
    if (cachedProviderToken
        && cachedProviderToken.cacheKey === cacheKey
        && cachedProviderToken.expiresAt - OAUTH_TOKEN_EXPIRY_SKEW_MILLISECONDS > Date.now()) {
        return cachedProviderToken.value;
    }

    let credential = buildFederatedCredential(tenantId, clientId);
    if (!credential) {
        const clientSecret = process.env.EPP_PROVIDER_CLIENT_SECRET
            || (process.env.EPP_PROVIDER_CLIENT_SECRET_NAME ? await resolveSecretValue(process.env.EPP_PROVIDER_CLIENT_SECRET_NAME) : '');
        if (!clientSecret) {
            throw new Error('oauth2 requires EPP_PROVIDER_MI_CLIENT_ID (managed identity) or EPP_PROVIDER_CLIENT_SECRET_NAME');
        }
        credential = new ClientSecretCredential(tenantId, clientId, clientSecret);
    }

    const accessToken = await credential.getToken(scope);
    if (!accessToken || !accessToken.token) {
        throw new Error('oauth2 token acquisition returned no token');
    }
    cachedProviderToken = {
        value: accessToken.token,
        expiresAt: accessToken.expiresOnTimestamp || (Date.now() + 55 * 60 * 1000),
        cacheKey,
    };
    return cachedProviderToken.value;
}

async function resolveProviderCredential(authConfiguration = {}) {
    if (oauthModeEnabled(authConfiguration)) {
        const bearerToken = await acquireProviderTokenFromEntra();
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

// An HTTP failure must never become acceptance based on a success-looking body.
function resolveOutcome(manifest, parsedResponse) {
    const responseMapping = manifest.responseMapping || {};
    const providerStatusKey = parsedResponse.providerStatusName || parsedResponse.providerStatusCode;
    if (providerStatusKey) {
        const outcome = Object.hasOwn(responseMapping, providerStatusKey)
            ? responseMapping[providerStatusKey] : (responseMapping.default || OUTCOME.FAIL);
        return outcome === OUTCOME.CONTINUE && !parsedResponse.success ? OUTCOME.FAIL : outcome;
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
        const response = await fetch(providerRequest.url, {
            method: providerRequest.method || 'POST',
            headers: providerRequest.headers,
            body: providerRequest.body,
            signal: abortController.signal,
        });
        const responseText = await response.text();
        return { response, responseText };
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

    if (shutter) {
        writeLog(`[SHUTTER] requestId=${requestId} provider=${providerId} channel=${channel} processed but NOT sending`);
        return {
            httpStatus: HTTP_STATUS.OK,
            body: { status: RESPONSE_STATUS.ACCEPTED, shutterProcessed: true, provider: providerId, channel, correlationId: dispatch.correlationId, messageId: dispatch.messageId, requestId },
        };
    }

    let credential = null;
    try {
        credential = await resolveProviderCredential(manifest.auth);
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
    if (!isValidProviderEndpoint(endpointBaseUrl)) {
        writeLog(`[DISPATCH_ERROR] requestId=${requestId} provider=${providerId} channel=${channel} endpoint not configured`);
        return { httpStatus: HTTP_STATUS.BAD_GATEWAY, body: failBody(providerId, channel, 'provider endpoint must be an absolute HTTPS URL', dispatch, requestId) };
    }

    const providerRequest = adapter.buildRequest({
        channel,
        endpoint: endpointBaseUrl,
        dispatch,
        credential,
        env: process.env,
    });
    if (!isValidProviderEndpoint(providerRequest.url)) {
        writeLog(`[DISPATCH_ERROR] requestId=${requestId} provider=${providerId} channel=${channel} request URL is not HTTPS`);
        return { httpStatus: HTTP_STATUS.BAD_GATEWAY, body: failBody(providerId, channel, 'provider request URL must be absolute HTTPS', dispatch, requestId) };
    }

    writeLog(`[DISPATCH] requestId=${requestId} provider=${providerId} channel=${channel} correlationId=${dispatch.correlationId} shutter=${!!shutter}`);

    const timeoutMilliseconds = normalizeProviderTimeoutMilliseconds(process.env.EPP_PROVIDER_TIMEOUT_MS);
    let providerResult;
    try {
        providerResult = await fetchWithTimeout(providerRequest, timeoutMilliseconds);
    } catch (error) {
        const isTimeout = typeof error.message === 'string' && error.message.startsWith('endpoint timeout');
        const httpStatus = isTimeout ? HTTP_STATUS.GATEWAY_TIMEOUT : HTTP_STATUS.BAD_GATEWAY;
        writeLog(`[${isTimeout ? 'DISPATCH_TIMEOUT' : 'DISPATCH_ERROR'}] requestId=${requestId} provider=${providerId} channel=${channel} reason=${error.message}`);
        const reason = isTimeout ? `endpoint timeout after ${timeoutMilliseconds}ms` : 'provider request failed';
        return { httpStatus, body: failBody(providerId, channel, reason, dispatch, requestId) };
    }

    const { response: providerResponse, responseText } = providerResult;
    let responseJson;
    try {
        responseJson = JSON.parse(responseText);
    } catch {
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
    isValidProviderEndpoint,
    normalizeProviderTimeoutMilliseconds,
};
