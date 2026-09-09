// <copyright file="config.js" company="Microsoft Corporation">
// Copyright (c) Microsoft Corporation. All rights reserved.
// </copyright>

'use strict';

// Settings the request handler needs. dispatch.js and security.js read their own directly.

function readConfig() {
    const env = process.env;
    return {
        decryptionKeyPem: env.EPP_DECRYPTION_KEY_PEM || '',
        expectedClientId: env.EPP_EXPECTED_CLIENT_ID || '',
    };
}

module.exports = { readConfig };
