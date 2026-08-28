// <copyright file="infobip.js" company="Microsoft Corporation">
// Copyright (c) Microsoft Corporation. All rights reserved.
// </copyright>

'use strict';

// Infobip: SMS /sms/3/messages, voice /tts/3/advanced (unverified). Auth: App API key, or Bearer in oauth2 mode.

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
    const authorization = credential.mode === 'oauth2' ? `Bearer ${credential.token}` : `App ${credential.secret}`;
    const headers = {
        Authorization: authorization,
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
    return {
        success: ok,
        providerHttpStatus: httpStatus,
        providerMessageId: (firstMessage && firstMessage.messageId) || null,
        providerStatusName: (status.groupName || status.name || '').toUpperCase() || null,
        providerStatusDescription: status.description || null,
    };
}

module.exports = { manifest, buildRequest, parseResponse };
