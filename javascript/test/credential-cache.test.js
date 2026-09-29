'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { inspect } = require('node:util');
const { ApiKeyCache, AccessTokenCache, ProviderCredentials, isCacheEnabled } = require('../src/functions/credentials');
const { ClientAssertionCredential, ManagedIdentityCredential } = require('@azure/identity');
const { SecretClient } = require('@azure/keyvault-secrets');
const { readConfig } = require('../src/functions/config');

const flush = () => new Promise(setImmediate);
const auth = { mode: 'apiKey', keyVaultSecretName: 'key', identityKeyVaultSecretName: 'id' };
const config = readConfig({ KEY_VAULT_URL: 'https://unit.vault.azure.net', EPP_KEY_VAULT_CACHE_ENABLED: 'true',
    EPP_ACCESS_TOKEN_CACHE_ENABLED: 'false' });
const oauth = readConfig({
    EPP_PROVIDER_TENANT_ID: 'tenant', EPP_OUTBOUND_CLIENT_ID: 'app',
    EPP_OUTBOUND_MI_CLIENT_ID: 'identity', EPP_PROVIDER_SCOPE: 'scope',
    EPP_ACCESS_TOKEN_CACHE_ENABLED: 'true', EPP_KEY_VAULT_CACHE_ENABLED: 'false',
});
function clock() {
    let time = 1700000000000;
    const timers = new Set();
    return {
        options: {
            now: () => time,
            schedule: (callback, delay) => {
                const timer = { at: time + delay, period: delay, callback, unref() {} };
                timers.add(timer);
                return timer;
            },
            cancel: (timer) => timers.delete(timer),
        },
        get now() { return time; },
        get timerCount() { return timers.size; },
        async advance(ms) {
            time += ms;
            for (const timer of [...timers]) {
                if (timer.at <= time && timers.has(timer)) {
                    timer.at = time + timer.period;
                    timer.callback();
                }
            }
            await flush();
        },
    };
}

test('cache switches default to enabled and accept only trimmed true or false independently', () => {
    for (const [value, expected] of [[undefined, true], ['true', true], [' TRUE ', true], ['false', false], [' FaLsE ', false]]) {
        const settings = readConfig({ EPP_KEY_VAULT_CACHE_ENABLED: value, EPP_ACCESS_TOKEN_CACHE_ENABLED: value });
        assert.equal(isCacheEnabled(auth, settings), expected);
        assert.equal(isCacheEnabled({ mode: 'oauth' }, settings), expected);
    }
    const mixed = readConfig({ EPP_KEY_VAULT_CACHE_ENABLED: 'false', EPP_ACCESS_TOKEN_CACHE_ENABLED: 'true' });
    assert.equal(isCacheEnabled(auth, mixed), false);
    assert.equal(isCacheEnabled({ mode: 'oauth' }, mixed), true);
});

test('invalid cache switches fail before I/O or scheduling rather than silently enabling a cache', async (t) => {
    const time = clock();
    const vault = t.mock.method(SecretClient.prototype, 'getSecret', () => assert.fail('Unexpected Key Vault'));
    const token = t.mock.method(ClientAssertionCredential.prototype, 'getToken', () => assert.fail('Unexpected OAuth'));
    for (const mode of ['apiKey', 'oauth']) {
        for (const value of ['', '1', '0', 'yes', 'PRIVATE-INVALID']) {
            const failures = [];
            const manager = new ProviderCredentials({ cacheOptions: time.options, reportFailure: (kind) => failures.push(kind) });
            const settings = readConfig({ ...oauth.env, ...config.env,
                EPP_KEY_VAULT_CACHE_ENABLED: value, EPP_ACCESS_TOKEN_CACHE_ENABLED: value });
            try {
                await assert.rejects(manager.resolve({ ...auth, mode }, settings), /^Error: provider credential unavailable$/);
                assert.deepEqual(failures, ['configuration']);
                assert.equal(manager.current, null);
                assert.equal(time.timerCount, 0);
            } finally { manager.close(); }
        }
    }
    assert.equal(vault.mock.callCount(), 0);
    assert.equal(token.mock.callCount(), 0);
});

