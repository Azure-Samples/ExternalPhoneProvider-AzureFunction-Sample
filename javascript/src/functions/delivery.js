'use strict';

const { inspect } = require('node:util');

class DeliveryContext {
    constructor({ nonce, phoneNumber, message, extension, locale, riskContext }) {
        this.nonce = nonce;
        this.phoneNumber = phoneNumber;
        this.message = message;
        this.extension = extension;
        this.locale = locale;
        this.riskContext = riskContext;
        Object.freeze(this);
    }

    static fromPayload(value) {
        return value && typeof value === 'object' && !Array.isArray(value)
            ? new DeliveryContext(value) : null;
    }

    get isComplete() {
        return [this.nonce, this.phoneNumber, this.message]
            .every((value) => typeof value === 'string' && value.trim().length > 0);
    }

    [inspect.custom]() { return '[DeliveryContext]'; }
}

class OtpDelivery {
    constructor({ phoneNumber, message, channel, messageId, correlationId, locale }) {
        this.phoneNumber = phoneNumber;
        this.message = message;
        this.channel = channel;
        this.messageId = messageId;
        this.correlationId = correlationId;
        this.locale = locale;
        Object.freeze(this);
    }

    [inspect.custom]() { return '[OtpDelivery]'; }
}

module.exports = { DeliveryContext, OtpDelivery };
