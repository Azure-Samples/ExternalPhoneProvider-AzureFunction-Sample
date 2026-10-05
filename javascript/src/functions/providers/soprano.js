'use strict';

const { OUTCOME, ProviderResult, classifyFailure } = require('../providerResult');

const DEFAULT_VOICE_LANGUAGE = 'en-US';
const SUCCESS = new Set(['ENROUTE', 'ACCEPTED', 'SUBMITTED', 'SENT', 'DELIVERED', 'QUEUED']);
const REJECTED = new Set(['FAILED', 'REJECTED', 'FILTERED']);

function buildTextToVoice(message, locale) {
    const renderedMessage = String(message || '');
    const match = renderedMessage.match(/[0-9]{6}/);
    if (!match) throw new Error('voice message does not contain a six-digit passcode');
    return {
        beforePasswordText: renderedMessage.slice(0, match.index),
        password: match[0],
        afterPasswordText: renderedMessage.slice(match.index + match[0].length),
        language: typeof locale === 'string' && locale.trim() ? locale : DEFAULT_VOICE_LANGUAGE,
        gender: 1,
        loop: 2,
    };
}

function responseIdentifier(value) {
    if (typeof value === 'string') return value || null;
    return typeof value === 'number' && Number.isFinite(value) ? String(value) : null;
}

const provider = Object.freeze({
    name: 'soprano',
    authenticationMode: 'oauth',
    credentialSpec: Object.freeze({ mode: 'oauth' }),

    createRequest({ channel, endpoint, delivery, credential }) {
        const body = {
            destination: String(delivery.phoneNumber || '').replace(/^\++/, ''),
            messageTypes: [channel === 'voice' ? 'voice' : 'sms'],
            correlationId: delivery.correlationId || delivery.messageId,
            shutterMode: false,
        };
        if (channel === 'voice') {
            body.voice = { text2voice: buildTextToVoice(delivery.message, delivery.locale) };
        } else {
            body.text = delivery.message;
        }
        return {
            url: endpoint,
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                Accept: 'application/json',
                Authorization: ['Bearer', credential.accessToken].join(' '),
            },
            body: JSON.stringify(body),
        };
    },

    interpretResponse(response) {
        const root = Array.isArray(response.json) ? response.json[0] : response.json;
        const payload = root && typeof root === 'object' && !Array.isArray(root) ? root : {};
        const selectedStatus = payload.status == null ? payload.state : payload.status;
        const status = typeof selectedStatus === 'string' && selectedStatus.trim()
            ? selectedStatus.toUpperCase() : 'UNKNOWN';
        const recognized = SUCCESS.has(status) || REJECTED.has(status) || status === 'BLOCKED';
        let mappedOutcome = OUTCOME.FAIL;
        if (SUCCESS.has(status)) mappedOutcome = OUTCOME.CONTINUE;
        if (status === 'BLOCKED') mappedOutcome = OUTCOME.BLOCK;
        const outcome = !response.ok && mappedOutcome === OUTCOME.CONTINUE
            ? OUTCOME.FAIL : mappedOutcome;
        return new ProviderResult({
            outcome,
            statusRecognized: recognized,
            providerHttpStatus: response.providerHttpStatus,
            providerMessageId: responseIdentifier(payload.id) || responseIdentifier(payload.messageId),
            providerStatusName: status,
            failureReason: classifyFailure({
                providerHttpStatus: response.providerHttpStatus,
                outcome,
                statusRecognized: recognized,
                validJson: response.validJson,
            }),
        });
    },
});

module.exports = provider;
