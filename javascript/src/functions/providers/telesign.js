'use strict';

const { OUTCOME, ProviderResult, classifyFailure } = require('../providerResult');

const VOICE_PASSCODE_PATTERN = /(?<![0-9])[0-9]{6}(?![0-9])/g;
const SUCCESS = new Set(['200', '203', '290', '291', '292', '100', '101', '102', '103', '3001']);

function buildVoiceMessage(message) {
    const paced = message.replace(VOICE_PASSCODE_PATTERN, (passcode) => [...passcode].join(', '));
    return `${paced} ${paced}`;
}

const provider = Object.freeze({
    name: 'telesign',
    authenticationMode: 'oauth',
    credentialSpec: Object.freeze({ mode: 'oauth' }),

    createRequest({ channel, endpoint, delivery, credential }) {
        if (!['sms', 'voice'].includes(channel)) throw new Error('unsupported channel');
        if (typeof delivery.phoneNumber !== 'string'
            || !/^\+[1-9][0-9]{1,14}$/.test(delivery.phoneNumber)) {
            throw new Error('invalid recipient');
        }
        const message = {
            text: channel === 'voice' ? buildVoiceMessage(delivery.message) : delivery.message,
        };
        if (typeof delivery.locale === 'string' && delivery.locale.trim()) {
            message.language = delivery.locale;
        }
        const correlationId = typeof delivery.correlationId === 'string' && delivery.correlationId
            ? delivery.correlationId : delivery.messageId;
        const body = {
            recipient: { phone_number: delivery.phoneNumber },
            message,
            channels: [{ channel }],
            correlation_id: correlationId,
        };
        for (const [source, target] of [
            ['scenario', 'account_lifecycle_event'], ['ipAddress', 'originating_ip'],
        ]) {
            const value = delivery.riskContext?.[source];
            if (value == null) continue;
            body[target] = value;
        }
        return {
            url: endpoint,
            method: 'POST',
            headers: {
                Authorization: `Bearer ${credential.accessToken}`,
                'Content-Type': 'application/json',
                Accept: 'application/json',
            },
            body: JSON.stringify(body),
        };
    },

    interpretResponse(response) {
        const payload = response.json && typeof response.json === 'object' && !Array.isArray(response.json)
            ? response.json : {};
        const statusObject = payload.status && typeof payload.status === 'object' && !Array.isArray(payload.status)
            ? payload.status : {};
        const code = typeof statusObject.code === 'number' && Number.isInteger(statusObject.code)
            ? String(statusObject.code) : 'UNKNOWN';
        const recognized = SUCCESS.has(code) || code === '3072';
        const mappedOutcome = code === '3072' ? OUTCOME.BLOCK
            : recognized ? OUTCOME.CONTINUE : OUTCOME.FAIL;
        const outcome = response.ok ? mappedOutcome : OUTCOME.FAIL;
        return new ProviderResult({
            outcome,
            statusRecognized: recognized,
            providerHttpStatus: response.providerHttpStatus,
            providerMessageId: typeof payload.reference_id === 'string' ? payload.reference_id : null,
            providerStatusCode: code,
            providerStatusDescription: typeof statusObject.description === 'string'
                ? statusObject.description : null,
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
