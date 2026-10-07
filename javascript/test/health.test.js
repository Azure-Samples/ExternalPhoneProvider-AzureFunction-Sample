'use strict';

const { test, beforeEach, afterEach, mock } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const http = require('node:http');
const https = require('node:https');
const net = require('node:net');
const tls = require('node:tls');
const Module = require('node:module');

const healthPath = require.resolve('../src/functions/health');
const { publicKey, privateKey } = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });
const pem = privateKey.export({ type: 'pkcs8', format: 'pem' });
const envKeys = ['EPP_FRONT_DOOR_HEALTH_ENABLED', 'EPP_DECRYPTION_KEY_PEM'];
let savedEnv;
let networkMocks;

beforeEach(() => {
    savedEnv = Object.fromEntries(envKeys.map((key) => [key, process.env[key]]));
    for (const key of envKeys) delete process.env[key];
    networkMocks = [
        [global, 'fetch'], [http, 'request'], [http, 'get'],
        [https, 'request'], [https, 'get'], [net.Socket.prototype, 'connect'],
        [tls, 'connect'],
    ].map(([target, method]) => mock.method(target, method, () => {
        throw new Error('Health must not perform network I/O');
    }));
});

afterEach(() => {
    const networkCalls = networkMocks.reduce((count, stub) => count + stub.mock.callCount(), 0);
    mock.restoreAll();
    delete require.cache[healthPath];
    for (const [key, value] of Object.entries(savedEnv)) {
        if (value === undefined) delete process.env[key];
        else process.env[key] = value;
    }
    assert.equal(networkCalls, 0);
});

function loadHealth(enabled = 'true') {
    if (enabled === null) delete process.env.EPP_FRONT_DOOR_HEALTH_ENABLED;
    else process.env.EPP_FRONT_DOOR_HEALTH_ENABLED = enabled;
    delete require.cache[healthPath];
    const registrations = [];
    const originalLoad = Module._load;
    const registration = mock.method(Module, '_load', function (name, ...args) {
        if (name === '@azure/functions') {
            return { app: { http: (name, options) => registrations.push({ name, ...options }) } };
        }
        assert.doesNotMatch(name, /credentials|providers|delivery|SendOtp|jwe|@azure\/identity|@azure\/keyvault/i,
            'Health must not load delivery or credential code');
        return originalLoad.call(this, name, ...args);
    });
    try {
        require(healthPath);
    } finally {
        registration.mock.restore();
    }
    return registrations;
}

async function invoke(handler, method = 'GET') {
    const records = [];
    const capture = (level) => (value) => records.push({ level, ...JSON.parse(value) });
    const response = await handler({
        method,
        url: 'https://example.test/api/health/ready?PRIVATE-QUERY',
        headers: { get: () => { throw new Error('Health must not read client identifiers'); } },
        text: async () => { throw new Error('Health must not read an OTP body'); },
    }, {
        invocationId: 'health-invocation-id',
        log: capture('log'),
        warn: capture('warn'),
        error: capture('error'),
    });
    const ready = response.status === 200;
    assert.deepEqual(records.map((record) => record.eventName),
        ready ? ['request_completed'] : ['request_failed', 'request_completed']);
    assert.equal(records.at(-1).result, ready ? 'ready' : 'not_ready');
    assert.ok(records.every((record) => record.logType === 'service'
        && record.httpStatus === response.status
        && record.functionName === 'FrontDoorHealth'
        && record.functionInvocationId === 'health-invocation-id'
        && record.functionRequestId
        && record['x-ms-client-request-id'] === null
        && record['x-ms-correlation-id'] === null
        && record.providerName === null
        && record.providerTenantId === null));
    if (!ready) {
        assert.equal(records[0].level, 'error');
        assert.equal(records[0].failureStage, 'readiness');
        assert.equal(records[0].failureReason, 'key_unavailable');
    }
    assert.doesNotMatch(JSON.stringify({ response, records }), /PRIVATE|BEGIN|RSA|base64|openssl/i);
    assert.ok(!JSON.stringify({ response, records }).includes(pem.split('\n')[1]));
    assert.equal(response.headers['Cache-Control'], 'no-store');
    return response;
}

test('registration is disabled unless the gate is exactly true', () => {
    const createKey = mock.method(crypto, 'createPrivateKey');
    process.env.EPP_DECRYPTION_KEY_PEM = pem;
    for (const value of [null, '', 'false', 'TRUE', 'True', '1', ' true', 'true ']) {
        assert.equal(loadHealth(value).length, 0, value);
    }
    assert.equal(createKey.mock.callCount(), 0);
});

