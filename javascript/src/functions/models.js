'use strict';

const { inspect } = require('node:util');

/**
 * Validated routing metadata, constructed only after envelope validation.
 * @typedef {Object} Envelope
 * @property {string} type
 * @property {*} tenantId
 * @property {*} correlationId
 * @property {number} channel
 * @property {number} mode
 * @property {number|undefined} ttlSeconds
 * @property {string} encryptedDeliveryContext
 */

/**
 * Provider-neutral delivery request. Message text is never rewritten.
 * @typedef {Object} DispatchRequest
 * @property {string} destination
 * @property {string} message
 * @property {string} channel
 * @property {string} messageId
 * @property {*} correlationId
 * @property {*} locale
 */

class DeliveryContext {
    constructor({ nonce, phoneNumber, message, extension, locale, riskContext }) {
        this.nonce = nonce;
        this.phoneNumber = phoneNumber;
        this.message = message;
        this.extension = extension;
        this.locale = locale;
        this.riskContext = riskContext;
    }

    static fromPayload(payload) {
        return payload && typeof payload === 'object' && !Array.isArray(payload)
            ? new DeliveryContext(payload) : null;
    }

    get isComplete() {
        return [this.nonce, this.phoneNumber, this.message]
            .every(value => typeof value === 'string' && value.trim().length > 0);
    }

    [inspect.custom]() { return '[DeliveryContext]'; }
}

// Adapter-normalized result for outcome mapping, not a public HTTP response.
class ParsedResponse {
    /**
     * @param {Object} fields
     * @param {boolean} fields.success
     * @param {number} fields.providerHttpStatus
     * @param {string|null} [fields.providerMessageId]
     * @param {string|null} [fields.providerStatusName]
     * @param {string|null} [fields.providerStatusCode]
     * @param {string|null} [fields.providerStatusDescription]
     */
    constructor({ success, providerHttpStatus, providerMessageId = null,
        providerStatusName = null, providerStatusCode = null, providerStatusDescription = null }) {
        this.success = success;
        this.providerHttpStatus = providerHttpStatus;
        this.providerMessageId = providerMessageId;
        this.providerStatusName = providerStatusName;
        this.providerStatusCode = providerStatusCode;
        this.providerStatusDescription = providerStatusDescription;
    }

    [inspect.custom]() { return '[ParsedResponse]'; }
}

module.exports = { DeliveryContext, ParsedResponse };
