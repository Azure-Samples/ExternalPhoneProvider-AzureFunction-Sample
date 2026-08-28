'use strict';

// Tests for the SendOtp HTTP handler — the SAS → EPP envelope: validation, JWE decryption round-trip,
// the happy path (nonce echo), Evaluation mode, and auth rejection. Handlers are captured by stubbing
// @azure/functions; the JWE is encrypted here with a throwaway RSA key that the handler decrypts via
// EPP_DECRYPTION_KEY_PEM.

const { test, mock } = require('node:test');
const assert = require('node:assert');
const crypto = require('crypto');
const Module = require('module');
const { CompactEncrypt } = require('jose');

// Throwaway RSA keypair: the handler decrypts with the private PEM from the environment.
const { publicKey, privateKey } = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });
process.env.EPP_DECRYPTION_KEY_PEM = privateKey.export({ type: 'pkcs8', format: 'pem' });
process.env.KEY_VAULT_URL = 'https://test.vault.azure.net';
process.env.EPP_PROVIDER_ENDPOINT = 'https://api.infobip.com';
process.env.EPP_PROVIDER_NAME = 'infobip';

const { SecretClient } = require('@azure/keyvault-secrets');
mock.method(SecretClient.prototype, 'getSecret', async () => ({ value: 'ib' }));

// Capture the handlers SendOtp registers via app.http(...) by stubbing @azure/functions during require.
const handlers = {};
const originalLoad = Module._load;
Module._load = function (request, parent, isMain) {
    if (request === '@azure/functions') {
        return { app: { http: (name, opts) => { handlers[name] = opts.handler; } } };
    }
    return originalLoad.apply(this, arguments);
};
require('../src/functions/SendOtp');
Module._load = originalLoad;

// The handler answers before the provider call finishes, so tests await the send it kicked off.
const { whenDelivered } = require('../src/functions/SendOtp');

const ctx = { log() {} };

const makeReq = (body, headers = {}) => ({
    method: 'POST',
    url: 'http://localhost/api/SendOtp',
    headers: { get: (k) => headers[String(k).toLowerCase()] ?? null },
    text: async () => (typeof body === 'string' ? body : JSON.stringify(body)),
});

async function encryptContext(context, kid = 'test-key') {
    return new CompactEncrypt(Buffer.from(JSON.stringify(context)))
        .setProtectedHeader({ alg: 'RSA-OAEP-256', enc: 'A256GCM', kid })
        .encrypt(publicKey);
}

const sampleContext = () => ({
    nonce: 'nonce-abc',
    phoneNumber: '+14255551234',
    locale: 'en-US',
    message: 'Your code is 1 2 3 4 5 6',
});

async function makeEnvelope(overrides = {}, context = sampleContext()) {
    return {
        type: 'microsoft.mfa.otpDeliver.v1',
        tenantId: 'tenant-1',
        correlationId: 'corr-1',
        channel: 1,
        mode: 1,
        ttlSeconds: 60,
        encryptedDeliveryContext: await encryptContext(context),
        ...overrides,
    };
}

let sent;
global.fetch = async (url, opts) => {
    sent = { url, opts };
    return {
        ok: true,
        status: 200,
        text: async () => JSON.stringify({ messages: [{ status: { groupName: 'PENDING' }, messageId: 'x' }] }),
    };
};

test('SendOtp: invalid JSON body -> 400', async () => {
    const r = await handlers.SendOtp(makeReq('{ not json'), ctx);
    assert.equal(r.status, 400);
    assert.equal(r.jsonBody.error, 'bad_request');
});

test('SendOtp: missing encryptedDeliveryContext -> 400', async () => {
    const r = await handlers.SendOtp(makeReq({ type: 'v1', channel: 1, mode: 1 }), ctx);
    assert.equal(r.status, 400);
    assert.match(r.jsonBody.reason, /encryptedDeliveryContext/);
});

test('SendOtp: unsupported channel -> 400', async () => {
    const r = await handlers.SendOtp(makeReq(await makeEnvelope({ channel: 9 })), ctx);
    assert.equal(r.status, 400);
    assert.match(r.jsonBody.reason, /channel/);
});

test('SendOtp: unsupported mode -> 400', async () => {
    const r = await handlers.SendOtp(makeReq(await makeEnvelope({ mode: 5 })), ctx);
    assert.equal(r.status, 400);
    assert.match(r.jsonBody.reason, /mode/);
});

test('SendOtp: undecryptable context -> 400 decryption_failed', async () => {
    const r = await handlers.SendOtp(makeReq(await makeEnvelope({ encryptedDeliveryContext: 'eyJhbGciOiJSU0EtT0FFUC0yNTYiLCJlbmMiOiJBMjU2R0NNIn0.bad.bad.bad.bad' })), ctx);
    assert.equal(r.status, 400);
    assert.equal(r.jsonBody.error, 'decryption_failed');
});

test('SendOtp: incomplete context (no phoneNumber) -> 400', async () => {
    const r = await handlers.SendOtp(makeReq(await makeEnvelope({}, { nonce: 'n', message: 'm' })), ctx);
    assert.equal(r.status, 400);
    assert.match(r.jsonBody.reason, /incomplete/);
});

test('SendOtp: Live with ttlSeconds <= 0 still delivers, but warns', async () => {
    const lines = [];
    const warnCtx = { log: (m) => lines.push(String(m)), warn: (m) => lines.push(String(m)), error: () => {} };
    const r = await handlers.SendOtp(makeReq(await makeEnvelope({ ttlSeconds: 0 })), warnCtx);
    await whenDelivered();
    assert.equal(r.status, 200);
    assert.ok(lines.some((l) => /has expired/.test(l)), 'expected an expiry warning');
});

test('SendOtp: valid Live envelope -> 200 accepted, nonce echoed, sent over https', async () => {
    sent = undefined;
    const r = await handlers.SendOtp(makeReq(await makeEnvelope()), ctx);
    await whenDelivered();
    assert.equal(r.status, 200);
    assert.equal(r.jsonBody.providerStatus, 'accepted');
    assert.equal(r.jsonBody.nonce, 'nonce-abc');
    assert.equal(r.jsonBody.correlationId, 'corr-1');
    assert.match(sent.url, /^https:\/\//);
});

test('SendOtp: Evaluation mode -> 200 nonce echoed, nothing sent', async () => {
    let calls = 0;
    const original = global.fetch;
    global.fetch = async (...a) => { calls++; return original(...a); };
    try {
        const r = await handlers.SendOtp(makeReq(await makeEnvelope({ mode: 2 })), ctx);
        await whenDelivered();
        assert.equal(r.status, 200);
        assert.equal(r.jsonBody.nonce, 'nonce-abc');
        assert.equal(calls, 0);
    } finally {
        global.fetch = original;
    }
});

test('SendOtp: REQUIRE_AUTH enabled but misconfigured -> 401', async () => {
    process.env.EPP_REQUIRE_AUTH = 'true';
    try {
        const r = await handlers.SendOtp(makeReq(await makeEnvelope(), { authorization: 'Bearer abc' }), ctx);
        assert.equal(r.status, 401);
    } finally {
        delete process.env.EPP_REQUIRE_AUTH;
    }
});
