'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { inspect } = require('node:util');
const { RefreshingCache, tokenEntry } = require('../src/functions/refreshingCache');
const { ProviderCredentials } = require('../src/functions/credentials');
const { ClientAssertionCredential, ManagedIdentityCredential } = require('@azure/identity');
const { SecretClient } = require('@azure/keyvault-secrets');
const { readConfig } = require('../src/functions/config');

const flush = () => new Promise(setImmediate);
const deferred = () => {
    let resolve;
    let reject;
    const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
    return { promise, resolve, reject };
};

function clock() {
    let time = 1700000000000;
    const timers = new Set();
    return {
        options: {
            now: () => time,
            random: () => 0,
            schedule: (callback, delay) => {
                const timer = { at: time + delay, callback, unref() {} };
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
                if (timer.at <= time && timers.delete(timer)) timer.callback();
            }
            await flush();
        },
    };
}

test('concurrent empty-cache readers join one refresh; fresh hits make no loader calls', async () => {
    const time = clock();
    const gate = deferred();
    let calls = 0;
    const cache = new RefreshingCache(async () => {
        calls++;
        await gate.promise;
        return { value: 'PRIVATE-VALUE', expiresAt: time.now + 300000, refreshAt: time.now + 240000 };
    }, time.options);
    try {
        const readers = Array.from({ length: 20 }, () => cache.get());
        await flush();
        assert.equal(calls, 1);
        gate.resolve();
        assert.deepEqual(await Promise.all(readers), Array(20).fill('PRIVATE-VALUE'));
        assert.equal(await cache.get(), 'PRIVATE-VALUE');
        assert.equal(calls, 1);
        assert.equal(time.timerCount, 1);
        assert.doesNotMatch(inspect(cache) + JSON.stringify(cache), /PRIVATE/);
    } finally { cache.close(); }
    assert.equal(time.timerCount, 0);
});

test('scheduled refresh serves the valid old entry, replaces atomically, and never extends a failed entry', async () => {
    const time = clock();
    let next = async () => ({ value: 'first', expiresAt: time.now + 300000, refreshAt: time.now + 240000 });
    const failures = [];
    const cache = new RefreshingCache(() => next(), { ...time.options, onFailure: () => failures.push('failed') });
    try {
        assert.equal(await cache.get(), 'first');
        const gate = deferred();
        next = () => gate.promise;
        await time.advance(240000);
        assert.equal(await cache.get(), 'first');
        gate.reject(new Error('PRIVATE-REFRESH-ERROR'));
        await flush();
        assert.deepEqual(failures, ['failed']);
        assert.equal(await cache.get(), 'first');
        await time.advance(60000);
        await assert.rejects(cache.get(), /provider credential unavailable/);
        next = async () => ({ value: 'recovered', expiresAt: time.now + 300000, refreshAt: time.now + 240000 });
        await time.advance(10000);
        assert.equal(await cache.get(), 'recovered');
    } finally { cache.close(); }
});

test('failed cold refresh applies bounded backoff instead of a fetch per request', async () => {
    const time = clock();
    let calls = 0;
    const cache = new RefreshingCache(async () => { calls++; throw new Error('PRIVATE-FAILURE'); }, time.options);
    try {
        await assert.rejects(cache.get(), /^Error: provider credential unavailable$/);
        for (let i = 0; i < 10; i++) await assert.rejects(cache.get(), /unavailable/);
        assert.equal(calls, 1);
        await time.advance(4999);
        assert.equal(calls, 1);
        await time.advance(1);
        assert.equal(calls, 2);
        await time.advance(9999);
        assert.equal(calls, 2);
        await time.advance(1);
        assert.equal(calls, 3);
    } finally { cache.close(); }
});

test('stopping a cache cancels refresh and prevents late publication or rescheduling', async () => {
    const time = clock();
    const gate = deferred();
    let signal;
    const cache = new RefreshingCache(async (abortSignal) => {
        signal = abortSignal;
        return gate.promise;
    }, time.options);
    const pending = cache.get();
    await flush();
    cache.close();
    assert.equal(signal.aborted, true);
    gate.resolve({ value: 'late', expiresAt: time.now + 300000, refreshAt: time.now + 240000 });
    await assert.rejects(pending, /unavailable/);
    await assert.rejects(cache.get(), /unavailable/);
    assert.equal(time.timerCount, 0);
});

