'use strict';

const { OUTCOME, ProviderResult, classifyFailure } = require('../providerResult');

const SUCCESS = new Set(['ACCEPTED', 'PENDING', 'DELIVERED']);
const REJECTED = new Set(['REJECTED', 'EXPIRED', 'UNDELIVERABLE']);

const provider = Object.freeze({
    name: 'infobip',
    authenticationMode: 'apiKey',
    credentialSpec: Object.freeze({ mode: 'apiKey', keyVaultSecretName: 'infobip-api-key' }),

    createRequest({ channel, endpoint, delivery, credential, env }) {
        const senderId = env.EPP_PROVIDER_ACCOUNT_NAME || 'Verify';
        const messageId = delivery.correlationId || delivery.messageId;
        const headers = {
            Authorization: `App ${credential.secret}`,
            'Content-Type': 'application/json',
            Accept: 'application/json',
        };
        if (channel === 'voice') {
            return {
                url: `${endpoint}/tts/3/advanced`,
                method: 'POST',
                headers,
                body: JSON.stringify({
                    messages: [{
                        from: senderId,
                        destinations: [{ to: delivery.phoneNumber, messageId }],
                        text: delivery.message,
                        language: delivery.locale || 'en',
                        voice: { name: 'Joanna', gender: 'female' },
                    }],
                }),
            };
        }
        return {
            url: `${endpoint}/sms/3/messages`,
            method: 'POST',
            headers,
            body: JSON.stringify({
                messages: [{
                    sender: senderId,
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
