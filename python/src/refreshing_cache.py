import math
import random
import threading
import time
from concurrent.futures import Future, TimeoutError
from dataclasses import dataclass


@dataclass(repr=False)
class CacheEntry:
    value: object
    expires_at: float
    refresh_at: float


def _schedule(delay, callback):
    timer = threading.Timer(delay, callback)
    timer.daemon = True
    timer.start()
    return timer


class RefreshingCache:
    def __init__(self, load, *, clock=time.time, schedule=_schedule, jitter=random.random,
                 on_failure=lambda: None, wait_timeout=2.5):
        self._load = load
        self._clock = clock
        self._schedule = schedule
        self._jitter = jitter
        self._on_failure = on_failure
        self._wait_timeout = wait_timeout
        self._lock = threading.RLock()
        self._entry = None
        self._inflight = None
        self._timer = None
        self._retry_at = 0
        self._failures = 0
        self._closed = False

    def get(self):
        with self._lock:
            if self._closed:
                raise ValueError("provider credential unavailable")
            now = self._clock()
            if self._entry and self._entry.expires_at > now:
                if self._entry.refresh_at <= now and self._retry_at <= now:
                    self._begin_refresh()
                return self._entry.value
            if self._inflight is None and self._retry_at > now:
                raise ValueError("provider credential unavailable")
            future = self._begin_refresh()
        try:
            return future.result(timeout=self._wait_timeout)
        except TimeoutError:
            # A waiter does not cancel the shared refresh needed by other requests.
            raise ValueError("provider credential unavailable") from None

    def refresh(self):
        with self._lock:
            if self._closed or self._retry_at > self._clock():
                raise ValueError("provider credential unavailable")
            return self._begin_refresh()

    def _begin_refresh(self):
        if self._inflight is not None:
            return self._inflight
        if self._timer is not None:
            self._timer.cancel()
            self._timer = None
        future = Future()
        self._inflight = future
        threading.Thread(target=self._run_refresh, args=(future,), daemon=True).start()
        return future

    def _run_refresh(self, future):
        entry = None
        failed = False
        try:
            entry = self._load()
            if (not isinstance(entry, CacheEntry) or not math.isfinite(entry.expires_at)
                    or entry.expires_at <= self._clock() or not math.isfinite(entry.refresh_at)):
                raise ValueError("provider credential unavailable")
        except Exception:
            failed = True
        with self._lock:
            if self._closed:
                if not future.done():
                    future.set_exception(ValueError("provider credential unavailable"))
                self._inflight = None
                return
            if failed:
                self._failures += 1
                backoff = min(60, 5 * 2 ** min(self._failures - 1, 4))
                self._retry_at = self._clock() + backoff * (1 + self._jitter() * 0.2)
                self._on_failure()
            else:
                self._entry = entry
                self._failures = 0
                self._retry_at = 0
            self._inflight = None
            next_refresh = self._retry_at if failed else entry.refresh_at
            self._timer = self._schedule(max(1, next_refresh - self._clock()), self._scheduled_refresh)
            if failed:
                future.set_exception(ValueError("provider credential unavailable"))
            else:
                future.set_result(entry.value)

    def _scheduled_refresh(self):
        with self._lock:
            self._timer = None
            if not self._closed:
                self._begin_refresh()

    def close(self):
        with self._lock:
            self._closed = True
            if self._timer is not None:
                self._timer.cancel()
                self._timer = None
            self._entry = None


def token_entry(token, now):
    value = getattr(token, "token", None)
    expiry = getattr(token, "expires_on", None)
    if (not isinstance(value, str) or not value.strip() or type(expiry) not in (int, float)
            or not math.isfinite(expiry) or expiry <= now + 30):
        raise ValueError("provider credential unavailable")
    expires_at = expiry - 30
    refresh_at = expiry - 300
    hint = getattr(token, "refresh_on", None)
    if type(hint) in (int, float) and math.isfinite(hint):
        refresh_at = min(refresh_at, hint)
    if refresh_at <= now:
        refresh_at = now + max(1, min(60, (expires_at - now) / 2))
    return CacheEntry(token, expires_at, refresh_at)
