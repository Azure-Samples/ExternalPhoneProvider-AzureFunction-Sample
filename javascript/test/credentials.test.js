'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { inspect } = require('node:util');
const { ClientAssertionCredential, ManagedIdentityCredential } = require('@azure/identity');
const { SecretClient } = require('@azure/keyvault-secrets');
const { CredentialTokenService } = require('../src/functions/credentials');
const { readConfig } = require('../src/functions/config');

const flush = () => new Promise(setImmediate);
const auth = { mode: 'apiKey', keyVaultSecretName: 'key', identityKeyVaultSecretName: 'id' };
const config = readConfig({ KEY_VAULT_URL: 'https://unit.vault.azure.net' });
const oauth = readConfig({
    EPP_PROVIDER_TENANT_ID: 'tenant', EPP_OUTBOUND_CLIENT_ID: 'app',
    EPP_OUTBOUND_MI_CLIENT_ID: 'identity', EPP_PROVIDER_SCOPE: 'scope',
});
const now = 1700000000000;
const token = (value) => ({ token: value, expiresOnTimestamp: now + 3600000 });

test('API keys are read on each request with no warmup, polling, stale fallback, or failure cooldown', async (t) => {
    t.mock.method(global, 'setInterval', () => assert.fail('Credentials must not poll'));
    let version = 1;
    let fail = false;
    const vault = t.mock.method(SecretClient.prototype, 'getSecret', async (name) => {
        if (fail && name === 'id') throw new Error('PRIVATE-FAILURE');
        return { value: `${name}-${version}` };
    });
    t.mock.method(ClientAssertionCredential.prototype, 'getToken', () => assert.fail('Unexpected OAuth'));
    const manager = new CredentialTokenService();
    try {
        assert.equal(vault.mock.callCount(), 0);
        assert.equal((await manager.getCredentials(auth, config)).secret, 'key-1');
        version = 2;
        assert.deepEqual(await manager.getCredentials(auth, config), { mode: 'apiKey', secret: 'key-2', identity: 'id-2' });
        fail = true;
        await assert.rejects(manager.getCredentials(auth, config), /^Error: provider credential unavailable$/);
        fail = false;
        version = 3;
        assert.equal((await manager.getCredentials(auth, config)).identity, 'id-3');
        assert.equal(vault.mock.callCount(), 8);
        assert.ok(vault.mock.calls.every((call) => call.this === vault.mock.calls[0].this));
        assert.equal(manager.controllers.size, 0);
        assert.doesNotMatch(inspect(manager) + JSON.stringify(manager), /key-3|id-3/);
        await flush();
        assert.equal(vault.mock.callCount(), 8);
    } finally { manager.close(); }
});

test('concurrent secret requests are independent and shutdown aborts all waiters', async (t) => {
    let release;
    const gate = new Promise((resolve) => { release = resolve; });
    const vault = t.mock.method(SecretClient.prototype, 'getSecret', async () => {
        await gate;
        return { value: 'PRIVATE-LATE-KEY' };
    });
    const manager = new CredentialTokenService();
    try {
        const requests = Array.from({ length: 3 }, () => manager.getCredentials(auth, config));
        const rejected = requests.map((request) => assert.rejects(request, /unavailable/));
        await flush();
        assert.equal(vault.mock.callCount(), 6);
        manager.close();
        await Promise.all(rejected);
        release();
        await flush();
        assert.equal(manager.controllers.size, 0);
        await assert.rejects(manager.getCredentials(auth, config), /unavailable/);
    } finally { release(); manager.close(); }
});

test('empty, disabled, future, or expired secrets fail instead of returning old credentials', async (t) => {
    const vault = t.mock.method(SecretClient.prototype, 'getSecret', async () => ({ value: 'valid' }));
    for (const invalid of [
        { value: '' },
        { value: 'bad', properties: { enabled: false } },
        { value: 'bad', properties: { notBefore: new Date(now + 3600000) } },
        { value: 'bad', properties: { expiresOn: new Date(now) } },
        { value: 'bad', properties: { expiresOn: new Date('invalid') } },
    ]) {
        const manager = new CredentialTokenService({ now: () => now });
        try {
            vault.mock.mockImplementation(async () => ({ value: 'valid' }));
            await manager.getCredentials(auth, config);
            vault.mock.mockImplementation(async () => invalid);
            await assert.rejects(manager.getCredentials(auth, config), /unavailable/);
        } finally { manager.close(); }
    }
});

