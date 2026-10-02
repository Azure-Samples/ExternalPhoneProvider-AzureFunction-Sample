// <copyright file="SendOtp.js" company="Microsoft Corporation">
// Copyright (c) Microsoft Corporation. All rights reserved.
// </copyright>

'use strict';

const { app } = require('@azure/functions');
const crypto = require('node:crypto');
const { performance } = require('node:perf_hooks');
const { readConfig } = require('./config');
const { parseEntraPayload } = require('./entraPayload');
const { OtpDelivery } = require('./delivery');
const { decryptDeliveryContext } = require('./jwe');
const { selectProvider } = require('./providers');
const {
    credentialTokenService,
    reportRefreshFailure,
} = require('./credentials');
const {
    ProviderTransportError,
    isValidProviderUrl,
    parseProviderTimeout,
    sendProviderRequest,
} = require('./providerTransport');
const {
    safeIdentifier,
    createRequestContext,
    payloadContext,
    providerContext,
    credentialContext,
    emit,
    requestFailed,
    requestCompleted,
    unexpectedError,
} = require('./logging');

async function startProviderCredentialRefresh() {
    const config = readConfig();
    if (!config.providerName) return;
    const provider = selectProvider(config.providerName);
    if (!provider || (config.providerAuthMode
        && config.providerAuthMode !== provider.authenticationMode)) {
        reportRefreshFailure('configuration');
        return;
    }
    try {
        await credentialTokenService.getCredentials(provider.credentialSpec, config);
    } catch {
        if (!credentialTokenService.current) reportRefreshFailure('configuration');
    }
}

function stopProviderCredentialRefresh() {
    credentialTokenService.close();
}

app.hook.appStart(startProviderCredentialRefresh);
app.hook.appTerminate(stopProviderCredentialRefresh);

