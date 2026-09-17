// <copyright file="soprano.js" company="Microsoft Corporation">
// Copyright (c) Microsoft Corporation. All rights reserved.
// </copyright>

'use strict';

const { ParsedResponse } = require('../models');

const DEFAULT_VOICE_LANGUAGE = 'en-US';
const VOICE_GENDER = 1;
const VOICE_LOOP = 2;

const manifest = {
    id: 'soprano',
    auth: { mode: 'oauth' },
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

function buildTextToVoice(message, locale) {
    const renderedMessage = String(message || '');
    const passcodeMatch = renderedMessage.match(/\d{6}/);
    if (!passcodeMatch) {
        throw new Error('voice message does not contain a six-digit passcode');
    }

    const passcodeIndex = passcodeMatch.index;
    return {
        beforePasswordText: renderedMessage.slice(0, passcodeIndex),
        password: passcodeMatch[0],
        afterPasswordText: renderedMessage.slice(passcodeIndex + passcodeMatch[0].length),
        language: typeof locale === 'string' && locale.trim() ? locale : DEFAULT_VOICE_LANGUAGE,
        gender: VOICE_GENDER,
        loop: VOICE_LOOP,
    };
}

function buildRequest({ channel, endpoint, dispatch, credential }) {
    const headers = {
        'Content-Type': 'application/json',
        Accept: 'application/json',
        Authorization: `Bearer ${credential.accessToken}`,
    };
    let destination = String(dispatch.destination || '');
    while (destination.startsWith('+')) destination = destination.slice(1);
    const body = {
        destination,
        messageTypes: [channel === 'voice' ? 'voice' : 'sms'],
        correlationId: dispatch.correlationId || dispatch.messageId,
        shutterMode: false,
    };
    if (channel === 'voice') {
        body.voice = { text2voice: buildTextToVoice(dispatch.message, dispatch.locale) };
    } else {
        body.text = dispatch.message;
    }
    return { url: endpoint, method: 'POST', headers, body: JSON.stringify(body) };
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
