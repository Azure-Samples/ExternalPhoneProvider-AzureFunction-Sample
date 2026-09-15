'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { SecretClient } = require('@azure/keyvault-secrets');
const { AppConfig, readConfig } = require('../src/functions/config');
const { DeliveryContext, TextToVoice, ParsedResponse } = require('../src/functions/models');
const fixtures = require('../../tests/fixtures/contract.json');
const { inspect } = require('node:util');
const {
    dispatchOtp, getProvider, resolveOutcome, outcomeToHttpStatus,
    parseEnvelope, parseProviderTimeout, isValidProviderUrl, contextToDispatch,
} = require('../src/functions/dispatch');
const dispatch = { destination: '+15551234567', message: '  Your code is 918273.\n',
    channel: 'sms', messageId: 'message-id', correlationId: 'correlation-id' };
const input = { channel: 'sms', endpoint: 'https://provider.example', dispatch,
    credential: { mode: 'apiKey', identity: 'id', secret: 'key' }, env: { SINCH_SERVICE_PLAN_ID: 'plan' } };
const envelope = (overrides = {}) => ({ type: 'microsoft.mfa.otpDeliver.v1', channel: 1, mode: 1,
    encryptedDeliveryContext: 'a.b.c.d.e', ...overrides });

test('config uses the deployment provider, with no hardcoded fallback', async (t) => {
    const env = { EPP_PROVIDER_NAME: ' SiNcH ',
        EPP_PROVIDER_TIMEOUT_MS: ' 0012 ', SINCH_SERVICE_PLAN_ID: 'custom-plan',
        EPP_PROVIDER_ENDPOINT: input.endpoint, KEY_VAULT_URL: 'https://config-test.vault.azure.net' };
    const getSecret = t.mock.method(SecretClient.prototype, 'getSecret', async () => ({ value: 'fixture-key' }));
    const fetchMock = t.mock.method(global, 'fetch', async () => ({ ok: true, status: 200,
        text: async () => JSON.stringify({ id: 'batch-id' }) }));
    const config = readConfig(env);
    assert.ok(config instanceof AppConfig);
    assert.equal(inspect(config), '[AppConfig]');
    assert.deepEqual([config.providerName, config.providerTimeoutMs], ['sinch', ' 0012 ']);
    assert.equal(config.env, env);
    assert.equal(readConfig({}).providerName, '');
    for (const providerName of ['', 'unknown']) {
        assert.equal((await dispatchOtp(dispatch, { config: { ...config, providerName } })).httpStatus, 400);
    }
    assert.deepEqual([getSecret.mock.callCount(), fetchMock.mock.callCount()], [0, 0]);
    const result = await dispatchOtp({ ...dispatch, provider: 'unknown' }, { config });
    assert.deepEqual([result.httpStatus, result.body.provider, result.body.outcome], [200, 'sinch', 'Continue']);
    assert.deepEqual([getSecret.mock.callCount(), fetchMock.mock.callCount()], [1, 1]);
    const [url, init] = fetchMock.mock.calls[0].arguments;
    assert.equal(url, `${input.endpoint}/xms/v1/custom-plan/batches`);
    assert.equal(JSON.parse(init.body).body, dispatch.message);
});

test('request models preserve content and accept valid TTL boundaries', () => {
    const context = DeliveryContext.fromPayload({ nonce: 'test-nonce', phoneNumber: dispatch.destination, message: dispatch.message });
    assert.ok(context instanceof DeliveryContext);
    assert.ok(context.isComplete);
    assert.equal(context.message, dispatch.message);
    assert.equal(inspect(context), '[DeliveryContext]');
    for (const payload of [null, [], 'text', 1]) assert.equal(DeliveryContext.fromPayload(payload), null);
    assert.equal(DeliveryContext.fromPayload({ nonce: 123, phoneNumber: 'phone', message: 'text' }).isComplete, false);
    assert.ok(parseEnvelope(envelope()).envelope);
    assert.ok(parseEnvelope(envelope({ ttlSeconds: 1 })).envelope);
    assert.ok(parseEnvelope(envelope({ ttlSeconds: 2147483647 })).envelope);
});

