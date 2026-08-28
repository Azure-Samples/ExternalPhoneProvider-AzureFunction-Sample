// <copyright file="config.js" company="Microsoft Corporation">
// Copyright (c) Microsoft Corporation. All rights reserved.
// </copyright>

'use strict';

// Settings the request handler needs. dispatch.js and security.js read their own directly.

function readConfig() {
    const env = process.env;
    return {
        decryptionKeyPem: env.EPP_DECRYPTION_KEY_PEM || '',
        expectedKeyId: env.EPP_ENCRYPTION_KEY_ID || '',
        expectedAudience: env.EPP_EXPECTED_AUDIENCE || '',
        expectedClientId: env.EPP_EXPECTED_CLIENT_ID || '',
        tenantId: env.EPP_TENANT_ID || '',
        // PII in the log. Diagnostics only, and must stay false in production.
        logPlaintext: String(env.EPP_LOG_PLAINTEXT || '').toLowerCase() === 'true',
        requireAuth: String(env.EPP_REQUIRE_AUTH || '').toLowerCase() === 'true',
        provider: {
            name: env.EPP_PROVIDER_NAME || '',
            endpoint: env.EPP_PROVIDER_ENDPOINT || '',
        },
    };
}

// Reported, never thrown: a missing provider setting still lets the delivery prove decryption.
function missingSettings(config) {
    const absent = [];
    if (!config.decryptionKeyPem) absent.push('EPP_DECRYPTION_KEY_PEM');
    if (!config.provider.name) absent.push('EPP_PROVIDER_NAME');
    if (!config.provider.endpoint) absent.push('EPP_PROVIDER_ENDPOINT');
    if (config.requireAuth && !config.expectedAudience) absent.push('EPP_EXPECTED_AUDIENCE');
    if (config.requireAuth && !config.tenantId) absent.push('EPP_TENANT_ID');
    return absent;
}

module.exports = { readConfig, missingSettings };
