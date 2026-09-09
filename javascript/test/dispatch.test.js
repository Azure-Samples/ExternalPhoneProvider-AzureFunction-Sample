'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { SecretClient } = require('@azure/keyvault-secrets');
const { readConfig } = require('../src/functions/config');
const {
    dispatchOtp, getProvider, resolveOutcome, outcomeToHttpStatus,
    parseEnvelope, parseProviderTimeout, isValidProviderUrl,
} = require('../src/functions/dispatch');
const dispatch = { destination: '+15551234567', message: '  Your code is 918273.\n',
    channel: 'sms', messageId: 'message-id', correlationId: 'correlation-id' };
const input = { channel: 'sms', endpoint: 'https://provider.example', dispatch,
    credential: { mode: 'apiKey', identity: 'id', secret: 'key' }, env: { SINCH_SERVICE_PLAN_ID: 'plan' } };
const envelope = (overrides = {}) => ({ type: 'microsoft.mfa.otpDeliver.v1', channel: 1, mode: 1,
    encryptedDeliveryContext: 'a.b.c.d.e', ...overrides });

test('config uses the supplied audience and deployment provider, with no hardcoded fallback', async () => {
    const audience = '11111111-2222-4333-8444-555555555555';
    const env = { EPP_EXPECTED_AUDIENCE: ` ${audience} `, EPP_PROVIDER_NAME: ' SiNcH ',
        EPP_PROVIDER_TIMEOUT_MS: ' 0012 ', SINCH_SERVICE_PLAN_ID: 'custom-plan',
        EPP_TENANT_ID: ' trusted-tenant ', WEBSITE_HOSTNAME: 'azure-test' };
    const config = readConfig(env);
    assert.deepEqual([config.expectedAudience, config.providerName, config.providerTimeoutMs], [audience, 'sinch', ' 0012 ']);
    assert.equal(config.env, env);
    assert.equal(config.tenantId, 'trusted-tenant');
    assert.equal(Object.hasOwn(config, 'onAzure'), false);
    const result = await dispatchOtp({ ...dispatch, provider: 'unknown' }, { config, shutter: true });
    assert.deepEqual([result.httpStatus, result.body.provider], [200, 'sinch']);
    const defaults = readConfig({});
    assert.deepEqual([defaults.expectedAudience, defaults.providerName], ['', '']);
    for (const providerName of ['', 'unknown']) {
        assert.equal((await dispatchOtp(dispatch, { config: { ...config, providerName }, shutter: true })).httpStatus, 400);
    }
});

test('envelope TTL boundaries and routing reject coercion', () => {
    assert.ok(parseEnvelope(envelope()).envelope);
    assert.ok(parseEnvelope(envelope({ ttlSeconds: 2147483647 })).envelope);
    for (const ttlSeconds of [-1, 0, '60', null, true, 1.5, 2147483648]) {
        assert.ok(parseEnvelope(envelope({ ttlSeconds })).error, String(ttlSeconds));
    }
    assert.equal(parseEnvelope(envelope({ channel: '1' })).error, 'unsupported channel');
    assert.equal(parseEnvelope(envelope({ mode: true })).error, 'unsupported mode');
});

test('provider URLs and timeouts retain representative safety boundaries', () => {
    for (const url of ['http://provider.example', 'https://@provider.example', 'https://provider.example#',
        'https://provider.example:0', 'https://provider.example:-1', 'https://provider.example:65536']) {
        assert.equal(isValidProviderUrl(url), false, url);
    }
    assert.equal(isValidProviderUrl('https://provider.example:65535/path'), true);
    for (const value of [null, '0', '-1', '1e3']) {
        assert.equal(parseProviderTimeout(value), 1500);
    }
    assert.equal(parseProviderTimeout(' 0012 '), 12);
    assert.equal(parseProviderTimeout('9999'), 2500);
});

test('omnimsg uses API ID/key headers and a constant false shutterMode wire field', () => {
    const request = getProvider('soprano').adapter.buildRequest({ ...input, env: undefined, endpoint: `${input.endpoint}/cgpapi///` });
    assert.equal(request.url, 'https://provider.example/cgpapi/messages/omnimsg');
    assert.equal(request.method, 'POST');
    assert.deepEqual(request.headers, { 'Content-Type': 'application/json', Accept: 'application/json',
        'X-MEMS-API-ID': 'id', 'X-MEMS-API-Key': 'key' });
    assert.deepEqual(JSON.parse(request.body), { text: dispatch.message, destination: '15551234567',
        messageTypes: ['sms'], correlationId: 'correlation-id', shutterMode: false });
});

