// <copyright file="SendOtp.js" company="Microsoft Corporation">
// Copyright (c) Microsoft Corporation. All rights reserved.
// </copyright>

'use strict';

const { app } = require('@azure/functions');
const crypto = require('crypto');
const {
    dispatchOtp,
    parseEnvelope,
    decryptDeliveryContext,
    contextToDispatch,
    startProviderCredentialRefresh,
    stopProviderCredentialRefresh,
    MODE,
} = require('./dispatch');
const { readConfig } = require('./config');
const { RequestLog } = require('./requestLog');

app.hook.appStart(startProviderCredentialRefresh);
app.hook.appTerminate(stopProviderCredentialRefresh);

app.http('SendOtp', {
    methods: ['POST'],
    authLevel: 'anonymous', // Protected by platform authentication in Azure.
    handler: async (request, context) => {
        const requestId = crypto.randomUUID();
        const msRequestId = request.headers.get('x-ms-client-request-id');
        const headerCorrelationId = request.headers.get('x-ms-correlation-id') || null;
        const log = new RequestLog(context, requestId, msRequestId, headerCorrelationId);
        let correlationId = headerCorrelationId || requestId;
        let evaluation = false;
        let httpStatus = 500;
        const respond = (status, jsonBody) => {
            httpStatus = status;
            log.responsePrepared(status, Object.hasOwn(jsonBody, 'nonce'), Object.hasOwn(jsonBody, 'correlationId'));
            return { status, jsonBody };
        };

        try {
            log.service('request_received');
            const config = readConfig();
            const clientRequestId = msRequestId || requestId;

            let payload;
            try {
                payload = JSON.parse(await request.text());
            } catch {
                log.failure('request_validation', 'invalid JSON body', 400);
                return respond(400, { error: 'bad_request', reason: 'invalid JSON body', requestId });
            }

            const parsed = parseEnvelope(payload);
            if (parsed.error) {
                log.failure('request_validation', parsed.error, 400);
                return respond(400, { error: 'bad_request', reason: parsed.error, requestId });
            }
            const envelope = parsed.envelope;
            correlationId = envelope.correlationId || headerCorrelationId || requestId;
            evaluation = envelope.mode === MODE.EVALUATION;
            log.envelopeValidated(envelope, envelope.correlationId || headerCorrelationId,
                envelope.correlationId ? 'envelope' : 'header');

            let delivery;
            let header;
            try {
                ({ context: delivery, header } = await decryptDeliveryContext(
                    envelope.encryptedDeliveryContext, config));
            } catch {
                log.failure('decryption', 'decryption_failed', 400);
                return respond(400, { error: 'decryption_failed', correlationId, requestId });
            }
            log.service('delivery_context_decrypted');

            // Key ID is advisory after authenticated decryption.
            if (config.expectedKeyId && config.expectedKeyId !== header.kid) {
                log.keyIdMismatch();
            }

            if (!delivery?.isComplete) {
                log.failure('delivery_context_validation', 'incomplete delivery context', 400);
                return respond(400, { error: 'bad_request', reason: 'incomplete delivery context', correlationId, requestId });
            }

            // Evaluation proves decryption without resolving a provider or requiring provider config.
            if (!evaluation) {
                const dispatch = contextToDispatch(delivery, envelope, clientRequestId);
                dispatch.correlationId = correlationId;
                const result = await dispatchOtp(dispatch, { requestId, config, log }).catch(() => {
                    if (!log.data.failureStage) log.failure('provider_dispatch', 'unexpected_error', 500);
                    return { httpStatus: 500 };
                });
                if (result.httpStatus !== 200) {
                    return respond(result.httpStatus, { error: 'provider_delivery_failed', correlationId, requestId });
                }
            } else {
                log.service('evaluation_completed');
            }

            // Only a successful delivery (or validated evaluation) may echo the nonce and accepted.
            return respond(200, { nonce: delivery.nonce, correlationId, providerStatus: 'accepted' });
        } catch {
            if (!log.data.failureStage) log.failure('handler', 'unexpected_error', 500);
            return respond(500, { error: 'delivery_failed', correlationId, requestId });
        } finally {
            log.complete(httpStatus);
        }
    },
});
