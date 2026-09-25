'use strict';

const { test, beforeEach, afterEach, mock } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const Module = require('node:module');
const { CompactEncrypt } = require('jose');
const { ClientAssertionCredential, ManagedIdentityCredential } = require('@azure/identity');
const { SecretClient } = require('@azure/keyvault-secrets');
const fixtures = require('../../tests/fixtures/contract.json');
const { getProvider } = require('../src/functions/dispatch');
const { ProviderCredentials, providerCredentials } = require('../src/functions/credentials');
const { RequestLog } = require('../src/functions/requestLog');

// Capture the real handler; keys stay in memory and all external I/O is mocked.
const { publicKey, privateKey } = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });
let handler;
let startHook;
let stopHook;
const originalLoad = Module._load;
const registration = mock.method(Module, '_load', function (name, ...args) {
    if (name === '@azure/functions') {
        return { app: { hook: { appStart: (callback) => { startHook = callback; },
            appTerminate: (callback) => { stopHook = callback; } },
            http: (_name, options) => { handler = options.handler; } } };
    }
    return originalLoad.call(this, name, ...args);
});
try {
    require('../src/functions/SendOtp');
} finally {
    registration.mock.restore();
}

const envKeys = ['EPP_ENCRYPTION_KEY_ID', 'AZURE_CLIENT_ID', 'EPP_PROVIDER_NAME', 'EPP_PROVIDER_ENDPOINT', 'EPP_PROVIDER_CHANNEL',
    'EPP_PROVIDER_TIMEOUT_MS', 'EPP_PROVIDER_AUTH_MODE', 'EPP_PROVIDER_TENANT_ID', 'EPP_PROVIDER_SCOPE',
    'EPP_OUTBOUND_CLIENT_ID', 'EPP_OUTBOUND_MI_CLIENT_ID', 'EPP_LOG_PLAINTEXT', 'KEY_VAULT_URL',
    'EPP_DECRYPTION_KEY_PEM'];
