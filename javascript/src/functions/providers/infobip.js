'use strict';

const { OUTCOME, ProviderResult, classifyFailure } = require('../providerResult');
const { buildVoiceMessage } = require('../voiceMessage');

const SUCCESS = new Set(['ACCEPTED', 'PENDING', 'DELIVERED']);
const REJECTED = new Set(['REJECTED', 'EXPIRED', 'UNDELIVERABLE']);

const provider = Object.freeze({
    name: 'infobip',
    authenticationMode: 'oauth',
    credentialSpec: Object.freeze({ mode: 'oauth' }),

    createRequest({ channel, endpoint, delivery, credential, env }) {
        const messageId = delivery.correlationId || delivery.messageId;
        const headers = {
            Authorization: ['Bearer', credential.accessToken].join(' '),
            'Content-Type': 'application/json',
            Accept: 'application/json',
        };
        if (channel === 'voice') {
            const senderId = env.INFOBIP_VOICE_SENDER_ID?.trim();
            if (!senderId) throw new Error('INFOBIP_VOICE_SENDER_ID is required for voice');
            return {
                url: endpoint,
                method: 'POST',
                headers,
                body: JSON.stringify({
                    to: delivery.phoneNumber,
                    text: buildVoiceMessage(delivery.message, delivery.otp),
                    language: (delivery.locale?.trim() || 'en').split('-')[0].toLowerCase(),
                    voice: { name: 'Joanna', gender: 'female' },
                    from: senderId,
                }),
            };
        }
        return {
            url: endpoint,
            method: 'POST',
            headers,
            body: JSON.stringify({
                messages: [{
                    destinations: [{ to: delivery.phoneNumber, messageId }],
                    content: { text: delivery.message },
                }],
            }),
        };
    },

    interpretResponse(response) {
        const message = Array.isArray(response.json?.messages) ? response.json.messages[0] : null;
        const statusObject = message && typeof message.status === 'object' && !Array.isArray(message.status)
            ? message.status : null;
        const rawStatus = typeof statusObject?.groupName === 'string'
            ? statusObject.groupName : typeof statusObject?.name === 'string' ? statusObject.name : null;
        const status = rawStatus?.toUpperCase() || null;
        const recognized = SUCCESS.has(status) || REJECTED.has(status);
        const mappedOutcome = SUCCESS.has(status) ? OUTCOME.CONTINUE : OUTCOME.FAIL;
        const outcome = response.ok ? mappedOutcome : OUTCOME.FAIL;
        return new ProviderResult({
            outcome,
            statusRecognized: recognized,
            providerHttpStatus: response.providerHttpStatus,
            providerMessageId: typeof message?.messageId === 'string' ? message.messageId : null,
            providerStatusName: status,
            providerStatusDescription: typeof statusObject?.description === 'string'
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
