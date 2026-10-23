'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { CredentialResolutionError, credentialFailure } = require('../src/functions/credentialFailure');

for (const [code, expected] of [
    ['70025', 'federated_credential_missing'],
    ['70021', 'federated_credential_mismatch'],
    ['700016', 'provider_application_not_found'],
]) {
    test(`AADSTS${code} is preserved as a fixed diagnostic without its SDK message`, () => {
        const sdk = new Error(`AADSTS${code}: PRIVATE-ASSERTION PRIVATE-TOKEN PRIVATE-RESPONSE`);
        const error = credentialFailure(new Error('wrapper', { cause: sdk }), 'provider_token_exchange');
        assert.deepEqual(error.diagnostic, {
            credentialStage: 'provider_token_exchange', credentialFailure: expected, aadstsCode: code,
        });
        assert.equal(error.message, 'provider credential unavailable');
        assert.equal(error.cause, undefined);
        assert.doesNotMatch(error.stack + JSON.stringify(error), /PRIVATE/);
        assert.ok(Object.isFrozen(error.diagnostic));
    });
}

test('structured SDK codes take precedence and arbitrary code/message values are never emitted', () => {
    const error = Object.assign(new Error('AADSTS700016: PRIVATE'), { errorResponse: { error_codes: [70025] } });
    const wrapper = new Error('AADSTS700016: PRIVATE', { cause: error });
    assert.equal(credentialFailure(wrapper, 'provider_token_exchange').diagnostic.credentialFailure, 'federated_credential_missing');
    for (const message of ['PRIVATE', '70025', 'AADSTS999999: PRIVATE', 'AADSTS700211: PRIVATE', 'AADSTS70025suffix']) {
        const result = credentialFailure(new Error(message), 'provider_token_exchange');
        assert.deepEqual(result.diagnostic, {
            credentialStage: 'provider_token_exchange', credentialFailure: 'credential_unavailable', aadstsCode: null,
        });
    }
    const result = new CredentialResolutionError('PRIVATE-STAGE', 'PRIVATE-CAUSE', 'PRIVATE-CODE');
    assert.deepEqual(result.diagnostic, { credentialStage: 'unknown', credentialFailure: 'credential_unavailable', aadstsCode: null });
    const malformed = Object.assign(new Error('PRIVATE'), { error_codes: [{ toString: null }, null, true] });
    assert.equal(credentialFailure(malformed).diagnostic.aadstsCode, null);
});

test('bounded cause traversal preserves a classified hop and cannot loop on cyclic SDK errors', () => {
    const hop = new CredentialResolutionError('managed_identity');
    const wrapped = new Error('PRIVATE', { cause: hop });
    assert.equal(credentialFailure(wrapped, 'provider_token_exchange'), hop);
    const cyclic = new Error('PRIVATE');
    cyclic.cause = cyclic;
    assert.equal(credentialFailure(cyclic).diagnostic.credentialFailure, 'credential_unavailable');
    assert.equal(credentialFailure(new Error('AADSTS70025: PRIVATE'), 'managed_identity').diagnostic.credentialFailure, 'credential_unavailable');
});
