// <copyright file="sinch.js" company="Microsoft Corporation">
// Copyright (c) Microsoft Corporation. All rights reserved.
// </copyright>

'use strict';

const { ParsedResponse } = require('../models');

// A batch identifier indicates acceptance, not final delivery; delivery status arrives by callback.

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
    const headers = {
        Authorization: `Bearer ${credential.secret}`,
        'Content-Type': 'application/json',
        Accept: 'application/json',
    };

    if (channel === 'voice') {
        // Voice uses a separate host; verify that its authentication accepts the configured credential.
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
    return new ParsedResponse({
        success: ok,
        providerHttpStatus: httpStatus,
        providerMessageId: typeof messageOrCallId === 'string' ? messageOrCallId : (messageOrCallId && messageOrCallId.href) || null,
        providerStatusName: ok ? 'Dispatched' : (json && (json.text || json.status)) || null,
    });
}

module.exports = { manifest, buildRequest, parseResponse };
