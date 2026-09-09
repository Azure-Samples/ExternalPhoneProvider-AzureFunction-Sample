'use strict';

const { test, mock, beforeEach } = require('node:test');
const assert = require('node:assert');
const crypto = require('crypto');
const Module = require('module');
const { CompactEncrypt } = require('jose');
const { parseEnvelope, getProvider, decryptDeliveryContext } = require('../src/functions/dispatch');

const phone = '+15559876543';
const code = '918273';
const token = 'PRIVATE-TOKEN-SENTINEL';
const hostile = `${phone}|${code}|${token}`;

const { publicKey, privateKey } = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });
const privatePem = privateKey.export({ type: 'pkcs8', format: 'pem' });
process.env.EPP_DECRYPTION_KEY_PEM = privatePem;
process.env.KEY_VAULT_URL = 'https://test.vault.azure.net';
process.env.EPP_PROVIDER_ENDPOINT = 'https://api.infobip.com';
process.env.EPP_PROVIDER_NAME = 'infobip';

const { SecretClient } = require('@azure/keyvault-secrets');
mock.method(SecretClient.prototype, 'getSecret', async () => ({ value: token }));

// Capture the handler without starting the Functions host.
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

async function invoke(request) {
    const logs = [];
    const log = (...args) => logs.push(args);
    const response = await handlers.SendOtp(request, { log, warn: log, error: log, invocationId: hostile });
    if (response.status !== 200) assert.equal(response.jsonBody.nonce, undefined);
    const text = JSON.stringify(logs);
    for (const secret of [phone, code, token, privatePem, 'nonce-abc', delivery.message]) {
        assert.ok(!text.includes(secret), 'sensitive value must not appear in any log argument');
        if (response.status !== 200) assert.ok(!JSON.stringify(response.jsonBody).includes(secret), 'failure reflected private input');
    }
    return response;
}

beforeEach(() => {
    sent = undefined;
    process.env.EPP_REQUIRE_AUTH = 'false';
    process.env.EPP_LOG_PLAINTEXT = 'true';
    process.env.EPP_PROVIDER_ENDPOINT = 'https://api.infobip.com';
    delete process.env.WEBSITE_INSTANCE_ID;
    delete process.env.WEBSITE_HOSTNAME;
    delete process.env.EPP_EXPECTED_CLIENT_ID;
    delete process.env.EPP_PROVIDER_AUTH_MODE;
    delete process.env.EPP_PROVIDER_TIMEOUT_MS;
    delete process.env.EPP_EXPECTED_AUDIENCE;
    delete process.env.EPP_TENANT_ID;
});

const makeReq = (body, headers = {}) => ({
    method: 'POST',
    url: 'http://localhost/api/SendOtp',
    headers: { get: (k) => headers[String(k).toLowerCase()] ?? null },
    text: async () => (typeof body === 'string' ? body : JSON.stringify(body)),
});

async function encryptContext(context, kid = hostile) {
    return new CompactEncrypt(Buffer.from(JSON.stringify(context)))
        .setProtectedHeader({ alg: 'RSA-OAEP-256', enc: 'A256GCM', kid })
        .encrypt(publicKey);
}

const delivery = { nonce: 'nonce-abc', phoneNumber: phone, locale: 'en-US', message: `Your code is ${code}; reference 2026-09-08.` };

