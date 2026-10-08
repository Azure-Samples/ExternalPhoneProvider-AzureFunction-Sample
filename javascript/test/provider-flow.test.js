'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { inspect } = require('node:util');
const fixtures = require('../../tests/fixtures/contract.json');
const { AppConfig, readConfig } = require('../src/functions/config');
const { parseEntraPayload } = require('../src/functions/entraPayload');
const { DeliveryContext, OtpDelivery } = require('../src/functions/delivery');
const { OUTCOME } = require('../src/functions/providerResult');
const { selectProvider } = require('../src/functions/providers');
const {
    ProviderTransportError,
    isValidProviderUrl,
    parseProviderTimeout,
    sendProviderRequest,
} = require('../src/functions/providerTransport');
const { createRequestContext } = require('../src/functions/logging');

const delivery = new OtpDelivery({
    phoneNumber: '+15551234567',
    message: '  Your code is 001234; ref 1234567; alternate 654321.\n',
    channel: 'sms',
    messageId: 'message-id',
    correlationId: 'correlation-id',
    locale: 'fr-FR',
});
const input = {
    channel: 'sms',
    endpoint: 'https://provider.example',
    delivery,
    credential: { mode: 'apiKey', identity: 'id', secret: 'key' },
    env: { SINCH_SERVICE_PLAN_ID: 'plan' },
};
const response = (json, providerHttpStatus = 200, validJson = true) => ({
    json,
    providerHttpStatus,
    ok: providerHttpStatus >= 200 && providerHttpStatus < 300,
    validJson,
    elapsedMs: 1,
});
const envelope = (overrides = {}) => ({
    type: 'microsoft.mfa.otpDeliver.v1',
    channel: 1,
    mode: 1,
    encryptedDeliveryContext: 'a.b.c.d.e',
    ...overrides,
});

test('config and fixed provider lookup have no default or registry', () => {
    const config = readConfig({ EPP_PROVIDER_NAME: ' SiNcH ', EPP_PROVIDER_TIMEOUT_MS: ' 0012 ' });
    assert.ok(config instanceof AppConfig);
    assert.equal(inspect(config), '[AppConfig]');
    assert.deepEqual([config.providerName, config.providerTimeoutMs], ['sinch', ' 0012 ']);
    assert.equal(selectProvider(' SiNcH ').name, 'sinch');
    assert.equal(selectProvider('unknown'), null);
    assert.equal(selectProvider(''), null);
});

test('validated Entra payload and delivery models preserve content', () => {
    const parsed = parseEntraPayload(envelope({ channel: 'voice', mode: 'evaluation', ttlSeconds: 1 }));
    assert.equal(parsed.error, undefined);
    assert.equal(parsed.payload.channelName, 'voice');
    assert.equal(parsed.payload.isEvaluation, true);
    assert.equal(inspect(parsed.payload), '[EntraSendOtpPayload]');
    const context = DeliveryContext.fromPayload({
        nonce: 'nonce',
        phoneNumber: delivery.phoneNumber,
        message: delivery.message,
    });
    assert.ok(context.isComplete);
    assert.equal(context.message, delivery.message);
    assert.equal(inspect(context), '[DeliveryContext]');
    assert.equal(inspect(delivery), '[OtpDelivery]');
    for (const value of [null, [], 'text', 1]) assert.equal(DeliveryContext.fromPayload(value), null);
});

test('payload validation preserves exact shared reasons and order', () => {
    for (const fixture of fixtures.badRequests) {
        if (fixture.reason === 'invalid JSON body') continue;
        const value = fixture.rawBody !== undefined
            ? JSON.parse(fixture.rawBody)
            : envelope(fixture.overrides);
        assert.equal(parseEntraPayload(value).error, fixture.reason, fixture.name);
    }
});

test('provider URLs and timeout parsing preserve safety boundaries and cap', () => {
    for (const url of ['http://provider.example', 'https://@provider.example', 'https://provider.example#',
        'https://provider.example:0', 'https://provider.example:-1', 'https://provider.example:65536',
        'https://provider.example\\path', 'https://provider.example/\npath']) {
        assert.equal(isValidProviderUrl(url), false, url);
    }
    assert.equal(isValidProviderUrl('https://provider.example:65535/path?secret=hidden'), true);
    for (const value of [null, '0', '-1', '1e3']) assert.equal(parseProviderTimeout(value), 1500);
    assert.equal(parseProviderTimeout(' 0012 '), 12);
    assert.equal(parseProviderTimeout('999999999999999999999999999'), 2500);
});

