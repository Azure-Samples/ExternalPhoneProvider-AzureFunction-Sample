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
        this.providerTimeoutMs = env.EPP_PROVIDER_TIMEOUT_MS || '';
        this.keyVaultUrl = (env.KEY_VAULT_URL || '').trim();
        this.managedIdentityClientId = (env.AZURE_CLIENT_ID || '').trim();
        this.env = env;
    }

    [inspect.custom]() { return '[AppConfig]'; }
}

const readConfig = (env = process.env) => new AppConfig(env);

module.exports = { AppConfig, readConfig };
