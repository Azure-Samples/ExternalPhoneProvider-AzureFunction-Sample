// <copyright file="SendOtp.js" company="Microsoft Corporation">
// Copyright (c) Microsoft Corporation. All rights reserved.
// </copyright>

'use strict';

const { app } = require('@azure/functions');
const crypto = require('crypto');
const { validateToken, isExpectedCaller } = require('./security');
const {
    dispatchOtp,
    parseEnvelope,
    decryptDeliveryContext,
    contextToDispatch,
    MODE,
} = require('./dispatch');
const { readConfig } = require('./config');

function readCallerAppId(request) {
    const encoded = request.headers.get('x-ms-client-principal');
    if (!encoded) return undefined;
    try {
        const principal = JSON.parse(Buffer.from(encoded, 'base64').toString('utf8'));
        const claim = (principal.claims || []).find((c) => c.typ === 'appid' || c.typ === 'azp');
        return claim && claim.val;
    } catch {
        return undefined;
    }
}

app.http('SendOtp', {
    methods: ['POST'],
    authLevel: 'anonymous', // In-process token validation is mandatory on Azure.
    handler: async (request, context) => {
        const started = Date.now();
        const requestId = crypto.randomUUID();
        let correlationId = requestId;
        let evaluation = false;
        let httpStatus = 500;
        const respond = (status, jsonBody) => {
            httpStatus = status;
            return { status, jsonBody };
        };

        try {
            const config = readConfig();
            const clientRequestId = request.headers.get('x-ms-client-request-id') || requestId;
            const headerCorrelationId = request.headers.get('x-ms-correlation-id') || null;
            correlationId = headerCorrelationId || requestId;
            // Do not treat a forged Easy Auth header as authentication, especially on Azure.
            const tokenValidation = await validateToken(request, config);
            if (!tokenValidation.ok) {
                return respond(401, { error: 'unauthorized', reason: tokenValidation.reason, requestId });
            }

            const callerAppId = readCallerAppId(request);
            if (callerAppId && !isExpectedCaller({ azp: callerAppId }, config.expectedClientId)) {
                return respond(403, { error: 'unexpected_caller', correlationId, requestId });
            }

            let payload;
            try {
                payload = JSON.parse(await request.text());
            } catch {
                return respond(400, { error: 'bad_request', reason: 'invalid JSON body', requestId });
            }

            const parsed = parseEnvelope(payload);
            if (parsed.error) {
                return respond(400, { error: 'bad_request', reason: parsed.error, requestId });
            }
            const envelope = parsed.envelope;
            correlationId = envelope.correlationId || headerCorrelationId || requestId;
            evaluation = envelope.mode === MODE.EVALUATION;

            let delivery;
            let header;
            try {
                ({ context: delivery, header } = await decryptDeliveryContext(
                    envelope.encryptedDeliveryContext, config));
            } catch {
                return respond(400, { error: 'decryption_failed', correlationId, requestId });
            }

            // Key ID is advisory after authenticated decryption.
            if (config.expectedKeyId && config.expectedKeyId !== header.kid) {
                context.warn('encryption_key_id_mismatch');
            }

            if (!delivery || typeof delivery !== 'object' || Array.isArray(delivery)
                || ['nonce', 'phoneNumber', 'message'].some((field) => typeof delivery[field] !== 'string' || !delivery[field].trim())) {
                return respond(400, { error: 'bad_request', reason: 'incomplete delivery context', correlationId, requestId });
            }

            // Evaluation proves decryption without resolving a provider or requiring provider config.
            if (!evaluation) {
                const dispatch = contextToDispatch(delivery, envelope, clientRequestId);
                dispatch.correlationId = correlationId;
                const result = await dispatchOtp(dispatch, { requestId, config }).catch(() => ({ httpStatus: 500 }));
                if (result.httpStatus !== 200) {
                    return respond(result.httpStatus, { error: 'provider_delivery_failed', correlationId, requestId });
                }
            }

            // Only a successful delivery (or validated evaluation) may echo the nonce and accepted.
            return respond(200, { nonce: delivery.nonce, correlationId, providerStatus: 'accepted' });
        } catch {
            return respond(500, { error: 'delivery_failed', correlationId, requestId });
        } finally {
            const rawId = typeof correlationId === 'string' ? correlationId : JSON.stringify(correlationId);
            context.log({
                requestId,
                correlationId: crypto.createHash('sha256').update(rawId).digest('hex').slice(0, 16),
                httpStatus,
                elapsedMs: Date.now() - started,
                evaluation,
            });
        }
    },
});
