'use strict';

// Integration tests for the dispatch pipeline with a mocked provider fetch and a mocked Key Vault.

const { test, beforeEach, mock } = require('node:test');
const assert = require('node:assert');

// Non-secret provider config (app settings, not secrets) — set before requiring the modules.
process.env.KEY_VAULT_URL = 'https://test.vault.azure.net';
process.env.SINCH_SERVICE_PLAN_ID = 'sp';
process.env.EPP_PROVIDER_ENDPOINT = 'https://api.infobip.com';

// Provider secrets come from Key Vault via managed identity in production; mock getSecret here.
const providerSecrets = {
    'infobip-api-key': 'ib',
    'telesign-api-key': 'ts',
    'telesign-customer-id': 'cust',
    'sinch-api-token': 'st',
    'soprano-api-key': 'sp',
    'soprano-api-id': 'sp-id',
};
const { SecretClient } = require('@azure/keyvault-secrets');
mock.method(SecretClient.prototype, 'getSecret', async (name) => ({ value: providerSecrets[name] }));

const { dispatchOtp, getProvider, resolveOutcome, outcomeToHttpStatus } = require('../src/functions/dispatch');

let resp;
let sent;
global.fetch = async (url, opts) => {
    sent = { url, opts };
    if (resp === 'THROW') throw new Error('neterr');
    if (resp === 'TIMEOUT') throw new Error('endpoint timeout after 1500ms');
    return { ok: resp.ok, status: resp.status, text: async () => JSON.stringify(resp.body) };
};

const ctx = { log() {} };
let n = 0;
const uniqueDest = () => '+1555' + String(1000000 + n++).slice(-7);
const disp = (o = {}) => ({ destination: uniqueDest(), message: 'Your code is 918273', channel: 'sms', messageId: 'm', correlationId: 'c' + Math.random(), ...o });

beforeEach(() => {
    resp = { ok: true, status: 200, body: { messages: [{ status: { name: 'DELIVERED' } }] } };
});

// A "success" response body shaped the way each provider's parseResponse expects, so each yields a
// status that maps to Continue (unknown statuses now fail closed — see resolveOutcome).
const successBody = {
    infobip: { messages: [{ status: { name: 'DELIVERED' } }] },
    telesign: { status: { code: 290 } },
    sinch: { id: 'batch-1' },
    soprano: { status: 'DELIVERED' },
};

