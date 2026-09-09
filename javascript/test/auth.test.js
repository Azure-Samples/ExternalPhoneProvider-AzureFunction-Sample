'use strict';

const { test, beforeEach } = require('node:test');
const assert = require('node:assert');
const crypto = require('crypto');
const Module = require('module');
const jose = require('jose');
const { validateToken } = require('../src/functions/security');

const hostile = '+15559876543|918273|PRIVATE-TOKEN-SENTINEL';
const validate = (jwt) => validateToken({ headers: { get: () => jwt ? `Bearer ${jwt}` : null } });
const { publicKey, privateKey } = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });
const issuer = 'https://login.microsoftonline.com/local-test-tenant/v2.0';

beforeEach(() => {
    delete process.env.EPP_REQUIRE_AUTH;
    delete process.env.EPP_EXPECTED_AUDIENCE;
    delete process.env.EPP_TENANT_ID;
    delete process.env.EPP_EXPECTED_CLIENT_ID;
    delete process.env.EPP_EXPECTED_ISSUER;
    delete process.env.WEBSITE_INSTANCE_ID;
    delete process.env.WEBSITE_HOSTNAME;
});

test('auth opt-out is local only; Azure fails closed', async () => {
    assert.deepEqual(await validate(), { ok: true, skipped: true });
    process.env.WEBSITE_INSTANCE_ID = 'instance';
    assert.deepEqual(await validate(), { ok: false, reason: 'EPP_REQUIRE_AUTH must be true in Azure' });
});

test('required auth rejects missing configuration, missing bearer and malformed tokens', async (t) => {
    process.env.EPP_REQUIRE_AUTH = 'true';
    assert.deepEqual(await validate(), {
        ok: false, reason: 'EPP_REQUIRE_AUTH is set but EPP_EXPECTED_AUDIENCE / EPP_TENANT_ID are missing',
    });
    configureLocalJwt(t);
    assert.deepEqual(await validate(), { ok: false, reason: 'missing bearer token' });
    assert.deepEqual(await validate(hostile), { ok: false, reason: 'token validation failed' });
});

// Replace only remote key discovery; jose still verifies the real signature and claims.
function configureLocalJwt(t) {
    process.env.EPP_REQUIRE_AUTH = 'true';
    process.env.EPP_EXPECTED_AUDIENCE = 'local-audience';
    process.env.EPP_TENANT_ID = 'local-test-tenant';
    process.env.EPP_EXPECTED_CLIENT_ID = 'expected-app';
    const originalLoad = Module._load;
    t.mock.method(Module, '_load', function (name, ...args) {
        return name === 'jose' ? { ...jose, createRemoteJWKSet: () => publicKey }
            : originalLoad.call(this, name, ...args);
    });
}

function sign(claims = {}, alg = 'RS256', key = privateKey) {
    return new jose.SignJWT({ azp: 'expected-app', ...claims })
        .setProtectedHeader({ alg, kid: hostile })
        .setIssuer(claims.iss || issuer).setAudience(claims.aud || 'local-audience')
        .setExpirationTime(claims.exp ?? '5m').sign(key);
}

test('valid signed v1/v2 tokens pass with a local JWKS key', async (t) => {
    configureLocalJwt(t);
    assert.deepEqual(await validate(await sign()), { ok: true });
    const v1 = await sign({ azp: undefined, appid: 'expected-app', iss: 'https://sts.windows.net/local-test-tenant/' });
    assert.deepEqual(await validate(v1), { ok: true });
});

test('signed tokens enforce issuer, audience, expiry, not-before and an explicit issuer pin', async (t) => {
    configureLocalJwt(t);
    for (const claims of [{ aud: hostile }, { iss: hostile }, { exp: 1 }, { nbf: Math.floor(Date.now() / 1000) + 3600 }]) {
        assert.deepEqual(await validate(await sign(claims)), { ok: false, reason: 'token validation failed' });
    }
    process.env.EPP_EXPECTED_ISSUER = 'https://sts.windows.net/local-test-tenant/';
    assert.deepEqual(await validate(await sign()), { ok: false, reason: 'token validation failed' });
});

test('real JWT verification rejects the wrong signing key and non-RS256 algorithms', async (t) => {
    configureLocalJwt(t);
    const wrongKey = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 }).privateKey;
    assert.deepEqual(await validate(await sign({}, 'RS256', wrongKey)), { ok: false, reason: 'token validation failed' });
    const hmac = await sign({}, 'HS256', Buffer.from('local-test-key-for-HS256-rejection'));
    assert.deepEqual(await validate(hmac), { ok: false, reason: 'token validation failed' });
});

test('signed callers must match the pin; an unpinned caller is allowed', async (t) => {
    configureLocalJwt(t);
    const unexpected = await sign({ azp: hostile });
    assert.deepEqual(await validate(unexpected), { ok: false, reason: 'unexpected caller' });
    assert.deepEqual(await validate(await sign({ azp: undefined })), { ok: false, reason: 'unexpected caller' });
    delete process.env.EPP_EXPECTED_CLIENT_ID;
    assert.deepEqual(await validate(unexpected), { ok: true });
});
