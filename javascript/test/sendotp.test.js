'use strict';

const { test, beforeEach, afterEach, mock } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const Module = require('node:module');
const { CompactEncrypt } = require('jose');
const { ClientAssertionCredential } = require('@azure/identity');
const { SecretClient } = require('@azure/keyvault-secrets');
const fixtures = require('../../tests/fixtures/contract.json');

// Capture the real handler; keys stay in memory and all external I/O is mocked.
const { publicKey, privateKey } = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });
let handler;
const originalLoad = Module._load;
const registration = mock.method(Module, '_load', function (name, ...args) {
    if (name === '@azure/functions') {
        return { app: { http: (_name, options) => { handler = options.handler; } } };
    }
    return originalLoad.call(this, name, ...args);
});
try {
    require('../src/functions/SendOtp');
} finally {
    registration.mock.restore();
}

const envKeys = ['EPP_ENCRYPTION_KEY_ID', 'AZURE_CLIENT_ID', 'EPP_PROVIDER_NAME', 'EPP_PROVIDER_ENDPOINT',
    'EPP_PROVIDER_TIMEOUT_MS', 'EPP_PROVIDER_AUTH_MODE', 'EPP_PROVIDER_TENANT_ID', 'EPP_PROVIDER_SCOPE',
    'EPP_OUTBOUND_CLIENT_ID', 'EPP_OUTBOUND_MI_CLIENT_ID', 'EPP_LOG_PLAINTEXT', 'KEY_VAULT_URL',
    'EPP_DECRYPTION_KEY_PEM'];
let savedEnv;
let fetchMock;
let getSecret;
let logs;
let warnings;
beforeEach(() => {
    savedEnv = Object.fromEntries(envKeys.map((key) => [key, process.env[key]]));
    for (const key of envKeys) delete process.env[key];
    Object.assign(process.env, { EPP_LOG_PLAINTEXT: 'true',
        EPP_DECRYPTION_KEY_PEM: privateKey.export({ type: 'pkcs8', format: 'pem' }),
        KEY_VAULT_URL: 'https://unit-test.vault.azure.net', EPP_PROVIDER_NAME: 'soprano',
        EPP_PROVIDER_ENDPOINT: 'https://provider.example/epp/messages', EPP_PROVIDER_AUTH_MODE: 'oauth',
        EPP_PROVIDER_TENANT_ID: '11111111-1111-1111-1111-111111111111',
        EPP_PROVIDER_SCOPE: 'api://provider/.default',
        EPP_OUTBOUND_CLIENT_ID: '22222222-2222-2222-2222-222222222222',
        EPP_OUTBOUND_MI_CLIENT_ID: '33333333-3333-3333-3333-333333333333' });
    mock.method(ClientAssertionCredential.prototype, 'getToken', async () => ({ token: 'PRIVATE-OAUTH-TOKEN' }));
    getSecret = mock.method(SecretClient.prototype, 'getSecret', async () => ({ value: 'PRIVATE-API-KEY' }));
    fetchMock = mock.method(global, 'fetch', async () => ({ ok: true, status: 201,
        text: async () => JSON.stringify({ status: 'ENROUTE', id: 'PRIVATE-ID', description: 'PRIVATE-STATUS' }) }));
});
afterEach(() => {
    mock.restoreAll();
    for (const [key, value] of Object.entries(savedEnv)) {
        if (value === undefined) delete process.env[key];
        else process.env[key] = value;
    }
});

const delivery = { nonce: 'PRIVATE-NONCE', phoneNumber: '+15551234567',
    message: '  PRIVATE-MESSAGE 918273.\n', locale: 'PRIVATE-LOCALE', riskContext: { detail: 'PRIVATE-RISK' } };
async function envelope(overrides = {}, context = delivery, header = {}) {
    const encryptedDeliveryContext = await new CompactEncrypt(Buffer.from(JSON.stringify(context)))
        .setProtectedHeader({ alg: 'RSA-OAEP-256', enc: 'A256GCM', kid: 'PRIVATE-KID', ...header })
        .encrypt(publicKey);
    return { type: 'microsoft.mfa.otpDeliver.v1', channel: 1, mode: 1, ttlSeconds: 60,
        correlationId: 'correlation-id', encryptedDeliveryContext, ...overrides };
}
const invoke = (body, headers = {}) => {
    logs = [];
    warnings = [];
    return handler({ headers: { get: (name) => headers[name.toLowerCase()] || null },
        text: async () => typeof body === 'string' ? body : JSON.stringify(body) },
        { log: (value) => logs.push(value), warn: (...values) => warnings.push(values) });
};
function assertFailure(result, status, error = 'provider_delivery_failed') {
    assert.equal(result.status, status);
    assert.equal(result.jsonBody.error, error);
    assert.equal(result.jsonBody.nonce, undefined);
    assert.doesNotMatch(JSON.stringify(result.jsonBody), /PRIVATE|accepted/);
}

