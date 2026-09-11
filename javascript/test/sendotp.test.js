'use strict';

const { test, beforeEach, afterEach, mock } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const Module = require('node:module');
const { CompactEncrypt } = require('jose');
const { SecretClient } = require('@azure/keyvault-secrets');
const { ProviderTokenAcquirer } = require('../src/functions/providerToken');
const { getProvider, resolveOutcome } = require('../src/functions/dispatch');
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
    'EPP_PROVIDER_TIMEOUT_MS', 'EPP_LOG_PLAINTEXT', 'KEY_VAULT_URL', 'EPP_DECRYPTION_KEY_PEM',
    'EPP_PROVIDER_AUTH_MODE', 'EPP_PROVIDER_TENANT_ID', 'EPP_PROVIDER_CLIENT_ID', 'EPP_PROVIDER_SCOPE',
    'EPP_PROVIDER_MI_CLIENT_ID', 'EPP_PROVIDER_CLIENT_SECRET_NAME', 'EPP_PROVIDER_CLIENT_SECRET',
    'EPP_PROVIDER_TOKEN_EXCHANGE_AUDIENCE', 'EPP_PROVIDER_JWT_ENABLED'];
let savedEnv;
let fetchMock;
let getSecret;
let getToken;
let logs;
let warnings;
beforeEach(() => {
    savedEnv = Object.fromEntries(envKeys.map((key) => [key, process.env[key]]));
    for (const key of envKeys) delete process.env[key];
    Object.assign(process.env, { EPP_LOG_PLAINTEXT: 'true',
        EPP_DECRYPTION_KEY_PEM: privateKey.export({ type: 'pkcs8', format: 'pem' }),
        KEY_VAULT_URL: 'https://unit-test.vault.azure.net', EPP_PROVIDER_NAME: 'soprano',
        EPP_PROVIDER_ENDPOINT: 'https://provider.example/cgpapi/' });
    getSecret = mock.method(SecretClient.prototype, 'getSecret', async () => ({ value: 'PRIVATE-API-KEY' }));
    getToken = mock.method(ProviderTokenAcquirer.prototype, 'acquire', async () => 'PRIVATE-PROVIDER-TOKEN');
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
    for (const value of ['PRIVATE', 'accepted'])
        assert.equal(JSON.stringify(result.jsonBody).includes(value), false);
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
    process.env.EPP_PROVIDER_AUTH_MODE = 'oauth2';
    process.env.EPP_PROVIDER_JWT_ENABLED = 'true';
    for (const expectedKeyId of ['', 'PRIVATE-KID', 'private-kid']) {
        process.env.EPP_ENCRYPTION_KEY_ID = expectedKeyId;
        const result = await invoke(await envelope({ channel: 2, mode: 'evaluation', provider: 'unknown' }));
        assert.equal(result.status, 200);
        assert.deepEqual(result.jsonBody, { nonce: delivery.nonce, correlationId: 'correlation-id', providerStatus: 'accepted' });
        assert.equal(logs[0].evaluation, true);
        assert.deepEqual(warnings, expectedKeyId === 'private-kid' ? [['encryption_key_id_mismatch']] : []);
    }
    assert.deepEqual([getSecret.mock.callCount(), getToken.mock.callCount(), fetchMock.mock.callCount()], [0, 0, 0]);
});

