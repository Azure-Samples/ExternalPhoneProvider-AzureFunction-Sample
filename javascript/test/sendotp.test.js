'use strict';

const { test, beforeEach, afterEach, mock } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const Module = require('node:module');
const { CompactEncrypt } = require('jose');
const { ClientAssertionCredential, ManagedIdentityCredential } = require('@azure/identity');
const { SecretClient } = require('@azure/keyvault-secrets');
const fixtures = require('../../tests/fixtures/contract.json');
const {
    CredentialTokenService,
    credentialTokenService,
} = require('../src/functions/credentials');

const { publicKey, privateKey } = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });
let handler;
let startHook;
let stopHook;
const originalLoad = Module._load;
const registration = mock.method(Module, '_load', function (name, ...args) {
    if (name === '@azure/functions') {
        return {
            app: {
                hook: {
                    appStart: (callback) => { startHook = callback; },
                    appTerminate: (callback) => { stopHook = callback; },
                },
                http: (_name, options) => { handler = options.handler; },
            },
        };
    }
    return originalLoad.call(this, name, ...args);
});
try {
    require('../src/functions/SendOtp');
} finally {
    registration.mock.restore();
}

const envKeys = [
    'EPP_ENCRYPTION_KEY_ID', 'AZURE_CLIENT_ID', 'EPP_PROVIDER_NAME',
    'EPP_PROVIDER_ENDPOINT', 'EPP_PROVIDER_CHANNEL', 'EPP_PROVIDER_TIMEOUT_MS',
    'EPP_PROVIDER_AUTH_MODE', 'EPP_PROVIDER_TENANT_ID', 'EPP_PROVIDER_SCOPE',
    'EPP_OUTBOUND_CLIENT_ID', 'EPP_OUTBOUND_MI_CLIENT_ID', 'KEY_VAULT_URL',
    'EPP_DECRYPTION_KEY_PEM', 'SINCH_SERVICE_PLAN_ID',
    'EPP_KEY_VAULT_CACHE_ENABLED', 'EPP_ACCESS_TOKEN_CACHE_ENABLED',
];
const baseDelivery = {
    nonce: 'PRIVATE-NONCE',
    phoneNumber: '+15551234567',
    message: '  PRIVATE-MESSAGE 918273.\n',
    locale: 'fr-FR',
    riskContext: { value: 'PRIVATE-RISK' },
};
let savedEnv;
let service;
let fetchMock;
let getSecret;
let getToken;
let records;

beforeEach(() => {
    savedEnv = Object.fromEntries(envKeys.map((key) => [key, process.env[key]]));
    for (const key of envKeys) delete process.env[key];
    Object.assign(process.env, {
        EPP_DECRYPTION_KEY_PEM: privateKey.export({ type: 'pkcs8', format: 'pem' }),
        KEY_VAULT_URL: 'https://unit-test.vault.azure.net',
        EPP_PROVIDER_NAME: 'soprano',
        EPP_PROVIDER_ENDPOINT: 'https://provider.example/epp/messages',
        EPP_PROVIDER_AUTH_MODE: 'oauth',
        EPP_PROVIDER_TENANT_ID: '11111111-1111-1111-1111-111111111111',
        EPP_PROVIDER_SCOPE: 'api://provider/.default',
        EPP_OUTBOUND_CLIENT_ID: '22222222-2222-2222-2222-222222222222',
        EPP_OUTBOUND_MI_CLIENT_ID: '33333333-3333-3333-3333-333333333333',
    });
    service = new CredentialTokenService();
    mock.method(credentialTokenService, 'getCredentials',
        (...args) => service.getCredentials(...args));
    mock.method(credentialTokenService, 'close', () => service.close());
    mock.method(ManagedIdentityCredential.prototype, 'getToken', async () => ({
        token: 'PRIVATE-ASSERTION',
        expiresOnTimestamp: Date.now() + 3600000,
    }));
    getToken = mock.method(ClientAssertionCredential.prototype, 'getToken', async function () {
        assert.equal(await this.getAssertion(), 'PRIVATE-ASSERTION');
        return { token: 'PRIVATE-OAUTH-TOKEN', expiresOnTimestamp: Date.now() + 3600000 };
    });
    getSecret = mock.method(SecretClient.prototype, 'getSecret',
        async () => ({ value: 'PRIVATE-API-KEY' }));
    fetchMock = mock.method(global, 'fetch', async () => ({
        ok: true,
        status: 201,
        text: async () => JSON.stringify({
            status: 'ENROUTE',
            id: 'provider-reference-id',
            description: 'PRIVATE-STATUS',
        }),
    }));
});