test('disabled Key Vault cache fetches each complete bundle without shared state, polling, or failure cooldown', async (t) => {
    const time = clock();
    let version = 1;
    let fail = false;
    const vault = t.mock.method(SecretClient.prototype, 'getSecret', async (name) => {
        if (fail && name === 'id') throw new Error('PRIVATE-FAILURE');
        return { value: `${name}-${version}` };
    });
    const settings = readConfig({ ...config.env, EPP_KEY_VAULT_CACHE_ENABLED: 'false',
        EPP_ACCESS_TOKEN_CACHE_ENABLED: 'PRIVATE-UNUSED' });
    const failures = [];
    const manager = new ProviderCredentials({ cacheOptions: time.options, reportFailure: (kind) => failures.push(kind) });
    try {
        assert.equal((await manager.resolve(auth, settings)).secret, 'key-1');
        version = 2;
        const pair = await manager.resolve(auth, settings);
        assert.deepEqual(pair, { mode: 'apiKey', secret: 'key-2', identity: 'id-2' });
        fail = true;
        await assert.rejects(manager.resolve(auth, settings), /unavailable/);
        fail = false;
        version = 3;
        assert.equal((await manager.resolve(auth, settings)).identity, 'id-3');
        assert.equal(vault.mock.callCount(), 8);
        assert.deepEqual(failures, ['key_vault']);
        assert.equal(manager.current, null);
        assert.equal(manager.pending, null);
        assert.equal(manager.controllers.size, 0);
        assert.equal(time.timerCount, 0);
        await time.advance(300000);
        assert.equal(vault.mock.callCount(), 8);
    } finally { manager.close(); }
});

test('disabled access-token cache creates fresh SDK credentials per request without Key Vault or polling', async (t) => {
    const time = clock();
    t.mock.method(ManagedIdentityCredential.prototype, 'getToken', async () => ({
        token: 'assertion', expiresOnTimestamp: time.now + 3600000,
    }));
    let generation = 0;
    const token = t.mock.method(ClientAssertionCredential.prototype, 'getToken', async function () {
        await this.getAssertion();
        return { token: `PRIVATE-TOKEN-${++generation}`, expiresOnTimestamp: time.now + 3600000 };
    });
    const vault = t.mock.method(SecretClient.prototype, 'getSecret', () => assert.fail('Unexpected Key Vault'));
    const settings = readConfig({ ...oauth.env, EPP_ACCESS_TOKEN_CACHE_ENABLED: 'false',
        EPP_KEY_VAULT_CACHE_ENABLED: 'PRIVATE-UNUSED' });
    const manager = new ProviderCredentials({ cacheOptions: time.options });
    try {
        assert.equal((await manager.resolve({ mode: 'oauth' }, settings)).accessToken, 'PRIVATE-TOKEN-1');
        const next = await manager.resolve({ mode: 'oauth' }, settings);
        assert.equal(next.accessToken, 'PRIVATE-TOKEN-2');
        assert.equal(JSON.stringify(next), '{"mode":"oauth"}');
        assert.notEqual(token.mock.calls[0].this, token.mock.calls[1].this);
        assert.equal(manager.current, null);
        assert.equal(time.timerCount, 0);
        await time.advance(30000);
        assert.equal(token.mock.callCount(), 2);
        assert.equal(vault.mock.callCount(), 0);
    } finally { manager.close(); }
});

test('disabled caches isolate concurrent requests and shutdown cancels every outstanding acquisition', async (t) => {
    const time = clock();
    let release;
    const gate = new Promise((resolve) => { release = resolve; });
    const vault = t.mock.method(SecretClient.prototype, 'getSecret', async () => {
        await gate;
        return { value: 'PRIVATE-LATE-KEY' };
    });
    const settings = readConfig({ ...config.env, EPP_KEY_VAULT_CACHE_ENABLED: 'false' });
    const manager = new ProviderCredentials({ cacheOptions: time.options });
    try {
        const requests = Array.from({ length: 5 }, () => manager.resolve(auth, settings));
        const rejected = requests.map((request) => assert.rejects(request, /unavailable/));
        await flush();
        assert.equal(vault.mock.callCount(), 10);
        assert.equal(manager.controllers.size, 5);
        assert.equal(time.timerCount, 0);
        manager.close();
        await Promise.all(rejected);
        release();
        await flush();
        assert.equal(manager.current, null);
        assert.equal(manager.controllers.size, 0);
        await assert.rejects(manager.resolve(auth, settings), /unavailable/);
    } finally { release(); manager.close(); }
});