let savedEnv;
let fetchMock;
let getSecret;
let logs;
let warnings;
let records;
let getToken;
let credentials;
beforeEach(() => {
    credentials = new ProviderCredentials();
    mock.method(providerCredentials, 'resolve', (...args) => credentials.resolve(...args));
    mock.method(providerCredentials, 'close', () => credentials.close());
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
    mock.method(ManagedIdentityCredential.prototype, 'getToken', async () => ({
        token: 'PRIVATE-ASSERTION', expiresOnTimestamp: Date.now() + 3600000,
    }));
    getToken = mock.method(ClientAssertionCredential.prototype, 'getToken', async function () {
        assert.equal(await this.getAssertion(), 'PRIVATE-ASSERTION');
        return { token: 'PRIVATE-OAUTH-TOKEN', expiresOnTimestamp: Date.now() + 3600000 };
    });
    getSecret = mock.method(SecretClient.prototype, 'getSecret', async () => ({ value: 'PRIVATE-API-KEY' }));
    fetchMock = mock.method(global, 'fetch', async () => ({ ok: true, status: 201,
        text: async () => JSON.stringify({ status: 'ENROUTE', id: 'provider-reference-id', description: 'PRIVATE-STATUS' }) }));
});
afterEach(() => {
    credentials.close();
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
    records = [];
    const capture = (level) => (value) => {
        const record = JSON.parse(value);
        records.push(record);
        if (level === 'log') logs.push(record);
        if (level === 'warn') warnings.push(record);
    };
    return handler({ headers: { get: (name) => headers[name.toLowerCase()] || null },
        text: async () => typeof body === 'string' ? body : JSON.stringify(body) },
        { invocationId: 'function-invocation-id', log: capture('log'), warn: capture('warn'), error: capture('error') })
        .then((result) => {
            const record = summary();
            assert.deepEqual(Object.keys(record).sort(), [...fixtures.logging.summaryFields].sort());
            assert.equal(records.at(-1), record);
            assert.equal(record.httpStatus, result.status);
            assert.equal(record.responseContainsNonce, Object.hasOwn(result.jsonBody, 'nonce'));
            assert.equal(record.responseContainsCorrelationId, Object.hasOwn(result.jsonBody, 'correlationId'));
            const prepared = records.filter((event) => event.eventName === 'response_prepared');
            assert.equal(prepared.length, 1);
            assert.equal(prepared[0], records.at(-2));
            assert.equal(prepared[0].httpStatus, result.status);
            assert.equal(prepared[0].responseContainsNonce, record.responseContainsNonce);
            assert.equal(prepared[0].responseContainsCorrelationId, record.responseContainsCorrelationId);
            assert.ok(record.elapsedMs >= 0);
            for (const event of records) {
                assert.equal(event.functionRequestId, record.functionRequestId);
                assert.equal(event.functionInvocationId, 'function-invocation-id');
                assert.equal(event.functionName, 'SendOtp');
            }
            assert.doesNotMatch(JSON.stringify(records), /PRIVATE|FORGED|918273|15551234567/);
            return result;
        });
};
function summary() {
    const summaries = records.filter((record) => record.logType === 'request');
    assert.equal(summaries.length, 1);
    assert.equal(summaries[0].eventName, 'request_completed');
    assert.equal(records.filter((record) => record.logType === 'service').length, records.length - 1);
    return summaries[0];
}
function assertFailure(result, status, error = 'provider_delivery_failed') {
    assert.equal(result.status, status);
    assert.equal(result.jsonBody.error, error);
    assert.equal(result.jsonBody.nonce, undefined);
    assert.doesNotMatch(JSON.stringify(result.jsonBody), /PRIVATE|accepted/);
}

test('worker startup preloads credentials without delivery and leaves evaluation independent', async () => {
    await startHook();
    assert.equal(getToken.mock.callCount(), 1);
    assert.equal(fetchMock.mock.callCount(), 0);
    assert.equal(getSecret.mock.callCount(), 0);
    const response = await invoke(await envelope({ mode: 2 }));
    assert.equal(response.status, 200);
    assert.equal(getToken.mock.callCount(), 1);
    assert.equal(fetchMock.mock.callCount(), 0);
    await invoke(await envelope());
    assert.equal(getToken.mock.callCount(), 1);
    assert.equal(fetchMock.mock.callCount(), 1);
    stopHook();
    assertFailure(await invoke(await envelope()), 502);
    assert.equal(getToken.mock.callCount(), 1);
    assert.equal(fetchMock.mock.callCount(), 1);
});

test('worker startup without a configured provider does not acquire any credentials', async () => {
    delete process.env.EPP_PROVIDER_NAME;
    await startHook();
    assert.equal(getToken.mock.callCount(), 0);
    assert.equal(getSecret.mock.callCount(), 0);
    assert.equal(fetchMock.mock.callCount(), 0);
});

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
        assert.equal(warnings.some((record) => record.eventName === 'encryption_key_id_mismatch'), false);
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
        assert.equal(summary().evaluation, true);
        assert.equal(summary().result, 'evaluated');
        assert.equal(summary().providerAttempted, false);
        assert.equal(summary().providerName, null);
        assert.equal(summary().providerHttpStatus, null);
        assert.equal(summary().providerElapsedMs, null);
        assert.equal(summary().providerCredentialSource, null);
        assert.equal(summary().providerCredentialElapsedMs, null);
        assert.equal(summary().providerEndpoint, null);
        assert.deepEqual(warnings.map((record) => record.eventName),
            expectedKeyId === 'private-kid' ? ['encryption_key_id_mismatch'] : []);
        assert.equal(summary().encryptionKeyIdMismatch, expectedKeyId === 'private-kid');
        assert.deepEqual(records.filter((record) => record.eventName !== 'encryption_key_id_mismatch')
            .map((record) => record.eventName), fixtures.logging.evaluationEvents);
    }
    assert.deepEqual([getSecret.mock.callCount(), fetchMock.mock.callCount()], [0, 0]);
    assert.equal(getToken.mock.callCount(), 0);
});

