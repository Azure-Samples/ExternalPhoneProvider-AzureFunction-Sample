'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { OtpDelivery } = require('../src/functions/delivery');
const { OUTCOME } = require('../src/functions/providerResult');
const { selectProvider } = require('../src/functions/providers');

const SERVICE_SID = `VA${'a'.repeat(32)}`;
const twilio = selectProvider(' TwiLio ');
const delivery = new OtpDelivery({
    phoneNumber: '+15551234567',
    message: 'Your verification code is 012345.',
    otp: '012345',
    channel: 'sms',
    messageId: 'message-id',
    correlationId: 'correlation-id',
    locale: 'en-US',
});
const input = {
    channel: 'sms',
    endpoint: 'https://verify.twilio.com',
    delivery,
    credential: { mode: 'apiKey', identity: 'SKkeysid', secret: 'keysecret' },
    env: { TWILIO_VERIFY_SERVICE_SID: SERVICE_SID },
};
const response = (json, providerHttpStatus = 201, validJson = true) => ({
    json,
    providerHttpStatus,
    ok: providerHttpStatus >= 200 && providerHttpStatus < 300,
    validJson,
    elapsedMs: 1,
});

test('twilio is registered with API-key auth and two Key Vault secrets', () => {
    assert.equal(twilio.name, 'twilio');
    assert.equal(twilio.authenticationMode, 'apiKey');
    assert.deepEqual(twilio.credentialSpec, {
        mode: 'apiKey',
        keyVaultSecretName: 'twilio-api-key-secret',
        identityKeyVaultSecretName: 'twilio-api-key-id',
    });
});

test('SMS request starts a Verify verification with the Entra-supplied code', () => {
    const request = twilio.createRequest(input);
    assert.equal(request.method, 'POST');
    assert.equal(request.url, `https://verify.twilio.com/v2/Services/${SERVICE_SID}/Verifications`);
    assert.equal(request.headers['Content-Type'], 'application/x-www-form-urlencoded');
    assert.equal(request.headers.Authorization,
        `Basic ${Buffer.from('SKkeysid:keysecret').toString('base64')}`);
    const body = new URLSearchParams(request.body);
    assert.deepEqual(Object.fromEntries(body), {
        To: '+15551234567', Channel: 'sms', CustomCode: '012345',
        Tags: JSON.stringify({ entra_byot_correlation_id: 'correlation-id' }),
    });
});

test('voice request uses the call channel and preserves leading zeros in the code', () => {
    const request = twilio.createRequest({ ...input, channel: 'voice' });
    const body = new URLSearchParams(request.body);
    assert.equal(body.get('Channel'), 'call');
    assert.equal(body.get('CustomCode'), '012345');
});

test('a trailing slash on the endpoint does not double up', () => {
    const request = twilio.createRequest({ ...input, endpoint: 'https://verify.twilio.com/' });
    assert.equal(request.url, `https://verify.twilio.com/v2/Services/${SERVICE_SID}/Verifications`);
});

test('only To, Channel, CustomCode, and Tags are sent; Entra message text and locale are not forwarded', () => {
    const body = new URLSearchParams(twilio.createRequest(input).body);
    assert.deepEqual([...body.keys()].sort(), ['Channel', 'CustomCode', 'Tags', 'To']);
});

test('Tags carry only the Entra correlation ID, or unknown when it is missing or not ID-shaped', () => {
    const tagsFor = (correlationId) => JSON.parse(new URLSearchParams(twilio.createRequest({
        ...input, delivery: new OtpDelivery({ ...delivery, correlationId }),
    }).body).get('Tags'));
    const id = '00877757-333f-2369-058f-88d4e7cc2935';
    assert.deepEqual(tagsFor(id), { entra_byot_correlation_id: id });
    for (const bad of [undefined, '', '+15551234567 012345', 'a'.repeat(129), 'id with spaces', { id }]) {
        assert.deepEqual(tagsFor(bad), { entra_byot_correlation_id: 'unknown' });
    }
    assert.doesNotMatch(JSON.stringify(tagsFor(id)), /15551234567|012345/);
});

