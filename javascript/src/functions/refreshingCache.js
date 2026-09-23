// Copyright (c) Microsoft Corporation. All rights reserved.
'use strict';

const { inspect } = require('node:util');

const unavailable = () => new Error('provider credential unavailable');

class RefreshingCache {
    constructor(load, { now = Date.now, schedule = setTimeout, cancel = clearTimeout,
        random = Math.random, onFailure = () => {} } = {}) {
        this.load = load;
        this.now = now;
        this.schedule = schedule;
        this.cancel = cancel;
        this.random = random;
        this.onFailure = onFailure;
        this.entry = null;
        this.inFlight = null;
        this.timer = null;
        this.retryAt = 0;
        this.failures = 0;
        this.closed = false;
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
                const backoff = Math.min(60000, 5000 * 2 ** Math.min(this.failures - 1, 4));
                this.retryAt = this.now() + Math.floor(backoff * (1 + this.random() * 0.2));
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

    arm(at) {
        this.clearTimer();
        this.timer = this.schedule(() => {
            this.timer = null;
            this.refreshInBackground();
        }, Math.max(1000, Math.min(2147483647, at - this.now())));
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

function tokenEntry(token, now) {
    if (typeof token?.token !== 'string' || !token.token.trim()
        || !Number.isFinite(token.expiresOnTimestamp) || token.expiresOnTimestamp <= now + 30000) {
        throw unavailable();
    }
    const expiresAt = token.expiresOnTimestamp - 30000;
    let refreshAt = token.expiresOnTimestamp - 300000;
    if (Number.isFinite(token.refreshAfterTimestamp)) refreshAt = Math.min(refreshAt, token.refreshAfterTimestamp);
    // An SDK may return its existing token on refresh. Never extend that token's lifetime or spin.
    if (refreshAt <= now) refreshAt = now + Math.max(1000, Math.min(60000, (expiresAt - now) / 2));
    return { value: token, expiresAt, refreshAt };
}

module.exports = { RefreshingCache, tokenEntry };