test('Soprano OAuth failures never fall back to keys or forward an inbound token', async () => {
    for (const failure of [async () => { throw new Error('PRIVATE-TOKEN-ERROR'); },
        async () => ({ token: 'PRIVATE-EXPIRED', expiresOnTimestamp: Date.now() - 1 })]) {
        getToken.mock.mockImplementation(failure);
        assertFailure(await invoke(await envelope({}, { ...delivery, providerJwt: 'FORGED-PAYLOAD' }),
            { authorization: 'Bearer FORGED-INBOUND' }), 502);
        assert.equal(summary().failureStage, 'provider_credentials');
        assert.equal(summary().failureReason, 'credential_unavailable');
        assert.equal(summary().providerAttempted, false);
        assert.equal(summary().providerCredentialSource, 'managed_identity_client_assertion');
        assert.ok(summary().providerCredentialElapsedMs >= 0);
        assert.equal(records.some((record) => record.eventName === 'provider_credential_resolved'), false);
    }
    assert.deepEqual([getSecret.mock.callCount(), fetchMock.mock.callCount()], [0, 0]);
});

test('SMS/voice preserve content and correlation without reflecting headers or logging PII', async () => {
    const correlationId = 'support-correlation-id';
    const forgedHeaders = { authorization: 'Bearer FORGED-BEARER',
        'x-ms-client-principal': Buffer.from(JSON.stringify({
            claims: [{ typ: 'appid', val: 'FORGED-CALLER' }],
        })).toString('base64') };
    for (const [channel, name] of [[1, 'sms'], [2, 'voice']]) {
        const headers = channel === 1 ? {} : forgedHeaders;
        const result = await invoke(await envelope({ channel, correlationId, provider: 'unknown' },
            { ...delivery, textToVoice: { language: 'override', gender: 2, loop: 9 } }), headers);
        assert.equal(result.status, 200);
        assert.deepEqual(result.jsonBody, { nonce: delivery.nonce, correlationId, providerStatus: 'accepted' });
        const init = fetchMock.mock.calls.at(-1).arguments[1];
        const sent = JSON.parse(init.body);
        assert.deepEqual([sent.messageTypes, sent.correlationId], [[name], correlationId]);
        if (channel === 2) {
            assert.deepEqual(sent.voice, { text2voice: {
                beforePasswordText: '  PRIVATE-MESSAGE ',
                password: '918273',
                afterPasswordText: '.\n',
                language: delivery.locale,
                gender: 1,
                loop: 2,
            } });
            assert.equal(sent.text, undefined);
        } else {
            assert.equal(sent.text, delivery.message);
            assert.equal(sent.voice, undefined);
        }
        assert.deepEqual(init.headers, { 'Content-Type': 'application/json', Accept: 'application/json',
            Authorization: 'Bear' + 'er PRIVATE-OAUTH-TOKEN' });
        assert.equal(init.redirect, 'manual');
        assert.deepEqual(records.map((record) => record.eventName), fixtures.logging.liveEvents);
        assert.equal(summary()['x-ms-correlation-id'], correlationId);
        assert.equal(summary().providerName, 'soprano');
        assert.equal(summary().providerAuthMode, 'oauth');
        assert.equal(summary().providerMessageId, 'provider-reference-id');
        assert.equal(summary().providerHttpStatus, 201);
        assert.equal(summary().providerStatus, 'ENROUTE');
        assert.equal(summary().providerOutcome, 'Continue');
        assert.equal(summary().channel, name);
        assert.equal(summary().providerAttempted, true);
        assert.equal(summary().providerTimeoutMs, 1500);
        assert.ok(summary().providerElapsedMs >= 0 && summary().providerElapsedMs <= summary().elapsedMs);
        assert.equal(summary().failureStage, null);
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
            text: async () => JSON.stringify({ reference_id: 'telesign-reference-id', correlation_id: 'provider-correlation',
                status: { code, description: 'PRIVATE-STATUS' } }) }));
        const result = await invoke(await envelope({ channel }), { authorization: 'Bearer FORGED-TOKEN', 'x-shutter-mode': 'true' });
        assert.deepEqual(result.jsonBody, { nonce: delivery.nonce, correlationId: 'correlation-id', providerStatus: 'accepted' });
        assert.equal(result.status, 200);
        const [url, init] = fetchMock.mock.calls.at(-1).arguments;
        assert.equal(url, 'https://verify.telesign.com/epp/send');
        const expectedText = name === 'voice'
            ? '  PRIVATE-MESSAGE 9, 1, 8, 2, 7, 3.\n   PRIVATE-MESSAGE 9, 1, 8, 2, 7, 3.\n'
            : delivery.message;
        assert.deepEqual(JSON.parse(init.body), { recipient: { phone_number: delivery.phoneNumber },
            message: { text: expectedText, language: delivery.locale }, channels: [{ channel: name }], correlation_id: 'correlation-id' });
        assert.deepEqual(init.headers, { Authorization: `Basic ${Buffer.from('PRIVATE-API-KEY:PRIVATE-API-KEY').toString('base64')}`,
            'Content-Type': 'application/json', Accept: 'application/json' });
        assert.equal(init.redirect, 'manual');
        assert.doesNotMatch(JSON.stringify(logs), /PRIVATE|918273|15551234567|FORGED/);
        assert.equal(result.jsonBody.reference_id, undefined);
        assert.equal(summary().providerStatus, String(code));
        assert.equal(summary().providerMessageId, 'telesign-reference-id');
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
        assert.equal(summary().providerHttpStatus, status);
        assert.equal(summary().providerOutcome, 'Fail');
        assert.equal(summary().failureStage, 'provider_response');
        assert.equal(summary().failureReason, 'provider_rejected');
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
            assert.equal(records.some((record) => record.logType === 'request'), false);
            assert.equal(records.at(-1).eventName, 'provider_response_received');
            assert.ok(records.some((record) => record.eventName === 'provider_request_started'));
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
    assert.equal(summary().failureStage, 'provider_transport');
    assert.equal(summary().failureReason, 'provider_timeout');
    assert.equal(summary().providerHttpStatus, 200);
    assert.equal(summary().providerTimeoutMs, 1);
    assert.equal(summary().providerStatus, null);
    assert.ok(summary().providerElapsedMs >= 0);
});