test('enabled health registers only the anonymous GET/HEAD readiness route', () => {
    const registrations = loadHealth();
    assert.equal(registrations.length, 1);
    const { name, route, methods, authLevel, handler } = registrations[0];
    assert.equal(name, 'FrontDoorHealth');
    assert.equal(route, 'health/ready');
    assert.deepEqual(methods, ['GET', 'HEAD']);
    assert.equal(authLevel, 'anonymous');
    assert.equal(typeof handler, 'function');
});

test('GET/HEAD readiness validates raw and base64 keys without provider or network I/O', async () => {
    const [{ handler }] = loadHealth();
    const cases = [
        ['RSA PKCS8', pem, 200],
        ['RSA PKCS1', privateKey.export({ type: 'pkcs1', format: 'pem' }), 200],
        ['missing', undefined, 503], ['empty', '', 503],
        ['invalid key', 'PRIVATE-invalid-key', 503], ['invalid base64', '%%%not-base64%%%', 503],
        ['public key', publicKey.export({ type: 'spki', format: 'pem' }), 503],
        ['EC key', crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' })
            .privateKey.export({ type: 'pkcs8', format: 'pem' }), 503],
        ['encrypted key', privateKey.export({ type: 'pkcs8', format: 'pem', cipher: 'aes-256-cbc', passphrase: 'PRIVATE' }), 503],
        ['RSA below 2048 bits', crypto.generateKeyPairSync('rsa', { modulusLength: 1024 })
            .privateKey.export({ type: 'pkcs8', format: 'pem' }), 503],
    ];
    for (const [name, key, status] of cases) {
        const forms = key ? [key, Buffer.from(key).toString('base64')] : [key];
        for (const value of forms) {
            if (value === undefined) delete process.env.EPP_DECRYPTION_KEY_PEM;
            else process.env.EPP_DECRYPTION_KEY_PEM = value;
            for (const method of ['GET', 'HEAD']) {
                const response = await invoke(handler, method);
                assert.equal(response.status, status, `${name}: ${method}`);
                assert.equal(response.body, undefined);
                assert.deepEqual(response.jsonBody, method === 'HEAD' ? undefined
                    : { status: status === 200 ? 'ready' : 'not_ready' });
            }
        }
    }
});

test('validation caches success and failure by PEM and rechecks after key changes', async () => {
    const [{ handler }] = loadHealth();
    const createKey = mock.method(crypto, 'createPrivateKey');
    const decrypt = mock.method(crypto, 'privateDecrypt');
    for (const [key, status, parses, decryptions] of [
        [pem, 200, 1, 1], [pem, 200, 1, 1],
        ['PRIVATE-invalid-key', 503, 2, 1], ['PRIVATE-invalid-key', 503, 2, 1],
        [pem, 200, 3, 2], ['', 503, 3, 2], [pem, 200, 4, 3],
    ]) {
        process.env.EPP_DECRYPTION_KEY_PEM = key;
        assert.equal((await invoke(handler)).status, status);
        assert.equal(createKey.mock.callCount(), parses);
        assert.equal(decrypt.mock.callCount(), decryptions);
    }
});

test('readiness exercises an RSA-OAEP-256 roundtrip with a 32-byte synthetic key', async () => {
    const [{ handler }] = loadHealth();
    process.env.EPP_DECRYPTION_KEY_PEM = pem;
    const encrypt = mock.method(crypto, 'publicEncrypt');
    const decrypt = mock.method(crypto, 'privateDecrypt');
    assert.equal((await invoke(handler)).status, 200);
    for (const operation of [encrypt, decrypt]) {
        assert.equal(operation.mock.callCount(), 1);
        const [options] = operation.mock.calls[0].arguments;
        assert.equal(options.padding, crypto.constants.RSA_PKCS1_OAEP_PADDING);
        assert.equal(options.oaepHash, 'sha256');
    }
    assert.equal(encrypt.mock.calls[0].arguments[1].length, 32);
    assert.deepEqual(decrypt.mock.calls[0].result, encrypt.mock.calls[0].arguments[1]);
});

test('RSA operation failures return cached 503 without logging exception secrets', async () => {
    process.env.EPP_DECRYPTION_KEY_PEM = pem;
    for (const operation of ['createPrivateKey', 'createPublicKey', 'publicEncrypt', 'privateDecrypt']) {
        const [{ handler }] = loadHealth();
        const failure = mock.method(crypto, operation, () => {
            throw new Error(`PRIVATE-crypto-error ${pem}`);
        });
        assert.equal((await invoke(handler)).status, 503);
        assert.equal((await invoke(handler)).status, 503);
        assert.equal(failure.mock.callCount(), 1);
        failure.mock.restore();
    }
});

test('a mismatched OAEP roundtrip is not ready', async () => {
    const [{ handler }] = loadHealth();
    process.env.EPP_DECRYPTION_KEY_PEM = pem;
    mock.method(crypto, 'privateDecrypt', () => Buffer.alloc(32, 1));
    assert.equal((await invoke(handler)).status, 503);
});
