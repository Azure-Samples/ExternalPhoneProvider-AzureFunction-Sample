// <copyright file="requestLog.js" company="Microsoft Corporation">
// Copyright (c) Microsoft Corporation. All rights reserved.
// </copyright>

'use strict';

const { performance } = require('node:perf_hooks');

const contextFields = [
    'functionName', 'functionRequestId', 'functionInvocationId',
    'x-ms-client-request-id', 'x-ms-correlation-id', 'msCorrelationIdSource', 'omittedIdFields',
    'channel', 'evaluation', 'providerName',
];
const credentialFields = [
    'providerAuthMode', 'providerCredentialSource', 'providerTenantId',
    'functionOutboundClientId', 'functionOutboundManagedIdentityClientId',
];
const httpMethods = new Set(['GET', 'HEAD', 'POST', 'PUT', 'DELETE', 'CONNECT', 'OPTIONS', 'TRACE', 'PATCH']);

const identifierPattern = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/;

// Only explicitly selected metadata enters logs; never serialize request/provider models.
class RequestLog {
    constructor(context, requestId, msRequestId, msCorrelationId) {
        this.context = context;
        this.started = performance.now();
        this.providerStarted = null;
        this.credentialStarted = null;
        this.data = {
            functionName: 'SendOtp',
            functionRequestId: requestId,
            functionInvocationId: context.invocationId || null,
            'x-ms-client-request-id': null,
            'x-ms-correlation-id': null,
            msCorrelationIdSource: 'none',
            omittedIdFields: [],
            envelopeType: null,
            ttlSeconds: null,
            channel: null,
            evaluation: null,
            encryptionKeyIdMismatch: false,
            providerName: null,
            providerAuthMode: null,
            providerCredentialSource: null,
            providerCredentialElapsedMs: null,
            providerTenantId: null,
            functionOutboundClientId: null,
            functionOutboundManagedIdentityClientId: null,
            providerHttpMethod: null,
            providerEndpoint: null,
            providerAttempted: false,
            providerHttpStatus: null,
            providerStatus: null,
            providerOutcome: null,
            providerMessageId: null,
            providerElapsedMs: null,
            providerTimeoutMs: null,
            failureStage: null,
            failureReason: null,
            responseContainsNonce: null,
            responseContainsCorrelationId: null,
        };
        this.setIdentifier('x-ms-client-request-id', msRequestId);
        this.setIdentifier('x-ms-correlation-id', msCorrelationId);
        this.data.msCorrelationIdSource = this.data['x-ms-correlation-id'] ? 'header' : 'none';
    }

    setIdentifier(field, value) {
        const valid = typeof value === 'string' && value.length <= 128 && identifierPattern.exec(value)?.[0] === value;
        this.data[field] = valid ? value : null;
        this.data.omittedIdFields = this.data.omittedIdFields.filter((name) => name !== field);
        if (!valid && value != null && !(typeof value === 'string' && !value.trim())) {
            this.data.omittedIdFields.push(field);
        }
    }

    service(eventName, details = {}, level = 'log') {
        const context = Object.fromEntries(contextFields.map((key) => [key, this.data[key]]));
        this.context[level](JSON.stringify({
            logType: 'service', eventName, ...context, ...details,
            elapsedMs: Math.floor(performance.now() - this.started),
        }));
    }

    envelopeValidated(envelope, correlationId, source) {
        this.data.envelopeType = envelope.type;
        this.data.ttlSeconds = envelope.ttlSeconds ?? null;
        this.data.channel = envelope.channel === 1 ? 'sms' : 'voice';
        this.data.evaluation = envelope.mode === 2;
        this.setIdentifier('x-ms-correlation-id', correlationId);
        this.data.msCorrelationIdSource = this.data['x-ms-correlation-id'] ? source : 'none';
        this.service('envelope_validated', {
            envelopeType: this.data.envelopeType,
            ttlSeconds: this.data.ttlSeconds,
            encryptedDeliveryContextPresent: true,
        });
    }

    keyIdMismatch() {
        this.data.encryptionKeyIdMismatch = true;
        this.service('encryption_key_id_mismatch', {}, 'warn');
    }

    providerSelected(manifest) {
        this.data.providerName = manifest.id;
        this.data.providerAuthMode = ['apiKey', 'oauth'].includes(manifest.auth?.mode)
            ? manifest.auth.mode : 'unsupported';
        this.service('provider_selected', { providerAuthMode: this.data.providerAuthMode });
    }