afterEach(() => {
    service.close();
    mock.restoreAll();
    for (const [key, value] of Object.entries(savedEnv)) {
        if (value === undefined) delete process.env[key];
        else process.env[key] = value;
    }
});

async function envelope(overrides = {}, delivery = baseDelivery, protectedHeader = {}) {
    const encryptedDeliveryContext = await new CompactEncrypt(Buffer.from(JSON.stringify(delivery)))
        .setProtectedHeader({
            alg: 'RSA-OAEP-256',
            enc: 'A256GCM',
            kid: 'PRIVATE-KID',
            ...protectedHeader,
        })
        .encrypt(publicKey);
    return {
        type: 'microsoft.mfa.otpDeliver.v1',
        channel: 1,
        mode: 1,
        ttlSeconds: 60,
        correlationId: 'correlation-id',
        encryptedDeliveryContext,
        ...overrides,
    };
}

async function invoke(body, headers = {}) {
    records = [];
    const capture = (value) => records.push(JSON.parse(value));
    const result = await handler({
        headers: { get: (name) => headers[name.toLowerCase()] ?? null },
        text: async () => typeof body === 'string' ? body : JSON.stringify(body),
    }, {
        invocationId: 'function-invocation-id',
        log: capture,
        warn: capture,
        error: capture,
    });
    assert.equal(records.at(-1).eventName, 'request_completed');
    assert.equal(records.at(-1).httpStatus, result.status);
    assert.equal(records.filter((event) => event.eventName === 'request_completed').length, 1);
    assert.equal(records.filter((event) => event.eventName === 'response_prepared').length, 1);
    assert.ok(records.every((event) => event.functionRequestId
        && event.functionInvocationId === 'function-invocation-id'));
    assert.doesNotMatch(JSON.stringify(records), /PRIVATE|FORGED|918273|15551234567/);
    return result;
}

function failure(result, status, error = 'provider_delivery_failed') {
    assert.equal(result.status, status);
    assert.equal(result.jsonBody.error, error);
    assert.equal(result.jsonBody.nonce, undefined);
}

function event(name) {
    return records.find((record) => record.eventName === name);
}

for (const provider of ['telesign', 'soprano']) {
    test(`${provider}: disabled cache skips startup and evaluation but acquires for every live request`, async () => {
        const apiKey = provider === 'telesign';
        process.env.EPP_PROVIDER_NAME = provider;
        process.env.EPP_PROVIDER_AUTH_MODE = apiKey ? 'apiKey' : 'oauth';
        process.env[apiKey ? 'EPP_KEY_VAULT_CACHE_ENABLED' : 'EPP_ACCESS_TOKEN_CACHE_ENABLED'] = 'false';
        process.env[apiKey ? 'EPP_ACCESS_TOKEN_CACHE_ENABLED' : 'EPP_KEY_VAULT_CACHE_ENABLED'] = 'PRIVATE-UNUSED';
        if (apiKey) fetchMock.mock.mockImplementation(async () => ({
            ok: true, status: 200, text: async () => JSON.stringify({ status: { code: 3001 } }),
        }));
        await startHook();
        const evaluated = await invoke(await envelope({ mode: 2 }));
        assert.equal(evaluated.status, 200);
        assert.equal(evaluated.jsonBody.nonce, baseDelivery.nonce);
        assert.deepEqual([getSecret.mock.callCount(), getToken.mock.callCount(), fetchMock.mock.callCount()], [0, 0, 0]);
        for (let i = 0; i < 2; i++) assert.equal((await invoke(await envelope())).status, 200);
        assert.equal(getSecret.mock.callCount(), apiKey ? 4 : 0);
        assert.equal(getToken.mock.callCount(), apiKey ? 0 : 2);
        assert.equal(service.current, null);
        assert.equal(service.timer, null);
    });
}