test('shared invalid requests return matching safe reasons before provider I/O', async () => {
    const valid = { type: 'microsoft.mfa.otpDeliver.v1', channel: 1, mode: 1, encryptedDeliveryContext: 'unused' };
    for (const fixture of fixtures.badRequests) {
        const result = await invoke(fixture.rawBody ?? { ...valid, ...fixture.overrides });
        assertFailure(result, 400, 'bad_request');
        assert.ok(result.jsonBody.requestId);
        assert.deepEqual(result.jsonBody, { error: 'bad_request', reason: fixture.reason,
            requestId: result.jsonBody.requestId }, fixture.name);
    }
    for (const changes of fixtures.incompleteContexts) {
        const result = await invoke(await envelope({ mode: 2 }, { ...delivery, ...changes }));
        assertFailure(result, 400, 'bad_request');
        assert.deepEqual(result.jsonBody, { error: 'bad_request', reason: 'incomplete delivery context',
            correlationId: 'correlation-id', requestId: result.jsonBody.requestId });
    }
    assert.deepEqual([getSecret.mock.callCount(), fetchMock.mock.callCount()], [0, 0]);
});

test('real JWE requires five segments and rejects a bad tag', async () => {
    process.env.EPP_ENCRYPTION_KEY_ID = 'mismatch';
    const body = await envelope();
    const parts = body.encryptedDeliveryContext.split('.');
    parts[4] = (parts[4][0] === 'A' ? 'B' : 'A') + parts[4].slice(1);
    for (const invalid of [{ ...body, encryptedDeliveryContext: parts.join('.') },
        { ...body, encryptedDeliveryContext: parts.slice(0, 4).join('.') }]) {
        assertFailure(await invoke(invalid), 400, 'decryption_failed');
        assert.deepEqual(warnings, []);
    }
    assert.deepEqual([getSecret.mock.callCount(), fetchMock.mock.callCount()], [0, 0]);
});

test('shared JWE policy permits only RSA-OAEP-256 with A256GCM', async () => {
    for (const { alg, enc, accepted } of fixtures.jwe) {
        const result = await invoke(await envelope({ mode: 2 }, delivery, { alg, enc }));
        if (accepted) {
            assert.equal(result.status, 200);
            assert.equal(result.jsonBody.nonce, delivery.nonce);
        } else {
            assertFailure(result, 400, 'decryption_failed');
            assert.deepEqual(result.jsonBody, { error: 'decryption_failed', correlationId: 'correlation-id',
                requestId: result.jsonBody.requestId });
        }
    }
    assert.deepEqual([getSecret.mock.callCount(), fetchMock.mock.callCount()], [0, 0]);
});

test('JWE authenticates the original protected-header bytes, not reserialized JSON', async () => {
    const header = '{ "kid" : "test-key", "enc" : "A256GCM", "alg" : "RSA-OAEP-256" }';
    const encodedHeader = Buffer.from(header).toString('base64url');
    const key = crypto.randomBytes(32);
    const iv = crypto.randomBytes(12);
    const cipher = crypto.createCipheriv('aes-256-gcm', key, iv);
    cipher.setAAD(Buffer.from(encodedHeader, 'ascii'));
    const ciphertext = Buffer.concat([cipher.update(JSON.stringify(delivery), 'utf8'), cipher.final()]);
    const wrappedKey = crypto.publicEncrypt({ key: publicKey, oaepHash: 'sha256',
        padding: crypto.constants.RSA_PKCS1_OAEP_PADDING }, key);
    const segments = [encodedHeader, ...[wrappedKey, iv, ciphertext, cipher.getAuthTag()]
        .map(value => value.toString('base64url'))];
    const body = await envelope({ mode: 2, encryptedDeliveryContext: segments.join('.') });
    const result = await invoke(body);
    assert.equal(result.status, 200);
    assert.equal(result.jsonBody.nonce, delivery.nonce);
    segments[0] = Buffer.from(JSON.stringify(JSON.parse(header))).toString('base64url');
    assertFailure(await invoke({ ...body, encryptedDeliveryContext: segments.join('.') }), 400, 'decryption_failed');
    assert.deepEqual([getSecret.mock.callCount(), fetchMock.mock.callCount()], [0, 0]);
});

