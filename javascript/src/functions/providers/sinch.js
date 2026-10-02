'use strict';

const { OUTCOME, ProviderResult, classifyFailure } = require('../providerResult');

const SUCCESS = new Set(['Dispatched', 'Delivered', 'Queued']);
const REJECTED = new Set(['Failed', 'Rejected']);

function nonblankString(value) {
    return typeof value === 'string' && value.trim() ? value : null;
}

const provider = Object.freeze({
    name: 'sinch',
    authenticationMode: 'apiKey',
    credentialSpec: Object.freeze({ mode: 'apiKey', keyVaultSecretName: 'sinch-api-token' }),

    createRequest({ channel, endpoint, delivery, credential, env }) {
        const headers = {
            Authorization: ['Bearer', credential.secret].join(' '),
            'Content-Type': 'application/json',
            Accept: 'application/json',
        };
        if (channel === 'voice') {
            const voiceBase = env.SINCH_VOICE_ENDPOINT || 'https://calling.api.sinch.com';
            return {
                url: `${voiceBase}/calling/v1/callouts`,
                method: 'POST',
                headers,
                body: JSON.stringify({
                    method: 'ttsCallout',
                    ttsCallout: {
                        destination: { type: 'number', endpoint: delivery.phoneNumber },
                        text: delivery.message,
                        locale: delivery.locale || 'en-US',
                        custom: delivery.correlationId || delivery.messageId,
                    },
                }),
            };
        }
        const servicePlanId = env.SINCH_SERVICE_PLAN_ID || '';
        return {
            url: `${endpoint}/xms/v1/${servicePlanId}/batches`,
            method: 'POST',
            headers,
            body: JSON.stringify({
                from: env.EPP_PROVIDER_ACCOUNT_NAME || 'Verify',
                to: [delivery.phoneNumber],
                body: delivery.message,
                client_reference: delivery.correlationId || delivery.messageId,
            }),
        };
    },

    interpretResponse(response) {
        const payload = response.json && typeof response.json === 'object' && !Array.isArray(response.json)
            ? response.json : {};
        const messageId = nonblankString(payload.id) || nonblankString(payload.callId);
        let status = nonblankString(payload.status);
        if (payload.status == null && response.ok && messageId) status = 'Dispatched';
        const recognized = SUCCESS.has(status) || REJECTED.has(status);
        const mappedOutcome = SUCCESS.has(status) ? OUTCOME.CONTINUE : OUTCOME.FAIL;
        const outcome = response.ok && messageId ? mappedOutcome : OUTCOME.FAIL;
        const failureReason = response.validJson && response.ok && !messageId
            ? 'missing_provider_message_id'
            : classifyFailure({
                providerHttpStatus: response.providerHttpStatus,
                outcome,
                statusRecognized: recognized,
                validJson: response.validJson,
            });
        return new ProviderResult({
            outcome,
            statusRecognized: recognized,
            providerHttpStatus: response.providerHttpStatus,
            providerMessageId: messageId,
            providerStatusName: status,
            providerStatusDescription: typeof payload.text === 'string' ? payload.text : null,
            failureReason,
        });
    },
});

module.exports = provider;
