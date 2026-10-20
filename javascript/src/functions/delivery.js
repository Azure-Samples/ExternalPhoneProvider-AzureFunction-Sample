'use strict';

const { inspect } = require('node:util');

class DeliveryContext {
    constructor({ nonce, phoneNumber, message, otp, extension, locale, riskContext }) {
        this.nonce = nonce;
        this.phoneNumber = phoneNumber;
        this.message = message;
        this.otp = otp;
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
            .every((value) => typeof value === 'string' && value.trim().length > 0)
            && (this.otp == null || typeof this.otp === 'string')
            && (this.riskContext == null
                || (typeof this.riskContext === 'object' && !Array.isArray(this.riskContext)));
    }

    [inspect.custom]() { return '[DeliveryContext]'; }
}

class OtpDelivery {
    constructor({ phoneNumber, message, otp, channel, messageId, correlationId, locale, riskContext }) {
        this.phoneNumber = phoneNumber;
        this.message = message;
        this.otp = otp;
        this.channel = channel;
        this.messageId = messageId;
        this.correlationId = correlationId;
        this.locale = locale;
        this.riskContext = riskContext;
        Object.freeze(this);
    }

    [inspect.custom]() { return '[OtpDelivery]'; }
}

module.exports = { DeliveryContext, OtpDelivery };
