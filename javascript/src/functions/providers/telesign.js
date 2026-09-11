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
        default: 'Fail',
    },
};

function buildRequest({ channel, endpoint, dispatch, credential, env }) {
    const base = endpoint;
    const contentType = 'application/x-www-form-urlencoded';
    const authorization = `Basic ${Buffer.from(`${credential.identity}:${credential.secret}`).toString('base64')}`;

    let path;
    let params;
    if (channel === 'voice') {
        path = '/v1/voice';
        params = new URLSearchParams({
            phone_number: dispatch.destination,
            message: dispatch.message,
            message_type: 'OTP',
            voice: env.TELESIGN_VOICE || 'f-en-US',
            external_id: dispatch.correlationId || dispatch.messageId,
        });
    } else {
        path = '/v1/messaging';
        params = new URLSearchParams({
            phone_number: dispatch.destination,
            message: dispatch.message,
            sender_id: env.EPP_PROVIDER_ACCOUNT_NAME || '',
            message_type: 'OTP',
            external_id: dispatch.correlationId || dispatch.messageId,
            is_primary: 'true',
        });
    }

    return {
        url: `${base}${path}`,
        method: 'POST',
        headers: {
            Authorization: authorization,
            'Content-Type': contentType,
            Accept: 'application/json',
        },
        body: params.toString(),
    };
}

function parseResponse({ httpStatus, ok, json }) {
    const payload = json && typeof json === 'object' && !Array.isArray(json) ? json : {};
    const status = payload.status && typeof payload.status === 'object' && !Array.isArray(payload.status) ? payload.status : {};
    const code = status.code;
    return new ParsedResponse({
        success: ok,
        providerHttpStatus: httpStatus,
        providerMessageId: payload.reference_id || null,
        providerStatusCode: typeof code === 'number' || (typeof code === 'string' && code.trim()) ? String(code) : 'UNKNOWN',
    });
}

module.exports = { manifest, buildRequest, parseResponse };