test('SMS/voice preserve content and correlation without reflecting headers or logging PII', async () => {
    const correlationId = 'PRIVATE-CORRELATION';
    const forgedHeaders = { authorization: 'Bearer FORGED-BEARER',
        'x-ms-client-principal': Buffer.from(JSON.stringify({
            claims: [{ typ: 'appid', val: 'FORGED-CALLER' }],
        })).toString('base64') };
    for (const [channel, name, mode, jwtEnabled, tokenError] of [[1, 'sms', 'apiKey', 'false'], [2, 'voice', 'apiKey', 'false'],
        [1, 'sms', 'oauth2', 'true'], [2, 'voice', 'oauth2', 'true'],
        [1, 'sms', 'apiKey', 'true'], [2, 'voice', 'apiKey', 'true'],
        [1, 'sms', 'apiKey', 'true', 'Error'], [2, 'voice', 'apiKey', 'true', 'TimeoutError']]) {
        process.env.EPP_PROVIDER_AUTH_MODE = mode;
        process.env.EPP_PROVIDER_JWT_ENABLED = jwtEnabled;
        getToken.mock.mockImplementation(async () => {
            if (tokenError) throw Object.assign(new Error('PRIVATE-SDK-ERROR'), { name: tokenError });
            return 'PRIVATE-PROVIDER-TOKEN';
        });
        const headers = channel === 1 ? {} : forgedHeaders;
        const voiceContext = { ...delivery, voice: { text2voice: fixtures.textToVoice } };
        const result = await invoke(await envelope({ channel, correlationId, provider: 'unknown' }, voiceContext), headers);
        assert.equal(result.status, 200);
        assert.deepEqual(result.jsonBody, { nonce: delivery.nonce, correlationId, providerStatus: 'accepted' });
        const init = fetchMock.mock.calls.at(-1).arguments[1];
        assert.equal(init.headers.Authorization, jwtEnabled === 'true' && !tokenError ? 'Bearer PRIVATE-PROVIDER-TOKEN' : undefined);
        assert.equal(init.headers['X-MEMS-API-Key'], mode === 'apiKey' ? 'PRIVATE-API-KEY' : undefined);
        assert.equal(init.headers['X-MEMS-API-ID'], mode === 'apiKey' ? 'PRIVATE-API-KEY' : undefined);
        const sent = JSON.parse(init.body);
        assert.deepEqual(sent, { destination: delivery.phoneNumber.slice(1), messageTypes: [name], correlationId,
            shutterMode: false, ...(channel === 2 ? { voice: { text2voice: fixtures.textToVoice } } : { text: delivery.message }) });
        assert.equal(init.redirect, 'manual');
        assert.equal(logs.length, 1);
        assert.deepEqual(Object.keys(logs[0]).sort(), ['correlationId', 'elapsedMs', 'evaluation', 'httpStatus', 'requestId']);
        assert.equal(logs[0].correlationId, crypto.createHash('sha256').update(correlationId).digest('hex').slice(0, 16));
        for (const value of ['PRIVATE', '918273', '15551234567'])
            assert.equal(JSON.stringify(logs).includes(value), false);
        for (const value of Object.values(fixtures.textToVoice)) {
            assert.equal(JSON.stringify([result.jsonBody, logs, warnings]).includes(value), false);
        }
        const output = JSON.stringify([result.jsonBody, logs, warnings]);
        assert.equal(output.includes('FORGED'), false);
        for (const value of Object.values(forgedHeaders)) assert.equal(output.includes(value), false);
    }
    assert.equal(fetchMock.mock.callCount(), 8);
    assert.equal(getToken.mock.callCount(), 6);
});

test('incomplete encrypted voice fails closed even with a valid outer voice object', async () => {
    process.env.EPP_PROVIDER_JWT_ENABLED = 'true';
    for (const mode of ['apiKey', 'oauth2']) {
        process.env.EPP_PROVIDER_AUTH_MODE = mode;
        for (const changes of fixtures.incompleteVoiceContexts) {
            const result = await invoke(await envelope({ channel: 2, voice: { text2voice: fixtures.textToVoice } },
                { ...delivery, ...changes }));
            assertFailure(result, 400);
            assert.deepEqual(result.jsonBody, { error: 'provider_delivery_failed', correlationId: 'correlation-id',
                requestId: result.jsonBody.requestId });
            for (const value of ['PRIVATE', '012345', 'en-GB', 'Your code is'])
                assert.equal(JSON.stringify([logs, warnings]).includes(value), false);
        }
    }
    assert.deepEqual([getSecret.mock.callCount(), getToken.mock.callCount(), fetchMock.mock.callCount()], [0, 0, 0]);
});

test('outbound authentication failures return fixed 502/504 without a nonce or provider send', async () => {
    process.env.EPP_PROVIDER_JWT_ENABLED = 'true';
    for (const [mode, errorName, status] of [['unknown', 'Error', 502], ['oauth2', 'Error', 502], ['oauth2', 'TimeoutError', 504]]) {
        process.env.EPP_PROVIDER_AUTH_MODE = mode;
        getToken.mock.mockImplementation(async () => { throw Object.assign(new Error('PRIVATE-SDK-ERROR'), { name: errorName }); });
        const result = await invoke(await envelope());
        assertFailure(result, status);
        assert.deepEqual(result.jsonBody, { error: 'provider_delivery_failed', correlationId: 'correlation-id',
            requestId: result.jsonBody.requestId });
        assert.equal(JSON.stringify([logs, warnings]).includes('PRIVATE'), false);
    }
    assert.deepEqual([getSecret.mock.callCount(), getToken.mock.callCount(), fetchMock.mock.callCount()], [0, 2, 0]);
});