test('Soprano owns OAuth request creation and rendered voice splitting', () => {
    const soprano = selectProvider('soprano');
    assert.deepEqual(soprano.credentialSpec, { mode: 'oauth' });
    const sms = soprano.createRequest({
        ...input,
        endpoint: 'https://provider.example/messages',
        credential: { mode: 'oauth', accessToken: 'token' },
    });
    assert.equal(sms.url, 'https://provider.example/messages');
    assert.equal(sms.headers.Authorization, 'Bearer token');
    assert.deepEqual(JSON.parse(sms.body), {
        destination: '15551234567',
        messageTypes: ['sms'],
        correlationId: 'correlation-id',
        shutterMode: false,
        text: delivery.message,
    });
    const voice = soprano.createRequest({
        ...input,
        channel: 'voice',
        credential: { mode: 'oauth', accessToken: 'token' },
    });
    assert.deepEqual(JSON.parse(voice.body).voice.text2voice, {
        beforePasswordText: '  Your code is ',
        password: '001234',
        afterPasswordText: '; ref 1234567; alternate 654321.\n',
        language: 'fr-FR',
        gender: 1,
        loop: 2,
    });
    assert.throws(() => soprano.createRequest({
        ...input,
        channel: 'voice',
        delivery: new OtpDelivery({ ...delivery, message: 'No code.' }),
        credential: { mode: 'oauth', accessToken: 'token' },
    }), /six-digit passcode/);
});

test('Soprano accepts root or first array object with strict status and flexible IDs', () => {
    const soprano = selectProvider('soprano');
    for (const [json, id, status, outcome] of [
        [{ id: 123, status: 'enroute' }, '123', 'ENROUTE', OUTCOME.CONTINUE],
        [[{ id: '', messageId: 456, state: 'accepted' }], '456', 'ACCEPTED', OUTCOME.CONTINUE],
        [{ id: {}, messageId: 'fallback', status: '', state: 'ACCEPTED' }, 'fallback', 'UNKNOWN', OUTCOME.FAIL],
        [{ status: false, state: 'ACCEPTED' }, null, 'UNKNOWN', OUTCOME.FAIL],
        [[], null, 'UNKNOWN', OUTCOME.FAIL],
    ]) {
        const result = soprano.interpretResponse(response(json));
        assert.deepEqual([result.providerMessageId, result.providerStatusName, result.outcome],
            [id, status, outcome]);
    }
});

test('Infobip accepts only strict recognized status strings', () => {
    const infobip = selectProvider('infobip');
    const request = infobip.createRequest(input);
    assert.equal(request.headers.Authorization, 'App key');
    assert.equal(JSON.parse(request.body).messages[0].content.text, delivery.message);
    for (const [status, expected] of [
        ['ACCEPTED', OUTCOME.CONTINUE],
        ['pending', OUTCOME.CONTINUE],
        ['DELIVERED', OUTCOME.CONTINUE],
        ['REJECTED', OUTCOME.FAIL],
        [290, OUTCOME.FAIL],
        [true, OUTCOME.FAIL],
        [{}, OUTCOME.FAIL],
        [null, OUTCOME.FAIL],
    ]) {
        const result = infobip.interpretResponse(response({
            messages: [{ messageId: 'provider-id', status: { groupName: status } }],
        }));
        assert.equal(result.outcome, expected);
        assert.equal(result.statusRecognized, typeof status === 'string'
            && ['ACCEPTED', 'PENDING', 'DELIVERED', 'REJECTED'].includes(status.toUpperCase()));
    }
});

test('Sinch HTTP success requires a nonblank string ID and may infer Dispatched', () => {
    const sinch = selectProvider('sinch');
    const request = sinch.createRequest(input);
    assert.equal(request.headers.Authorization, 'Bearer key');
    assert.equal(JSON.parse(request.body).body, delivery.message);
    for (const [json, outcome, reason, status] of [
        [{ id: 'batch-id' }, OUTCOME.CONTINUE, null, 'Dispatched'],
        [{ callId: 'call-id', status: 'Delivered' }, OUTCOME.CONTINUE, null, 'Delivered'],
        [{ id: ' ', status: 'Delivered' }, OUTCOME.FAIL, 'missing_provider_message_id', 'Delivered'],
        [{ id: 123, status: 'Delivered' }, OUTCOME.FAIL, 'missing_provider_message_id', 'Delivered'],
        [{ id: 'batch-id', status: true }, OUTCOME.FAIL, 'unrecognized_provider_status', null],
    ]) {
        const result = sinch.interpretResponse(response(json));
        assert.deepEqual([result.outcome, result.failureReason, result.providerStatusName],
            [outcome, reason, status]);
    }
});

