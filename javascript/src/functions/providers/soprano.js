// <copyright file="soprano.js" company="Microsoft Corporation">
// Copyright (c) Microsoft Corporation. All rights reserved.
// </copyright>

'use strict';

// Soprano Connect (MEMS): POST {base}/messages/omnimsg, base https://<mems_domain>/cgpapi.
// One endpoint for every channel — `messageTypes` picks it and Soprano does the TTS for voice.
// Auth: an Entra ID v2.0 Bearer JWT (audience = Soprano's app id), or X-MEMS-API-ID + X-MEMS-API-Key.

const manifest = {
    id: 'soprano',
    auth: {
        mode: 'apiKey',
        keyVaultSecretName: 'soprano-api-key',
        identityKeyVaultSecretName: 'soprano-api-id',
    },
    responseMapping: {
        ENROUTE: 'Continue',
        ACCEPTED: 'Continue',
        SUBMITTED: 'Continue',
        SENT: 'Continue',
        DELIVERED: 'Continue',
        QUEUED: 'Continue',
        // Accepted (HTTP 201) but stopped by an account/destination filter — nothing was delivered.
        FILTERED: 'Fail',
        FAILED: 'Fail',
        REJECTED: 'Fail',
        BLOCKED: 'Block',
        default: 'Fail',
    },
};

function buildRequest({ channel, endpoint, dispatch, credential, env }) {
    const headers = { 'Content-Type': 'application/json', Accept: 'application/json' };
    if (credential.mode === 'oauth2') {
        headers.Authorization = `Bearer ${credential.token}`;
    } else {
        headers['X-MEMS-API-ID'] = credential.identity;
        headers['X-MEMS-API-Key'] = credential.secret;
    }

    const body = {
        text: dispatch.message,
        destination: String(dispatch.destination || '').replace(/^\++/, ''), // E.164 without the leading +
        messageTypes: [channel === 'voice' ? 'voice' : 'sms'],
        correlationId: dispatch.correlationId || dispatch.messageId,
        // Soprano processes the request but delivers nothing — connectivity/credential testing.
        shutterMode: String(env.SOPRANO_SHUTTER_MODE || '').toLowerCase() === 'true',
    };

    return { url: `${endpoint}/messages/omnimsg`, method: 'POST', headers, body: JSON.stringify(body) };
}

function parseResponse({ httpStatus, ok, json }) {
    const payload = (Array.isArray(json) ? json[0] : json) || {};
    const status = (payload.status || payload.state || '').toString().toUpperCase() || (ok ? 'SUBMITTED' : null);
    return {
        success: ok,
        providerHttpStatus: httpStatus,
        providerMessageId: (payload.id != null ? String(payload.id) : null) || payload.messageId || null,
        providerStatusName: status,
        providerStatusDescription: payload.errorDescription || payload.statusText || payload.description || null,
    };
}

module.exports = { manifest, buildRequest, parseResponse };
