'use strict';

const { test, mock, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const Module = require('node:module');
const crypto = require('node:crypto');
const { setTimeout: delay } = require('node:timers/promises');
const identity = require('@azure/identity');
const { createHttpHeaders } = require('@azure/core-rest-pipeline');
const { readConfig } = require('../src/functions/config');

let state;
const originalLoad = Module._load;
const load = mock.method(Module, '_load', function (name, ...args) {
    if (name !== '@azure/identity') return originalLoad.call(this, name, ...args);
    return {
        ...identity,
        ManagedIdentityCredential: class extends identity.ManagedIdentityCredential {
            constructor(...args) { super(...args); this.testState = state; }
            async getToken() {
                this.testState.miCalls++;
                return { token: 'PRIVATE-ASSERTION', expiresOnTimestamp: Date.now() + 3600000 };
            }
        },
        ClientAssertionCredential: class extends identity.ClientAssertionCredential {
            constructor(tenant, client, assertion, options) {
                super(tenant, client, assertion, { ...options, httpClient: state.transport });
            }
        },
    };
});
let ProviderCredentials;
try { ({ ProviderCredentials } = require('../src/functions/credentials')); }
finally { load.mock.restore(); }

beforeEach(() => {
    state = { miCalls: 0, tokenCalls: 0, wait: 5, abortObserved: false };
    const current = state;
    state.transport = {
        async sendRequest(request) {
            const url = new URL(request.url);
            assert.equal(request.method, 'POST');
            assert.ok(url.pathname.endsWith('/oauth2/v2.0/token'));
            current.tokenCalls++;
            try { await delay(current.wait, null, { signal: request.abortSignal }); }
            catch (error) { current.abortObserved = true; throw error; }
            return { request, status: 200, headers: createHttpHeaders({ 'content-type': 'application/json' }),
                bodyAsText: JSON.stringify({ access_token: 'PRIVATE-TOKEN', token_type: 'Bearer',
                    expires_in: 3600, scope: 'api://provider/.default' }) };
        },
    };
});

function config() {
    return readConfig({
        EPP_PROVIDER_TENANT_ID: '11111111-1111-1111-1111-111111111111',
        EPP_OUTBOUND_CLIENT_ID: crypto.randomUUID(),
        EPP_OUTBOUND_MI_CLIENT_ID: '33333333-3333-3333-3333-333333333333',
        EPP_PROVIDER_SCOPE: 'api://provider/.default',
    });
}

test('real SDK sees one initial Entra exchange and none on concurrent or later warm requests', async () => {
    const manager = new ProviderCredentials();
    const settings = config();
    try {
        const tokens = await Promise.all(Array.from({ length: 20 }, () => manager.resolve({ mode: 'oauth' }, settings)));
        assert.ok(tokens.every((token) => token.accessToken === 'PRIVATE-TOKEN'));
        assert.equal(state.tokenCalls, 1);
        assert.equal(state.miCalls, 1);
        await manager.resolve({ mode: 'oauth' }, settings);
        assert.equal(state.tokenCalls, 1);
        assert.equal(state.miCalls, 1);
    } finally { manager.close(); }
});

test('the cache-owned acquisition budget aborts actual SDK transport and does not cache a late token', async () => {
    const failures = [];
    const manager = new ProviderCredentials({ reportFailure: (kind) => failures.push(kind) });
    const settings = config();
    state.wait = 10000;
    try {
        await assert.rejects(manager.resolve({ mode: 'oauth' }, settings), /^Error: provider OAuth token unavailable$/);
        await new Promise(setImmediate);
        assert.equal(state.abortObserved, true);
        assert.deepEqual(failures, ['provider_token']);
        assert.equal(state.tokenCalls, 1);
        await assert.rejects(manager.resolve({ mode: 'oauth' }, settings), /unavailable/);
        assert.equal(state.tokenCalls, 1);
    } finally { manager.close(); }
});

test('changing configuration cancels old work without publishing its token into the replacement cache', async () => {
    const manager = new ProviderCredentials({ reportFailure: () => {} });
    const settings = config();
    state.wait = 10000;
    const first = manager.resolve({ mode: 'oauth' }, settings);
    const firstRejected = assert.rejects(first, /unavailable/);
    await delay(20);
    state.wait = 5;
    const result = await manager.resolve({ mode: 'oauth' }, { ...settings, outboundClientId: crypto.randomUUID() });
    await firstRejected;
    try {
        assert.equal(result.accessToken, 'PRIVATE-TOKEN');
        assert.equal(state.abortObserved, true);
        assert.equal(state.tokenCalls, 2);
    } finally { manager.close(); }
});
