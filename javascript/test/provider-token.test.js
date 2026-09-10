'use strict';

const { test, beforeEach, mock } = require('node:test');
const assert = require('node:assert/strict');
const { inspect } = require('node:util');
const Module = require('node:module');
const { readConfig } = require('../src/functions/config');
const { SecretClient } = require('@azure/keyvault-secrets');
const { TextToVoice } = require('../src/functions/models');

let state;
const accessToken = (token = 'fixture-provider-token') => ({ token, expiresOnTimestamp: Date.now() + 600000 });
const invalidTokens = () => [null, accessToken(''), accessToken('bad\r\nheader'), { token: 'no-expiry' },
    ...['token\u0001', 'token\u007f', 't\u00f6ken'].map(accessToken),
    { token: 'expired', expiresOnTimestamp: Date.now() - 1 }, { token: 'near-expiry', expiresOnTimestamp: Date.now() + 59000 }];
function sdkCredential(kind) {
    return class {
        constructor(...args) {
            this.args = args;
            state.created.push({ kind, args, credential: this });
        }
        async getToken(scope, options) {
            state.calls.push({ kind, scope, options, credential: this });
            if (kind === 'assertion') assert.equal(await this.args[2](), 'fixture-assertion');
            return state.getToken(kind, scope, options);
        }
    };
}
const sdk = { ManagedIdentityCredential: sdkCredential('mi'), ClientAssertionCredential: sdkCredential('assertion'),
    ClientSecretCredential: sdkCredential('secret'),
    logger: Object.fromEntries(['error', 'warning', 'info', 'verbose'].map(level => [level, { enabled: true }])) };
// Exercise the real acquirer/factory against SDK stubs, never a CLI or live identity endpoint.
const originalLoad = Module._load;
const registration = mock.method(Module, '_load', function (name, ...args) {
    return name === '@azure/identity' ? sdk : originalLoad.call(this, name, ...args);
});
let ProviderTokenAcquirer;
let ProviderTokenConfig;
try {
    ({ ProviderTokenAcquirer, ProviderTokenConfig } = require('../src/functions/providerToken'));
} finally {
    registration.mock.restore();
}
const { dispatchOtp, getProvider } = require('../src/functions/dispatch');
const base = { EPP_PROVIDER_NAME: 'soprano', EPP_PROVIDER_ENDPOINT: 'https://provider.example/cgpapi',
    EPP_PROVIDER_AUTH_MODE: 'oauth2', EPP_PROVIDER_JWT_ENABLED: 'true', EPP_PROVIDER_TENANT_ID: '11111111-2222-4333-8444-555555555555',
    EPP_PROVIDER_CLIENT_ID: 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee', EPP_PROVIDER_SCOPE: 'api://provider/.default',
    EPP_PROVIDER_CLIENT_SECRET_NAME: 'provider-client-secret', KEY_VAULT_URL: 'https://oauth-test.vault.azure.net' };
const dispatch = { destination: '+15551234567', message: '  code 1 2 3 4 5 6.\n', channel: 'voice',
    messageId: 'message-id', correlationId: 'correlation-id',
    textToVoice: new TextToVoice(require('../../tests/fixtures/contract.json').textToVoice) };
beforeEach(() => {
    state = { created: [], calls: [], getToken: async kind => accessToken(kind === 'mi' ? 'fixture-assertion' : undefined) };
});