app.http('SendOtp', {
    methods: ['POST'],
    authLevel: 'anonymous',
    handler: async (request, azureContext) => {
        const requestId = crypto.randomUUID();
        const headerCorrelationId = request.headers.get('x-ms-correlation-id');
        const msRequestId = request.headers.get('x-ms-client-request-id');
        let logContext = createRequestContext(
            azureContext,
            requestId,
            msRequestId,
            headerCorrelationId,
        );
        let correlationId = safeIdentifier(headerCorrelationId) || requestId;
        let evaluation = false;
        let status = 500;
        let failureEmitted = false;

        const fail = (failureStage, failureReason, httpStatus) => {
            failureEmitted = true;
            requestFailed(logContext, failureStage, failureReason, httpStatus);
            return httpStatus;
        };
        const respond = (httpStatus, jsonBody) => {
            status = httpStatus;
            emit(logContext, 'response_prepared', {
                httpStatus,
                responseContainsNonce: Object.hasOwn(jsonBody, 'nonce'),
                responseContainsCorrelationId: Object.hasOwn(jsonBody, 'correlationId'),
            });
            return { status: httpStatus, jsonBody };
        };

        try {
            emit(logContext, 'request_received');
            const config = readConfig();

            let rawPayload;
            try {
                rawPayload = JSON.parse(await request.text());
            } catch {
                fail('request_validation', 'invalid JSON body', 400);
                return respond(400, { error: 'bad_request', reason: 'invalid JSON body', requestId });
            }

            const parsed = parseEntraPayload(rawPayload);
            if (parsed.error) {
                fail('request_validation', parsed.error, 400);
                return respond(400, { error: 'bad_request', reason: parsed.error, requestId });
            }
            const payload = parsed.payload;
            logContext = payloadContext(logContext, payload);
            correlationId = typeof payload.correlationId === 'string' && payload.correlationId
                ? payload.correlationId
                : headerCorrelationId
                || requestId;
            evaluation = payload.isEvaluation;
            emit(logContext, 'envelope_validated', {
                envelopeType: payload.type,
                ttlSeconds: payload.ttlSeconds ?? null,
                encryptedDeliveryContextPresent: true,
            });

            let decrypted;
            try {
                decrypted = await decryptDeliveryContext(
                    payload.encryptedDeliveryContext,
                    config.decryptionKeyPem,
                );
            } catch {
                fail('decryption', 'decryption_failed', 400);
                return respond(400, { error: 'decryption_failed', correlationId, requestId });
            }
            emit(logContext, 'delivery_context_decrypted');

            if (config.expectedKeyId && config.expectedKeyId !== decrypted.keyId) {
                emit(logContext, 'encryption_key_id_mismatch', {}, 'warn');
            }
            if (!decrypted.delivery?.isComplete) {
                fail('delivery_context_validation', 'incomplete delivery context', 400);
                return respond(400, {
                    error: 'bad_request',
                    reason: 'incomplete delivery context',
                    correlationId,
                    requestId,
                });
            }

            if (evaluation) {
                emit(logContext, 'evaluation_completed');
                return respond(200, {
                    nonce: decrypted.delivery.nonce,
                    correlationId,
                    providerStatus: 'accepted',
                });
            }

            const provider = selectProvider(config.providerName);
            if (!provider) {
                fail('provider_selection', 'unknown_provider', 400);
                return respond(400, { error: 'provider_delivery_failed', correlationId, requestId });
            }
            logContext = providerContext(logContext, provider);
            emit(logContext, 'provider_selected');

            const channel = payload.channelName;
            if (config.providerChannel && config.providerChannel !== channel) {
                fail('provider_configuration', 'channel_not_configured', 400);
                return respond(400, { error: 'provider_delivery_failed', correlationId, requestId });
            }
            if (config.providerAuthMode
                && config.providerAuthMode !== provider.authenticationMode) {
                fail('provider_configuration', 'authentication_mode_mismatch', 502);
                return respond(502, { error: 'provider_delivery_failed', correlationId, requestId });
            }
            if (!isValidProviderUrl(config.providerEndpoint)) {
                fail('provider_configuration', 'invalid_provider_endpoint', 502);
                return respond(502, { error: 'provider_delivery_failed', correlationId, requestId });
            }

            let credential;
            const credentialStarted = performance.now();
            try {
                if (provider.authenticationMode === 'oauth') {
                    logContext = credentialContext(logContext, config);
                }
                emit(logContext, 'provider_credential_resolution_started', {
                    providerCredentialSource: provider.authenticationMode === 'oauth'
                        ? 'managed_identity_client_assertion' : 'key_vault',
                    providerTenantId: logContext.providerTenantId,
                    functionOutboundClientId: logContext.functionOutboundClientId,
                    functionOutboundManagedIdentityClientId:
                        logContext.functionOutboundManagedIdentityClientId,
                });
                credential = await credentialTokenService.getCredentials(
                    provider.credentialSpec,
                    config,
                );
            } catch {
                fail('provider_credentials', 'credential_unavailable', 502);
                return respond(502, { error: 'provider_delivery_failed', correlationId, requestId });
            }
            const needsIdentity = provider.credentialSpec.identityKeyVaultSecretName;
            const credentialUnavailable = !credential
                || (credential.mode === 'apiKey'
                    && (!credential.secret || (needsIdentity && !credential.identity)))
                || (credential.mode === 'oauth' && !credential.accessToken);
            if (credentialUnavailable) {
                fail('provider_credentials', 'credential_unavailable', 502);
                return respond(502, { error: 'provider_delivery_failed', correlationId, requestId });
            }
            emit(logContext, 'provider_credential_resolved', {
                providerCredentialElapsedMs: Math.floor(performance.now() - credentialStarted),
            });

            const delivery = new OtpDelivery({
                phoneNumber: decrypted.delivery.phoneNumber,
                message: decrypted.delivery.message,
                channel,
                messageId: msRequestId || requestId,
                correlationId,
                locale: decrypted.delivery.locale,
            });
            let providerRequest;
            try {
                emit(logContext, 'provider_request_build_started');
                providerRequest = provider.createRequest({
                    channel,
                    endpoint: config.providerEndpoint,
                    delivery,
                    credential,
                    env: config.env,
                });
            } catch {
                fail('provider_request_build', 'request_build_failed', 502);
                return respond(502, { error: 'provider_delivery_failed', correlationId, requestId });
            }

            let transportResponse;
            try {
                transportResponse = await sendProviderRequest(
                    providerRequest,
                    parseProviderTimeout(config.providerTimeoutMs),
                    logContext,
                );
            } catch (error) {
                if (error instanceof ProviderTransportError) {
                    fail(error.stage, error.reason, error.httpStatus);
                    return respond(error.httpStatus, {
                        error: 'provider_delivery_failed',
                        correlationId,
                        requestId,
                    });
                }
                throw error;
            }

            let result;
            try {
                result = provider.interpretResponse(transportResponse);
            } catch {
                fail('provider_response', 'response_parse_failed', 500);
                return respond(500, { error: 'provider_delivery_failed', correlationId, requestId });
            }
            emit(logContext, 'provider_response_processed', {
                providerHttpStatus: result.providerHttpStatus,
                providerStatus: result.statusRecognized
                    ? result.providerStatusName || result.providerStatusCode
                    : 'unmapped',
                providerOutcome: result.outcome,
                providerMessageId: safeIdentifier(result.providerMessageId),
                providerElapsedMs: transportResponse.elapsedMs,
                failureReason: result.failureReason,
                httpStatus: result.httpStatus,
            }, result.httpStatus >= 500 ? 'error' : result.httpStatus === 200 ? 'log' : 'warn');

            if (result.httpStatus >= 400) {
                fail('provider_response', result.failureReason || 'provider_rejected', result.httpStatus);
                return respond(result.httpStatus, {
                    error: 'provider_delivery_failed',
                    correlationId,
                    requestId,
                });
            }
            return respond(200, {
                nonce: decrypted.delivery.nonce,
                correlationId,
                providerStatus: 'accepted',
            });
        } catch {
            if (!failureEmitted) {
                failureEmitted = true;
                unexpectedError(logContext);
            }
            return respond(500, { error: 'delivery_failed', correlationId, requestId });
        } finally {
            requestCompleted(logContext, status, status === 200
                ? evaluation ? 'evaluated' : 'accepted'
                : 'failed');
        }
    },
});

module.exports = { startProviderCredentialRefresh, stopProviderCredentialRefresh };