test('library-backed bundle shares concurrent reads, serves during refresh, and publishes pairs atomically', async (t) => {
    const time = clock();
    let release;
    let gate = new Promise((resolve) => { release = resolve; });
    let version = 1;
    const getSecret = t.mock.method(SecretClient.prototype, 'getSecret', async (name) => {
        await gate;
        return { value: `${name}-${version}` };
    });
    const manager = new ProviderCredentials({ cacheOptions: time.options });
    try {
        const pending = Array.from({ length: 20 }, () => manager.resolve(auth, config));
        await flush();
        assert.equal(getSecret.mock.callCount(), 2);
        release();
        assert.ok((await Promise.all(pending)).every((value) => value.secret === 'key-1' && value.identity === 'id-1'));
        assert.ok(manager.current instanceof ApiKeyCache);
        assert.equal(time.timerCount, 1);
        assert.doesNotMatch(inspect(manager) + JSON.stringify(manager), /key-1|id-1/);
        gate = new Promise((resolve) => { release = resolve; });
        version = 2;
        await time.advance(240000);
        assert.deepEqual(await manager.resolve(auth, config), { mode: 'apiKey', secret: 'key-1', identity: 'id-1' });
        release();
        await flush();
        assert.deepEqual(await manager.resolve(auth, config), { mode: 'apiKey', secret: 'key-2', identity: 'id-2' });
        assert.equal(getSecret.mock.callCount(), 4);
    } finally { release(); manager.close(); }
    assert.equal(time.timerCount, 0);
});

test('partial refresh failure retains the old pair only until hard expiry, with fixed retry cadence', async (t) => {
    const time = clock();
    let fail = false;
    const getSecret = t.mock.method(SecretClient.prototype, 'getSecret', async (name) => {
        if (fail && name === 'id') throw new Error('PRIVATE-FAILURE');
        return { value: name };
    });
    const failures = [];
    const manager = new ProviderCredentials({ cacheOptions: time.options, reportFailure: (kind) => failures.push(kind) });
    try {
        await manager.resolve(auth, config);
        fail = true;
        await time.advance(240000);
        for (let i = 0; i < 10; i++) assert.equal((await manager.resolve(auth, config)).identity, 'id');
        assert.equal(getSecret.mock.callCount(), 4);
        assert.deepEqual(failures, ['key_vault']);
        await time.advance(60000);
        for (let i = 0; i < 10; i++) await assert.rejects(manager.resolve(auth, config), /unavailable/);
        assert.equal(getSecret.mock.callCount(), 6);
        for (const delay of [30000, 30000, 30000, 30000, 30000]) {
            const calls = getSecret.mock.callCount();
            await time.advance(delay - 1);
            assert.equal(getSecret.mock.callCount(), calls);
            await time.advance(1);
            assert.equal(getSecret.mock.callCount(), calls + 2);
        }
        fail = false;
        await time.advance(30000);
        assert.equal((await manager.resolve(auth, config)).secret, 'key');
        assert.equal(getSecret.mock.callCount(), 18);
    } finally { manager.close(); }
});

test('invalid or disabled secret values are never published', async (t) => {
    const time = clock();
    const getSecret = t.mock.method(SecretClient.prototype, 'getSecret', async () => ({ value: 'old' }));
    for (const invalid of [{ value: '' }, { value: 'bad', properties: { enabled: false } },
        { value: 'bad', properties: { notBefore: new Date(time.now + 3600000) } },
        { value: 'bad', properties: { expiresOn: new Date(time.now) } }]) {
        const manager = new ProviderCredentials({ cacheOptions: time.options, reportFailure() {} });
        getSecret.mock.mockImplementation(async () => invalid);
        await assert.rejects(manager.resolve(auth, config), /unavailable/);
        manager.close();
    }
});

test('SDK credentials are reused, one refresh loop warms both tokens, and reads retain real token expiry', async (t) => {
    const time = clock();
    const expiry = time.now + 3600000;
    const identity = t.mock.method(ManagedIdentityCredential.prototype, 'getToken', async () => ({
        token: 'PRIVATE-ASSERTION', expiresOnTimestamp: expiry,
    }));
    const provider = t.mock.method(ClientAssertionCredential.prototype, 'getToken', async function () {
        await this.getAssertion();
        await this.getAssertion();
        return { token: 'PRIVATE-PROVIDER', expiresOnTimestamp: expiry, refreshAfterTimestamp: time.now + 10000 };
    });
    const manager = new ProviderCredentials({ cacheOptions: time.options, reportFailure() {} });
    try {
        const results = await Promise.all(Array.from({ length: 20 }, () => manager.resolve({ mode: 'oauth' }, oauth)));
        assert.ok(results.every((value) => value.accessToken === 'PRIVATE-PROVIDER'));
        assert.ok(manager.current instanceof AccessTokenCache);
        assert.equal(provider.mock.callCount(), 1);
        assert.equal(identity.mock.callCount(), 3); // One warmup plus SDK assertion callbacks, not network calls.
        assert.equal(time.timerCount, 1);
        assert.equal(JSON.stringify(results[0]), '{"mode":"oauth"}');
        await manager.resolve({ mode: 'oauth' }, oauth);
        assert.equal(provider.mock.callCount(), 1);
        await time.advance(30000);
        assert.equal(provider.mock.callCount(), 2);
        assert.equal(provider.mock.calls[0].this, provider.mock.calls[1].this);
        await time.advance(3540000);
        await assert.rejects(manager.resolve({ mode: 'oauth' }, oauth), /unavailable/);
        await time.advance(10000);
        await assert.rejects(manager.resolve({ mode: 'oauth' }, oauth), /unavailable/);
    } finally { manager.close(); }
});