test('token refresh retains original expiry, honors refresh hints, and avoids spinning on SDK cache hits', () => {
    const now = 1700000000000;
    const token = { token: 'PRIVATE-TOKEN', expiresOnTimestamp: now + 3600000 };
    assert.deepEqual(tokenEntry(token, now), { value: token, expiresAt: now + 3570000, refreshAt: now + 3300000 });
    const repeated = tokenEntry(token, now + 3300000);
    assert.equal(repeated.expiresAt, now + 3570000);
    assert.equal(repeated.refreshAt, now + 3360000);
    assert.equal(tokenEntry({ ...token, refreshAfterTimestamp: now + 600000 }, now).refreshAt, now + 600000);
    for (const invalid of [null, { ...token, token: '' }, { ...token, token: ' ' },
        { ...token, expiresOnTimestamp: now + 30000 }, { ...token, expiresOnTimestamp: NaN },
        { ...token, expiresOnTimestamp: Infinity }, { token: 'PRIVATE' }]) {
        assert.throws(() => tokenEntry(invalid, now), /unavailable/);
    }
});

test('Key Vault refresh fetches a parallel credential bundle once and keeps a complete old pair on partial failure', async (t) => {
    const time = clock();
    let failIdentity = false;
    let version = 1;
    const getSecret = t.mock.method(SecretClient.prototype, 'getSecret', async (name) => {
        if (failIdentity && name === 'customer-id') throw new Error('PRIVATE-IDENTITY-ERROR');
        return { value: `${name}-${version}` };
    });
    const failures = [];
    const manager = new ProviderCredentials({ cacheOptions: time.options, reportFailure: (kind) => failures.push(kind) });
    const auth = { mode: 'apiKey', keyVaultSecretName: 'api-key', identityKeyVaultSecretName: 'customer-id' };
    const config = readConfig({ KEY_VAULT_URL: 'https://unit.vault.azure.net' });
    try {
        const results = await Promise.all(Array.from({ length: 10 }, () => manager.resolve(auth, config)));
        assert.equal(getSecret.mock.callCount(), 2);
        assert.ok(results.every((value) => value.secret === 'api-key-1' && value.identity === 'customer-id-1'));
        failIdentity = true;
        version = 2;
        await time.advance(240000);
        const old = await manager.resolve(auth, config);
        assert.deepEqual(old, { mode: 'apiKey', secret: 'api-key-1', identity: 'customer-id-1' });
        assert.deepEqual(failures, ['key_vault']);
        failIdentity = false;
        await time.advance(5000);
        assert.deepEqual(await manager.resolve(auth, config),
            { mode: 'apiKey', secret: 'api-key-2', identity: 'customer-id-2' });
        assert.equal(getSecret.mock.callCount(), 6);
    } finally { manager.close(); }
    assert.equal(time.timerCount, 0);
});

test('MI and final Entra tokens have independent single-flight refresh and warm requests skip both SDKs', async (t) => {
    const time = clock();
    const identity = t.mock.method(ManagedIdentityCredential.prototype, 'getToken', async () => ({
        token: 'PRIVATE-ASSERTION', expiresOnTimestamp: time.now + 3600000,
    }));
    const provider = t.mock.method(ClientAssertionCredential.prototype, 'getToken', async function () {
        await this.getAssertion();
        await this.getAssertion();
        return { token: 'PRIVATE-PROVIDER', expiresOnTimestamp: time.now + 3600000 };
    });
    const manager = new ProviderCredentials({ cacheOptions: time.options });
    const config = readConfig({
        EPP_PROVIDER_TENANT_ID: '11111111-1111-1111-1111-111111111111',
        EPP_OUTBOUND_CLIENT_ID: '22222222-2222-2222-2222-222222222222',
        EPP_OUTBOUND_MI_CLIENT_ID: '33333333-3333-3333-3333-333333333333',
        EPP_PROVIDER_SCOPE: 'api://provider/.default',
    });
    try {
        const results = await Promise.all(Array.from({ length: 20 }, () => manager.resolve({ mode: 'oauth' }, config)));
        assert.ok(results.every((value) => value.accessToken === 'PRIVATE-PROVIDER'));
        assert.equal(identity.mock.callCount(), 1);
        assert.equal(provider.mock.callCount(), 1);
        assert.equal(time.timerCount, 2);
        assert.equal(JSON.stringify(results[0]), '{"mode":"oauth"}');
        await manager.resolve({ mode: 'oauth' }, config);
        assert.equal(provider.mock.callCount(), 1);
        await time.advance(3300000);
        assert.equal(identity.mock.callCount(), 2);
        assert.equal(provider.mock.callCount(), 2);
        await manager.resolve({ mode: 'oauth' }, { ...config, providerScope: 'api://second/.default' });
        assert.equal(identity.mock.callCount(), 2);
        assert.equal(provider.mock.callCount(), 3);
        assert.equal(provider.mock.calls[0].this, provider.mock.calls[2].this);
        await manager.resolve({ mode: 'oauth' }, { ...config, outboundClientId: '44444444-4444-4444-4444-444444444444' });
        assert.equal(identity.mock.callCount(), 3);
        assert.notEqual(provider.mock.calls[0].this, provider.mock.calls[3].this);
        assert.equal(time.timerCount, 2);
    } finally { manager.close(); }
    assert.equal(time.timerCount, 0);
});

