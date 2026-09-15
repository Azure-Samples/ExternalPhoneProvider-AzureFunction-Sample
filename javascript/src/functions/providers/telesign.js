// <copyright file="telesign.js" company="Microsoft Corporation">
// Copyright (c) Microsoft Corporation. All rights reserved.
// </copyright>

'use strict';

const { ParsedResponse } = require('../models');

const manifest = {
    id: 'telesign',
    auth: {
        mode: 'apiKey',
        keyVaultSecretName: 'telesign-api-key',
        identityKeyVaultSecretName: 'telesign-customer-id',
    },
    // SMS: 200/203 delivered, 290/291/292 in progress. Voice: 100 answered, 101/102/103 placed/ringing/in progress.
    responseMapping: {
        200: 'Continue',
        203: 'Continue',
        290: 'Continue',
        291: 'Continue',
        292: 'Continue',
        100: 'Continue',
        101: 'Continue',
        102: 'Continue',
        103: 'Continue',
        3001: 'Continue',
        default: 'Fail',
    },
};

function buildRequest({ channel, endpoint, dispatch, credential }) {
    if (!['sms', 'voice'].includes(channel)) throw new Error('unsupported channel');
    if (typeof dispatch.destination !== 'string' || !/^\+[1-9][0-9]{1,14}$/.test(dispatch.destination)
        || dispatch.destination.trim() !== dispatch.destination) {
        throw new Error('invalid recipient');
    }
    const authorization = `Basic ${Buffer.from(`${credential.identity}:${credential.secret}`).toString('base64')}`;
    const correlationId = typeof dispatch.correlationId === 'string' && dispatch.correlationId
        ? dispatch.correlationId : dispatch.messageId;
    const message = { text: dispatch.message };
    if (typeof dispatch.locale === 'string' && dispatch.locale.trim()) message.language = dispatch.locale;
    return {
        url: `${endpoint.replace(/\/+$/, '')}/integration/msft/cyot`,
        method: 'POST',
        headers: {
            Authorization: authorization,
            'Content-Type': 'application/json',
            Accept: 'application/json',
        },
        body: JSON.stringify({
            recipient: { phone_number: dispatch.destination },
            message,
            channels: [{ channel }],
            correlation_id: correlationId,
        }),
    };
}

function parseResponse({ httpStatus, ok, json }) {
    const status = (json && json.status) || {};
    return new ParsedResponse({
        success: ok,
        providerHttpStatus: httpStatus,
        providerMessageId: typeof json?.reference_id === 'string' ? json.reference_id : null,
        providerStatusCode: Number.isInteger(status.code) ? String(status.code) : 'UNKNOWN',
        providerStatusDescription: typeof status.description === 'string' ? status.description : null,
    });
}

module.exports = { manifest, buildRequest, parseResponse };