test('Microsoft, function and provider identifiers have distinct sources and no synthetic Microsoft IDs', async () => {
    const headers = { 'x-ms-client-request-id': 'ms-request-id', 'x-ms-correlation-id': 'ms-header-correlation-id' };
    for (const correlationId of ['ms-envelope-correlation-id', null]) {
        await invoke(await envelope({ correlationId }), headers);
        assert.equal(summary()['x-ms-client-request-id'], headers['x-ms-client-request-id']);
        assert.equal(summary()['x-ms-correlation-id'], correlationId || headers['x-ms-correlation-id']);
        assert.equal(summary().msCorrelationIdSource, correlationId ? 'envelope' : 'header');
        assert.equal(records[0].msCorrelationIdSource, 'header');
        assert.notEqual(summary().functionRequestId, summary()['x-ms-client-request-id']);
        assert.notEqual(summary().functionRequestId, summary().functionInvocationId);
    }
    const result = await invoke(await envelope({ correlationId: null }));
    assert.equal(result.jsonBody.correlationId, summary().functionRequestId);
    assert.equal(summary()['x-ms-client-request-id'], null);
    assert.equal(summary()['x-ms-correlation-id'], null);
    assert.equal(summary().msCorrelationIdSource, 'none');
});

test('early failures keep incoming Microsoft trace IDs and a fixed failure stage', async () => {
    const headers = { 'x-ms-client-request-id': 'ms-request-id', 'x-ms-correlation-id': 'ms-header-correlation-id' };
    for (const [body, stage, reason] of [
        ['{', 'request_validation', 'invalid JSON body'],
        [{}, 'request_validation', 'unsupported envelope type'],
        [await envelope({ encryptedDeliveryContext: 'PRIVATE-NOT-A-JWE' }), 'decryption', 'decryption_failed'],
        [await envelope({}, { ...delivery, nonce: '' }), 'delivery_context_validation', 'incomplete delivery context'],
    ]) {
        const result = await invoke(body, headers);
        assert.equal(result.status, 400);
        assert.equal(summary().functionRequestId, result.jsonBody.requestId);
        assert.equal(summary()['x-ms-client-request-id'], headers['x-ms-client-request-id']);
        assert.equal(summary().failureStage, stage);
        assert.equal(summary().msCorrelationIdSource, stage === 'request_validation' ? 'header' : 'envelope');
        assert.equal(summary()['x-ms-correlation-id'],
            stage === 'request_validation' ? headers['x-ms-correlation-id'] : 'correlation-id');
        assert.equal(summary().failureReason, reason);
        assert.equal(summary().providerAttempted, false);
        assert.equal(records.at(-3).eventName, `${stage}_failed`);
    }
});