test('App authentication uses JSON SMS content', () => {
    const request = getProvider('infobip').adapter.buildRequest(input);
    assert.equal(request.url, 'https://provider.example/sms/3/messages');
    assert.equal(request.headers.Authorization, 'App key');
    assert.equal(request.headers['Content-Type'], 'application/json');
    assert.equal(JSON.parse(request.body).messages[0].content.text, dispatch.message);
});

test('Basic authentication uses form-encoded SMS content', () => {
    const request = getProvider('telesign').adapter.buildRequest(input);
    assert.equal(request.url, 'https://provider.example/v1/messaging');
    assert.equal(request.headers.Authorization, `Basic ${Buffer.from('id:key').toString('base64')}`);
    assert.equal(request.headers['Content-Type'], 'application/x-www-form-urlencoded');
    assert.equal(new URLSearchParams(request.body).get('message'), dispatch.message);
});

test('static Bearer authentication uses the service-plan SMS route', () => {
    const request = getProvider('sinch').adapter.buildRequest(input);
    assert.equal(request.url, 'https://provider.example/xms/v1/plan/batches');
    assert.equal(request.headers.Authorization, 'Bearer key');
    assert.equal(request.headers['Content-Type'], 'application/json');
    assert.equal(JSON.parse(request.body).body, dispatch.message);
});

test('response parsing and HTTP mapping fail closed, including malformed status/state', () => {
    const { manifest, adapter } = getProvider('soprano');
    const mapping = { ...manifest, responseMapping: { ...manifest.responseMapping, CHALLENGE: 'StepUp' } };
    for (const [json, upstream, expected, status] of [
        [{ status: 'ENROUTE' }, 201, 'Continue', 200],
        [{ status: 'UNKNOWN' }, 200, 'Fail', 502],
        [{ status: 'FILTERED' }, 200, 'Fail', 502],
        [{ status: false, state: 'ACCEPTED' }, 200, 'Fail', 502],
        [{ status: 123, state: 'ACCEPTED' }, 200, 'Fail', 502],
        [{ state: false }, 200, 'Fail', 502],
        [{ status: 'ENROUTE' }, 500, 'Fail', 502],
        [{ status: 'BLOCKED' }, 500, 'Block', 403],
        [{ status: 'CHALLENGE' }, 500, 'StepUp', 409],
    ]) {
        const parsed = adapter.parseResponse({ json, httpStatus: upstream, ok: upstream < 300 });
        const outcome = resolveOutcome(mapping, parsed);
        assert.deepEqual([outcome, outcomeToHttpStatus(outcome, upstream)], [expected, status], JSON.stringify(json));
    }
});

test('missing key/identity and an unsafe final voice URL make zero HTTP calls', async (t) => {
    const settings = { KEY_VAULT_URL: 'https://unit-test.vault.azure.net',
        EPP_PROVIDER_ENDPOINT: input.endpoint, SINCH_VOICE_ENDPOINT: 'http://unsafe.example' };
    const getSecret = t.mock.method(SecretClient.prototype, 'getSecret', async (name) => ({
        value: ['soprano-api-id', 'telesign-api-key'].includes(name) ? '' : 'fixture-key',
    }));
    const fetchMock = t.mock.method(global, 'fetch', () => assert.fail('unexpected HTTP'));
    for (const [providerName, channel, reason] of [
        ['soprano', 'sms', 'provider credential unavailable'],
        ['telesign', 'sms', 'provider credential unavailable'],
        ['sinch', 'voice', 'provider request URL invalid'],
    ]) {
        const config = readConfig({ ...settings, EPP_PROVIDER_NAME: providerName });
        const result = await dispatchOtp({ ...dispatch, channel }, { config, requestId: 'request-id' });
        assert.deepEqual([result.httpStatus, result.body.reason], [502, reason]);
    }
    const config = readConfig({ ...settings, EPP_PROVIDER_NAME: 'sinch' });
    const calls = getSecret.mock.callCount();
    for (const override of [{}, { managedIdentityClientId: '11111111-2222-4333-8444-555555555555' },
        { keyVaultUrl: 'https://other-test.vault.azure.net' }]) {
        const nextConfig = { ...config, ...override };
        await dispatchOtp({ ...dispatch, channel: 'voice' }, { config: nextConfig });
        assert.equal(getSecret.mock.calls.at(-1).this.vaultUrl, nextConfig.keyVaultUrl);
    }
    assert.equal(getSecret.mock.callCount(), calls + 2);
    assert.equal(new Set(getSecret.mock.calls.map((call) => call.this)).size, 3);
    assert.equal(fetchMock.mock.callCount(), 0);
});
