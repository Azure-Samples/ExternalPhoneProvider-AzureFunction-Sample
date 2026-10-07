'use strict';

const { app } = require('@azure/functions');
const crypto = require('node:crypto');
const {
    createRequestContext,
    extendRequestContext,
    requestFailed,
    requestCompleted,
} = require('./logging');

let cachedPem;
let cachedReady = false;

function isKeyReady(pem) {
    if (pem === cachedPem) return cachedReady;
    cachedPem = pem;
    cachedReady = false;
    try {
        if (!pem) return false;
        const normalized = pem.includes('-----BEGIN')
            ? pem : Buffer.from(pem, 'base64').toString('utf8');
        const key = crypto.createPrivateKey(normalized);
        if (key.asymmetricKeyType !== 'rsa' || key.asymmetricKeyDetails.modulusLength < 2048) return false;

        // Exercise the JWE key-unwrapping algorithm with a synthetic AES-256 key.
        const plaintext = Buffer.alloc(32);
        const encrypted = crypto.publicEncrypt({
            key: crypto.createPublicKey(key),
            padding: crypto.constants.RSA_PKCS1_OAEP_PADDING,
            oaepHash: 'sha256',
        }, plaintext);
        cachedReady = crypto.privateDecrypt({
            key,
            padding: crypto.constants.RSA_PKCS1_OAEP_PADDING,
            oaepHash: 'sha256',
        }, encrypted).equals(plaintext);
    } catch {
        // Parser and crypto errors can contain configuration or key material.
        cachedReady = false;
    }
    return cachedReady;
}

if (process.env.EPP_FRONT_DOOR_HEALTH_ENABLED === 'true') {
    app.http('FrontDoorHealth', {
        route: 'health/ready',
        methods: ['GET', 'HEAD'],
        authLevel: 'anonymous',
        handler: async (request, azureContext) => {
            const logContext = extendRequestContext(
                createRequestContext(azureContext, crypto.randomUUID()),
                { functionName: 'FrontDoorHealth' },
            );
            const ready = isKeyReady(process.env.EPP_DECRYPTION_KEY_PEM);
            const status = ready ? 200 : 503;
            if (!ready) {
                requestFailed(logContext, 'readiness', 'key_unavailable', status);
            }
            requestCompleted(logContext, status, ready ? 'ready' : 'not_ready');
            return {
                status,
                headers: { 'Cache-Control': 'no-store' },
                ...(request.method === 'HEAD' ? {} : {
                    jsonBody: { status: ready ? 'ready' : 'not_ready' },
                }),
            };
        },
    });
}