test('handler awaits the provider body and returns failures without a nonce or retries, including dual-header 401', async () => {
    process.env.EPP_PROVIDER_JWT_ENABLED = 'true';
    for (const status of [500, 429, 401]) {
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
        assertFailure(await pending, status === 500 ? 502 : status);
    }
    assert.equal(fetchMock.mock.callCount(), 3);
    assert.equal(getToken.mock.callCount(), 3);
});

test('all providers require acceptance evidence and preserve failed HTTP without a nonce', async () => {
    const cases = [
        ['infobip', [
            '{"messages":[{"status":{"groupName":"PENDING"}}]}',
            '{"messages":[{"status":{"name":"ACCEPTED"}}]}',
            '{"messages":[{"status":{"groupName":null,"name":"DELIVERED"}}]}',
        ], [
            '{"messages":{"0":{"status":{"groupName":"PENDING"}}}}', '{"messages":[null]}',
            '{"messages":[{"status":[]}]}', '{"messages":[{"status":{"name":123}}]}',
            ...[false, [], '', ' '].map(groupName => JSON.stringify({ messages: [{ status: { groupName, name: 'PENDING' } }] })),
        ]],
        ['telesign', [290, '290', 100, '100'].map(code => JSON.stringify({ status: { code } })), [
            '{"status":{}}', '{"status":[]}',
            ...[true, [290], {}, ''].map(code => JSON.stringify({ status: { code } })),
        ]],
        ['sinch', ['{"id":"batch-id"}', '{"callId":"call-id"}',
            '{"_links":{"self":"/batches/batch-id"}}', '{"_links":{"self":{"href":"/calls/call-id"}}}'], [
            '{"id":" "}', '{"callId":123}', '{"id":{"href":"/not-an-id"}}',
            '{"_links":{"self":{"href":123}}}', '{"_links":{"self":" "}}', '{"status":"Dispatched"}',
        ]],
        ['soprano', ['{"status":"ENROUTE"}', '[{"state":"ACCEPTED"}]'],
            ['{"status":false,"state":"ACCEPTED"}', '{"status":{},"state":"ACCEPTED"}']],
    ];
    const request = await envelope();
    for (const [provider, accepted, malformed] of cases) {
        process.env.EPP_PROVIDER_NAME = provider;
        const { adapter, manifest } = getProvider(provider);
        const rejectedJson = ['{}', 'null', '[]', ...malformed,
            ...(provider === 'soprano' ? [] : [`[${accepted[0]}]`])];
        for (const raw of rejectedJson) {
            const parsed = adapter.parseResponse({ httpStatus: 200, ok: true, json: JSON.parse(raw) });
            assert.equal(parsed.success, true); // Transport success is not acceptance.
            if (provider !== 'soprano') assert.equal(parsed.providerStatusName || parsed.providerStatusCode, 'UNKNOWN');
            assert.equal(resolveOutcome(manifest, parsed), 'Fail', `${provider}: ${raw}`);
        }
        const responses = [
            ...['<html>PRIVATE-UPSTREAM</html>', '', '{', ...rejectedJson].map(raw => [200, raw, 502]),
            [200, accepted[0].slice(0, -1) + ',"invalid":NaN}', 502],
            ...accepted.map(raw => [201, raw, 200]),
            ...[401, 403, 429, 500].flatMap(status => [accepted[0], '<html>PRIVATE-UPSTREAM</html>']
                .map(raw => [status, raw, status === 403 ? 401 : status === 500 ? 502 : status])),
        ];
        for (const [status, raw, expected] of responses) {
            const calls = fetchMock.mock.callCount();
            fetchMock.mock.mockImplementation(async () => ({ ok: status < 300, status, text: async () => raw }));
            const result = await invoke(request);
            if (expected === 200) {
                assert.equal(result.status, 200);
                assert.equal(result.jsonBody.nonce, delivery.nonce);
            } else assertFailure(result, expected);
            assert.equal(fetchMock.mock.callCount(), calls + 1);
            assert.equal(JSON.stringify([result.jsonBody, logs, warnings]).includes('PRIVATE-UPSTREAM'), false);
        }
    }
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
