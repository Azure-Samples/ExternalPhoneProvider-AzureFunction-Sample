'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { parseEnvelope, getProvider, resolveOutcome, outcomeToHttpStatus } = require('../src/functions/dispatch');

const envelope = (overrides = {}) => ({
    type: 'microsoft.mfa.otpDeliver.v1', channel: 1, mode: 1,
    encryptedDeliveryContext: 'unused', ...overrides,
});

for (const field of ['channel', 'mode']) {
    for (const value of [[], [1], {}, true, false, null, '__proto__', 'constructor', '1']) {
        test(`${field} rejects ${JSON.stringify(value)}`, () => {
            assert.ok(parseEnvelope(envelope({ [field]: value })).error);
        });
    }
}

test('TTL may be omitted but explicit null is invalid', () => {
    assert.ok(parseEnvelope(envelope()).envelope);
    assert.ok(parseEnvelope(envelope({ ttlSeconds: null })).error);
});

for (const [provider, body] of [
    ['infobip', { messages: [{ status: { name: 'DELIVERED' } }] }],
    ['telesign', { status: { code: 290 } }],
    ['soprano', { status: 'ENROUTE' }],
    ['sinch', { status: 'Dispatched' }],
]) {
    for (const [status, expected] of [[401, 401], [429, 429], [500, 502]]) {
        test(`${provider}: HTTP ${status} overrides success-looking body`, () => {
            const { adapter, manifest } = getProvider(provider);
            const parsed = adapter.parseResponse({ httpStatus: status, ok: false, json: body });
            const outcome = resolveOutcome(manifest, parsed);
            assert.equal(outcome, 'Fail');
            assert.equal(outcomeToHttpStatus(outcome, status), expected);
        });
    }
}

test('explicit Block and StepUp outcomes remain failures', () => {
    const manifest = { responseMapping: { BLOCKED: 'Block', RISK: 'StepUp', default: 'Fail' } };
    for (const [status, expected] of [['BLOCKED', 'Block'], ['RISK', 'StepUp']]) {
        assert.equal(resolveOutcome(manifest, { success: false, providerStatusName: status }), expected);
    }
});