test('evaluation decrypts without provider config or I/O and checks the advisory key ID', async () => {
    for (const key of ['EPP_PROVIDER_NAME', 'EPP_PROVIDER_ENDPOINT', 'KEY_VAULT_URL']) delete process.env[key];
    for (const expectedKeyId of ['', 'PRIVATE-KID', 'private-kid']) {
        process.env.EPP_ENCRYPTION_KEY_ID = expectedKeyId;
        const result = await invoke(await envelope({ mode: 'evaluation', provider: 'unknown' }));
        assert.equal(result.status, 200);
        assert.deepEqual(result.jsonBody, { nonce: delivery.nonce, correlationId: 'correlation-id', providerStatus: 'accepted' });
        assert.equal(logs[0].evaluation, true);
        assert.deepEqual(warnings, expectedKeyId === 'private-kid' ? [['encryption_key_id_mismatch']] : []);
    }
    assert.deepEqual([getSecret.mock.callCount(), fetchMock.mock.callCount()], [0, 0]);
});

test('SMS/voice preserve content and correlation without reflecting headers or logging PII', async () => {
    const correlationId = 'PRIVATE-CORRELATION';
    const textToVoice = { beforePasswordText: ' PRIVATE-PROMPT ', password: '001234', language: 'en-US' };
    const forgedHeaders = { authorization: 'Bearer FORGED-BEARER',
        'x-ms-client-principal': Buffer.from(JSON.stringify({
            claims: [{ typ: 'appid', val: 'FORGED-CALLER' }],
        })).toString('base64') };
    for (const [channel, name] of [[1, 'sms'], [2, 'voice']]) {
        const headers = channel === 1 ? {} : forgedHeaders;
        const result = await invoke(await envelope({ channel, correlationId, provider: 'unknown' },
            { ...delivery, textToVoice }), headers);
        assert.equal(result.status, 200);
        assert.deepEqual(result.jsonBody, { nonce: delivery.nonce, correlationId, providerStatus: 'accepted' });
        const init = fetchMock.mock.calls.at(-1).arguments[1];
        const sent = JSON.parse(init.body);
        assert.deepEqual([sent.messageTypes, sent.correlationId], [[name], correlationId]);
        if (channel === 2) {
            assert.deepEqual(sent.voice, { text2voice: textToVoice });
            assert.equal(sent.text, undefined);
        } else {
            assert.equal(sent.text, delivery.message);
            assert.equal(sent.voice, undefined);
        }
        assert.deepEqual(init.headers, { 'Content-Type': 'application/json', Accept: 'application/json',
            Authorization: 'Bear' + 'er PRIVATE-OAUTH-TOKEN' });
        assert.equal(init.redirect, 'manual');
        assert.equal(logs.length, 1);
        assert.deepEqual(Object.keys(logs[0]).sort(), ['correlationId', 'elapsedMs', 'evaluation', 'httpStatus', 'requestId']);
        assert.equal(logs[0].correlationId, crypto.createHash('sha256').update(correlationId).digest('hex').slice(0, 16));
        assert.doesNotMatch(JSON.stringify(logs), /PRIVATE|918273|001234|15551234567/);
        const output = JSON.stringify([result.jsonBody, logs, warnings]);
        assert.doesNotMatch(output, /FORGED/);
        for (const value of Object.values(forgedHeaders)) assert.equal(output.includes(value), false);
    }
    assert.equal(fetchMock.mock.callCount(), 2);
});

