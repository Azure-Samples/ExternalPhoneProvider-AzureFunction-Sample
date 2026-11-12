'use strict';

// Drives the SendOtp handler with the settings guided setup applies for the Twilio profile.
// Key Vault and the Verify API are mocked; no network access.

const { test, beforeEach, afterEach, mock } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const Module = require('node:module');
const { CompactEncrypt } = require('jose');
const { SecretClient } = require('@azure/keyvault-secrets');
const { CredentialTokenService, credentialTokenService } = require('../src/functions/credentials');
const profile = require('../../setup/providers/twilio.json');

const { publicKey, privateKey } = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });
let handler;
const originalLoad = Module._load;
const registration = mock.method(Module, '_load', function (name, ...args) {
    if (name === '@azure/functions') {
        return {
            app: {
                hook: { appStart: () => {}, appTerminate: () => {} },
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

const KEY_ID = 'SK' + '0123456789abcdef'.repeat(2);
const KEY_SECRET = 'PRIVATE-SECRET-VALUE';
const SERVICE_SID = 'VA' + 'fedcba9876543210'.repeat(2);
const { identityKeyVaultSecretName, keyVaultSecretName } = profile.deployment.authentication;
const route = profile.deployment.routes.global;
const settings = {
    EPP_PROVIDER_NAME: 'twilio',
    EPP_PROVIDER_AUTH_MODE: profile.deployment.authentication.mode,
    EPP_PROVIDER_SMS_ENDPOINT: route.smsEndpoint,
    EPP_PROVIDER_VOICE_ENDPOINT: route.voiceEndpoint,
    EPP_PROVIDER_TIMEOUT_MS: String(route.timeoutMilliseconds),
    TWILIO_VERIFY_SERVICE_SID: SERVICE_SID,
    KEY_VAULT_URL: 'https://unit-test.vault.azure.net',
};
let savedEnv;
let service;
let secrets;
let getSecret;
let fetchMock;
let records;

beforeEach(() => {
    const keys = [...Object.keys(settings), 'EPP_DECRYPTION_KEY_PEM'];
    savedEnv = Object.fromEntries(keys.map((key) => [key, process.env[key]]));
    Object.assign(process.env, settings, { EPP_DECRYPTION_KEY_PEM: privateKey.export({ type: 'pkcs8', format: 'pem' }) });
    service = new CredentialTokenService();
    mock.method(credentialTokenService, 'getCredentials', (...args) => service.getCredentials(...args));
    mock.method(credentialTokenService, 'close', () => service.close());
    secrets = {
        [identityKeyVaultSecretName]: { value: KEY_ID, properties: { enabled: true } },
        [keyVaultSecretName]: { value: KEY_SECRET, properties: { enabled: true } },
    };
    getSecret = mock.method(SecretClient.prototype, 'getSecret', async (name) => {
        if (!secrets[name]) throw Object.assign(new Error('PRIVATE-NOT-FOUND'), { statusCode: 404 });
        return secrets[name];
    });
    fetchMock = mock.method(global, 'fetch', async () => ({
        ok: true,
        status: 201,
        text: async () => JSON.stringify({ sid: 'VE' + 'a'.repeat(32), status: 'pending' }),
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

async function envelope(overrides = {}) {
    const encryptedDeliveryContext = await new CompactEncrypt(Buffer.from(JSON.stringify({
        nonce: 'PRIVATE-NONCE', phoneNumber: '+15551234567', otp: '012345',
        message: 'PRIVATE-MESSAGE 012345', locale: 'en-US',
    }))).setProtectedHeader({ alg: 'RSA-OAEP-256', enc: 'A256GCM', kid: 'unit-kid' }).encrypt(publicKey);
    return {
        type: 'microsoft.mfa.otpDeliver.v1', channel: 1, mode: 1, ttlSeconds: 60,
        correlationId: '00877757-333f-2369-058f-88d4e7cc2935', encryptedDeliveryContext, ...overrides,
    };
}

async function invoke(body) {
    records = [];
    const capture = (value) => records.push(JSON.parse(value));
    const result = await handler({
        headers: { get: () => null },
        text: async () => JSON.stringify(body),
    }, { invocationId: 'unit-invocation', log: capture, warn: capture, error: capture });
    assert.equal(records.at(-1).eventName, 'request_completed');
    assert.doesNotMatch(JSON.stringify(records), /PRIVATE|012345|15551234567/);
    return result;
}

test('the profile secret names match the Twilio adapter', () => {
    const { selectProvider } = require('../src/functions/providers');
    const { credentialSpec } = selectProvider('twilio');
    assert.equal(credentialSpec.identityKeyVaultSecretName, identityKeyVaultSecretName);
    assert.equal(credentialSpec.keyVaultSecretName, keyVaultSecretName);
});

test('evaluation returns 200 without reading credentials or calling Twilio', async () => {
    const result = await invoke(await envelope({ mode: 2 }));
    assert.equal(result.status, 200);
    assert.equal(result.jsonBody.nonce, 'PRIVATE-NONCE');
    assert.deepEqual([getSecret.mock.callCount(), fetchMock.mock.callCount()], [0, 0]);
});

for (const [channel, twilioChannel] of [[1, 'sms'], [2, 'call']]) {
    test(`live ${twilioChannel} reads both Key Vault secrets and sends the exact Entra code`, async () => {
        const result = await invoke(await envelope({ channel }));
        assert.equal(result.status, 200);
        assert.deepEqual(getSecret.mock.calls.map((call) => call.arguments[0]).sort(),
            [identityKeyVaultSecretName, keyVaultSecretName].sort());
        assert.equal(fetchMock.mock.callCount(), 1);
        const [url, init] = fetchMock.mock.calls[0].arguments;
        assert.equal(String(url), `https://verify.twilio.com/v2/Services/${SERVICE_SID}/Verifications`);
        assert.equal(new Headers(init.headers).get('authorization'),
            `Basic ${Buffer.from(`${KEY_ID}:${KEY_SECRET}`).toString('base64')}`);
        const form = Object.fromEntries(new URLSearchParams(String(init.body)));
        assert.deepEqual(form, {
            To: '+15551234567', Channel: twilioChannel, CustomCode: '012345',
            Tags: JSON.stringify({ entra_byot_correlation_id: '00877757-333f-2369-058f-88d4e7cc2935' }),
            Locale: 'en',
        });
    });
}

test('missing or disabled API key secrets fail with 502 before any Twilio call', async () => {
    for (const change of [
        () => { delete secrets[keyVaultSecretName]; },
        () => { delete secrets[identityKeyVaultSecretName]; },
        () => { secrets[keyVaultSecretName].properties.enabled = false; },
        () => { secrets[identityKeyVaultSecretName] = { value: '', properties: { enabled: true } }; },
    ]) {
        service.close();
        service = new CredentialTokenService();
        secrets = {
            [identityKeyVaultSecretName]: { value: KEY_ID, properties: { enabled: true } },
            [keyVaultSecretName]: { value: KEY_SECRET, properties: { enabled: true } },
        };
        change();
        fetchMock.mock.resetCalls();
        const result = await invoke(await envelope());
        assert.equal(result.status, 502);
        assert.equal(result.jsonBody.nonce, undefined);
        assert.equal(fetchMock.mock.callCount(), 0);
    }
});

test('a Verify timeout returns 504', async () => {
    process.env.EPP_PROVIDER_TIMEOUT_MS = '1';
    fetchMock.mock.mockImplementation(async (_url, { signal }) => ({
        ok: true,
        status: 201,
        text: () => new Promise((_resolve, reject) => {
            signal.addEventListener('abort', () => reject(new Error('PRIVATE-TIMEOUT')), { once: true });
        }),
    }));
    const result = await invoke(await envelope());
    assert.equal(result.status, 504);
    assert.equal(records.find((record) => record.eventName === 'request_failed').failureReason, 'provider_timeout');
});