test('every OAuth request calls the same SDK client and only the SDK requests assertions', async (t) => {
    t.mock.method(global, 'setInterval', () => assert.fail('Credentials must not poll'));
    t.mock.method(SecretClient.prototype, 'getSecret', () => assert.fail('OAuth must not read Key Vault'));
    const identity = t.mock.method(ManagedIdentityCredential.prototype, 'getToken', async () => token('PRIVATE-ASSERTION'));
    let calls = 0;
    const provider = t.mock.method(ClientAssertionCredential.prototype, 'getToken', async function (scope) {
        assert.equal(scope, 'scope');
        if (++calls === 1) assert.equal(await this.getAssertion(), 'PRIVATE-ASSERTION');
        return token(`PRIVATE-TOKEN-${calls}`);
    });
    const manager = new CredentialTokenService({ now: () => now });
    try {
        assert.equal(identity.mock.callCount(), 0);
        assert.equal(provider.mock.callCount(), 0);
        assert.equal((await manager.getCredentials({ mode: 'oauth' }, oauth)).accessToken, 'PRIVATE-TOKEN-1');
        const second = await manager.getCredentials({ mode: 'oauth' }, oauth);
        assert.equal(second.accessToken, 'PRIVATE-TOKEN-2');
        assert.equal(provider.mock.callCount(), 2);
        assert.equal(provider.mock.calls[0].this, provider.mock.calls[1].this);
        assert.equal(identity.mock.callCount(), 1);
        assert.equal(JSON.stringify(second), '{"mode":"oauth"}');
        assert.doesNotMatch(inspect(manager) + JSON.stringify(manager), /PRIVATE/);
    } finally { manager.close(); }
});

test('OAuth errors are sanitized and the next request retries with the same SDK client', async (t) => {
    let fail = true;
    const provider = t.mock.method(ClientAssertionCredential.prototype, 'getToken', async () => {
        if (fail) throw new Error('PRIVATE-SDK-FAILURE');
        return token('PRIVATE-TOKEN');
    });
    const manager = new CredentialTokenService({ now: () => now });
    try {
        await assert.rejects(manager.getCredentials({ mode: 'oauth' }, oauth), /^Error: provider credential unavailable$/);
        fail = false;
        assert.equal((await manager.getCredentials({ mode: 'oauth' }, oauth)).accessToken, 'PRIVATE-TOKEN');
        assert.equal(provider.mock.callCount(), 2);
        assert.equal(provider.mock.calls[0].this, provider.mock.calls[1].this);
    } finally { manager.close(); }
});

test('invalid assertions and access tokens are rejected before use', async (t) => {
    const identity = t.mock.method(ManagedIdentityCredential.prototype, 'getToken', async () => token('assertion'));
    const provider = t.mock.method(ClientAssertionCredential.prototype, 'getToken', async function () {
        await this.getAssertion();
        return token('provider');
    });
    for (const invalid of [null, token(' '), { token: 'expired', expiresOnTimestamp: now },
        { token: 'expiring', expiresOnTimestamp: now + 30000 }, { token: 'bad', expiresOnTimestamp: NaN }]) {
        for (const invalidAssertion of [true, false]) {
            identity.mock.mockImplementation(async () => invalidAssertion ? invalid : token('assertion'));
            provider.mock.mockImplementation(async function () {
                await this.getAssertion();
                return invalidAssertion ? token('provider') : invalid;
            });
            const manager = new CredentialTokenService({ now: () => now });
            try {
                await assert.rejects(manager.getCredentials({ mode: 'oauth' }, oauth), /unavailable/);
            } finally { manager.close(); }
        }
    }
});

test('invalid configuration performs no SDK calls and does not poison later requests', async (t) => {
    const vault = t.mock.method(SecretClient.prototype, 'getSecret', async () => ({ value: 'key' }));
    const provider = t.mock.method(ClientAssertionCredential.prototype, 'getToken', async () => token('provider'));
    const manager = new CredentialTokenService({ now: () => now });
    try {
        for (const [spec, settings] of [
            [{ mode: 'unknown' }, config],
            [{ mode: 'apiKey' }, config],
            [auth, readConfig({})],
            [{ mode: 'oauth' }, readConfig({})],
        ]) await assert.rejects(manager.getCredentials(spec, settings), /unavailable/);
        assert.equal(vault.mock.callCount(), 0);
        assert.equal(provider.mock.callCount(), 0);
        assert.equal((await manager.getCredentials({ mode: 'oauth' }, oauth)).accessToken, 'provider');
    } finally { manager.close(); }
});