test('Telesign uses OAuth while E.164 validation and voice pacing remain unchanged', () => {
    const telesign = selectProvider('telesign');
    const credential = { mode: 'oauth', accessToken: 'provider-token' };
    const voice = telesign.createRequest({ ...input, channel: 'voice', credential });
    assert.equal(telesign.authenticationMode, 'oauth');
    assert.deepEqual(telesign.credentialSpec, { mode: 'oauth' });
    assert.deepEqual(voice.headers, {
        Authorization: ['Bearer', credential.accessToken].join(' '),
        'Content-Type': 'application/json',
        Accept: 'application/json',
    });
    assert.equal(JSON.parse(voice.body).message.text,
        '  Your code is 0, 0, 1, 2, 3, 4; ref 1234567; alternate 6, 5, 4, 3, 2, 1.\n'
        + '   Your code is 0, 0, 1, 2, 3, 4; ref 1234567; alternate 6, 5, 4, 3, 2, 1.\n');
    for (const phoneNumber of ['15551234567', '+0123', '+1', '+1234567890123456', '+123\n']) {
        assert.throws(() => telesign.createRequest({
            ...input,
            credential,
            delivery: new OtpDelivery({ ...delivery, phoneNumber }),
        }), /invalid recipient/);
    }
});

test('Telesign status.code must be an integer number', () => {
    const telesign = selectProvider('telesign');
    for (const [code, outcome, normalized] of [
        [290, OUTCOME.CONTINUE, '290'],
        [3001, OUTCOME.CONTINUE, '3001'],
        [true, OUTCOME.FAIL, 'UNKNOWN'],
        ['290', OUTCOME.FAIL, 'UNKNOWN'],
        [290.5, OUTCOME.FAIL, 'UNKNOWN'],
        [null, OUTCOME.FAIL, 'UNKNOWN'],
    ]) {
        const result = telesign.interpretResponse(response({ status: { code } }));
        assert.deepEqual([result.outcome, result.providerStatusCode], [outcome, normalized]);
    }
});

test('providers fail closed with fixed safe classifications', () => {
    const cases = [
        [selectProvider('infobip'), response(null, 200, false), 'invalid_provider_json', 502],
        [selectProvider('soprano'), response({ status: 'PRIVATE' }), 'unrecognized_provider_status', 502],
        [selectProvider('infobip'), response({ messages: [{ status: { name: 'REJECTED' } }] }),
            'provider_rejected', 502],
        [selectProvider('telesign'), response({ status: { code: 290 } }, 429), 'provider_http_error', 429],
        [selectProvider('sinch'), response({ id: 'id' }, 500), 'provider_http_error', 502],
    ];
    for (const [provider, providerResponse, reason, httpStatus] of cases) {
        const result = provider.interpretResponse(providerResponse);
        assert.deepEqual([result.failureReason, result.httpStatus], [reason, httpStatus]);
    }
});

test('shared transport uses manual redirects, omits query from logs, and awaits the body', async (t) => {
    const records = [];
    const context = createRequestContext({
        invocationId: 'invocation',
        log: (value) => records.push(JSON.parse(value)),
        warn: (value) => records.push(JSON.parse(value)),
        error: (value) => records.push(JSON.parse(value)),
    }, 'request-id', null, null);
    let release;
    const body = new Promise((resolve) => { release = resolve; });
    const fetchMock = t.mock.method(global, 'fetch', async () => ({
        ok: true,
        status: 200,
        text: () => body,
    }));
    let settled = false;
    const pending = sendProviderRequest({
        url: 'https://provider.example/api/send?secret=PRIVATE',
        method: 'POST',
        headers: { Authorization: 'PRIVATE-TOKEN' },
        body: '{}',
    }, 1500, context).then((value) => { settled = true; return value; });
    await new Promise(setImmediate);
    assert.equal(settled, false);
    release('{"status":"ok"}');
    assert.equal((await pending).validJson, true);
    assert.equal(fetchMock.mock.calls[0].arguments[1].redirect, 'manual');
    assert.equal(records.find((event) => event.eventName === 'provider_request_built').providerEndpoint,
        'https://provider.example/api/send');
    assert.doesNotMatch(JSON.stringify(records), /PRIVATE/);
});

test('shared transport AbortController covers body reading and classifies timeout', async (t) => {
    const context = createRequestContext({
        invocationId: 'invocation',
        log() {},
        warn() {},
        error() {},
    }, 'request-id', null, null);
    const fetchMock = t.mock.method(global, 'fetch', async (_url, { signal }) => ({
        ok: true,
        status: 200,
        text: () => new Promise((_resolve, reject) => {
            signal.addEventListener('abort', () => reject(new Error('private')), { once: true });
        }),
    }));
    await assert.rejects(
        sendProviderRequest({ url: 'https://provider.example', method: 'POST' }, 1, context),
        (error) => error instanceof ProviderTransportError
            && error.httpStatus === 504
            && error.reason === 'provider_timeout',
    );
    assert.equal(fetchMock.mock.calls[0].arguments[1].signal.aborted, true);
});
