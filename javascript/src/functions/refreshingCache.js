// Copyright (c) Microsoft Corporation. All rights reserved.
'use strict';

const { inspect } = require('node:util');

const CACHE_POLICY = Object.freeze({
    acquisitionTimeoutMs: 2500,
    secretTtlMs: 5 * 60 * 1000,
    secretRefreshIntervalMs: 4 * 60 * 1000,
    secretExpiryRefreshLeadMs: 30 * 1000,
    tokenExpirySkewMs: 30 * 1000,
    tokenRefreshLeadMs: 5 * 60 * 1000,
    minRefreshDelayMs: 1000,
    maxRefreshDelayMs: 60 * 1000,
    initialRetryDelayMs: 5000,
    maxRetryDelayMs: 60 * 1000,
    maxRetryExponent: 4,
    retryJitterRatio: 0.2,
    maxTimerDelayMs: 2 ** 31 - 1,
});

/**
 * @template T
 * @typedef {object} CacheEntry
 * @property {T} value
 * @property {number} expiresAt Absolute Unix time in milliseconds.
 * @property {number} refreshAt Absolute Unix time in milliseconds.
 */

/**
 * @typedef {object} CacheOptions
 * @property {() => number} [now] Unix time in milliseconds.
 * @property {typeof setTimeout} [schedule]
 * @property {typeof clearTimeout} [cancel]
 * @property {() => number} [random]
 * @property {() => void} [onFailure]
 */

const unavailable = () => new Error('provider credential unavailable');

/** @template T */
class RefreshingCache {
    /**
     * @param {(signal: AbortSignal) => Promise<CacheEntry<T>>} load
     * @param {CacheOptions} [options]
     */
    constructor(load, { now = Date.now, schedule = setTimeout, cancel = clearTimeout,
        random = Math.random, onFailure = () => {} } = {}) {
        this.load = load;
        this.now = now;
        this.schedule = schedule;
        this.cancel = cancel;
        this.random = random;
        this.onFailure = onFailure;
        /** @type {CacheEntry<T> | null} */
        this.entry = null;
        /** @type {Promise<T> | null} */
        this.inFlight = null;
        /** @type {ReturnType<typeof setTimeout> | null} */
        this.timer = null;
        this.retryAt = 0;
        this.failures = 0;
        this.closed = false;
        /** @type {AbortController | null} */
        this.controller = null;
    }

    [inspect.custom]() { return '[RefreshingCache]'; }
    toJSON() { return '[RefreshingCache]'; }

    get() {
        if (this.closed) return Promise.reject(unavailable());
        if (this.entry && this.entry.expiresAt > this.now()) {
            if (this.entry.refreshAt <= this.now() && this.retryAt <= this.now()) {
                this.refreshInBackground();
            }
            return Promise.resolve(this.entry.value);
        }
        if (this.inFlight) return this.inFlight;
        if (this.retryAt > this.now()) return Promise.reject(unavailable());
        return this.refresh();
    }

    refresh() {
        if (this.closed) return Promise.reject(unavailable());
        if (this.inFlight) return this.inFlight;
        if (this.retryAt > this.now()) return Promise.reject(unavailable());
        this.clearTimer();
        this.controller = new AbortController();
        const controller = this.controller;
        // Publish the promise before calling a loader that may synchronously reenter the cache.
        const operation = Promise.resolve().then(() => this.load(controller.signal)).then((entry) => {
            if (this.closed || controller.signal.aborted) throw unavailable();
            if (!entry || !Number.isFinite(entry.expiresAt) || entry.expiresAt <= this.now()
                || !Number.isFinite(entry.refreshAt)) throw unavailable();
            this.entry = entry;
            this.failures = 0;
            this.retryAt = 0;
            return entry.value;
        }).catch(() => {
            if (!this.closed) {
                this.failures++;
                const exponent = Math.min(this.failures - 1, CACHE_POLICY.maxRetryExponent);
                const backoff = Math.min(CACHE_POLICY.maxRetryDelayMs, CACHE_POLICY.initialRetryDelayMs * 2 ** exponent);
                this.retryAt = this.now() + Math.floor(backoff * (1 + this.random() * CACHE_POLICY.retryJitterRatio));
                this.onFailure();
            }
            throw unavailable();
        }).finally(() => {
            this.inFlight = null;
            this.controller = null;
            if (!this.closed) {
                const next = this.retryAt || this.entry?.refreshAt;
                if (next != null) this.arm(next);
            }
        });
        this.inFlight = operation;
        return operation;
    }

    refreshInBackground() {
        if (!this.closed && this.retryAt > this.now()) {
            this.arm(this.retryAt);
            return;
        }
        // refresh reports its failure; a timer has no request waiting to handle the rejection.
        void this.refresh().catch(() => {});
    }

    /** @param {number} at Absolute Unix time in milliseconds. */
    arm(at) {
        this.clearTimer();
        this.timer = this.schedule(() => {
            this.timer = null;
            this.refreshInBackground();
        }, Math.max(CACHE_POLICY.minRefreshDelayMs, Math.min(CACHE_POLICY.maxTimerDelayMs, at - this.now())));
        this.timer?.unref?.();
    }

    clearTimer() {
        if (this.timer !== null) this.cancel(this.timer);
        this.timer = null;
    }

    close() {
        this.closed = true;
        this.clearTimer();
        this.controller?.abort();
        this.entry = null;
    }
}

/**
 * @param {import('@azure/core-auth').AccessToken | null | undefined} token
 * @param {number} now Unix time in milliseconds.
 * @returns {CacheEntry<import('@azure/core-auth').AccessToken>}
 */
function tokenEntry(token, now) {
    if (typeof token?.token !== 'string' || !token.token.trim()
        || !Number.isFinite(token.expiresOnTimestamp) || token.expiresOnTimestamp <= now + CACHE_POLICY.tokenExpirySkewMs) {
        throw unavailable();
    }
    const expiresAt = token.expiresOnTimestamp - CACHE_POLICY.tokenExpirySkewMs;
    let refreshAt = token.expiresOnTimestamp - CACHE_POLICY.tokenRefreshLeadMs;
    if (typeof token.refreshAfterTimestamp === 'number' && Number.isFinite(token.refreshAfterTimestamp)) {
        refreshAt = Math.min(refreshAt, token.refreshAfterTimestamp);
    }
    // An SDK may return its existing token on refresh. Never extend that token's lifetime or spin.
    if (refreshAt <= now) {
        const delay = Math.min(CACHE_POLICY.maxRefreshDelayMs, (expiresAt - now) / 2);
        refreshAt = now + Math.max(CACHE_POLICY.minRefreshDelayMs, delay);
    }
    return { value: token, expiresAt, refreshAt };
}

module.exports = { CACHE_POLICY, RefreshingCache, tokenEntry };
