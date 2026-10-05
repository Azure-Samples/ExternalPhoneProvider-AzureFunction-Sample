'use strict';

const OUTCOME = Object.freeze({ CONTINUE: 'Continue', FAIL: 'Fail', BLOCK: 'Block' });

function endpointHttpStatus(outcome, providerHttpStatus) {
    if (outcome === OUTCOME.CONTINUE) return 200;
    if (outcome === OUTCOME.BLOCK) return 403;
    if (providerHttpStatus === 429) return 429;
    if (providerHttpStatus === 401 || providerHttpStatus === 403) return 401;
    if (providerHttpStatus >= 400 && providerHttpStatus < 500) return 400;
    return 502;
}

function classifyFailure({ providerHttpStatus, outcome, statusRecognized, validJson = true }) {
    if (!validJson) return 'invalid_provider_json';
    if (providerHttpStatus < 200 || providerHttpStatus >= 300) return 'provider_http_error';
    if (outcome !== OUTCOME.FAIL) return null;
    return statusRecognized ? 'provider_rejected' : 'unrecognized_provider_status';
}

class ProviderResult {
    constructor({ outcome, statusRecognized, providerHttpStatus, providerMessageId = null,
        providerStatusName = null, providerStatusCode = null, providerStatusDescription = null,
        failureReason = null, httpStatus = endpointHttpStatus(outcome, providerHttpStatus) }) {
        this.outcome = outcome;
        this.statusRecognized = statusRecognized;
        this.providerHttpStatus = providerHttpStatus;
        this.providerMessageId = providerMessageId;
        this.providerStatusName = providerStatusName;
        this.providerStatusCode = providerStatusCode;
        this.providerStatusDescription = providerStatusDescription;
        this.failureReason = failureReason;
        this.httpStatus = httpStatus;
        Object.freeze(this);
    }

    toString() { return 'ProviderResult'; }
}

module.exports = { OUTCOME, ProviderResult, endpointHttpStatus, classifyFailure };
