'use strict';

const { test, beforeEach, mock } = require('node:test');
const assert = require('node:assert');
const phone = '+15559876543';
const code = '918273';
const token = 'PRIVATE-TOKEN-SENTINEL';
const hostile = `${phone}|${code}|${token}`;

process.env.KEY_VAULT_URL = 'https://test.vault.azure.net';
process.env.SINCH_SERVICE_PLAN_ID = 'sp';
process.env.EPP_PROVIDER_ENDPOINT = 'https://api.infobip.com';

const providerSecrets = {
    'infobip-api-key': token,
    'telesign-api-key': 'ts',
    'telesign-customer-id': 'cust',
    'sinch-api-token': 'st',
    'soprano-api-key': 'sp',
    'soprano-api-id': 'sp-id',
};
const { SecretClient } = require('@azure/keyvault-secrets');
mock.method(SecretClient.prototype, 'getSecret', async (name) => ({ value: providerSecrets[name] }));
const { ClientSecretCredential } = require('@azure/identity');

const {
    dispatchOtp,
    getProvider,
    normalizeProviderTimeoutMilliseconds,
    outcomeToHttpStatus,
    resolveOutcome,
} = require('../src/functions/dispatch');

let resp;
let sent;
global.fetch = async (url, opts) => {
    sent = { url, opts };
    return { ok: resp.ok, status: resp.status, text: async () => JSON.stringify(resp.body) };
};

const ctx = { log: (...args) => {
    const text = JSON.stringify(args);
    for (const secret of [phone, code, token]) assert.ok(!text.includes(secret), 'engine log leaked a sensitive value');
} };
const send = (provider = 'infobip', channel = 'sms') => dispatchOtp({
    destination: phone, message: `Your code is ${code}`, channel, messageId: 'm', correlationId: 'c',
}, { requestProvider: provider, context: ctx, requestId: 'r' });

beforeEach(() => {
    sent = undefined;
    process.env.EPP_PROVIDER_ENDPOINT = 'https://api.infobip.com';
    delete process.env.EPP_PROVIDER_AUTH_MODE;
    delete process.env.EPP_PROVIDER_MI_CLIENT_ID;
    delete process.env.EPP_PROVIDER_TIMEOUT_MS;
    delete process.env.SINCH_VOICE_ENDPOINT;
    resp = { ok: true, status: 200, body: { messages: [{ status: { name: 'DELIVERED' } }] } };
});

test('Infobip SMS sends JSON with App API-key auth', async () => {
    assert.equal((await send()).httpStatus, 200);
    assert.equal(sent.opts.headers.Authorization, `App ${token}`);
    assert.ok(sent.url.endsWith('/sms/3/messages'));
    assert.equal(JSON.parse(sent.opts.body).messages[0].content.text, `Your code is ${code}`);
});

test('Telesign voice sends a form with Basic customer/key auth', async () => {
    resp.body = { status: { code: 100 } };
    assert.equal((await send('telesign', 'voice')).httpStatus, 200);
    assert.equal(sent.opts.headers.Authorization, `Basic ${Buffer.from('cust:ts').toString('base64')}`);
    assert.ok(sent.url.endsWith('/v1/voice'));
    const form = new URLSearchParams(sent.opts.body);
    assert.equal(form.get('phone_number'), phone);
    assert.equal(form.get('message'), `Your code is ${code}`);
});

test('Sinch SMS uses its API token as Bearer auth', async () => {
    resp.body = { id: 'batch-1' };
    assert.equal((await send('sinch')).httpStatus, 200);
    assert.equal(sent.opts.headers.Authorization, 'Bearer st');
    assert.ok(sent.url.endsWith('/xms/v1/sp/batches'));
    assert.equal(JSON.parse(sent.opts.body).body, `Your code is ${code}`);
});

test('Soprano omnimsg sends SMS and voice with API ID/key headers', async () => {
    resp.body = { status: 'DELIVERED' };
    for (const channel of ['sms', 'voice']) {
        assert.equal((await send('soprano', channel)).httpStatus, 200);
        assert.ok(sent.url.endsWith('/messages/omnimsg'));
        assert.equal(sent.opts.headers['X-MEMS-API-ID'], 'sp-id');
        assert.equal(sent.opts.headers['X-MEMS-API-Key'], 'sp');
        assert.equal(sent.opts.headers.Authorization, undefined);
        const body = JSON.parse(sent.opts.body);
        assert.deepEqual(body.messageTypes, [channel]);
        assert.equal(body.destination, phone.slice(1));
        assert.equal(body.text, `Your code is ${code}`);
    }
});

test('a failed HTTP response cannot be accepted despite a success-looking body', async () => {
    resp.ok = false;
    resp.status = 429;
    const r = await send();
    assert.equal(r.httpStatus, 429);
    assert.equal(r.body.outcome, 'Fail');
});

test('unknown statuses fail closed; outcome and HTTP categories stay distinct', () => {
    const infobip = getProvider('infobip').manifest;
    const soprano = getProvider('soprano').manifest;
    for (const status of ['UNKNOWN', 'constructor', '__proto__']) {
        assert.equal(resolveOutcome(infobip, { success: true, providerStatusName: status }), 'Fail', status);
    }
    assert.equal(resolveOutcome({ responseMapping: { RISK: 'StepUp' } }, { success: false, providerStatusName: 'RISK' }), 'StepUp');
    assert.equal(resolveOutcome(soprano, { success: false, providerStatusName: 'BLOCKED' }), 'Block');
    assert.equal(outcomeToHttpStatus('Block', 200), 403);
    assert.equal(outcomeToHttpStatus('StepUp', 200), 409);
    for (const [status, expected] of [[401, 401], [403, 401], [422, 400], [429, 429], [500, 502]]) {
        assert.equal(outcomeToHttpStatus('Fail', status), expected, String(status));
    }
});

