'use strict';

const STAGES = new Set(['unknown', 'configuration', 'managed_identity', 'provider_token_exchange', 'key_vault']);
const FAILURES = new Set(['credential_unavailable', 'configuration_invalid', 'timeout', 'cancelled',
    'federated_credential_missing', 'federated_credential_mismatch', 'provider_application_not_found']);
const CODES = new Map([
    ['70025', 'federated_credential_missing'],
    ['70021', 'federated_credential_mismatch'],
    ['700016', 'provider_application_not_found'],
]);
const CODE_PATTERN = /\bAADSTS(70025|70021|700016)\b/i;

class CredentialResolutionError extends Error {
    constructor(stage = 'unknown', failure = 'credential_unavailable', code = null) {
        super('provider credential unavailable');
        Object.defineProperty(this, 'diagnostic', { value: Object.freeze({
            credentialStage: STAGES.has(stage) ? stage : 'unknown',
            credentialFailure: FAILURES.has(failure) ? failure : 'credential_unavailable',
            aadstsCode: CODES.has(code) ? code : null,
        }) });
    }
}

function credentialFailure(error, stage = 'unknown') {
    const pending = [error];
    const seen = new Set();
    let code = null;
    let messageCode = null;
    let interrupted = null;
    while (pending.length && seen.size < 8) {
        const current = pending.shift();
        if (!current || typeof current !== 'object' || seen.has(current)) continue;
        seen.add(current);
        if (current instanceof CredentialResolutionError) return current;
        const structured = current.errorResponse?.error_codes ?? current.errorResponse?.errorCodes
            ?? current.error_codes ?? current.errorCodes;
        if (!code && Array.isArray(structured)) {
            const value = structured.slice(0, 8).find((item) =>
                (typeof item === 'number' || typeof item === 'string') && CODES.has(String(item)));
            if (value !== undefined) code = String(value);
        }
        for (const message of [current.message, current.errorMessage]) {
            if (!messageCode && typeof message === 'string') {
                messageCode = CODE_PATTERN.exec(message.slice(0, 8192))?.[1] ?? null;
            }
        }
        if (current.name === 'TimeoutError') interrupted = 'timeout';
        else if (!interrupted && current.name === 'AbortError') interrupted = 'cancelled';
        pending.push(current.cause, current.innerError);
        if (Array.isArray(current.errors)) pending.push(...current.errors.slice(0, 8));
    }
    code ??= messageCode;
    const failure = stage === 'configuration' ? 'configuration_invalid'
        : stage === 'provider_token_exchange' && code ? CODES.get(code)
        : interrupted || 'credential_unavailable';
    // Keep only fixed diagnostics; SDK exceptions can contain assertions, tokens and response bodies.
    return new CredentialResolutionError(stage, failure, code);
}

module.exports = { CredentialResolutionError, credentialFailure };