test('auth settings fail closed before secrets, SDK construction or sends', async (t) => {
    assert.equal(readConfig({}).providerAuthMode, 'apiKey');
    assert.equal(readConfig({}).providerJwtEnabled, false);
    assert.equal(readConfig({ EPP_PROVIDER_JWT_ENABLED: ' TrUe ' }).providerJwtEnabled, true);
    assert.equal(readConfig({ EPP_PROVIDER_JWT_ENABLED: ' FaLsE ' }).providerJwtEnabled, false);
    assert.equal(readConfig({ EPP_PROVIDER_AUTH_MODE: ' APIkey ' }).providerAuthMode, 'apiKey');
    assert.equal(readConfig({ EPP_PROVIDER_AUTH_MODE: ' OAuTh2 ' }).providerAuthMode, 'oauth2');
    const resolveSecretValue = t.mock.fn(async () => assert.fail('unexpected secret resolution'));
    const acquirer = new ProviderTokenAcquirer({ resolveSecretValue });
    assert.equal(inspect(acquirer), '[ProviderTokenAcquirer]');
    assert.equal(inspect(new ProviderTokenConfig(readConfig(base))), '[ProviderTokenConfig]');
    new ProviderTokenConfig(readConfig({ ...base, EPP_PROVIDER_SCOPE: 'resource/.default',
        KEY_VAULT_URL: ` ${base.KEY_VAULT_URL} ` })).checkConfiguration(); // Scope need not be a URL; AppConfig still trims the vault URL.
    for (const change of [
        ...['common', 'ORGANIZATIONS', 'consumers', 'AdFs', '', 'tenant/path'].map(EPP_PROVIDER_TENANT_ID => ({ EPP_PROVIDER_TENANT_ID })),
        ...['', ' value', 'value ', 'va lue', 'val\u0001ue', 'val\u007fue', 'val\u00e9ue', 123]
            .map(EPP_PROVIDER_CLIENT_ID => ({ EPP_PROVIDER_CLIENT_ID })),
        { EPP_PROVIDER_TENANT_ID: 'tenant name' }, { EPP_PROVIDER_SCOPE: 'api://provider/\u00e9/.default' },
        { EPP_PROVIDER_MI_CLIENT_ID: 'bad\r\nheader', EPP_PROVIDER_CLIENT_SECRET_NAME: '' },
        { EPP_PROVIDER_CLIENT_SECRET_NAME: ' bad-secret' }, { AZURE_CLIENT_ID: 'bad identity' },
        ...['', 'http://vault.example', 'https://', 'https://user@vault.example', 'https://vault.example/#fragment',
            'https://vault.example:0'].map(KEY_VAULT_URL => ({ KEY_VAULT_URL })),
        { EPP_PROVIDER_SCOPE: 'api://provider/read' },
        { EPP_PROVIDER_SCOPE: '/.default' },
        { EPP_PROVIDER_SCOPE: 'api://one/.default api://two/.default' }, { EPP_PROVIDER_SCOPE: ' api://provider/.default' },
        { EPP_PROVIDER_CLIENT_SECRET_NAME: '' }, { EPP_PROVIDER_MI_CLIENT_ID: 'fixture-mi' },
        ...['', 'unsupported'].flatMap(value => [
            { EPP_PROVIDER_CLIENT_SECRET: value }, { EPP_PROVIDER_TOKEN_EXCHANGE_AUDIENCE: value },
        ]),
    ]) {
        await assert.rejects(acquirer.acquire(readConfig({ ...base, ...change })), { message: 'provider token unavailable' });
    }
    const secrets = t.mock.method(SecretClient.prototype, 'getSecret', async () => assert.fail('unexpected Key Vault call'));
    const tokens = t.mock.method(ProviderTokenAcquirer.prototype, 'acquire', async () => assert.fail('unexpected token acquisition'));
    const send = t.mock.method(global, 'fetch', async () => assert.fail('unexpected provider send'));
    for (const change of [...['unknown', '', null, false].map(EPP_PROVIDER_AUTH_MODE => ({ EPP_PROVIDER_AUTH_MODE })),
        ...['', 'yes', true, null, 0].map(EPP_PROVIDER_JWT_ENABLED => ({ EPP_PROVIDER_AUTH_MODE: 'apiKey', EPP_PROVIDER_JWT_ENABLED })),
        { EPP_PROVIDER_JWT_ENABLED: 'false' }, { EPP_PROVIDER_JWT_ENABLED: undefined },
        { EPP_PROVIDER_ENDPOINT: 'http://unsafe.example' },
        ...['apiKey', 'oauth2'].map(EPP_PROVIDER_AUTH_MODE => ({ EPP_PROVIDER_NAME: 'infobip', EPP_PROVIDER_AUTH_MODE }))]) {
        const config = readConfig({ ...base, ...change });
        if (config.providerName !== 'soprano') assert.notEqual(getProvider(config.providerName).manifest.supportsOAuth, true);
        assert.equal((await dispatchOtp(dispatch, { config })).httpStatus, 502);
    }
    assert.deepEqual([resolveSecretValue.mock.callCount(), secrets.mock.callCount(), tokens.mock.callCount(),
        state.created.length, state.calls.length, send.mock.callCount()], [0, 0, 0, 0, 0, 0]);
});

