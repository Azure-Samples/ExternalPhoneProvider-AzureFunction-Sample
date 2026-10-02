'use strict';

const crypto = require('node:crypto');
const { compactDecrypt } = require('jose');
const { DeliveryContext } = require('./delivery');

const MAX_JWE_LENGTH = 16384;
let cachedKey;
let cachedPem;

function assertWellFormedJwe(value) {
    if (typeof value !== 'string' || value.length === 0) throw new Error('malformed JWE');
    if (value.length > MAX_JWE_LENGTH) throw new Error('delivery context exceeds size limit');
    const segments = value.split('.');
    if (segments.length !== 5 || segments.some((segment) => segment.length === 0)) {
        throw new Error('malformed JWE: expected five non-empty segments');
    }
}

function normalizePem(value) {
    const text = String(value || '');
    return text.includes('-----BEGIN') ? text : Buffer.from(text, 'base64').toString('utf8');
}

function loadPrivateKey(pem) {
    if (!pem) throw new Error('private key unavailable (EPP_DECRYPTION_KEY_PEM is not set)');
    if (cachedKey && cachedPem === pem) return cachedKey;
    cachedKey = crypto.createPrivateKey(normalizePem(pem));
    cachedPem = pem;
    return cachedKey;
}

function readProtectedHeader(compactJwe) {
    const protectedBytes = Buffer.from(compactJwe.split('.')[0], 'base64url');
    return JSON.parse(protectedBytes.toString('utf8'));
}

async function decryptDeliveryContext(compactJwe, decryptionKeyPem) {
    assertWellFormedJwe(compactJwe);
    const protectedHeader = readProtectedHeader(compactJwe);
    const { plaintext } = await compactDecrypt(compactJwe, loadPrivateKey(decryptionKeyPem), {
        keyManagementAlgorithms: ['RSA-OAEP-256'],
        contentEncryptionAlgorithms: ['A256GCM'],
    });
    const payload = JSON.parse(Buffer.from(plaintext).toString('utf8'));
    return Object.freeze({
        keyId: typeof protectedHeader.kid === 'string' ? protectedHeader.kid : null,
        delivery: DeliveryContext.fromPayload(payload),
    });
}

module.exports = { MAX_JWE_LENGTH, assertWellFormedJwe, decryptDeliveryContext };
