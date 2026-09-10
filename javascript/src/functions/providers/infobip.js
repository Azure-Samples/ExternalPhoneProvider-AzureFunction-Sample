// <copyright file="infobip.js" company="Microsoft Corporation">
// Copyright (c) Microsoft Corporation. All rights reserved.
// </copyright>

'use strict';

const { ParsedResponse } = require('../models');

// Voice integration is unverified; confirm the request format before production use.

const manifest = {
    id: 'infobip',
    auth: { mode: 'apiKey', keyVaultSecretName: 'infobip-api-key' },
    responseMapping: {
        ACCEPTED: 'Continue',
        PENDING: 'Continue',
        DELIVERED: 'Continue',
        REJECTED: 'Fail',
        EXPIRED: 'Fail',
        UNDELIVERABLE: 'Fail',
        default: 'Fail',
    },
};

function buildRequest({ channel, endpoint, dispatch, credential, env }) {
    const base = endpoint;
    const senderId = env.EPP_PROVIDER_ACCOUNT_NAME || 'Verify';
    const headers = {
        Authorization: `App ${credential.secret}`,
        'Content-Type': 'application/json',
        Accept: 'application/json',
    };

    if (channel === 'voice') {
        const body = {
            messages: [{
                from: senderId,
                destinations: [{ to: dispatch.destination, messageId: dispatch.correlationId || dispatch.messageId }],
                text: dispatch.message,
                language: dispatch.locale || 'en',
                voice: { name: 'Joanna', gender: 'female' },
            }],
        };
        return { url: `${base}/tts/3/advanced`, method: 'POST', headers, body: JSON.stringify(body) };
    }

    const body = {
        messages: [{
            sender: senderId,
            destinations: [{ to: dispatch.destination, messageId: dispatch.correlationId || dispatch.messageId }],
            content: { text: dispatch.message },
        }],
    };
    return { url: `${base}/sms/3/messages`, method: 'POST', headers, body: JSON.stringify(body) };
}

function parseResponse({ httpStatus, ok, json }) {
    const firstMessage = json && json.messages && json.messages[0];
    const status = (firstMessage && firstMessage.status) || {};
    return new ParsedResponse({
        success: ok,
        providerHttpStatus: httpStatus,
        providerMessageId: (firstMessage && firstMessage.messageId) || null,
        providerStatusName: (status.groupName || status.name || '').toUpperCase() || null,
    });
}

module.exports = { manifest, buildRequest, parseResponse };