test('client secret and federated MI use the SDK, fixed scopes, and one reusable credential entry', async (t) => {
    let secret = 'fixture-secret-v1';
    const resolveSecretValue = t.mock.fn(async () => secret);
    const acquirer = new ProviderTokenAcquirer({ resolveSecretValue });
    const config = readConfig(base);
    assert.deepEqual(await Promise.all([acquirer.acquire(config), acquirer.acquire(readConfig({ ...base }))]),
        ['fixture-provider-token', 'fixture-provider-token']);
    assert.equal(state.created.length, 1);
    assert.equal(state.calls.length, 2); // Tokens are requested from the reused SDK, not a custom token map.
    assert.deepEqual(state.created[0].args.slice(0, 3), [base.EPP_PROVIDER_TENANT_ID, base.EPP_PROVIDER_CLIENT_ID, secret]);
    assert.equal(state.calls[0].scope, base.EPP_PROVIDER_SCOPE);
    assert.ok(resolveSecretValue.mock.calls[0].arguments[2].abortSignal instanceof AbortSignal);
    await acquirer.acquire(readConfig({ ...base, EPP_PROVIDER_SCOPE: 'api://other/.default' }));
    await acquirer.acquire(config);
    assert.equal(state.created.length, 3); // Returning to old settings builds anew; only one entry survives.
    secret = 'fixture-secret-v2';
    await acquirer.acquire(config);
    assert.equal(state.created.length, 4);
    const federated = { ...base, EPP_PROVIDER_CLIENT_SECRET_NAME: '', EPP_PROVIDER_MI_CLIENT_ID: 'fixture-mi' };
    const secretCalls = resolveSecretValue.mock.callCount();
    const beforeMi = state.created.length;
    await Promise.all([acquirer.acquire(readConfig(federated)), acquirer.acquire(readConfig(federated))]);
    assert.equal(resolveSecretValue.mock.callCount(), secretCalls);
    assert.equal(state.created.length, beforeMi + 2);
    assert.deepEqual(state.created.slice(-2).map(entry => entry.kind), ['mi', 'assertion']);
    assert.equal(state.created.at(-2).args[0], 'fixture-mi');
    assert.deepEqual(state.created.at(-1).args.slice(0, 2), [base.EPP_PROVIDER_TENANT_ID, base.EPP_PROVIDER_CLIENT_ID]);
    const calls = state.calls.slice(-4);
    assert.equal(new Set(calls.map(call => call.options.abortSignal)).size, 2);
    for (let index = 0; index < calls.length; index += 2) {
        assert.equal(calls[index].options.abortSignal, calls[index + 1].options.abortSignal);
    }
    for (const call of calls) assert.equal(call.scope, call.kind === 'mi' ? 'api://AzureADTokenExchange/.default' : base.EPP_PROVIDER_SCOPE);
    await acquirer.acquire(readConfig({ ...federated, EPP_PROVIDER_MI_CLIENT_ID: 'other-mi' }));
    await acquirer.acquire(config);
    assert.deepEqual(state.created.slice(-3).map(entry => entry.kind), ['mi', 'assertion', 'secret']);
    for (const { args } of state.created) {
        const options = args.at(-1);
        assert.equal(options.authorityHost, 'https://login.microsoftonline.com');
        assert.equal(options.retryOptions.maxRetries, 0);
        assert.equal(options.loggingOptions.logger.enabled, false);
        assert.equal(options.loggingOptions.enableUnsafeSupportLogging, false);
    }
    assert.ok(Object.values(sdk.logger).every(log => log.enabled === false));
});

