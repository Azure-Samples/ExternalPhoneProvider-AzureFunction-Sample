'use strict';

const { test, beforeEach, afterEach, mock } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const Module = require('node:module');
const jose = require('jose');
const { validateToken } = require('../src/functions/security');
const { readConfig } = require('../src/functions/config');

// Generate one key pair; replace network discovery, not signature verification.
const { privateKey, publicKey } = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });
const jwk = { ...publicKey.export({ format: 'jwk' }), kid: 'local-key', alg: 'RS256', use: 'sig' };
const localKeys = jose.createLocalJWKSet({ keys: [jwk] });
const originalLoad = Module._load;
const audience = '11111111-2222-4333-8444-555555555555';
const envKeys = ['EPP_REQUIRE_AUTH', 'EPP_EXPECTED_AUDIENCE', 'EPP_TENANT_ID', 'EPP_EXPECTED_CLIENT_ID',
    'EPP_EXPECTED_ISSUER', 'WEBSITE_INSTANCE_ID', 'WEBSITE_HOSTNAME', 'WEBSITE_SITE_NAME'];
let savedEnv;
let discoveryUrls;
beforeEach(() => {
    discoveryUrls = [];
    savedEnv = Object.fromEntries(envKeys.map((key) => [key, process.env[key]]));
    for (const key of envKeys) delete process.env[key];
    Object.assign(process.env, { EPP_REQUIRE_AUTH: 'true', EPP_EXPECTED_AUDIENCE: audience,
        EPP_TENANT_ID: 'tenant', EPP_EXPECTED_CLIENT_ID: 'caller' });
    mock.method(Module, '_load', function (name, ...args) {
        if (name === 'jose') return { ...jose, createRemoteJWKSet: (url) => {
            discoveryUrls.push(url.href);
            return localKeys;
        } };
        return originalLoad.call(this, name, ...args);
    });
});
afterEach(() => {
    mock.restoreAll();
    for (const [key, value] of Object.entries(savedEnv)) {
        if (value === undefined) delete process.env[key];
        else process.env[key] = value;
    }
});

const claims = () => ({ iss: 'https://login.microsoftonline.com/tenant/v2.0', aud: audience,
    azp: 'caller', exp: Math.floor(Date.now() / 1000) + 300 });
const sign = (payload) => new jose.SignJWT(payload)
    .setProtectedHeader({ alg: 'RS256', kid: 'local-key' }).sign(privateKey);
const verify = (token, config, body = {}) => validateToken({
    headers: { get: () => token ? `Bearer ${token}` : null },
    text: async () => JSON.stringify(body),
}, config);

test('local opt-out is allowed, but Azure requires auth and a pinned caller', async () => {
    process.env.EPP_REQUIRE_AUTH = 'false';
    assert.deepEqual(await verify(), { ok: true, skipped: true });
    for (const metadata of ['WEBSITE_INSTANCE_ID', 'WEBSITE_HOSTNAME', 'WEBSITE_SITE_NAME']) {
        const env = { [metadata]: 'azure-test', EPP_REQUIRE_AUTH: 'false' };
        assert.equal((await verify(undefined, readConfig(env))).reason, 'EPP_REQUIRE_AUTH must be true on Azure');
        env.EPP_REQUIRE_AUTH = 'true';
        env.EPP_EXPECTED_CLIENT_ID = ' ';
        assert.equal((await verify(undefined, readConfig(env))).reason, 'EPP_EXPECTED_CLIENT_ID is required on Azure');
    }
});

test('real RSA verification enforces signature, expiry, issuer, audience, caller and algorithm', async () => {
    const config = readConfig({ ...process.env, EPP_TENANT_ID: 'configured-tenant' });
    const body = { tenantId: 'incoming-tenant' };
    const payload = { ...claims(), iss: 'https://login.microsoftonline.com/configured-tenant/v2.0',
        tid: 'configured-tenant' };
    const valid = await sign(payload);
    assert.deepEqual(await verify(valid, config, body), { ok: true });
    const parts = valid.split('.');
    const signature = Buffer.from(parts[2], 'base64url');
    signature[0] ^= 1;
    parts[2] = signature.toString('base64url');
    const wrongAlgorithm = await new jose.SignJWT(payload).setProtectedHeader({ alg: 'HS256' }).sign(crypto.randomBytes(32));
    for (const [label, token] of [
        ['signature', parts.join('.')],
        ['expired', await sign({ ...payload, exp: 0 })],
        ['missing expiry', await sign({ ...payload, exp: undefined })],
        ['incoming tenant cannot select issuer', await sign({ ...payload,
            iss: `https://login.microsoftonline.com/${body.tenantId}/v2.0`, tid: body.tenantId })],
        ['audience', await sign({ ...payload, aud: 'other' })],
        ['caller precedence', await sign({ ...payload, azp: 'other', appid: 'caller' })],
        ['algorithm', wrongAlgorithm],
    ]) {
        assert.equal((await verify(token, config, body)).ok, false, label);
    }
    assert.equal(config.tenantId, 'configured-tenant');
    assert.deepEqual(discoveryUrls, ['https://login.microsoftonline.com/configured-tenant/discovery/v2.0/keys']);
});

test('v1 issuer/appid is accepted unless the issuer is explicitly pinned to v2', async () => {
    const token = await sign({ ...claims(), iss: 'https://sts.windows.net/tenant/', azp: undefined, appid: 'caller' });
    assert.equal((await verify(token)).ok, true);
    const config = readConfig({ EPP_REQUIRE_AUTH: ' true ', EPP_EXPECTED_AUDIENCE: ` ${audience} `,
        EPP_TENANT_ID: ' tenant ', EPP_EXPECTED_CLIENT_ID: ' CALLER ', EPP_EXPECTED_ISSUER: ` ${claims().iss} ` });
    assert.equal((await verify(token, config)).ok, false);
    assert.equal((await verify(await sign(claims()), config)).ok, true);
    assert.equal((await verify(token)).ok, true);
});