test('invalid cache settings fail live credentials but leave evaluation and private logs unchanged', async () => {
    const warnings = mock.method(console, 'warn', () => {});
    process.env.EPP_KEY_VAULT_CACHE_ENABLED = 'PRIVATE-INVALID';
    process.env.EPP_ACCESS_TOKEN_CACHE_ENABLED = 'PRIVATE-INVALID';
    await startHook();
    assert.equal((await invoke(await envelope({ mode: 2 }))).status, 200);
    failure(await invoke(await envelope()), 502);
    assert.equal(event('request_failed').failureReason, 'credential_unavailable');
    assert.deepEqual([getToken.mock.callCount(), getSecret.mock.callCount(), fetchMock.mock.callCount()], [0, 0, 0]);
    assert.ok(warnings.mock.callCount() > 0);
    assert.doesNotMatch(JSON.stringify(warnings.mock.calls.map((call) => call.arguments)), /PRIVATE/);
});

test('startup prewarms only the configured provider and shutdown closes the service', async () => {
    await startHook();
    assert.equal(getToken.mock.callCount(), 1);
    assert.equal(getSecret.mock.callCount(), 0);
    assert.equal(fetchMock.mock.callCount(), 0);
    await invoke(await envelope());
    assert.equal(getToken.mock.callCount(), 1);
    assert.equal(fetchMock.mock.callCount(), 1);
    stopHook();
    failure(await invoke(await envelope()), 502);
    assert.equal(event('request_failed').failureReason, 'credential_unavailable');
});

test('startup without a provider and evaluation perform no provider I/O', async () => {
    delete process.env.EPP_PROVIDER_NAME;
    await startHook();
    const result = await invoke(await envelope({ mode: 'evaluation' }));
    assert.equal(result.status, 200);
    assert.equal(result.jsonBody.nonce, baseDelivery.nonce);
    assert.deepEqual([getToken.mock.callCount(), getSecret.mock.callCount(), fetchMock.mock.callCount()],
        [0, 0, 0]);
    assert.equal(event('evaluation_completed').eventName, 'evaluation_completed');
});

test('shared invalid requests preserve exact reasons and never perform provider I/O', async () => {
    const valid = {
        type: 'microsoft.mfa.otpDeliver.v1',
        channel: 1,
        mode: 1,
        encryptedDeliveryContext: 'unused',
    };
    for (const fixture of fixtures.badRequests) {
        const result = await invoke(fixture.rawBody ?? { ...valid, ...fixture.overrides });
        failure(result, 400, 'bad_request');
        assert.equal(result.jsonBody.reason, fixture.reason, fixture.name);
        assert.equal(event('request_failed').failureStage, 'request_validation');
    }
    for (const changes of fixtures.incompleteContexts) {
        const result = await invoke(await envelope({ mode: 2 }, { ...baseDelivery, ...changes }));
        failure(result, 400, 'bad_request');
        assert.equal(result.jsonBody.reason, 'incomplete delivery context');
        assert.equal(event('request_failed').failureStage, 'delivery_context_validation');
    }
    assert.deepEqual([getToken.mock.callCount(), getSecret.mock.callCount(), fetchMock.mock.callCount()],
        [0, 0, 0]);
});

test('JWE algorithm policy, size/shape and bad tags fail before provider I/O', async () => {
    for (const fixture of fixtures.jwe) {
        const result = await invoke(await envelope({ mode: 2 }, baseDelivery, fixture));
        if (fixture.accepted) assert.equal(result.status, 200);
        else failure(result, 400, 'decryption_failed');
    }
    const body = await envelope({ mode: 2 });
    const parts = body.encryptedDeliveryContext.split('.');
    parts[4] = `${parts[4][0] === 'A' ? 'B' : 'A'}${parts[4].slice(1)}`;
    for (const encryptedDeliveryContext of [
        parts.join('.'),
        parts.slice(0, 4).join('.'),
        'a'.repeat(16385),
    ]) {
        failure(await invoke({ ...body, encryptedDeliveryContext }), 400, 'decryption_failed');
    }
    assert.equal(fetchMock.mock.callCount(), 0);
});