for (const prov of ['infobip', 'telesign', 'sinch', 'soprano']) {
    for (const ch of ['sms', 'voice']) {
        test(`${prov}/${ch}: 200, message sent in body, https, provider auth scheme`, async () => {
            resp = { ok: true, status: 200, body: successBody[prov] };
            const r = await dispatchOtp(disp({ channel: ch }), { requestProvider: prov, context: ctx, requestId: 'r' });
            assert.equal(r.httpStatus, 200);
            assert.match(sent.url, /^https:\/\//);
            assert.ok(sent.opts.body.includes('918273'), 'rendered message missing from body');
            const providerAuth = sent.opts.headers.Authorization || sent.opts.headers['X-MEMS-API-Key'];
            assert.ok(providerAuth, 'provider auth header missing');
            if (sent.opts.headers.Authorization) {
                assert.match(sent.opts.headers.Authorization, /Bearer|App|Basic/);
            }
        });
    }
}

// Outcome + HTTP mapping is pure, so it is asserted directly here instead of once per case through
// the whole dispatch pipeline (mirrors the .NET and Python contract tests).
test('outcome mapping and HTTP status', () => {
    const infobip = getProvider('infobip').manifest;
    const soprano = getProvider('soprano').manifest;
    const telesign = getProvider('telesign').manifest;

    assert.equal(resolveOutcome(infobip, { success: true, providerStatusName: 'DELIVERED' }), 'Continue');
    assert.equal(resolveOutcome(infobip, { success: true, providerStatusName: 'REJECTED' }), 'Fail');
    assert.equal(resolveOutcome(infobip, { success: true, providerStatusName: 'WATWAT' }), 'Fail');
    assert.equal(resolveOutcome(soprano, { success: true, providerStatusName: 'BLOCKED' }), 'Block');
    assert.equal(resolveOutcome(telesign, { success: true, providerStatusCode: '100' }), 'Continue');

    assert.equal(outcomeToHttpStatus('Continue', 200), 200);
    assert.equal(outcomeToHttpStatus('Block', 200), 403);
    assert.equal(outcomeToHttpStatus('StepUp', 200), 409);
    assert.equal(outcomeToHttpStatus('Fail', 429), 429);
    assert.equal(outcomeToHttpStatus('Fail', 403), 401);
    assert.equal(outcomeToHttpStatus('Fail', 422), 400);
    assert.equal(outcomeToHttpStatus('Fail', 500), 502);
});

test('endpoint timeout maps to 504', async () => {
    resp = 'TIMEOUT';
    const r = await dispatchOtp(disp(), { requestProvider: 'infobip', context: ctx, requestId: 'r' });
    assert.equal(r.httpStatus, 504);
    assert.equal(r.body.outcome, 'Fail');
});

test('network error (non-timeout) maps to 502', async () => {
    resp = 'THROW';
    const r = await dispatchOtp(disp(), { requestProvider: 'infobip', context: ctx, requestId: 'r' });
    assert.equal(r.httpStatus, 502);
    assert.equal(r.body.outcome, 'Fail');
});

test('unknown provider status fails closed even on HTTP 200 (§15)', async () => {
    resp = { ok: true, status: 200, body: { messages: [{ status: { name: 'WATWATWAT' } }] } };
    const r = await dispatchOtp(disp(), { requestProvider: 'infobip', context: ctx, requestId: 'r' });
    assert.equal(r.body.outcome, 'Fail');
    assert.equal(r.body.status, 'failed');
});

// The code and phone necessarily appear in the outbound provider request — that is the delivery.
test('the code and phone never reach the logs or the response body', async () => {
    const logs = [];
    resp = { ok: true, status: 200, body: { messages: [{ status: { name: 'DELIVERED' }, messageId: 'x' }] } };
    const r = await dispatchOtp(
        { destination: '+15551234567', message: 'Your code is 918273', channel: 'sms', messageId: 'm', correlationId: 'c' },
        { requestProvider: 'infobip', context: { log: (m) => logs.push(String(m)) }, requestId: 'r' },
    );

    assert.equal(r.httpStatus, 200);
    assert.ok(sent.opts.body.includes('918273'), 'the rendered message IS sent to the provider');
    for (const line of logs) {
        assert.ok(!line.includes('918273'), `code leaked in a log line: ${line}`);
        assert.ok(!line.includes('5551234567'), `phone leaked in a log line: ${line}`);
    }
    const body = JSON.stringify(r.body);
    assert.ok(!body.includes('918273'), 'code leaked in response body');
    assert.ok(!body.includes('5551234567'), 'phone leaked in response body');
});

test('apiKey mode fails closed when the secret is missing (502)', async () => {
    const manifest = getProvider('soprano').manifest;
    const saved = JSON.parse(JSON.stringify(manifest.auth));
    manifest.auth = { mode: 'apiKey', keyVaultSecretName: '__missing_secret__' };
    try {
        const r = await dispatchOtp(disp(), { requestProvider: 'soprano', context: ctx, requestId: 'r' });
        assert.equal(r.httpStatus, 502);
        assert.equal(r.body.reason, 'provider credential unavailable');
    } finally {
        manifest.auth = saved;
    }
});

test('shutter returns 200 without sending', async () => {
    let calls = 0;
    const orig = global.fetch;
    global.fetch = async (...a) => { calls++; return orig(...a); };
    try {
        const r = await dispatchOtp(disp(), { requestProvider: 'infobip', shutter: true, context: ctx, requestId: 'r' });
        assert.equal(r.httpStatus, 200);
        assert.equal(r.body.shutterProcessed, true);
        assert.equal(calls, 0);
    } finally {
        global.fetch = orig;
    }
});

test('unknown provider is rejected (400)', async () => {
    const r = await dispatchOtp(disp(), { requestProvider: 'nope', context: ctx, requestId: 'r' });
    assert.equal(r.httpStatus, 400);
});

test('oauth2 mode uses a Bearer token and fails closed without one', async () => {
    const manifest = getProvider('sinch').manifest;
    const saved = JSON.parse(JSON.stringify(manifest.auth));
    manifest.auth.mode = 'oauth2';
    try {
        await dispatchOtp(disp(), { requestProvider: 'sinch', context: ctx, requestId: 'r', acquireProviderToken: async () => 'TKN' });
        assert.equal(sent.opts.headers.Authorization, 'Bearer TKN');

        const noToken = await dispatchOtp(disp(), { requestProvider: 'sinch', context: ctx, requestId: 'r' });
        assert.equal(noToken.httpStatus, 502); // credential unavailable → 502, not 401
    } finally {
        manifest.auth = saved;
    }
});

test('apiKey provider that needs an identity fails closed when the identity secret is missing (502)', async () => {
    const manifest = getProvider('telesign').manifest;
    const saved = JSON.parse(JSON.stringify(manifest.auth));
    manifest.auth.identityKeyVaultSecretName = '__missing_identity__';
    try {
        const r = await dispatchOtp(disp(), { requestProvider: 'telesign', context: ctx, requestId: 'r' });
        assert.equal(r.httpStatus, 502);
        assert.equal(r.body.reason, 'provider credential unavailable');
    } finally {
        manifest.auth = saved;
    }
});