test('invalid SDK tokens, failures and bounded auth timeouts make zero provider sends', async (t) => {
    const secrets = t.mock.method(SecretClient.prototype, 'getSecret', async () => ({ value: 'fixture-secret' }));
    const send = t.mock.method(global, 'fetch', async () => assert.fail('unexpected provider send'));
    for (const result of invalidTokens()) {
        state.getToken = async () => result;
        assert.equal((await dispatchOtp(dispatch, { config: readConfig(base) })).httpStatus, 502);
    }
    state.getToken = async () => { throw new Error('PRIVATE-SDK-ERROR'); };
    const failed = await dispatchOtp(dispatch, { config: readConfig(base) });
    assert.equal(failed.httpStatus, 502);
    assert.ok(!JSON.stringify(failed).includes('PRIVATE'));
    // A failed/invalid MI assertion cannot be replaced with a client secret or sent as the provider token.
    const federated = { ...base, EPP_PROVIDER_CLIENT_SECRET_NAME: '', EPP_PROVIDER_MI_CLIENT_ID: 'fixture-mi' };
    for (const getToken of [async () => { throw new Error('PRIVATE-MI-ERROR'); }, async () => accessToken('')]) {
        state.getToken = getToken;
        const secretCalls = secrets.mock.callCount();
        assert.equal((await dispatchOtp(dispatch, { config: readConfig(federated) })).httpStatus, 502);
        assert.equal(secrets.mock.callCount(), secretCalls);
    }
    // Providers/SDKs can ignore cancellation: the caller still stops waiting at the normalized deadline.
    const pending = [];
    state.getToken = (_kind, _scope, { abortSignal }) => new Promise((_, reject) => pending.push({ abortSignal, reject }));
    for (const settings of [base, federated]) {
        const result = await dispatchOtp(dispatch, { config: readConfig({ ...settings, EPP_PROVIDER_TIMEOUT_MS: ' 0005 ' }) });
        assert.equal(result.httpStatus, 504);
        assert.equal(pending.at(-1).abortSignal.aborted, true);
        pending.at(-1).reject(new Error('PRIVATE-LATE-ERROR'));
    }
    let secretSignal;
    let releaseSecret;
    const acquirer = new ProviderTokenAcquirer({ resolveSecretValue: (_name, _config, { abortSignal }) => {
        secretSignal = abortSignal;
        return new Promise(resolve => { releaseSecret = resolve; });
    } });
    const beforeSecretTimeout = state.created.length;
    await assert.rejects(acquirer.acquire(readConfig({ ...base, EPP_PROVIDER_TIMEOUT_MS: '5' })), { name: 'TimeoutError' });
    assert.equal(secretSignal.aborted, true);
    releaseSecret('late-secret');
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(state.created.length, beforeSecretTimeout);
    assert.equal(send.mock.callCount(), 0);
    assert.ok(secrets.mock.calls.every(call => call.arguments[0] === 'provider-client-secret'));
});

test('invalid API keys fail before optional JWT acquisition or provider sends', async (t) => {
    const secrets = t.mock.method(SecretClient.prototype, 'getSecret', async name => ({ value: `fixture-${name}` }));
    const tokens = t.mock.method(ProviderTokenAcquirer.prototype, 'acquire', async () => assert.fail('unexpected token acquisition'));
    const send = t.mock.method(global, 'fetch', async () => assert.fail('unexpected provider send'));
    let index = 0;
    for (const name of ['soprano-api-id', 'soprano-api-key']) {
        for (const value of ['', ' ', 'bad\r\nheader', null, 123]) {
            secrets.mock.mockImplementation(async key => ({ value: key === name ? value : 'fixture-key' }));
            const config = readConfig({ ...base, EPP_PROVIDER_AUTH_MODE: 'apiKey',
                KEY_VAULT_URL: `https://missing-key-${index++}.vault.azure.net` });
            assert.equal((await dispatchOtp(dispatch, { config })).httpStatus, 502);
        }
    }
    assert.deepEqual([tokens.mock.callCount(), state.calls.length, send.mock.callCount()], [0, 0, 0]);
});