test('request building fails closed on bad input', () => {
    const withDelivery = (overrides) => new OtpDelivery({ ...delivery, ...overrides });
    for (const bad of [
        { ...input, channel: 'whatsapp' },
        { ...input, env: {} },
        { ...input, env: { TWILIO_VERIFY_SERVICE_SID: 'VA123' } },
        { ...input, env: { TWILIO_VERIFY_SERVICE_SID: `AC${'a'.repeat(32)}` } },
        { ...input, delivery: withDelivery({ phoneNumber: '5551234567' }) },
        { ...input, delivery: withDelivery({ phoneNumber: '+0123' }) },
        { ...input, delivery: withDelivery({ otp: undefined }) },
        { ...input, delivery: withDelivery({ otp: null }) },
        { ...input, delivery: withDelivery({ otp: '123' }) },
        { ...input, delivery: withDelivery({ otp: '12345678901' }) },
        { ...input, delivery: withDelivery({ otp: '12ab56' }) },
    ]) {
        assert.throws(() => twilio.createRequest(bad));
    }
});

test('a pending verification with a SID is accepted', () => {
    const result = twilio.interpretResponse(response({ sid: `VE${'b'.repeat(32)}`, status: 'pending' }));
    assert.equal(result.outcome, OUTCOME.CONTINUE);
    assert.equal(result.httpStatus, 200);
    assert.equal(result.providerStatusName, 'pending');
    assert.equal(result.providerMessageId, `VE${'b'.repeat(32)}`);
    assert.equal(result.failureReason, null);
});

test('responses without a SID or with an unexpected status fail closed', () => {
    for (const [json, reason] of [
        [{ status: 'pending' }, 'missing_provider_message_id'],
        [{ sid: ' ', status: 'pending' }, 'missing_provider_message_id'],
        [{ sid: 123, status: 'pending' }, 'missing_provider_message_id'],
        [{ sid: 'VE1', status: 'mystery' }, 'unrecognized_provider_status'],
        [{ sid: 'VE1' }, 'unrecognized_provider_status'],
        [{ sid: 'VE1', status: true }, 'unrecognized_provider_status'],
        [{ sid: 'VE1', status: 'failed' }, 'provider_rejected'],
        [{ sid: 'VE1', status: 'canceled' }, 'provider_rejected'],
    ]) {
        const result = twilio.interpretResponse(response(json));
        assert.equal(result.outcome, OUTCOME.FAIL, JSON.stringify(json));
        assert.equal(result.failureReason, reason, JSON.stringify(json));
        assert.equal(result.httpStatus, 502);
    }
});

test('invalid JSON and HTTP errors map to the shared safe statuses', () => {
    for (const [providerResponse, reason, httpStatus] of [
        [response(null, 201, false), 'invalid_provider_json', 502],
        [response({ code: 20429 }, 429), 'provider_http_error', 429],
        [response({ code: 20003 }, 401), 'provider_http_error', 400],
        [response({ code: 60200 }, 400), 'provider_http_error', 400],
        [response({ code: 20404 }, 404), 'provider_http_error', 400],
        [response({ sid: 'VE1', status: 'pending' }, 500), 'provider_http_error', 502],
    ]) {
        const result = twilio.interpretResponse(providerResponse);
        assert.equal(result.outcome, OUTCOME.FAIL);
        assert.deepEqual([result.failureReason, result.httpStatus], [reason, httpStatus]);
    }
});

test('Fraud Guard and Geo Permissions blocks map to Block (422)', () => {
    for (const code of [60410, 60605]) {
        const result = twilio.interpretResponse(response({ code, status: 403 }, 403));
        assert.equal(result.outcome, OUTCOME.BLOCK);
        assert.equal(result.httpStatus, 422);
        assert.equal(result.failureReason, 'provider_blocked');
        assert.equal(result.providerStatusCode, code);
    }
});

test('a block code on a 2xx response is not trusted as a block', () => {
    const result = twilio.interpretResponse(response({ code: 60410, sid: 'VE1', status: 'pending' }, 201));
    assert.equal(result.outcome, OUTCOME.CONTINUE);
});

test('result objects carry no phone number, code, or credentials', () => {
    const result = twilio.interpretResponse(response({
        sid: 'VE1', status: 'pending', to: '+15551234567',
    }));
    assert.doesNotMatch(JSON.stringify(result), /15551234567|012345|keysecret/);
});