test('JWE authenticates original protected bytes and caches PEM-compatible keys', async () => {
    const header = '{ "kid" : "test-key", "enc" : "A256GCM", "alg" : "RSA-OAEP-256" }';
    const encodedHeader = Buffer.from(header).toString('base64url');
    const contentKey = crypto.randomBytes(32);
    const iv = crypto.randomBytes(12);
    const cipher = crypto.createCipheriv('aes-256-gcm', contentKey, iv);
    cipher.setAAD(Buffer.from(encodedHeader, 'ascii'));
    const ciphertext = Buffer.concat([
        cipher.update(JSON.stringify(baseDelivery), 'utf8'),
        cipher.final(),
    ]);
    const wrappedKey = crypto.publicEncrypt({
        key: publicKey,
        oaepHash: 'sha256',
        padding: crypto.constants.RSA_PKCS1_OAEP_PADDING,
    }, contentKey);
    const segments = [encodedHeader, ...[wrappedKey, iv, ciphertext, cipher.getAuthTag()]
        .map((value) => value.toString('base64url'))];
    const body = await envelope({ mode: 2, encryptedDeliveryContext: segments.join('.') });
    assert.equal((await invoke(body)).status, 200);
    segments[0] = Buffer.from(JSON.stringify(JSON.parse(header))).toString('base64url');
    failure(await invoke({ ...body, encryptedDeliveryContext: segments.join('.') }),
        400, 'decryption_failed');

    const certificate = require('node:tls').rootCertificates[0];
    const pem = privateKey.export({ type: 'pkcs8', format: 'pem' });
    for (const bundle of [`${certificate}\n${pem}`, `${pem}\n${certificate}`]) {
        for (const value of [bundle, Buffer.from(bundle).toString('base64')]) {
            process.env.EPP_DECRYPTION_KEY_PEM = value;
            assert.equal((await invoke(await envelope({ mode: 2 }))).status, 200);
        }
    }
});

test('evaluation checks advisory key ID but remains provider-independent', async () => {
    delete process.env.EPP_PROVIDER_ENDPOINT;
    delete process.env.KEY_VAULT_URL;
    process.env.EPP_ENCRYPTION_KEY_ID = 'different-kid';
    const result = await invoke(await envelope({ mode: 2 }));
    assert.equal(result.status, 200);
    assert.ok(event('encryption_key_id_mismatch'));
    assert.equal(event('provider_selected'), undefined);
    assert.deepEqual([getToken.mock.callCount(), getSecret.mock.callCount(), fetchMock.mock.callCount()],
        [0, 0, 0]);
});

test('live Soprano flow preserves message/correlation and never forwards inbound authorization', async () => {
    const result = await invoke(await envelope(), {
        authorization: 'FORGED-INBOUND-AUTH',
        'x-ms-client-principal': 'FORGED-PRINCIPAL',
        'x-ms-client-request-id': 'client-request-id',
    });
    assert.deepEqual(result, {
        status: 200,
        jsonBody: {
            nonce: baseDelivery.nonce,
            correlationId: 'correlation-id',
            providerStatus: 'accepted',
        },
    });
    const [url, init] = fetchMock.mock.calls[0].arguments;
    assert.equal(url, process.env.EPP_PROVIDER_ENDPOINT);
    assert.equal(init.redirect, 'manual');
    assert.equal(init.headers.Authorization, 'Bearer PRIVATE-OAUTH-TOKEN');
    assert.notEqual(init.headers.Authorization, 'FORGED-INBOUND-AUTH');
    assert.deepEqual(JSON.parse(init.body), {
        destination: '15551234567',
        messageTypes: ['sms'],
        correlationId: 'correlation-id',
        shutterMode: false,
        text: baseDelivery.message,
    });
    assert.deepEqual(records.map((record) => record.eventName), [
        'request_received',
        'envelope_validated',
        'delivery_context_decrypted',
        'provider_selected',
        'provider_credential_resolution_started',
        'provider_credential_resolved',
        'provider_request_build_started',
        'provider_request_built',
        'provider_request_started',
        'provider_response_received',
        'provider_response_processed',
        'response_prepared',
        'request_completed',
    ]);
    assert.equal(event('provider_response_processed').providerMessageId, 'provider-reference-id');
});

test('Soprano voice derives the first rendered six-digit code', async () => {
    const result = await invoke(await envelope({ channel: 2 }, {
        ...baseDelivery,
        message: 'Before 001234 after 654321.',
    }));
    assert.equal(result.status, 200);
    assert.deepEqual(JSON.parse(fetchMock.mock.calls[0].arguments[1].body).voice.text2voice, {
        beforePasswordText: 'Before ',
        password: '001234',
        afterPasswordText: ' after 654321.',
        language: 'fr-FR',
        gender: 1,
        loop: 2,
    });
});

