// <copyright file="config.js" company="Microsoft Corporation">
// Copyright (c) Microsoft Corporation. All rights reserved.
// </copyright>

'use strict';

const { inspect } = require('node:util');

class AppConfig {
    constructor(env = process.env) {
        this.decryptionKeyPem = env.EPP_DECRYPTION_KEY_PEM || '';
        this.expectedKeyId = env.EPP_ENCRYPTION_KEY_ID || '';
        this.providerName = (env.EPP_PROVIDER_NAME || '').trim().toLowerCase();
        this.providerEndpoint = env.EPP_PROVIDER_ENDPOINT || '';
        this.providerChannel = (env.EPP_PROVIDER_CHANNEL || '').trim().toLowerCase();
        this.providerAuthMode = (env.EPP_PROVIDER_AUTH_MODE || '').trim();
        this.providerTenantId = (env.EPP_PROVIDER_TENANT_ID || '').trim();
        this.providerScope = (env.EPP_PROVIDER_SCOPE || '').trim();
        this.outboundClientId = (env.EPP_OUTBOUND_CLIENT_ID || '').trim();
        this.outboundManagedIdentityClientId = (env.EPP_OUTBOUND_MI_CLIENT_ID || '').trim();
        this.providerTimeoutMs = env.EPP_PROVIDER_TIMEOUT_MS || '';
        this.keyVaultUrl = (env.KEY_VAULT_URL || '').trim();
        this.managedIdentityClientId = (env.AZURE_CLIENT_ID || '').trim();
        this.env = env;
    }

    [inspect.custom]() { return '[AppConfig]'; }
}

const readConfig = (env = process.env) => new AppConfig(env);

module.exports = { AppConfig, readConfig };