test('bad refresh results never replace a valid Key Vault bundle', async (t) => {
    const time = clock();
    const getSecret = t.mock.method(SecretClient.prototype, 'getSecret', async () => ({ value: 'old-key' }));
    const manager = new ProviderCredentials({ cacheOptions: time.options, reportFailure: () => {} });
    const auth = { mode: 'apiKey', keyVaultSecretName: 'key' };
    const config = readConfig({ KEY_VAULT_URL: 'https://unit.vault.azure.net' });
    try {
        assert.equal((await manager.resolve(auth, config)).secret, 'old-key');
        getSecret.mock.mockImplementation(async () => ({ value: '' }));
        await time.advance(240000);
        assert.equal((await manager.resolve(auth, config)).secret, 'old-key');
        await time.advance(60000);
        await assert.rejects(manager.resolve(auth, config), /unavailable/);
    } finally { manager.close(); }
});

test('incomplete OAuth reconfiguration clears old timers and never reuses old valid tokens', async (t) => {
    const time = clock();
    t.mock.method(ManagedIdentityCredential.prototype, 'getToken', async () => ({
        token: 'assertion', expiresOnTimestamp: time.now + 3600000,
    }));
    t.mock.method(ClientAssertionCredential.prototype, 'getToken', async function () {
        await this.getAssertion();
        return { token: 'token', expiresOnTimestamp: time.now + 3600000 };
    });
    const manager = new ProviderCredentials({ cacheOptions: time.options });
    const config = readConfig({ EPP_PROVIDER_TENANT_ID: 'tenant', EPP_OUTBOUND_CLIENT_ID: 'app',
        EPP_OUTBOUND_MI_CLIENT_ID: 'identity', EPP_PROVIDER_SCOPE: 'scope' });
    try {
        await manager.resolve({ mode: 'oauth' }, config);
        assert.equal(time.timerCount, 2);
        await assert.rejects(manager.resolve({ mode: 'oauth' }, { ...config, providerScope: '' }), /unavailable/);
        assert.equal(time.timerCount, 0);
        await manager.resolve({ mode: 'oauth' }, config);
        assert.equal(time.timerCount, 2);
    } finally { manager.close(); }
});

test('closing a credential manager is terminal, including after a configuration change', async (t) => {
    const time = clock();
    const getSecret = t.mock.method(SecretClient.prototype, 'getSecret', async () => ({ value: 'PRIVATE-KEY' }));
    const manager = new ProviderCredentials({ cacheOptions: time.options });
    const auth = { mode: 'apiKey', keyVaultSecretName: 'key' };
    const config = readConfig({ KEY_VAULT_URL: 'https://unit.vault.azure.net' });
    await manager.resolve(auth, config);
    manager.close();
    manager.close();
    for (const settings of [config, { ...config, keyVaultUrl: 'https://other.vault.azure.net' }]) {
        await assert.rejects(manager.resolve(auth, settings), /provider credential unavailable/);
    }
    await assert.rejects(manager.resolve({ mode: 'oauth' }, config), /provider credential unavailable/);
    assert.equal(getSecret.mock.callCount(), 1);
    assert.equal(time.timerCount, 0);
});