test('missing base endpoint and insecure alternate voice endpoint fail before sending', async () => {
    delete process.env.EPP_PROVIDER_ENDPOINT;
    const missing = await send();
    assert.equal(missing.httpStatus, 502);
    assert.equal(missing.body.reason, 'provider endpoint must be an absolute HTTPS URL');
    assert.equal(sent, undefined);
    process.env.EPP_PROVIDER_ENDPOINT = 'https://api.sinch.com';
    process.env.SINCH_VOICE_ENDPOINT = 'http://localhost:8080';
    const insecure = await send('sinch', 'voice');
    assert.equal(insecure.httpStatus, 502);
    assert.equal(insecure.body.reason, 'provider request URL must be absolute HTTPS');
    assert.equal(sent, undefined);
});

test('the bounded timeout really aborts a pending response body, without retrying', { timeout: 5000 }, async (t) => {
    assert.equal(normalizeProviderTimeoutMilliseconds('invalid'), 1500);
    assert.equal(normalizeProviderTimeoutMilliseconds('2000'), 2000);
    assert.equal(normalizeProviderTimeoutMilliseconds('999999'), 2500);
    process.env.EPP_PROVIDER_TIMEOUT_MS = '10';
    let signal;
    const fetch = t.mock.method(global, 'fetch', async (url, opts) => {
        signal = opts.signal;
        return { ok: true, status: 200, text: () => new Promise((resolve, reject) => {
            signal.addEventListener('abort', () => reject(new Error(hostile)), { once: true });
        }) };
    });
    const r = await send();
    assert.equal(r.httpStatus, 504);
    assert.equal(r.body.outcome, 'Fail');
    assert.equal(r.body.reason, 'provider timeout');
    assert.equal(signal.aborted, true);
    assert.equal(fetch.mock.callCount(), 1);
});

test('API-key auth requires both the secret and any provider identity', async (t) => {
    const manifest = getProvider('telesign').manifest;
    const auth = manifest.auth;
    t.after(() => { manifest.auth = auth; });
    for (const missing of [{ keyVaultSecretName: '__missing_key__' }, { identityKeyVaultSecretName: '__missing_id__' }]) {
        manifest.auth = { ...auth, ...missing };
        const r = await send('telesign');
        assert.equal(r.httpStatus, 502);
        assert.equal(r.body.reason, 'provider credential unavailable');
        assert.equal(sent, undefined);
    }
});

test('unknown provider and channel fail generically without sending', async () => {
    const r = await send(hostile);
    assert.equal(r.httpStatus, 400);
    assert.equal(r.body.reason, 'unknown provider');
    const badChannel = await send('infobip', hostile);
    assert.equal(badChannel.httpStatus, 400);
    assert.equal(badChannel.body.reason, 'unsupported channel');
    assert.equal(sent, undefined);
});

test('OAuth override replaces API-key headers with a minted Bearer and requires a token', async (t) => {
    process.env.EPP_PROVIDER_AUTH_MODE = 'oauth2';
    process.env.EPP_PROVIDER_TENANT_ID = 'tenant-a';
    process.env.EPP_PROVIDER_CLIENT_ID = 'client-a';
    process.env.EPP_PROVIDER_SCOPE = 'api://provider-a/.default';
    process.env.EPP_PROVIDER_CLIENT_SECRET = 'secret';
    t.after(() => {
        delete process.env.EPP_PROVIDER_AUTH_MODE;
        delete process.env.EPP_PROVIDER_TENANT_ID;
        delete process.env.EPP_PROVIDER_CLIENT_ID;
        delete process.env.EPP_PROVIDER_SCOPE;
        delete process.env.EPP_PROVIDER_CLIENT_SECRET;
    });
    let accessToken = { token, expiresOnTimestamp: Date.now() + 60000 };
    t.mock.method(ClientSecretCredential.prototype, 'getToken', async () => accessToken);
    resp.body = { status: 'DELIVERED' };
    assert.equal((await send('soprano')).httpStatus, 200);
    assert.equal(sent.opts.headers.Authorization, `Bearer ${token}`);
    assert.equal(sent.opts.headers['X-MEMS-API-Key'], undefined);
    assert.equal(sent.opts.headers['X-MEMS-API-ID'], undefined);
    accessToken = null;
    sent = undefined;
    const noToken = await send('soprano');
    assert.equal(noToken.httpStatus, 502);
    assert.equal(noToken.body.reason, 'provider credential unavailable');
    assert.equal(sent, undefined);
});

test('credential SDK exceptions never reach logs or failure reasons', async (t) => {
    const manifest = getProvider('infobip').manifest;
    const auth = manifest.auth;
    t.after(() => { manifest.auth = auth; });
    manifest.auth = { mode: 'apiKey', keyVaultSecretName: '__sdk_exception__' };
    t.mock.method(SecretClient.prototype, 'getSecret', async () => {
        throw new Error(hostile, { cause: new Error(hostile) });
    });
    const r = await send();
    assert.equal(r.httpStatus, 502);
    assert.equal(r.body.reason, 'provider credential unavailable');
    assert.equal(sent, undefined);
});

test('network errors map to 502 without leaking or impersonating timeouts', async (t) => {
    t.mock.method(global, 'fetch', async () => { throw new Error(`endpoint timeout ${hostile}`); });
    const r = await send();
    assert.equal(r.httpStatus, 502);
    assert.equal(r.body.outcome, 'Fail');
    assert.equal(r.body.reason, 'provider request failed');
    for (const secret of [phone, code, token]) assert.ok(!JSON.stringify(r.body).includes(secret));
});