async function makeEnvelope(overrides = {}, context = delivery) {
    return {
        type: 'microsoft.mfa.otpDeliver.v1',
        tenantId: 'tenant-1', correlationId: 'corr-1', channel: 1, mode: 1, ttlSeconds: 60,
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

test('SendOtp: parser failures never reflect private input, even in diagnostics', async () => {
    const envelope = await makeEnvelope();
    for (const [body, reason] of [
        [`{ ${hostile}`, 'invalid JSON body'], [{ ...envelope, type: hostile }, 'unsupported type'],
        [{ ...envelope, channel: hostile }, 'unsupported channel'], [{ ...envelope, mode: hostile }, 'unsupported mode'],
    ]) {
        const r = await invoke(makeReq(body));
        assert.deepEqual(r.jsonBody, { error: 'bad_request', reason, requestId: r.jsonBody.requestId });
        assert.equal(r.status, 400);
        assert.equal(sent, undefined);
    }
});

test('parser rejects malformed roots, missing ciphertext and coerced or inherited enums', async () => {
    const envelope = await makeEnvelope();
    assert.equal(parseEnvelope(null).error, 'invalid envelope');
    assert.equal(parseEnvelope([]).error, 'invalid envelope');
    assert.equal(parseEnvelope({ ...envelope, encryptedDeliveryContext: null }).error, 'encryptedDeliveryContext is required');
    assert.equal(parseEnvelope({ ...envelope, channel: [1] }).error, 'unsupported channel');
    assert.equal(parseEnvelope({ ...envelope, mode: true }).error, 'unsupported mode');
    assert.equal(parseEnvelope({ ...envelope, mode: '__proto__' }).error, 'unsupported mode');
});

test('SendOtp: incomplete context (no phoneNumber) -> 400', async () => {
    const r = await invoke(makeReq(await makeEnvelope({}, { nonce: hostile, message: hostile })));
    assert.equal(r.status, 400);
    assert.equal(r.jsonBody.reason, 'incomplete delivery context');
    assert.equal(sent, undefined);
});

test('SendOtp: Live with ttlSeconds <= 0 is refused and nothing is sent', async () => {
    const r = await invoke(makeReq(await makeEnvelope({ ttlSeconds: 0 })));
    assert.equal(r.status, 400);
    assert.equal(r.jsonBody.reason, 'passcode has expired');
    assert.equal(sent, undefined, 'an expired passcode must not reach the provider');
});

test('TTL accepts omission or a positive integer, not coercion or fractions', async () => {
    const envelope = await makeEnvelope();
    assert.ok(parseEnvelope(envelope).envelope);
    delete envelope.ttlSeconds;
    assert.ok(parseEnvelope(envelope).envelope);
    for (const ttlSeconds of [null, true, '60', 0.5]) {
        assert.equal(parseEnvelope({ ...envelope, ttlSeconds }).error, 'ttlSeconds must be a positive integer');
    }
});

test('SendOtp: real JWE waits for the provider body before echoing nonce; plaintext flag cannot leak', { timeout: 5000 }, async (t) => {
    let finishBody, bodyStarted;
    const body = new Promise((resolve) => { finishBody = resolve; });
    const reading = new Promise((resolve) => { bodyStarted = resolve; });
    t.mock.method(global, 'fetch', async (url, opts) => {
        sent = { url, opts };
        return { ok: true, status: 200, text: () => { bodyStarted(); return body; } };
    });
    const envelope = await makeEnvelope({ channel: 'SMS', mode: 'LIVE', correlationId: hostile });
    let completed = false;
    const pending = invoke(makeReq(envelope, { authorization: `Bearer ${token}`, 'x-ms-client-request-id': hostile }))
        .then((r) => { completed = true; return r; });
    await reading;
    await new Promise(setImmediate);
    const completedBeforeBody = completed;
    finishBody(JSON.stringify({ messages: [{ status: { name: 'DELIVERED' } }] }));
    const r = await pending;
    assert.equal(completedBeforeBody, false, 'the HTTP handler must wait for delivery acceptance');
    assert.equal(r.status, 200);
    assert.equal(r.jsonBody.providerStatus, 'accepted');
    assert.equal(r.jsonBody.nonce, delivery.nonce);
    assert.equal(r.jsonBody.correlationId, hostile);
    assert.equal(new URL(sent.url).protocol, 'https:');
    const message = JSON.parse(sent.opts.body).messages[0];
    assert.equal(message.content.text, delivery.message);
    assert.equal(message.destinations[0].messageId, hostile, 'wire IDs must not be hashed');
});

test('SendOtp: Evaluation echoes nonce without delivery or a configured endpoint', async () => {
    delete process.env.EPP_PROVIDER_ENDPOINT;
    const r = await invoke(makeReq(await makeEnvelope({ channel: 'VOICE', mode: 'Evaluation' })));
    assert.equal(r.status, 200);
    assert.equal(r.jsonBody.nonce, delivery.nonce);
    assert.equal(sent, undefined);
});

test('SendOtp: failed provider reply or unknown status cannot echo nonce or private fields', async (t) => {
    let httpStatus;
    t.mock.method(global, 'fetch', async () => ({ ok: httpStatus === 200, status: httpStatus,
        text: async () => JSON.stringify({ messages: [{ messageId: hostile, status: { name: hostile, description: hostile } }] }),
    }));
    const envelope = await makeEnvelope({}, { ...delivery, nonce: hostile });
    for (const [upstream, expected] of [[401, 401], [200, 502]]) {
        httpStatus = upstream;
        const r = await invoke(makeReq(envelope));
        assert.equal(r.status, expected);
        assert.deepEqual(r.jsonBody, { error: 'provider_delivery_failed', correlationId: 'corr-1', requestId: r.jsonBody.requestId });
    }
});

test('SendOtp: an adapter exception becomes a generic failure without nonce', async (t) => {
    t.mock.method(getProvider('infobip').adapter, 'buildRequest', () => {
        throw new Error(hostile, { cause: new Error(hostile) });
    });
    const r = await invoke(makeReq(await makeEnvelope()));
    assert.equal(r.status, 500);
    assert.deepEqual(r.jsonBody, { error: 'delivery_failed', correlationId: 'corr-1', requestId: r.jsonBody.requestId });
    assert.equal(sent, undefined);
});

test('SendOtp: bearer and header-caller rejection are generic and precede body parsing', async (t) => {
    process.env.EPP_REQUIRE_AUTH = 'true';
    process.env.EPP_EXPECTED_AUDIENCE = 'aud';
    process.env.EPP_TENANT_ID = 'tid';
    const request = makeReq(hostile, { authorization: `Bearer ${hostile}` });
    const read = t.mock.method(request, 'text');
    const r = await invoke(request);
    assert.equal(r.status, 401);
    assert.equal(r.jsonBody.reason, 'token validation failed');
    process.env.EPP_EXPECTED_CLIENT_ID = 'expected-app';
    const principal = Buffer.from(JSON.stringify({ claims: [{ typ: 'appid', val: hostile }] })).toString('base64');
    request.headers = makeReq('', { 'x-ms-client-principal': principal }).headers;
    const blocked = await invoke(request);
    assert.equal(blocked.status, 403);
    assert.deepEqual(blocked.jsonBody, { error: 'unexpected_caller' });
    assert.equal(read.mock.callCount(), 0);
});

test('SendOtp: tampered JWE authentication tag is rejected without logging the hostile kid', async () => {
    const segments = (await encryptContext(delivery)).split('.');
    const tag = Buffer.from(segments[4], 'base64url');
    tag[0] ^= 1;
    segments[4] = tag.toString('base64url');
    const r = await invoke(makeReq(await makeEnvelope({ encryptedDeliveryContext: segments.join('.') })));
    assert.equal(r.status, 400);
    assert.equal(r.jsonBody.error, 'decryption_failed');
    assert.equal(sent, undefined);
});

test('JWE shape, size and pinned algorithms reject invalid input locally', async () => {
    const decrypt = (value) => decryptDeliveryContext(value, { decryptionKeyPem: privatePem });
    await assert.rejects(decrypt('a.b..d.e'), { message: 'malformed JWE: expected five non-empty segments' });
    await assert.rejects(decrypt('a'.repeat(16385)), { message: 'delivery context exceeds size limit' });
    const wrongAlg = await new CompactEncrypt(Buffer.from(JSON.stringify(delivery)))
        .setProtectedHeader({ alg: 'RSA-OAEP', enc: 'A256GCM' }).encrypt(publicKey);
    const wrongEnc = await new CompactEncrypt(Buffer.from(JSON.stringify(delivery)))
        .setProtectedHeader({ alg: 'RSA-OAEP-256', enc: 'A128GCM' }).encrypt(publicKey);
    await assert.rejects(decrypt(wrongAlg));
    await assert.rejects(decrypt(wrongEnc));
});
