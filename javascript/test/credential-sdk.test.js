'use strict';

const { test, mock, beforeEach, afterEach } = require('node:test');
const assert = require('node:assert/strict');
const Module = require('node:module');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');
const path = require('node:path');
const { setTimeout: delay } = require('node:timers/promises');
const pipeline = require('@azure/core-rest-pipeline');
const { createHttpHeaders } = pipeline;
const { readConfig } = require('../src/functions/config');

let state;
const originalLoad = Module._load;
const load = mock.method(Module, '_load', function (name, ...args) {
    if (name !== '@azure/core-rest-pipeline') return originalLoad.call(this, name, ...args);
    return { ...pipeline, createDefaultHttpClient: () => state.transport };
});
let ProviderCredentials;
try { ({ ProviderCredentials } = require('../src/functions/credentials')); }
finally { load.mock.restore(); }

const envKeys = [
    'IDENTITY_ENDPOINT', 'IDENTITY_HEADER', 'IDENTITY_SERVER_THUMBPRINT',
    'MSI_ENDPOINT', 'MSI_SECRET', 'AZURE_FEDERATED_TOKEN_FILE',
];
let savedEnv;
beforeEach(() => {
    savedEnv = Object.fromEntries(envKeys.map((key) => [key, process.env[key]]));
    for (const key of envKeys) delete process.env[key];
    process.env.IDENTITY_ENDPOINT = 'http://127.0.0.1:1/synthetic-identity';
    process.env.IDENTITY_HEADER = 'synthetic-header';
    state = { miCalls: 0, tokenCalls: 0, vaultCalls: 0, wait: 5, miWait: 5, requests: [] };
    state.transport = {
        async sendRequest(request) {
            // MSAL reuses its first managed-identity transport across credential instances.
            const current = state;
            const url = new URL(request.url);
            if (url.hostname === 'unit.vault.azure.net') {
                current.vaultCalls++;
                return { request, status: 401, headers: createHttpHeaders({
                    'www-authenticate': 'Bearer authorization="https://login.microsoftonline.com/11111111-1111-1111-1111-111111111111", resource="https://vault.azure.net"',
                }) };
            }
            const managedIdentity = url.pathname === '/synthetic-identity';
            if (managedIdentity) {
                assert.equal(request.method, 'GET');
                current.miCalls++;
            } else {
                assert.equal(request.method, 'POST');
                assert.ok(url.pathname.endsWith('/oauth2/v2.0/token'));
                current.tokenCalls++;
            }
            const call = { managedIdentity, aborted: false, completed: false };
            current.requests.push(call);
            try {
                await delay(managedIdentity ? current.miWait : current.wait, null, { signal: request.abortSignal });
            } catch (error) {
                call.aborted = true;
                throw error;
            } finally {
                call.completed = true;
            }
            return { request, status: 200, headers: createHttpHeaders({ 'content-type': 'application/json' }),
                bodyAsText: JSON.stringify({
                    access_token: managedIdentity ? 'PRIVATE-ASSERTION' : 'PRIVATE-TOKEN',
                    token_type: 'Bearer', expires_in: 3600,
                    expires_on: String(Math.floor(Date.now() / 1000) + 3600),
                    resource: url.searchParams.get('resource'), scope: 'api://provider/.default',
                }) };
        },
    };
});

afterEach(() => {
    for (const [key, value] of Object.entries(savedEnv)) {
        if (value === undefined) delete process.env[key];
        else process.env[key] = value;
    }
});

async function waitForRequest(managedIdentity) {
    for (let i = 0; i < 200; i++) {
        if (state.requests.some((request) => request.managedIdentity === managedIdentity)) return;
        await delay(5);
    }
    assert.fail('SDK request did not reach the transport');
}

