// <copyright file="soprano.js" company="Microsoft Corporation">
// Copyright (c) Microsoft Corporation. All rights reserved.
// </copyright>

'use strict';

// Omnimsg handles SMS and voice; authentication can use API ID/key or a provider JWT.

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

    let destination = String(dispatch.destination || '');
    while (destination.startsWith('+')) destination = destination.slice(1);

    const body = {
        text: dispatch.message,
        destination,
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