test('Telesign EPP sends decrypted SMS and voice content with Basic auth and private logs', async () => {
    process.env.EPP_PROVIDER_NAME = 'telesign';
    process.env.EPP_PROVIDER_ENDPOINT = 'https://verify.telesign.com/epp/send';
    process.env.EPP_PROVIDER_AUTH_MODE = 'apiKey';
    for (const [channel, name, code] of [[1, 'sms', 290], [2, 'voice', 100],
        [1, 'sms', 3001], [2, 'voice', 3001]]) {
        fetchMock.mock.mockImplementation(async () => ({ ok: true, status: 200,
            text: async () => JSON.stringify({ reference_id: 'PRIVATE-REFERENCE', correlation_id: 'provider-correlation',
                status: { code, description: 'PRIVATE-STATUS' } }) }));
        const result = await invoke(await envelope({ channel }), { authorization: 'Bearer FORGED-TOKEN', 'x-shutter-mode': 'true' });
        assert.deepEqual(result.jsonBody, { nonce: delivery.nonce, correlationId: 'correlation-id', providerStatus: 'accepted' });
        assert.equal(result.status, 200);
        const [url, init] = fetchMock.mock.calls.at(-1).arguments;
        assert.equal(url, 'https://verify.telesign.com/epp/send');
        assert.deepEqual(JSON.parse(init.body), { recipient: { phone_number: delivery.phoneNumber },
            message: { text: delivery.message, language: delivery.locale }, channels: [{ channel: name }], correlation_id: 'correlation-id' });
        assert.deepEqual(init.headers, { Authorization: `Basic ${Buffer.from('PRIVATE-API-KEY:PRIVATE-API-KEY').toString('base64')}`,
            'Content-Type': 'application/json', Accept: 'application/json' });
        assert.equal(init.redirect, 'manual');
        assert.doesNotMatch(JSON.stringify(logs), /PRIVATE|918273|15551234567|FORGED/);
        assert.equal(result.jsonBody.reference_id, undefined);
    }
    assert.equal(fetchMock.mock.callCount(), 4);
});

test('Telesign evaluation never sends and invalid recipients never reach HTTP', async () => {
    process.env.EPP_PROVIDER_NAME = 'telesign';
    process.env.EPP_PROVIDER_ENDPOINT = 'https://verify.telesign.com';
    for (const channel of [1, 2]) {
        const result = await invoke(await envelope({ channel, mode: 2 }));
        assert.equal(result.status, 200);
        assert.equal(result.jsonBody.nonce, delivery.nonce);
    }
    assert.deepEqual([getSecret.mock.callCount(), fetchMock.mock.callCount()], [0, 0]);
    assertFailure(await invoke(await envelope({}, { ...delivery, phoneNumber: '15551234567' })), 502);
    assert.equal(fetchMock.mock.callCount(), 0);
});

test('Telesign missing status or upstream failure never acknowledges delivery', async () => {
    process.env.EPP_PROVIDER_NAME = 'telesign';
    process.env.EPP_PROVIDER_ENDPOINT = 'https://verify.telesign.com';
    process.env.EPP_PROVIDER_AUTH_MODE = 'apiKey';
    for (const [status, payload, expected] of [[200, {}, 502], [500, { status: { code: 290 } }, 502],
        [429, { status: { code: 290 } }, 429], [500, { status: { code: 3001 } }, 502],
        [401, { status: { code: 3001 } }, 401], [429, { status: { code: 3001 } }, 429]]) {
        fetchMock.mock.mockImplementation(async () => ({ ok: status === 200, status, text: async () => JSON.stringify(payload) }));
        assertFailure(await invoke(await envelope()), expected);
    }
    assert.equal(fetchMock.mock.callCount(), 6);
});

test('handler awaits the provider body and returns 502/429 without a nonce or retries', async () => {
    for (const status of [500, 429]) {
        let release;
        let bodyStarted;
        const started = new Promise((resolve) => { bodyStarted = resolve; });
        const body = new Promise((resolve) => { release = resolve; });
        fetchMock.mock.mockImplementation(async () => ({ ok: false, status,
            text: () => { bodyStarted(); return body; } }));
        let settled = false;
        const pending = invoke(await envelope()).then((value) => { settled = true; return value; });
        try {
            await started;
            assert.equal(settled, false);
            assert.deepEqual(logs, []);
        } finally {
            release(JSON.stringify({ status: 'ENROUTE', description: 'PRIVATE-STATUS' }));
        }
        assertFailure(await pending, status === 500 ? 502 : 429);
    }
    assert.equal(fetchMock.mock.callCount(), 2);
});

test('the real abort timer covers response-body reading: 504, no retry and no nonce', async () => {
    process.env.EPP_PROVIDER_TIMEOUT_MS = '1';
    fetchMock.mock.mockImplementation(async (_url, { signal }) => ({
        ok: true, status: 200,
        text: () => new Promise((_resolve, reject) => {
            const abort = () => reject(new Error('PRIVATE-TIMEOUT'));
            if (signal.aborted) abort();
            else signal.addEventListener('abort', abort, { once: true });
        }),
    }));
    assertFailure(await invoke(await envelope()), 504);
    assert.equal(fetchMock.mock.callCount(), 1);
    assert.equal(fetchMock.mock.calls[0].arguments[1].signal.aborted, true);
});
