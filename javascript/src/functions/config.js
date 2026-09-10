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
        const authValue = env.EPP_PROVIDER_AUTH_MODE === undefined ? 'apiKey' : env.EPP_PROVIDER_AUTH_MODE;
        const authMode = typeof authValue === 'string' ? authValue.trim().toLowerCase() : '';
        this.providerAuthMode = authMode === 'apikey' ? 'apiKey' : authMode;
        const jwtValue = env.EPP_PROVIDER_JWT_ENABLED === undefined ? 'false' : env.EPP_PROVIDER_JWT_ENABLED;
        const jwtFlag = typeof jwtValue === 'string' ? jwtValue.trim().toLowerCase() : '';
        this.providerJwtEnabled = jwtFlag === 'true' ? true : jwtFlag === 'false' ? false : null;
        this.keyVaultUrl = (env.KEY_VAULT_URL || '').trim();
        this.managedIdentityClientId = (env.AZURE_CLIENT_ID || '').trim();
        this.env = env;
    }

    [inspect.custom]() { return '[AppConfig]'; }
}

const readConfig = (env = process.env) => new AppConfig(env);

// App settings use trimmed ASCII decimal digits, no sign, exponent, or hex.
function parseProviderTimeout(value) {
    const text = typeof value === 'string' ? value.trim() : '';
    if (!text || [...text].some((character) => character < '0' || character > '9')) return 1500;
    const milliseconds = Number(text);
    return milliseconds > 0 ? Math.min(milliseconds, 2500) : 1500;
}

function isValidProviderUrl(value) {
    if (typeof value !== 'string' || !value.toLowerCase().startsWith('https://')) return false;
    for (const character of value) {
        if (!character.trim() || character.charCodeAt(0) < 32 || character === '\\' || character === '#') return false;
    }
    const authority = value.slice('https://'.length).split('/')[0].split('?')[0];
    // URL normalizes empty userinfo and empty ports away; reject those in the original authority too.
    if (!authority || authority.includes('@') || authority.endsWith(':')) return false;
    try {
        const url = new URL(value);
        return url.protocol === 'https:' && !!url.hostname && !url.username && !url.password && !url.hash
            && (!url.port || (Number(url.port) >= 1 && Number(url.port) <= 65535));
    } catch {
        return false;
    }
}

module.exports = { AppConfig, readConfig, parseProviderTimeout, isValidProviderUrl };