function config() {
    return readConfig({
        EPP_PROVIDER_TENANT_ID: '11111111-1111-1111-1111-111111111111',
        EPP_OUTBOUND_CLIENT_ID: crypto.randomUUID(),
        EPP_OUTBOUND_MI_CLIENT_ID: crypto.randomUUID(),
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
        assert.ok(state.requests.some((request) => !request.managedIdentity && request.aborted));
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
    await waitForRequest(false);
    state.wait = 5;
    const result = await manager.resolve({ mode: 'oauth' }, { ...settings, outboundClientId: crypto.randomUUID() });
    await firstRejected;
    try {
        assert.equal(result.accessToken, 'PRIVATE-TOKEN');
        assert.ok(state.requests.some((request) => !request.managedIdentity && request.aborted));
        assert.equal(state.tokenCalls, 2);
    } finally { manager.close(); }
});

test('the acquisition deadline aborts real managed-identity transport before another refresh starts', async () => {
    let now = Date.now();
    const manager = new ProviderCredentials({
        reportFailure: () => {},
        cacheOptions: { now: () => now, random: () => 0, schedule: () => ({ unref() {} }), cancel() {} },
    });
    const settings = config();
    state.miWait = 10000;
    try {
        await assert.rejects(manager.resolve({ mode: 'oauth' }, settings), /unavailable/);
        await new Promise(setImmediate);
        assert.equal(state.miCalls, 1);
        assert.ok(state.requests.every((request) => request.completed && request.aborted));
        assert.equal(state.tokenCalls, 0);
        now += 10000;
        state.miWait = 5;
        assert.equal((await manager.resolve({ mode: 'oauth' }, settings)).accessToken, 'PRIVATE-TOKEN');
        assert.equal(state.miCalls, 2);
        assert.equal(state.tokenCalls, 1);
    } finally { manager.close(); }
});

test('shutdown aborts managed-identity transport and cannot restart acquisition', async () => {
    const manager = new ProviderCredentials({ reportFailure: () => {} });
    const settings = config();
    state.miWait = 10000;
    const pending = manager.resolve({ mode: 'oauth' }, settings);
    const rejected = assert.rejects(pending, /unavailable/);
    try {
        await waitForRequest(true);
        manager.close();
        await rejected;
        await new Promise(setImmediate);
        assert.ok(state.requests.every((request) => request.completed && request.aborted));
        await assert.rejects(manager.resolve({ mode: 'oauth' }, settings), /unavailable/);
        assert.equal(state.miCalls, 1);
        assert.equal(state.tokenCalls, 0);
    } finally {
        manager.close();
        await rejected;
    }
});

test('Key Vault acquisition also aborts its real managed-identity transport', async () => {
    const manager = new ProviderCredentials({ reportFailure: () => {} });
    const settings = readConfig({
        KEY_VAULT_URL: 'https://unit.vault.azure.net', AZURE_CLIENT_ID: crypto.randomUUID(),
    });
    state.miWait = 10000;
    try {
        await assert.rejects(manager.resolve({ mode: 'apiKey', keyVaultSecretName: 'key' }, settings), /unavailable/);
        await new Promise(setImmediate);
        assert.equal(state.vaultCalls, 1);
        assert.equal(state.miCalls, 1);
        assert.ok(state.requests.every((request) => request.completed && request.aborted));
    } finally { manager.close(); }
});

test('the default Azure HTTP client closes a stalled managed-identity socket on timeout', () => {
    const script = `
        const assert = require('node:assert/strict');
        const { createServer } = require('node:http');
        const { setTimeout: delay } = require('node:timers/promises');
        const { ClientAssertionCredential } = require('@azure/identity');
        const { ProviderCredentials } = require('./src/functions/credentials');
        ClientAssertionCredential.prototype.getToken = async function () {
            await this.getAssertion();
            throw new Error('The synthetic managed-identity request must not complete');
        };
        (async () => {
            let requests = 0;
            let onDisconnect;
            const disconnected = new Promise(resolve => { onDisconnect = resolve; });
            const sockets = new Set();
            const server = createServer(() => { requests++; });
            server.on('connection', socket => {
                sockets.add(socket);
                socket.once('close', () => { sockets.delete(socket); onDisconnect(); });
            });
            await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
            for (const key of ['MSI_ENDPOINT', 'MSI_SECRET', 'IDENTITY_SERVER_THUMBPRINT', 'AZURE_FEDERATED_TOKEN_FILE']) {
                delete process.env[key];
            }
            process.env.IDENTITY_ENDPOINT = 'http://127.0.0.1:' + server.address().port + '/identity';
            process.env.IDENTITY_HEADER = 'synthetic-header';
            const manager = new ProviderCredentials({ reportFailure: () => {} });
            try {
                await assert.rejects(manager.resolve({ mode: 'oauth' }, {
                    providerTenantId: '11111111-1111-1111-1111-111111111111',
                    outboundClientId: '22222222-2222-2222-2222-222222222222',
                    outboundManagedIdentityClientId: '33333333-3333-3333-3333-333333333333',
                    providerScope: 'api://provider/.default',
                }), /unavailable/);
                assert.equal(requests, 1);
                const closed = await Promise.race([disconnected.then(() => true), delay(1000, false, { ref: false })]);
                assert.equal(closed, true);
                console.log('transport-aborted');
            } finally {
                manager.close();
                for (const socket of sockets) socket.destroy();
                await new Promise(resolve => server.close(resolve));
            }
        })().catch(error => { console.error(error); process.exitCode = 1; });
    `;
    const result = spawnSync(process.execPath, ['-e', script], {
        cwd: path.resolve(__dirname, '..'), encoding: 'utf8', timeout: 10000,
    });
    assert.equal(result.error, undefined);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout.trim(), 'transport-aborted');
});
