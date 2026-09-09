// <copyright file="SendOtp.js" company="Microsoft Corporation">
// Copyright (c) Microsoft Corporation. All rights reserved.
// </copyright>

'use strict';

// POST /api/SendOtp: authenticate, decrypt, dispatch, then echo the nonce on acceptance only.

const { app } = require('@azure/functions');
const crypto = require('crypto');
const { validateToken } = require('./security');
const {
    dispatchOtp,
    parseEnvelope,
    decryptDeliveryContext,
    contextToDispatch,
    MODE,
    safeTraceId,
} = require('./dispatch');
const { readConfig } = require('./config');

// Easy Auth is the primary gate; enforce its caller allowlist here as well.
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
    authLevel: 'anonymous', // Easy Auth is the gate; EPP_REQUIRE_AUTH adds in-process token validation.
    handler: async (request, context) => {
        const started = Date.now();
        const requestId = crypto.randomUUID();
        let correlationId = requestId;
        let evaluation = false;
        const reply = (status, jsonBody, reason, outcome = status === 200 ? 'Continue' : 'Fail') => {
            context.log('[EPP]', {
                requestId, correlationId: safeTraceId(correlationId), httpStatus: status,
                elapsedMs: Date.now() - started, nonceEcho: status === 200 && !!jsonBody.nonce,
                evaluation, reason, outcome,
            });
            return { status, jsonBody };
        };
        try {
            const config = readConfig();
            correlationId = request.headers.get('x-ms-correlation-id') || requestId;
            const clientRequestId = request.headers.get('x-ms-client-request-id') || requestId;
            const callerAppId = readCallerAppId(request);
            if (callerAppId && config.expectedClientId && callerAppId !== config.expectedClientId) {
                return reply(403, { error: 'unexpected_caller' }, 'unexpected_caller');
            }

            const tokenValidation = await validateToken(request);
            if (!tokenValidation.ok) {
                return reply(401, { error: 'unauthorized', reason: tokenValidation.reason, requestId }, 'unauthorized');
            }

            let payload;
            try {
                payload = JSON.parse(await request.text());
            } catch {
                return reply(400, { error: 'bad_request', reason: 'invalid JSON body', requestId }, 'invalid_json');
            }

            const parsed = parseEnvelope(payload);
            if (parsed.error) {
                return reply(400, { error: 'bad_request', reason: parsed.error, requestId }, 'invalid_envelope');
            }
            const envelope = parsed.envelope;
            correlationId = envelope.correlationId || correlationId;
            evaluation = envelope.mode === MODE.EVALUATION;

            let delivery;
            try {
                ({ context: delivery } = await decryptDeliveryContext(
                    envelope.encryptedDeliveryContext, config));
            } catch {
                return reply(400, { error: 'decryption_failed', correlationId, requestId }, 'decryption_failed');
            }

            if (!delivery.nonce || !delivery.phoneNumber || !delivery.message) {
                return reply(400, { error: 'bad_request', reason: 'incomplete delivery context', correlationId, requestId }, 'incomplete_context');
            }

            const dispatch = contextToDispatch(delivery, { ...envelope, correlationId }, clientRequestId);

            const providerResult = await dispatchOtp(dispatch, {
                shutter: evaluation,
                context,
                requestId,
            });
            if (providerResult.httpStatus !== 200) {
                return reply(providerResult.httpStatus,
                    { error: 'provider_delivery_failed', correlationId, requestId }, 'provider_delivery_failed',
                    providerResult.httpStatus === 403 ? 'Block' : providerResult.httpStatus === 409 ? 'StepUp' : 'Fail');
            }

            // SAS treats a 2xx without the matching nonce as failure and falls back to native delivery.
            return reply(200, { nonce: delivery.nonce, correlationId, providerStatus: 'accepted' },
                evaluation ? 'evaluation' : 'accepted');
        } catch {
            return reply(500, { error: 'delivery_failed', correlationId, requestId }, 'delivery_failed');
        }
    },
});