test('provider selection, configuration, credential and request-build failures are fixed and safe', async () => {
    const cases = [
        ['provider_selection', 'unknown_provider', 400, () => {
            process.env.EPP_PROVIDER_NAME = 'PRIVATE-UNKNOWN';
        }, {}],
        ['provider_configuration', 'channel_not_configured', 400, () => {
            process.env.EPP_PROVIDER_CHANNEL = 'voice';
        }, {}],
        ['provider_configuration', 'authentication_mode_mismatch', 502, () => {
            process.env.EPP_PROVIDER_AUTH_MODE = 'apiKey';
        }, {}],
        ['provider_configuration', 'invalid_provider_endpoint', 502, () => {
            process.env.EPP_PROVIDER_ENDPOINT = 'http://PRIVATE-ENDPOINT';
        }, {}],
        ['provider_request_build', 'request_build_failed', 502, () => {}, {
            delivery: { ...baseDelivery, message: 'No passcode here.' },
            envelope: { channel: 2 },
        }],
    ];
    for (const [stage, reason, status, configure, options] of cases) {
        configure();
        const result = await invoke(await envelope(options.envelope, options.delivery || baseDelivery));
        failure(result, status);
        assert.deepEqual([event('request_failed').failureStage, event('request_failed').failureReason],
            [stage, reason]);
        Object.assign(process.env, {
            EPP_PROVIDER_NAME: 'soprano',
            EPP_PROVIDER_ENDPOINT: 'https://provider.example/epp/messages',
            EPP_PROVIDER_AUTH_MODE: 'oauth',
        });
        delete process.env.EPP_PROVIDER_CHANNEL;
    }
});

test('credential failure emits request_failed without provider HTTP', async () => {
    credentialTokenService.getCredentials.mock.mockImplementation(async () => {
        throw new Error('PRIVATE-CREDENTIAL-FAILURE');
    });
    failure(await invoke(await envelope()), 502);
    assert.deepEqual([
        event('request_failed').failureStage,
        event('request_failed').failureReason,
        fetchMock.mock.callCount(),
    ], ['provider_credentials', 'credential_unavailable', 0]);
});

test('provider network, timeout, invalid JSON, unknown status and HTTP failures classify safely', async () => {
    const cases = [
        [async () => { throw new Error('PRIVATE-NETWORK'); }, 502, 'provider_network_error'],
        [async (_url, { signal }) => ({
            ok: true,
            status: 200,
            text: () => new Promise((_resolve, reject) => {
                signal.addEventListener('abort', () => reject(new Error('PRIVATE-TIMEOUT')), { once: true });
            }),
        }), 504, 'provider_timeout'],
        [async () => ({ ok: true, status: 200, text: async () => '<PRIVATE-HTML>' }),
            502, 'invalid_provider_json'],
        [async () => ({ ok: true, status: 200,
            text: async () => JSON.stringify({ id: 'provider-id', status: 'PRIVATE-STATUS' }) }),
        502, 'unrecognized_provider_status'],
        [async () => ({ ok: false, status: 429,
            text: async () => JSON.stringify({ id: 'provider-id', status: 'ENROUTE' }) }),
        429, 'provider_http_error'],
    ];
    for (const [implementation, status, reason] of cases) {
        process.env.EPP_PROVIDER_TIMEOUT_MS = status === 504 ? '1' : '1500';
        fetchMock.mock.mockImplementation(implementation);
        failure(await invoke(await envelope()), status);
        assert.equal(event('request_failed').failureReason, reason);
        assert.equal(records.at(-1).eventName, 'request_completed');
    }
});

test('Sinch successful HTTP without a nonblank message ID fails closed', async () => {
    process.env.EPP_PROVIDER_NAME = 'sinch';
    process.env.EPP_PROVIDER_AUTH_MODE = 'apiKey';
    process.env.SINCH_SERVICE_PLAN_ID = 'plan';
    fetchMock.mock.mockImplementation(async () => ({
        ok: true,
        status: 200,
        text: async () => JSON.stringify({ id: ' ', status: 'Delivered' }),
    }));
    failure(await invoke(await envelope()), 502);
    assert.equal(event('request_failed').failureReason, 'missing_provider_message_id');
});