    credentialResolutionStarted(config) {
        this.credentialStarted = performance.now();
        const oauth = this.data.providerAuthMode === 'oauth';
        this.data.providerCredentialSource = oauth ? 'managed_identity_client_assertion'
            : this.data.providerAuthMode === 'apiKey' ? 'key_vault' : 'unsupported';
        if (oauth) {
            this.setIdentifier('providerTenantId', config.providerTenantId);
            this.setIdentifier('functionOutboundClientId', config.outboundClientId);
            this.setIdentifier('functionOutboundManagedIdentityClientId', config.outboundManagedIdentityClientId);
        }
        this.service('provider_credential_resolution_started', this.credentialDetails());
    }

    credentialDetails() {
        return Object.fromEntries(credentialFields.map((key) => [key, this.data[key]]));
    }

    credentialResolutionFinished() {
        if (this.credentialStarted !== null) {
            this.data.providerCredentialElapsedMs = Math.floor(performance.now() - this.credentialStarted);
            this.credentialStarted = null;
        }
    }

    credentialResolved() {
        this.credentialResolutionFinished();
        this.service('provider_credential_resolved', {
            ...this.credentialDetails(),
            providerCredentialElapsedMs: this.data.providerCredentialElapsedMs,
        });
    }

    providerRequestBuilt(method, endpoint) {
        const normalizedMethod = typeof method === 'string' ? method.toUpperCase() : null;
        this.data.providerHttpMethod = httpMethods.has(normalizedMethod) ? normalizedMethod : 'other';
        const url = new URL(endpoint);
        this.data.providerEndpoint = `${url.protocol}//${url.host}${url.pathname}`;
        this.service('provider_request_built', {
            providerHttpMethod: this.data.providerHttpMethod,
            providerEndpoint: this.data.providerEndpoint,
            providerScheme: 'https',
            redirectsAllowed: false,
        });
    }

    providerRequestStarted(timeoutMs) {
        this.providerStarted = performance.now();
        this.data.providerAttempted = true;
        this.data.providerTimeoutMs = timeoutMs;
        this.service('provider_request_started', {
            providerTimeoutMs: timeoutMs,
            providerHttpMethod: this.data.providerHttpMethod,
            providerEndpoint: this.data.providerEndpoint,
        });
    }

    providerResponseReceived(status) {
        this.data.providerHttpStatus = status;
        this.service('provider_response_received', { providerHttpStatus: status });
    }

    providerRequestFinished() {
        if (this.providerStarted !== null) {
            this.data.providerElapsedMs = Math.floor(performance.now() - this.providerStarted);
            this.providerStarted = null;
        }
    }

    providerResponseProcessed(manifest, parsed, outcome, httpStatus, validJson) {
        const status = parsed.providerStatusName || parsed.providerStatusCode;
        const knownStatus = (typeof status === 'string' || typeof status === 'number')
            && status !== 'default' && Object.hasOwn(manifest.responseMapping || {}, status);
        this.data.providerStatus = knownStatus ? String(status) : 'unmapped';
        this.data.providerOutcome = outcome;
        this.setIdentifier('providerMessageId', parsed.providerMessageId);
        if (outcome !== 'Continue') {
            this.data.failureStage = 'provider_response';
            this.data.failureReason = validJson ? 'provider_rejected' : 'invalid_provider_json';
        }
        this.service('provider_response_processed', {
            providerHttpStatus: this.data.providerHttpStatus,
            providerStatus: this.data.providerStatus,
            providerOutcome: outcome,
            providerMessageId: this.data.providerMessageId,
            providerElapsedMs: this.data.providerElapsedMs,
            httpStatus,
            failureReason: this.data.failureReason,
        }, httpStatus >= 500 ? 'error' : httpStatus === 200 ? 'log' : 'warn');
    }

    failure(stage, reason, httpStatus) {
        this.credentialResolutionFinished();
        this.providerRequestFinished();
        this.data.failureStage = stage;
        this.data.failureReason = reason;
        this.service(`${stage}_failed`, { failureReason: reason, httpStatus },
            httpStatus >= 500 ? 'error' : 'warn');
    }

    responsePrepared(httpStatus, containsNonce, containsCorrelationId) {
        this.data.responseContainsNonce = containsNonce;
        this.data.responseContainsCorrelationId = containsCorrelationId;
        this.service('response_prepared', {
            httpStatus,
            responseContainsNonce: containsNonce,
            responseContainsCorrelationId: containsCorrelationId,
        });
    }

    complete(httpStatus) {
        this.credentialResolutionFinished();
        this.providerRequestFinished();
        this.context.log(JSON.stringify({
            logType: 'request',
            eventName: 'request_completed',
            ...this.data,
            httpStatus,
            result: httpStatus === 200 ? (this.data.evaluation ? 'evaluated' : 'accepted') : 'failed',
            elapsedMs: Math.floor(performance.now() - this.started),
        }));
    }
}

module.exports = { RequestLog };
