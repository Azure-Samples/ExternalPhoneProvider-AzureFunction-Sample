'use strict';

const { performance } = require('node:perf_hooks');

const IDENTIFIER_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/;
const HTTP_METHODS = new Set(['GET', 'HEAD', 'POST', 'PUT', 'DELETE', 'CONNECT', 'OPTIONS', 'TRACE', 'PATCH']);
const CONTEXT_FIELDS = [
    'functionName', 'functionRequestId', 'functionInvocationId',
    'x-ms-client-request-id', 'x-ms-correlation-id', 'msCorrelationIdSource',
    'omittedIdFields', 'channel', 'evaluation', 'providerName', 'providerAuthMode',
    'providerTenantId', 'functionOutboundClientId', 'functionOutboundManagedIdentityClientId',
];

function safeIdentifier(value) {
    return typeof value === 'string' && IDENTIFIER_PATTERN.test(value) ? value : null;
}

function createRequestContext(context, requestId, msRequestId, headerCorrelationId) {
    const clientId = safeIdentifier(msRequestId);
    const correlationId = safeIdentifier(headerCorrelationId);
    const omittedIdFields = [];
    if (msRequestId != null && !clientId && String(msRequestId).trim()) {
        omittedIdFields.push('x-ms-client-request-id');
    }
    if (headerCorrelationId != null && !correlationId && String(headerCorrelationId).trim()) {
        omittedIdFields.push('x-ms-correlation-id');
    }
    return Object.freeze({
        sink: context,
        started: performance.now(),
        functionName: 'SendOtp',
        functionRequestId: requestId,
        functionInvocationId: safeIdentifier(context.invocationId),
        'x-ms-client-request-id': clientId,
        'x-ms-correlation-id': correlationId,
        msCorrelationIdSource: correlationId ? 'header' : 'none',
        omittedIdFields: Object.freeze(omittedIdFields),
        channel: null,
        evaluation: null,
        providerName: null,
        providerAuthMode: null,
        providerTenantId: null,
        functionOutboundClientId: null,
        functionOutboundManagedIdentityClientId: null,
    });
}

function extendRequestContext(context, fields) {
    return Object.freeze({ ...context, ...fields });
}

function payloadContext(context, payload) {
    const hasPayloadCorrelationId = typeof payload.correlationId === 'string'
        && payload.correlationId.length > 0;
    const payloadCorrelationId = hasPayloadCorrelationId
        ? safeIdentifier(payload.correlationId) : null;
    const omittedIdFields = context.omittedIdFields
        .filter((field) => field !== 'x-ms-correlation-id');
    if (hasPayloadCorrelationId && !payloadCorrelationId) {
        omittedIdFields.push('x-ms-correlation-id');
    }
    return extendRequestContext(context, {
        'x-ms-correlation-id': hasPayloadCorrelationId
            ? payloadCorrelationId : context['x-ms-correlation-id'],
        msCorrelationIdSource: hasPayloadCorrelationId
            ? 'envelope' : context['x-ms-correlation-id'] ? 'header' : 'none',
        omittedIdFields: Object.freeze(omittedIdFields),
        channel: payload.channelName,
        evaluation: payload.isEvaluation,
    });
}

function providerContext(context, provider) {
    return extendRequestContext(context, {
        providerName: provider.name,
        providerAuthMode: provider.authenticationMode,
    });
}

function credentialContext(context, config) {
    const fields = {
        providerTenantId: config.providerTenantId,
        functionOutboundClientId: config.outboundClientId,
        functionOutboundManagedIdentityClientId: config.outboundManagedIdentityClientId,
    };
    const omittedIdFields = [...context.omittedIdFields];
    const safeFields = {};
    for (const [name, value] of Object.entries(fields)) {
        safeFields[name] = safeIdentifier(value);
        if (value != null && !safeFields[name] && String(value).trim()) {
            omittedIdFields.push(name);
        }
    }
    return extendRequestContext(context, {
        ...safeFields,
        omittedIdFields: Object.freeze([...new Set(omittedIdFields)]),
    });
}

function emit(context, eventName, details = {}, level = 'log') {
    const base = Object.fromEntries(CONTEXT_FIELDS.map((field) => [field, context[field] ?? null]));
    context.sink[level](JSON.stringify({
        logType: 'service',
        eventName,
        ...base,
        ...details,
        elapsedMs: Math.floor(performance.now() - context.started),
    }));
}

function requestFailed(context, failureStage, failureReason, httpStatus) {
    emit(context, 'request_failed', { failureStage, failureReason, httpStatus },
        httpStatus >= 500 ? 'error' : 'warn');
}

function requestCompleted(context, httpStatus, result) {
    emit(context, 'request_completed', { httpStatus, result });
}

function unexpectedError(context, httpStatus = 500) {
    emit(context, 'unexpected_error', { httpStatus }, 'error');
}

function normalizeHttpMethod(method) {
    const normalized = typeof method === 'string' ? method.toUpperCase() : '';
    return HTTP_METHODS.has(normalized) ? normalized : 'other';
}

function sanitizeEndpoint(value) {
    const url = new URL(value);
    return `${url.protocol}//${url.host}${url.pathname}`;
}

module.exports = {
    safeIdentifier,
    createRequestContext,
    extendRequestContext,
    payloadContext,
    providerContext,
    credentialContext,
    emit,
    requestFailed,
    requestCompleted,
    unexpectedError,
    normalizeHttpMethod,
    sanitizeEndpoint,
};
