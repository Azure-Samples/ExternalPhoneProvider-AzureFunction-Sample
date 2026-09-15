// <copyright file="soprano.js" company="Microsoft Corporation">
// Copyright (c) Microsoft Corporation. All rights reserved.
// </copyright>

'use strict';

const { ParsedResponse, TextToVoice } = require('../models');
const { ManagedIdentityCredential, ClientAssertionCredential } = require('@azure/identity');
const { AzureLogger } = require('@azure/logger');
const { AsyncLocalStorage } = require('node:async_hooks');

let tokenCredential;
let tokenCredentialSettings;
const tokenRequest = new AsyncLocalStorage();
let filteredLogger;

function jwtEnabled(env) {
    return typeof env?.EPP_PROVIDER_JWT_ENABLED === 'string'
        && env.EPP_PROVIDER_JWT_ENABLED.trim().toLowerCase() === 'true';
}

async function acquireToken(env) {
    if (!jwtEnabled(env)) return '';
    const scope = typeof env.EPP_PROVIDER_SCOPE === 'string' ? env.EPP_PROVIDER_SCOPE.trim() : '';
    const settings = [env.EPP_PROVIDER_TENANT_ID, env.EPP_PROVIDER_APPLICATION_ID, env.EPP_PROVIDER_MI_CLIENT_ID]
        .map(value => typeof value === 'string' ? value.trim() : '');
    if (!scope || settings.some(value => !value)) return '';
    if (AzureLogger.log !== filteredLogger) {
        const log = AzureLogger.log;
        filteredLogger = (...args) => { if (!tokenRequest.getStore()) log(...args); };
        AzureLogger.log = filteredLogger;
    }
    return tokenRequest.run(true, async () => {
        try {
            if (!tokenCredential || settings.some((value, index) => value !== tokenCredentialSettings[index])) {
                const [tenant, applicationId, managedIdentityId] = settings;
                const managedIdentity = new ManagedIdentityCredential({
                    clientId: managedIdentityId, retryOptions: { maxRetries: 0 },
                });
                tokenCredential = new ClientAssertionCredential(tenant, applicationId, async () => {
                    const assertion = await managedIdentity.getToken('api://AzureADTokenExchange/.default', {
                        abortSignal: AbortSignal.timeout(2500),
                    });
                    if (!assertion || assertion.expiresOnTimestamp <= Date.now() + 30000
                        || typeof assertion.token !== 'string' || !assertion.token.trim()) {
                        throw new Error('managed identity assertion unavailable');
                    }
                    return assertion.token;
                }, { authorityHost: 'https://login.microsoftonline.com', retryOptions: { maxRetries: 0 } });
                tokenCredentialSettings = settings;
            }
            const result = await tokenCredential.getToken(scope, { abortSignal: AbortSignal.timeout(2500) });
            return result && result.expiresOnTimestamp > Date.now() + 30000
                && typeof result.token === 'string' && result.token.trim() ? result.token : '';
        } catch {
            return '';
        }
    });
}

const manifest = {
    id: 'soprano',
    requiresTextToVoice: true,
    auth: {
        mode: 'apiKey',
        keyVaultSecretName: 'soprano-api-key',
        identityKeyVaultSecretName: 'soprano-api-id',
    },
    responseMapping: {
        ENROUTE: 'Continue',
        ACCEPTED: 'Continue',
        SUBMITTED: 'Continue',
        SENT: 'Continue',
        DELIVERED: 'Continue',
        QUEUED: 'Continue',
        FAILED: 'Fail',
        REJECTED: 'Fail',
        FILTERED: 'Fail',
        BLOCKED: 'Block',
        default: 'Fail',
    },
};

function buildRequest({ channel, endpoint, dispatch, credential, env }) {
    let base = endpoint;
    while (base.endsWith('/')) base = base.slice(0, -1);
    const headers = {
        'Content-Type': 'application/json',
        Accept: 'application/json',
        'X-MEMS-API-ID': credential.identity,
        'X-MEMS-API-Key': credential.secret,
    };
    if (jwtEnabled(env) && typeof credential.token === 'string' && credential.token.trim()) headers.Authorization = `Bearer ${credential.token}`;
    let destination = String(dispatch.destination || '');
    while (destination.startsWith('+')) destination = destination.slice(1);
    const body = {
        destination,
        messageTypes: [channel === 'voice' ? 'voice' : 'sms'],
        correlationId: dispatch.correlationId || dispatch.messageId,
        shutterMode: false,
    };
    if (channel === 'voice') {
        const voice = dispatch.textToVoice;
        if (!(voice instanceof TextToVoice) || !voice.isComplete) throw new Error('incomplete voice context');
        body.voice = { text2voice: voice };
    } else {
        body.text = dispatch.message;
    }
    return { url: `${base}/messages/omnimsg`, method: 'POST', headers, body: JSON.stringify(body) };
}

function parseResponse({ httpStatus, ok, json }) {
    const payload = (Array.isArray(json) ? json[0] : json) || {};
    const value = payload.status ?? payload.state;
    const status = typeof value === 'string' && value ? value.toUpperCase() : 'UNKNOWN';
    return new ParsedResponse({
        success: ok,
        providerHttpStatus: httpStatus,
        providerMessageId: (payload.id != null ? String(payload.id) : null) || payload.messageId || null,
        providerStatusName: status,
    });
}

module.exports = { manifest, buildRequest, parseResponse, acquireToken };
