'use strict';

const { inspect } = require('node:util');

const SUPPORTED_TYPE = 'microsoft.mfa.otpDeliver.v1';
const CHANNEL = Object.freeze({ SMS: 1, VOICE: 2 });
const MODE = Object.freeze({ LIVE: 1, EVALUATION: 2 });
const CHANNEL_BY_NAME = Object.freeze({ sms: CHANNEL.SMS, voice: CHANNEL.VOICE });
const MODE_BY_NAME = Object.freeze({ live: MODE.LIVE, evaluation: MODE.EVALUATION });

function normalizeEnum(value, names, first, second) {
    if (value === first || value === second) return value;
    if (typeof value === 'string') return names[value.toLowerCase()] || null;
    return null;
}

class EntraSendOtpPayload {
    constructor({ type, tenantId, correlationId, channel, mode, ttlSeconds, encryptedDeliveryContext }) {
        this.type = type;
        this.tenantId = tenantId;
        this.correlationId = correlationId;
        this.channel = channel;
        this.mode = mode;
        this.ttlSeconds = ttlSeconds;
        this.encryptedDeliveryContext = encryptedDeliveryContext;
        Object.freeze(this);
    }

    get channelName() { return this.channel === CHANNEL.VOICE ? 'voice' : 'sms'; }
    get isEvaluation() { return this.mode === MODE.EVALUATION; }
    [inspect.custom]() { return '[EntraSendOtpPayload]'; }
}

function parseEntraPayload(value) {
    if (!value || typeof value !== 'object' || Array.isArray(value)) {
        return { error: 'invalid envelope' };
    }
    if (value.type !== SUPPORTED_TYPE) {
        return { error: 'unsupported envelope type' };
    }
    if (typeof value.encryptedDeliveryContext !== 'string'
        || !value.encryptedDeliveryContext.trim()) {
        return { error: 'encryptedDeliveryContext is required' };
    }
    const channel = normalizeEnum(value.channel, CHANNEL_BY_NAME, CHANNEL.SMS, CHANNEL.VOICE);
    if (!channel) return { error: 'unsupported channel' };
    const mode = normalizeEnum(value.mode, MODE_BY_NAME, MODE.LIVE, MODE.EVALUATION);
    if (!mode) return { error: 'unsupported mode' };
    if (Object.hasOwn(value, 'ttlSeconds')) {
        if (!Number.isInteger(value.ttlSeconds) || value.ttlSeconds > 2147483647) {
            return { error: 'invalid ttlSeconds' };
        }
        if (value.ttlSeconds <= 0) return { error: 'ttlSeconds expired' };
    }
    return {
        payload: new EntraSendOtpPayload({
            ...value,
            channel,
            mode,
        }),
    };
}

module.exports = { EntraSendOtpPayload, parseEntraPayload, CHANNEL, MODE, SUPPORTED_TYPE };
