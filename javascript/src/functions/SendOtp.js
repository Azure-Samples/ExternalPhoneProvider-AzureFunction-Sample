// <copyright file="SendOtp.js" company="Microsoft Corporation">
// Copyright (c) Microsoft Corporation. All rights reserved.
// </copyright>

'use strict';

// POST /api/SendOtp — the SAS → External Phone Provider delivery endpoint. Validates the caller, parses
// the cleartext routing envelope, decrypts the JWE delivery context, dispatches to the provider, and
// echoes the nonce to prove decryption. Every line is tagged [EPP] so one filter pulls a whole delivery.

const { app } = require('@azure/functions');
const crypto = require('crypto');
const { validateToken } = require('./security');
const {
    dispatchOtp,
    parseEnvelope,
    decryptDeliveryContext,
    contextToDispatch,
    MODE,
} = require('./dispatch');
const { readConfig, missingSettings } = require('./config');

const TAG = '[EPP]';

// Easy Auth has already validated the token by the time this runs; this records which identity arrived.
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

const pad = (label) => label.padEnd(18, ' ');

// The handler deliberately does not await the provider, so tests need a handle on the send it started.
let pendingDelivery = Promise.resolve();
const whenDelivered = () => pendingDelivery;

// Microsoft allows 3.2 s for the whole call, so the provider is called after the response.
function deliverInBackground(dispatch, evaluation, context, requestId) {
    pendingDelivery = dispatchOtp(dispatch, { shutter: evaluation, context, requestId })
        .then(({ httpStatus, body }) => {
            context.log(`${TAG} provider result   : httpStatus=${httpStatus} outcome=${body.outcome || 'n/a'} providerStatus=${body.providerStatus || 'n/a'} providerMessageId=${body.providerMessageId || 'n/a'}`);
        })
        .catch((deliveryError) => {
            (context.error || context.log).call(context, `${TAG} provider delivery failed: ${deliveryError.message}`);
        });
    return pendingDelivery;
}

app.http('SendOtp', {
    methods: ['POST'],
    authLevel: 'anonymous', // Easy Auth is the gate; EPP_REQUIRE_AUTH adds in-process token validation.
    handler: async (request, context) => {
        const started = Date.now();
        const config = readConfig();
        const log = (label, value) => context.log(`${TAG} ${pad(label)}: ${value}`);
        const warn = (message) => (context.warn || context.log).call(context, `${TAG} ${message}`);
        const error = (message) => (context.error || context.log).call(context, `${TAG} ${message}`);

        const requestId = crypto.randomUUID();
        const clientRequestId = request.headers.get('x-ms-client-request-id') || requestId;
        const headerCorrelationId = request.headers.get('x-ms-correlation-id') || null;

        context.log(`${TAG} ======== delivery received ========`);
        log('invocation', context.invocationId || requestId);

        let envelope;
        try {
            // Logged, not thrown: a missing provider setting still lets this prove decryption works.
            const absent = missingSettings(config);
            if (absent.length > 0) {
                warn(`settings not set: ${absent.join(', ')}`);
            }

            const callerAppId = readCallerAppId(request);
            log('caller appid', callerAppId || 'none (Easy Auth off, or called directly)');

            if (callerAppId && config.expectedClientId && callerAppId !== config.expectedClientId) {
                error(`caller ${callerAppId} is not ${config.expectedClientId}. ` +
                    'Easy Auth allowedApplications is not doing its job.');
                return { status: 403, jsonBody: { error: 'unexpected_caller' } };
            }

            const tokenValidation = await validateToken(request, context, requestId);
            if (!tokenValidation.ok) {
                error(`token rejected: ${tokenValidation.reason}`);
                return { status: 401, jsonBody: { error: 'unauthorized', reason: tokenValidation.reason, requestId } };
            }

            let payload;
            try {
                payload = JSON.parse(await request.text());
            } catch (parseError) {
                error(`body is not JSON: ${parseError.message}`);
                return { status: 400, jsonBody: { error: 'bad_request', reason: 'invalid JSON body', requestId } };
            }

            const parsed = parseEnvelope(payload);
            if (parsed.error) {
                error(`envelope rejected: ${parsed.error}`);
                return { status: 400, jsonBody: { error: 'bad_request', reason: parsed.error, requestId } };
            }
            envelope = parsed.envelope;

            log('type', envelope.type);
            log('tenantId', envelope.tenantId);
            log('correlationId', envelope.correlationId);
            log('channel', envelope.channel);
            log('mode', envelope.mode);
            log('ttlSeconds', envelope.ttlSeconds);

            const correlationId = envelope.correlationId || headerCorrelationId || requestId;

            // Surfaced rather than swallowed: the passcode expires before it can be used.
            if (envelope.ttlSeconds !== undefined && envelope.ttlSeconds <= 0) {
                warn(`ttlSeconds is ${envelope.ttlSeconds}; the passcode has expired.`);
            }

            let header;
            let delivery;
            try {
                ({ header, context: delivery } = await decryptDeliveryContext(
                    envelope.encryptedDeliveryContext, config));
            } catch (decryptError) {
                error(`decryption failed: ${decryptError.message}`);
                return { status: 400, jsonBody: { error: 'decryption_failed', correlationId, requestId } };
            }

            const kidMatches = !config.expectedKeyId || header.kid === config.expectedKeyId;
            log('kid', `${header.kid}${kidMatches ? '' : ' (DOES NOT match EPP_ENCRYPTION_KEY_ID)'}`);
            log('alg / enc', `${header.alg} / ${header.enc}`);
            log('decrypted', 'OK');
            log('nonce', delivery.nonce);

            if (config.logPlaintext) {
                // DIAGNOSTICS ONLY — writes the phone number and passcode to the log.
                log('phoneNumber', delivery.phoneNumber);
                log('extension', delivery.extension || '(none)');
                log('locale', delivery.locale);
                log('message', delivery.message);
                log('riskContext', delivery.riskContext ? JSON.stringify(delivery.riskContext) : '(none)');
            } else {
                context.log(`${TAG} plaintext suppressed (EPP_LOG_PLAINTEXT=false)`);
            }

            if (!delivery.nonce || !delivery.phoneNumber || !delivery.message) {
                error('delivery context is incomplete (nonce/phoneNumber/message)');
                return { status: 400, jsonBody: { error: 'bad_request', reason: 'incomplete delivery context', correlationId, requestId } };
            }

            const evaluation = envelope.mode === MODE.EVALUATION;
            const dispatch = contextToDispatch(delivery, envelope, clientRequestId);

            deliverInBackground(dispatch, evaluation, context, requestId);

            // Echoing the nonce is the whole contract: a 2xx without it is treated as a failed delivery
            // and Microsoft re-sends over its own telephony, so the user gets the code twice.
            const body = { nonce: delivery.nonce, correlationId, providerStatus: 'accepted' };

            log('responding', `200, nonce echoed, ${Date.now() - started} ms`);
            context.log(`${TAG} ======== done ========`);

            return { status: 200, jsonBody: body };
        } catch (unhandled) {
            // Verbose on purpose: this endpoint exists to diagnose onboarding.
            error(`FAILED after ${Date.now() - started} ms: ${unhandled.message}`);
            if (unhandled.cause) {
                error(`caused by: ${unhandled.cause.message || unhandled.cause}`);
            }
            context.log(`${TAG} ======== failed ========`);

            return {
                status: 500,
                jsonBody: {
                    error: 'delivery_failed',
                    detail: unhandled.message,
                    correlationId: envelope && envelope.correlationId,
                },
            };
        }
    },
});

module.exports = { whenDelivered };