test('invalid correlation metadata cannot become a raw log field or prevent the request summary', async () => {
    for (const correlationId of [42, { detail: 'support-correlation-id' }, ['support-correlation-id'], '']) {
        const result = await invoke(await envelope({ mode: 2, correlationId }));
        assert.equal(result.status, 200);
        assert.equal(summary()['x-ms-correlation-id'], null);
        assert.equal(summary().msCorrelationIdSource, 'none');
    }
});

for (const [name, configure, stage, reason, status] of [
    ['unknown provider', () => { process.env.EPP_PROVIDER_NAME = 'PRIVATE-UNKNOWN-PROVIDER'; },
        'provider_selection', 'unknown_provider', 400],
    ['wrong channel', () => { process.env.EPP_PROVIDER_CHANNEL = 'voice'; },
        'provider_configuration', 'channel_not_configured', 400],
    ['authentication mismatch', () => { process.env.EPP_PROVIDER_AUTH_MODE = 'apiKey'; },
        'provider_configuration', 'authentication_mode_mismatch', 502],
    ['invalid endpoint', () => { process.env.EPP_PROVIDER_ENDPOINT = 'http://PRIVATE-ENDPOINT'; },
        'provider_configuration', 'invalid_provider_endpoint', 502],
    ['request build failure', () => {
        mock.method(getProvider('soprano').adapter, 'buildRequest', () => { throw new Error('PRIVATE-BUILD-ERROR'); });
    }, 'provider_request_build', 'request_build_failed', 502],
    ['network failure', () => {
        fetchMock.mock.mockImplementation(async () => { throw new Error('PRIVATE-NETWORK-ERROR'); });
    }, 'provider_transport', 'provider_network_error', 502],
    ['adapter response failure', () => {
        mock.method(getProvider('soprano').adapter, 'parseResponse', () => { throw new Error('PRIVATE-PARSE-ERROR'); });
    }, 'provider_response', 'response_parse_failed', 500],
]) {
    test(`${name} emits its own service failure and a complete request summary`, async () => {
        configure();
        assertFailure(await invoke(await envelope()), status);
        assert.equal(summary().failureStage, stage);
        assert.equal(summary().failureReason, reason);
        assert.equal(records.at(-3).eventName, `${stage}_failed`);
        const attempted = ['provider_transport', 'provider_response'].includes(stage);
        assert.equal(summary().providerAttempted, attempted);
        assert.equal(fetchMock.mock.callCount(), attempted ? 1 : 0);
    });
}

test('unknown provider status and malformed provider JSON never become raw diagnostic fields', async () => {
    for (const body of [JSON.stringify({ id: 'provider-reference-id', status: 'PRIVATE-STATUS\nFORGED', description: 'PRIVATE-DESCRIPTION' }),
        '<html>PRIVATE-RESPONSE</html>']) {
        fetchMock.mock.mockImplementation(async () => ({ ok: true, status: 200, text: async () => body }));
        assertFailure(await invoke(await envelope()), 502);
        assert.equal(summary().providerStatus, 'unmapped');
        assert.equal(summary().providerOutcome, 'Fail');
        assert.equal(summary().failureReason, body.startsWith('{') ? 'provider_rejected' : 'invalid_provider_json');
    }
});

