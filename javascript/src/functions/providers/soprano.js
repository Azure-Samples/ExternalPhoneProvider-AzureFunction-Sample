// <copyright file="soprano.js" company="Microsoft Corporation">
// Copyright (c) Microsoft Corporation. All rights reserved.
// </copyright>

'use strict';

const { ParsedResponse, TextToVoice } = require('../models');
const { isSafeBearerToken } = require('../providerToken');

const manifest = {
    id: 'soprano',
    supportsOAuth: true,
    requiresTextToVoice: true,
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
        FAILED: 'Fail',
        REJECTED: 'Fail',
        FILTERED: 'Fail',
        BLOCKED: 'Block',
        default: 'Fail',
    },
};

function buildRequest({ channel, endpoint, dispatch, credential }) {
    let base = endpoint;
    while (base.endsWith('/')) base = base.slice(0, -1);
    const headers = {
        'Content-Type': 'application/json',
        Accept: 'application/json',
    };
    if (credential.mode === 'apiKey') {
        if (!isSafeBearerToken(credential.identity) || !isSafeBearerToken(credential.secret)) {
            throw new Error('provider credential unavailable');
        }
        headers['X-MEMS-API-ID'] = credential.identity;
        headers['X-MEMS-API-Key'] = credential.secret;
    } else if (credential.mode !== 'oauth2') {
        throw new Error('unsupported provider authentication');
    }
    if (isSafeBearerToken(credential.token)) headers.Authorization = `Bearer ${credential.token}`;
    else if (credential.mode === 'oauth2') throw new Error('provider token unavailable');
    let destination = String(dispatch.destination || '');
    while (destination.startsWith('+')) destination = destination.slice(1);
    const body = {
        destination,
        messageTypes: [channel === 'voice' ? 'voice' : 'sms'],
        correlationId: dispatch.correlationId || dispatch.messageId,
        shutterMode: false,
    };
    if (channel === 'voice') {
        const voice = dispatch.textToVoice;
        if (!(voice instanceof TextToVoice) || !voice.isComplete) throw new Error('incomplete voice context');
        body.voice = { text2voice: {
            beforePasswordText: voice.beforePasswordText,
            password: voice.password,
            language: voice.language,
        } };
    } else {
        body.text = dispatch.message;
    }
    return { url: `${base}/messages/omnimsg`, method: 'POST', headers, body: JSON.stringify(body) };
}

function parseResponse({ httpStatus, ok, json }) {
    const payload = (Array.isArray(json) ? json[0] : json) || {};
    const value = payload.status ?? payload.state;
    const status = typeof value === 'string' && value ? value.toUpperCase() : 'UNKNOWN';
    return new ParsedResponse({
        success: ok,
        providerHttpStatus: httpStatus,
        providerMessageId: (payload.id != null ? String(payload.id) : null) || payload.messageId || null,
        providerStatusName: status,
    });
}

module.exports = { manifest, buildRequest, parseResponse };
