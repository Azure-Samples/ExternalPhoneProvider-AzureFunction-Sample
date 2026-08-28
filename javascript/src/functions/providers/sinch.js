// <copyright file="sinch.js" company="Microsoft Corporation">
// Copyright (c) Microsoft Corporation. All rights reserved.
// </copyright>

'use strict';

// Sinch: SMS via XMS batches, voice via the Calling TTS callout. XMS returns a batch id, not a final
// delivery status — that arrives asynchronously by callback.

const manifest = {
    id: 'sinch',
    auth: { mode: 'apiKey', keyVaultSecretName: 'sinch-api-token' },
    responseMapping: {
        Dispatched: 'Continue',
        Delivered: 'Continue',
        Queued: 'Continue',
        Failed: 'Fail',
        Rejected: 'Fail',
        default: 'Fail',
    },
};

function buildRequest({ channel, endpoint, dispatch, credential, env }) {
    const bearerToken = credential.mode === 'oauth2' ? credential.token : credential.secret;
    const headers = {
        Authorization: `Bearer ${bearerToken}`,
        'Content-Type': 'application/json',
        Accept: 'application/json',
    };

    if (channel === 'voice') {
        // Sinch Voice uses its own host and normally app-signed auth, not the XMS token — verify.
        const voiceBase = env.SINCH_VOICE_ENDPOINT || 'https://calling.api.sinch.com';
        const body = {
            method: 'ttsCallout',
            ttsCallout: {
                destination: { type: 'number', endpoint: dispatch.destination },
                text: dispatch.message,
                locale: dispatch.locale || 'en-US',
                custom: dispatch.correlationId || dispatch.messageId,
            },
        };
        return { url: `${voiceBase}/calling/v1/callouts`, method: 'POST', headers, body: JSON.stringify(body) };
    }

    const smsBase = endpoint;
    const servicePlanId = env.SINCH_SERVICE_PLAN_ID || '';
    const body = {
        from: env.EPP_PROVIDER_ACCOUNT_NAME || 'Verify',
        to: [dispatch.destination],
        body: dispatch.message,
        client_reference: dispatch.correlationId || dispatch.messageId,
    };
    return { url: `${smsBase}/xms/v1/${servicePlanId}/batches`, method: 'POST', headers, body: JSON.stringify(body) };
}

function parseResponse({ httpStatus, ok, json }) {
    const messageOrCallId = (json && (json.id || json.callId || json._links && json._links.self)) || null;
    return {
        success: ok,
        providerHttpStatus: httpStatus,
        providerMessageId: typeof messageOrCallId === 'string' ? messageOrCallId : (messageOrCallId && messageOrCallId.href) || null,
        providerStatusName: ok ? 'Dispatched' : (json && (json.text || json.status)) || null,
        providerStatusDescription: (json && (json.text || json.detailedStatus)) || null,
    };
}

module.exports = { manifest, buildRequest, parseResponse };