test('interleaved invocations retain their own log context and emit service events before completion', async () => {
    const eventSets = [[], []];
    const invocations = ['function-one', 'function-two'];
    const contexts = eventSets.map((events, index) => ({
        invocationId: invocations[index],
        log: (value) => events.push(JSON.parse(value)),
        warn: (value) => events.push(JSON.parse(value)),
        error: (value) => events.push(JSON.parse(value)),
    }));
    const bodies = await Promise.all(['correlation-first', 'correlation-second'].map((correlationId) => envelope({ correlationId })));
    await Promise.all(bodies.map((body, index) => handler({
        headers: { get: () => null },
        text: async () => JSON.stringify(body),
    }, contexts[index])));
    for (const [index, events] of eventSets.entries()) {
        assert.deepEqual(events.map((event) => event.eventName), fixtures.logging.liveEvents);
        const summary = events.at(-1);
        assert.equal(summary['x-ms-correlation-id'], bodies[index].correlationId);
        assert.ok(events.every((event) => event.functionRequestId === summary.functionRequestId
            && event.functionInvocationId === invocations[index]));
    }
    assert.notEqual(eventSets[0].at(-1).functionRequestId, eventSets[1].at(-1).functionRequestId);
    assert.doesNotMatch(JSON.stringify(eventSets), /PRIVATE/);
});

test('successful lifecycle logs allowed body fields, raw OAuth IDs and an endpoint without its query', async () => {
    process.env.EPP_PROVIDER_ENDPOINT = 'https://provider.example/api/send?key=PRIVATE-QUERY';
    const body = await envelope({
        tenantId: 'PRIVATE-TENANT',
        diagnosticData: { token: 'PRIVATE-UNKNOWN-FIELD' },
    });
    await invoke(body, { 'x-ms-client-principal': 'PRIVATE-PRINCIPAL', authorization: 'PRIVATE-INBOUND-AUTH' });
    const validated = records.find((record) => record.eventName === 'envelope_validated');
    assert.equal(validated.envelopeType, body.type);
    assert.equal(validated.ttlSeconds, 60);
    assert.equal(validated.encryptedDeliveryContextPresent, true);
    assert.equal(summary().envelopeType, body.type);
    assert.equal(summary().ttlSeconds, 60);
    const source = 'managed_identity_client_assertion';
    for (const record of [summary(), ...records.filter((record) =>
        ['provider_credential_resolution_started', 'provider_credential_resolved'].includes(record.eventName))]) {
        assert.equal(record.providerCredentialSource, source);
        assert.equal(record.functionOutboundClientId, process.env.EPP_OUTBOUND_CLIENT_ID);
        assert.equal(record.functionOutboundManagedIdentityClientId, process.env.EPP_OUTBOUND_MI_CLIENT_ID);
        assert.equal(record.providerTenantId, process.env.EPP_PROVIDER_TENANT_ID);
    }
    assert.ok(summary().providerCredentialElapsedMs >= 0 && summary().providerCredentialElapsedMs <= summary().elapsedMs);
    for (const record of [summary(), ...records.filter((record) =>
        ['provider_request_built', 'provider_request_started'].includes(record.eventName))]) {
        assert.equal(record.providerHttpMethod, 'POST');
        assert.equal(record.providerEndpoint, 'https://provider.example/api/send');
    }
    const built = records.find((record) => record.eventName === 'provider_request_built');
    assert.equal(built.providerScheme, 'https');
    assert.equal(built.redirectsAllowed, false);
    const output = JSON.stringify(records);
    for (const value of [body.encryptedDeliveryContext, process.env.EPP_PROVIDER_ENDPOINT]) {
        assert.equal(output.includes(value), false);
    }
    assert.deepEqual(records.map((record) => record.eventName), fixtures.logging.liveEvents);
});

