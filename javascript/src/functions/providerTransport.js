'use strict';

const { performance } = require('node:perf_hooks');
const { emit, normalizeHttpMethod, sanitizeEndpoint } = require('./logging');

class ProviderTransportError extends Error {
    constructor(httpStatus, stage, reason) {
        super(reason);
        this.httpStatus = httpStatus;
        this.stage = stage;
        this.reason = reason;
    }
}

function parseProviderTimeout(value) {
    const text = typeof value === 'string' ? value.trim() : '';
    if (!text) return 1500;
    let milliseconds = 0;
    for (const digit of text) {
        if (digit < '0' || digit > '9') return 1500;
        milliseconds = Math.min(2500, milliseconds * 10 + digit.charCodeAt(0) - 48);
    }
    return milliseconds > 0 ? milliseconds : 1500;
}

function isValidProviderUrl(value) {
    if (typeof value !== 'string' || !value.toLowerCase().startsWith('https://')) return false;
    for (const character of value) {
        if (!character.trim() || character.charCodeAt(0) < 32 || character === '\\' || character === '#') return false;
    }
    const authority = value.slice('https://'.length).split('/')[0].split('?')[0];
    if (!authority || authority.includes('@') || authority.endsWith(':')) return false;
    try {
        const url = new URL(value);
        return url.protocol === 'https:' && !!url.hostname && !url.username && !url.password && !url.hash
            && (!url.port || (Number(url.port) >= 1 && Number(url.port) <= 65535));
    } catch {
        return false;
    }
}

async function sendProviderRequest(providerRequest, timeoutMs, logContext) {
    if (!isValidProviderUrl(providerRequest?.url)) {
        throw new ProviderTransportError(502, 'provider_request_build', 'invalid_provider_request_url');
    }
    const providerHttpMethod = normalizeHttpMethod(providerRequest.method || 'POST');
    const providerEndpoint = sanitizeEndpoint(providerRequest.url);
    emit(logContext, 'provider_request_built', {
        providerHttpMethod,
        providerEndpoint,
        providerScheme: 'https',
        redirectsAllowed: false,
    });

    const controller = new AbortController();
    let timedOut = false;
    const timer = setTimeout(() => {
        timedOut = true;
        controller.abort();
    }, timeoutMs);
    const started = performance.now();
    try {
        emit(logContext, 'provider_request_started', {
            providerTimeoutMs: timeoutMs,
            providerHttpMethod,
            providerEndpoint,
        });
        const response = await fetch(providerRequest.url, {
            method: providerRequest.method || 'POST',
            headers: providerRequest.headers,
            body: providerRequest.body,
            signal: controller.signal,
            redirect: 'manual',
        });
        emit(logContext, 'provider_response_received', { providerHttpStatus: response.status });
        const responseText = await response.text();
        try {
            return Object.freeze({
                providerHttpStatus: response.status,
                ok: response.ok,
                json: JSON.parse(responseText),
                validJson: true,
                elapsedMs: Math.floor(performance.now() - started),
            });
        } catch {
            emit(logContext, 'provider_response_invalid_json', {}, 'warn');
            return Object.freeze({
                providerHttpStatus: response.status,
                ok: response.ok,
                json: null,
                validJson: false,
                elapsedMs: Math.floor(performance.now() - started),
            });
        }
    } catch {
        throw new ProviderTransportError(
            timedOut ? 504 : 502,
            'provider_transport',
            timedOut ? 'provider_timeout' : 'provider_network_error',
        );
    } finally {
        clearTimeout(timer);
    }
}

module.exports = {
    ProviderTransportError,
    parseProviderTimeout,
    isValidProviderUrl,
    sendProviderRequest,
};