test('envelope parser rejects invalid inputs with the contract reason', () => {
    for (const fixture of fixtures.badRequests) {
        // Malformed JSON is handled before the parser receives an object.
        if (fixture.reason === 'invalid JSON body') continue;
        const payload = fixture.rawBody !== undefined ? JSON.parse(fixture.rawBody) : envelope(fixture.overrides);
        const result = parseEnvelope(payload);
        assert.equal(result.error, fixture.reason, fixture.name);
        assert.equal(result.envelope, undefined, fixture.name);
    }
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

test('omnimsg preserves its API-key request and normalizes acceptance', () => {
    const request = getProvider('soprano').adapter.buildRequest({ ...input, env: undefined, endpoint: `${input.endpoint}/cgpapi///` });
    assert.equal(request.url, 'https://provider.example/cgpapi/messages/omnimsg');
    assert.equal(request.method, 'POST');
    assert.deepEqual(request.headers, { 'Content-Type': 'application/json', Accept: 'application/json',
        'X-MEMS-API-ID': 'id', 'X-MEMS-API-Key': 'key' });
    assert.deepEqual(JSON.parse(request.body), { text: dispatch.message, destination: '15551234567',
        messageTypes: ['sms'], correlationId: 'correlation-id', shutterMode: false });
    const response = getProvider('soprano').adapter.parseResponse({ httpStatus: 201, ok: true,
        json: { id: 123, status: 'ENROUTE' } });
    assert.deepEqual(response, new ParsedResponse({ success: true, providerHttpStatus: 201,
        providerMessageId: '123', providerStatusName: 'ENROUTE' }));
    assert.equal(inspect(response), '[ParsedResponse]');
});

test('Soprano Voice sends structured speech with API-key headers only', () => {
    const textToVoice = TextToVoice.fromPayload({ beforePasswordText: ' Your code is ', password: '001234',
        language: 'en-US', unexpected: 'must-not-be-forwarded' });
    const request = getProvider('soprano').adapter.buildRequest({ ...input, channel: 'voice',
        dispatch: { ...dispatch, textToVoice }, credential: { ...input.credential, token: 'ignored-token' } });
    assert.equal(request.url, `${input.endpoint}/messages/omnimsg`);
    assert.deepEqual(request.headers, { 'Content-Type': 'application/json', Accept: 'application/json',
        'X-MEMS-API-ID': 'id', 'X-MEMS-API-Key': 'key' });
    assert.deepEqual(JSON.parse(request.body), { destination: '15551234567', messageTypes: ['voice'],
        correlationId: 'correlation-id', shutterMode: false,
        voice: { text2voice: { beforePasswordText: ' Your code is ', password: '001234', language: 'en-US' } } });
    assert.equal(inspect(textToVoice), '[TextToVoice]');
    assert.throws(() => getProvider('soprano').adapter.buildRequest({ ...input, channel: 'voice' }),
        /incomplete voice context/);
});

test('Soprano Voice validates decrypted speech before secret lookup or HTTP', async (t) => {
    const getSecret = t.mock.method(SecretClient.prototype, 'getSecret', () => assert.fail('unexpected secret lookup'));
    const fetchMock = t.mock.method(global, 'fetch', () => assert.fail('unexpected HTTP'));
    const config = readConfig({ EPP_PROVIDER_NAME: 'soprano', EPP_PROVIDER_ENDPOINT: input.endpoint });
    for (const textToVoice of [null, [], 'text', {}, { beforePasswordText: '', password: 123, language: 'en' },
        { beforePasswordText: '', password: '001234', language: '' },
        { beforePasswordText: null, password: '001234', language: 'en' }]) {
        const context = DeliveryContext.fromPayload({ nonce: 'nonce', phoneNumber: dispatch.destination,
            message: dispatch.message, textToVoice });
        const result = await dispatchOtp(contextToDispatch(context, { channel: 2 }, 'message-id'), { config });
        assert.deepEqual([result.httpStatus, result.body.reason], [400, 'incomplete voice context']);
    }
    const context = DeliveryContext.fromPayload({ textToVoice: { beforePasswordText: '', password: '001234', language: 'en-US' } });
    assert.ok(contextToDispatch(context, { channel: 2 }, 'message-id').textToVoice.isComplete);
    assert.equal(getSecret.mock.callCount(), 0);
    assert.equal(fetchMock.mock.callCount(), 0);
});

test('App-auth SMS preserves its request and normalizes acceptance', () => {
    const request = getProvider('infobip').adapter.buildRequest(input);
    assert.equal(request.url, 'https://provider.example/sms/3/messages');
    assert.equal(request.headers.Authorization, 'App key');
    assert.equal(request.headers['Content-Type'], 'application/json');
    assert.equal(JSON.parse(request.body).messages[0].content.text, dispatch.message);
    const response = getProvider('infobip').adapter.parseResponse({ httpStatus: 200, ok: true,
        json: { messages: [{ messageId: 'message-id', status: { groupName: 'PENDING' } }] } });
    assert.deepEqual(response, new ParsedResponse({ success: true, providerHttpStatus: 200,
        providerMessageId: 'message-id', providerStatusName: 'PENDING' }));
});

test('Telesign EPP uses the same Basic-auth JSON contract for SMS and voice', () => {
    for (const [channel, locale] of [['sms', 'en'], ['voice', 'en'],
        ['sms', undefined], ['sms', ''], ['sms', { untrusted: true }]]) {
        const request = getProvider('telesign').adapter.buildRequest({ ...input, channel,
            endpoint: 'https://verify.telesign.com///', dispatch: { ...dispatch, locale } });
        assert.equal(request.url, 'https://verify.telesign.com/integration/msft/cyot');
        assert.equal(request.method, 'POST');
        assert.deepEqual(request.headers, { Authorization: `Basic ${Buffer.from('id:key').toString('base64')}`,
            'Content-Type': 'application/json', Accept: 'application/json' });
        assert.deepEqual(JSON.parse(request.body), {
            recipient: { phone_number: dispatch.destination },
            message: locale === 'en' ? { text: dispatch.message, language: 'en' } : { text: dispatch.message },
            channels: [{ channel }], correlation_id: dispatch.correlationId,
        });
    }
    const response = getProvider('telesign').adapter.parseResponse({ httpStatus: 200, ok: true,
        json: { reference_id: 'message-id', status: { code: 290 } } });
    assert.deepEqual(response, new ParsedResponse({ success: true, providerHttpStatus: 200,
        providerMessageId: 'message-id', providerStatusCode: '290' }));
});

test('Telesign EPP rejects invalid recipients and fails closed on unknown status', () => {
    const { adapter, manifest } = getProvider('telesign');
    for (const destination of ['15551234567', '+0123', '+1', '+1234567890123456', '+123\n', '+123\r', '+12 34', null]) {
        assert.throws(() => adapter.buildRequest({ ...input, dispatch: { ...dispatch, destination } }), /invalid recipient/);
    }
    assert.throws(() => adapter.buildRequest({ ...input, channel: 'email' }), /unsupported channel/);
    for (const correlationId of [undefined, null, '', 123, true, [], { invalid: true }]) {
        const request = adapter.buildRequest({ ...input, dispatch: { ...dispatch, correlationId } });
        assert.equal(JSON.parse(request.body).correlation_id, dispatch.messageId);
    }
    for (const code of [undefined, null, {}, true, '290', 999]) {
        const parsed = adapter.parseResponse({ httpStatus: 200, ok: true, json: { status: { code } } });
        assert.equal(resolveOutcome(manifest, parsed), 'Fail');
    }
    for (const [code, ok, expected] of [[290, true, 'Continue'], [100, true, 'Continue'], [290, false, 'Fail'],
        [3001, true, 'Continue'], [3001, false, 'Fail']]) {
        const parsed = adapter.parseResponse({ httpStatus: ok ? 200 : 500, ok,
            json: { reference_id: 'reference', status: { code, description: 'status detail' } } });
        assert.equal(parsed.providerStatusDescription, 'status detail');
        assert.equal(resolveOutcome(manifest, parsed), expected);
    }
});

test('static-Bearer SMS preserves its batch request and normalizes acceptance', () => {
    const request = getProvider('sinch').adapter.buildRequest(input);
    assert.equal(request.url, 'https://provider.example/xms/v1/plan/batches');
    assert.equal(request.headers.Authorization, 'Bearer key');
    assert.equal(request.headers['Content-Type'], 'application/json');
    assert.equal(JSON.parse(request.body).body, dispatch.message);
    const response = getProvider('sinch').adapter.parseResponse({ httpStatus: 200, ok: true, json: { id: 'message-id' } });
    assert.deepEqual(response, new ParsedResponse({ success: true, providerHttpStatus: 200,
        providerMessageId: 'message-id', providerStatusName: 'Dispatched' }));
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