test('only the selected cache is created, and new configuration uses a new worker', async (t) => {
    const time = clock();
    t.mock.method(ManagedIdentityCredential.prototype, 'getToken', async () => ({
        token: 'assertion', expiresOnTimestamp: time.now + 3600000,
    }));
    const provider = t.mock.method(ClientAssertionCredential.prototype, 'getToken', async () => ({
        token: 'token', expiresOnTimestamp: time.now + 3600000,
    }));
    const vault = t.mock.method(SecretClient.prototype, 'getSecret', () => assert.fail('OAuth must not read Key Vault'));
    let manager = new ProviderCredentials({ cacheOptions: time.options });
    try {
        await manager.resolve({ mode: 'oauth' }, oauth);
        await manager.resolve({ mode: 'oauth' }, oauth);
        assert.equal(provider.mock.callCount(), 1);
        assert.ok(manager.current instanceof AccessTokenCache);
        manager.close();
        manager = new ProviderCredentials({ cacheOptions: time.options });
        await manager.resolve({ mode: 'oauth' }, { ...oauth, providerScope: 'different-scope' });
        assert.notEqual(provider.mock.calls[0].this, provider.mock.calls[1].this);
        manager.close();
        manager = new ProviderCredentials({ cacheOptions: time.options });
        await manager.resolve({ mode: 'oauth' }, { ...oauth, outboundClientId: 'different-app' });
        assert.notEqual(provider.mock.calls[1].this, provider.mock.calls[2].this);
        assert.equal(time.timerCount, 1);
        assert.equal(vault.mock.callCount(), 0);
        manager.close();
        manager = new ProviderCredentials({ cacheOptions: time.options, reportFailure() {} });
        await assert.rejects(manager.resolve({ mode: 'oauth' }, { ...oauth, providerScope: '' }), /unavailable/);
        assert.equal(time.timerCount, 0);
        await manager.resolve({ mode: 'oauth' }, oauth);
        assert.equal(time.timerCount, 1);
    } finally { manager.close(); }
});

test('API-key mode never creates an access-token credential and unknown modes start nothing', async (t) => {
    const time = clock();
    t.mock.method(SecretClient.prototype, 'getSecret', async () => ({ value: 'key' }));
    const token = t.mock.method(ClientAssertionCredential.prototype, 'getToken', () => assert.fail('Unexpected OAuth'));
    const manager = new ProviderCredentials({ cacheOptions: time.options });
    try {
        await manager.resolve(auth, config);
        assert.ok(manager.current instanceof ApiKeyCache);
        assert.equal(token.mock.callCount(), 0);
    } finally { manager.close(); }
    const invalid = new ProviderCredentials({ cacheOptions: time.options, reportFailure() {} });
    await assert.rejects(invalid.resolve({ mode: 'unknown' }, config), /unavailable/);
    assert.equal(invalid.current, null);
    assert.equal(time.timerCount, 0);
    invalid.close();
});

test('shutdown aborts a pending read, prevents late publication, and cannot be reopened', async (t) => {
    const time = clock();
    let release;
    const gate = new Promise((resolve) => { release = resolve; });
    const getSecret = t.mock.method(SecretClient.prototype, 'getSecret', async () => {
        await gate;
        return { value: 'PRIVATE-LATE-KEY' };
    });
    const manager = new ProviderCredentials({ cacheOptions: time.options });
    const pending = manager.resolve(auth, config);
    const rejected = assert.rejects(pending, /unavailable/);
    await flush();
    manager.close();
    await rejected;
    release();
    await flush();
    for (const settings of [config, { ...config, keyVaultUrl: 'https://other.vault.azure.net' }]) {
        await assert.rejects(manager.resolve(auth, settings), /unavailable/);
    }
    assert.equal(time.timerCount, 0);
    assert.equal(getSecret.mock.callCount(), 2);
});