test('API-key resolution is identified as Key Vault even when a later request uses cached credentials', async () => {
    process.env.EPP_PROVIDER_NAME = 'telesign';
    process.env.EPP_PROVIDER_AUTH_MODE = 'apiKey';
    process.env.KEY_VAULT_URL = 'https://logging-cache-test.vault.azure.net';
    fetchMock.mock.mockImplementation(async () => ({ ok: true, status: 200,
        text: async () => JSON.stringify({ status: { code: 3001 } }) }));
    for (let attempt = 0; attempt < 2; attempt++) {
        await invoke(await envelope());
        assert.equal(summary().providerCredentialSource, 'key_vault');
        assert.equal(summary().providerAuthMode, 'apiKey');
        assert.equal(summary().providerTenantId, null);
        assert.equal(summary().functionOutboundClientId, null);
        assert.equal(summary().functionOutboundManagedIdentityClientId, null);
        assert.ok(summary().providerCredentialElapsedMs >= 0);
        assert.deepEqual(records.map((record) => record.eventName), fixtures.logging.liveEvents);
        assert.equal(getSecret.mock.callCount(), 2);
    }
    assert.equal(getToken.mock.callCount(), 0);
});

test('optional TTL stays null and invalid body values never enter body metadata', async () => {
    const body = await envelope({ mode: 2 });
    delete body.ttlSeconds;
    assert.equal((await invoke(body)).status, 200);
    assert.equal(summary().ttlSeconds, null);
    assert.equal(records.find((record) => record.eventName === 'envelope_validated').ttlSeconds, null);
    assert.equal((await invoke({ ...body, ttlSeconds: 'PRIVATE-INVALID-TTL' })).status, 400);
    assert.equal(summary().envelopeType, null);
    assert.equal(summary().ttlSeconds, null);
    assert.equal(records.some((record) => record.eventName === 'envelope_validated'), false);
});

test('request preparation records the adapter final URL, not the configured base or an arbitrary HTTP verb', async () => {
    const adapter = getProvider('soprano').adapter;
    const buildRequest = adapter.buildRequest;
    const finalUrl = 'https://different-provider.example/api/final?token=PRIVATE-TOKEN';
    mock.method(adapter, 'buildRequest', (options) => ({
        ...buildRequest(options), url: finalUrl, method: 'PRIVATE-METHOD',
    }));
    await invoke(await envelope());
    assert.equal(summary().providerEndpoint, 'https://different-provider.example/api/final');
    assert.equal(summary().providerHttpMethod, 'other');
    assert.notEqual(summary().providerEndpoint, process.env.EPP_PROVIDER_ENDPOINT);
    assert.equal(fetchMock.mock.calls[0].arguments[0], finalUrl);
});

test('shared ID cases preserve raw support values or explicitly omit invalid metadata', () => {
    const fields = ['x-ms-client-request-id', 'x-ms-correlation-id', 'providerTenantId',
        'functionOutboundClientId', 'functionOutboundManagedIdentityClientId', 'providerMessageId'];
    const manifest = getProvider('soprano').manifest;
    for (const fixture of fixtures.logging.identifiers) {
        const value = fixture.length ? 'A'.repeat(fixture.length) : fixture.value;
        const events = [];
        const log = new RequestLog({ log: (record) => events.push(JSON.parse(record)) }, 'function-request', value, value);
        log.providerSelected(manifest);
        log.credentialResolutionStarted({ providerTenantId: value, outboundClientId: value, outboundManagedIdentityClientId: value });
        log.providerResponseProcessed(manifest, { providerStatusName: 'ENROUTE', providerMessageId: value }, 'Continue', 200, true);
        log.complete(200);
        const summary = events.at(-1);
        for (const field of fields) assert.equal(summary[field], fixture.accepted ? value : null);
        assert.deepEqual(summary.omittedIdFields, fixture.omitted ? fields : []);
        assert.equal(events.some((event) => Object.keys(event).some((key) => key.endsWith('Hash'))), false);
        assert.doesNotMatch(JSON.stringify(events), /PRIVATE/);
    }
});

test('shared endpoint cases retain scheme host port and API path without credentials query or fragment', () => {
    for (const fixture of fixtures.logging.endpoints) {
        const events = [];
        const log = new RequestLog({ log: (record) => events.push(JSON.parse(record)) }, 'function-request', null, null);
        log.providerRequestBuilt('POST', fixture.url);
        log.providerRequestStarted(1500);
        log.complete(200);
        assert.ok(events.every((event) => event.providerEndpoint === fixture.logged));
        assert.doesNotMatch(JSON.stringify(events), /PRIVATE/);
    }
});
