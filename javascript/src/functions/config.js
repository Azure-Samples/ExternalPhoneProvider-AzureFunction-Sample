// <copyright file="config.js" company="Microsoft Corporation">
// Copyright (c) Microsoft Corporation. All rights reserved.
// </copyright>

'use strict';

function readConfig(env = process.env) {
    return {
        decryptionKeyPem: env.EPP_DECRYPTION_KEY_PEM || '',
        expectedKeyId: env.EPP_ENCRYPTION_KEY_ID || '',
        expectedAudience: (env.EPP_EXPECTED_AUDIENCE || '').trim(),
        expectedClientId: (env.EPP_EXPECTED_CLIENT_ID || '').trim(),
        expectedIssuer: (env.EPP_EXPECTED_ISSUER || '').trim(),
        tenantId: (env.EPP_TENANT_ID || '').trim(),
        requireAuth: (env.EPP_REQUIRE_AUTH || '').trim().toLowerCase() === 'true',
        providerName: (env.EPP_PROVIDER_NAME || '').trim().toLowerCase(),
        providerEndpoint: env.EPP_PROVIDER_ENDPOINT || '',
        providerTimeoutMs: env.EPP_PROVIDER_TIMEOUT_MS || '',
        keyVaultUrl: (env.KEY_VAULT_URL || '').trim(),
        managedIdentityClientId: (env.AZURE_CLIENT_ID || '').trim(),
        env,
    };
}

module.exports = { readConfig };
