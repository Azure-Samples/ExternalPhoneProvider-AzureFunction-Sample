// <copyright file="config.js" company="Microsoft Corporation">
// Copyright (c) Microsoft Corporation. All rights reserved.
// </copyright>

'use strict';

function readConfig(env = process.env) {
    return {
        decryptionKeyPem: env.EPP_DECRYPTION_KEY_PEM || '',
        expectedKeyId: env.EPP_ENCRYPTION_KEY_ID || '',
        providerName: (env.EPP_PROVIDER_NAME || '').trim().toLowerCase(),
        providerEndpoint: env.EPP_PROVIDER_ENDPOINT || '',
        providerTimeoutMs: env.EPP_PROVIDER_TIMEOUT_MS || '',
        keyVaultUrl: (env.KEY_VAULT_URL || '').trim(),
        managedIdentityClientId: (env.AZURE_CLIENT_ID || '').trim(),
        env,
    };
}

module.exports = { readConfig };