test('Telesign strict integer status and voice pacing keep endpoint outcomes stable', async () => {
    process.env.EPP_PROVIDER_NAME = 'telesign';
    process.env.EPP_PROVIDER_AUTH_MODE = 'apiKey';
    process.env.EPP_PROVIDER_ENDPOINT = 'https://verify.telesign.com/epp/send';
    for (const [code, status] of [[290, 200], ['290', 502], [true, 502]]) {
        fetchMock.mock.mockImplementation(async () => ({
            ok: true,
            status: 200,
            text: async () => JSON.stringify({ reference_id: 'reference-id', status: { code } }),
        }));
        const result = await invoke(await envelope({ channel: 2 }));
        assert.equal(result.status, status);
        const sent = JSON.parse(fetchMock.mock.calls.at(-1).arguments[1].body);
        assert.equal(sent.message.text,
            '  PRIVATE-MESSAGE 9, 1, 8, 2, 7, 3.\n   PRIVATE-MESSAGE 9, 1, 8, 2, 7, 3.\n');
    }
});

test('correlation precedence preserves wire IDs while logs omit unsafe values', async () => {
    const headers = {
        'x-ms-client-request-id': 'client-request-id',
        'x-ms-correlation-id': 'header-correlation-id',
    };
    for (const [value, expected] of [
        ['envelope-correlation-id', 'envelope-correlation-id'],
        ['opaque correlation/value', 'opaque correlation/value'],
        [null, 'header-correlation-id'],
        [{ private: 'PRIVATE' }, 'header-correlation-id'],
    ]) {
        const result = await invoke(await envelope({ mode: 2, correlationId: value }), headers);
        assert.equal(result.jsonBody.correlationId, expected);
        assert.equal(records[0]['x-ms-correlation-id'], 'header-correlation-id');
        assert.equal(records.at(-1)['x-ms-correlation-id'],
            value === 'opaque correlation/value' ? null : expected);
        assert.equal(records.at(-1).omittedIdFields.includes('x-ms-correlation-id'),
            value === 'opaque correlation/value');
    }
    const result = await invoke(await envelope({ mode: 2, correlationId: null }));
    assert.equal(result.jsonBody.correlationId, records.at(-1).functionRequestId);
});

test('fixed logging excludes bodies, secrets, query strings, descriptions and exceptions', async () => {
    process.env.EPP_PROVIDER_ENDPOINT = 'https://provider.example/api/send?key=PRIVATE-QUERY';
    fetchMock.mock.mockImplementation(async () => ({
        ok: true,
        status: 201,
        text: async () => JSON.stringify({
            id: 'support-id',
            status: 'ENROUTE',
            description: 'PRIVATE-DESCRIPTION',
        }),
    }));
    await invoke(await envelope({
        tenantId: 'PRIVATE-TENANT',
        unknown: { body: 'PRIVATE-BODY' },
    }), { authorization: 'PRIVATE-INBOUND' });
    assert.equal(event('provider_request_built').providerEndpoint,
        'https://provider.example/api/send');
    assert.equal(event('provider_request_started').providerEndpoint,
        'https://provider.example/api/send');
    assert.equal(event('provider_request_started').providerHttpMethod, 'POST');
    assert.deepEqual({
        providerTenantId: event('provider_credential_resolution_started').providerTenantId,
        functionOutboundClientId:
            event('provider_credential_resolution_started').functionOutboundClientId,
        functionOutboundManagedIdentityClientId:
            event('provider_credential_resolution_started').functionOutboundManagedIdentityClientId,
    }, {
        providerTenantId: process.env.EPP_PROVIDER_TENANT_ID,
        functionOutboundClientId: process.env.EPP_OUTBOUND_CLIENT_ID,
        functionOutboundManagedIdentityClientId: process.env.EPP_OUTBOUND_MI_CLIENT_ID,
    });
    assert.equal(event('provider_response_processed').providerMessageId, 'support-id');
    assert.equal(event('request_failed'), undefined);
    assert.doesNotMatch(JSON.stringify(records), /PRIVATE|918273|15551234567/);
});
