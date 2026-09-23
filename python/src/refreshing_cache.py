from __future__ import annotations

import math
import random
import threading
import time
from collections.abc import Callable
from concurrent.futures import Future, TimeoutError
from dataclasses import dataclass
from typing import Generic, Protocol, TypedDict, TypeVar

ACQUISITION_TIMEOUT_SECONDS = 2.5
SECRET_TTL_SECONDS = 5 * 60
SECRET_REFRESH_INTERVAL_SECONDS = 4 * 60
TOKEN_EXPIRY_SKEW_SECONDS = 30
TOKEN_REFRESH_LEAD_SECONDS = 5 * 60
MIN_REFRESH_DELAY_SECONDS = 1
MAX_REFRESH_DELAY_SECONDS = 60
INITIAL_RETRY_DELAY_SECONDS = 5
MAX_RETRY_DELAY_SECONDS = 60
MAX_RETRY_EXPONENT = 4
RETRY_JITTER_RATIO = 0.2
MAX_TIMER_DELAY_SECONDS = (2 ** 31 - 1) / 1000

T = TypeVar("T")


class Token(Protocol):
    @property
    def token(self) -> str: ...

    @property
    def expires_on(self) -> float: ...


class ScheduledCall(Protocol):
    def cancel(self) -> None: ...


class CacheOptions(TypedDict, total=False):
    clock: Callable[[], float]
    schedule: Callable[[float, Callable[[], None]], ScheduledCall]
    jitter: Callable[[], float]
    on_failure: Callable[[], None]
    wait_timeout: float


@dataclass(repr=False)
class CacheEntry(Generic[T]):
    value: T
    expires_at: float
    refresh_at: float


def _schedule(delay: float, callback: Callable[[], None]) -> ScheduledCall:
    timer = threading.Timer(delay, callback)
    timer.daemon = True
    timer.start()
    return timer


class RefreshingCache(Generic[T]):
    def __init__(
        self,
        load: Callable[[], CacheEntry[T]],
        *,
        clock: Callable[[], float] = time.time,
        schedule: Callable[[float, Callable[[], None]], ScheduledCall] = _schedule,
        jitter: Callable[[], float] = random.random,
        on_failure: Callable[[], None] = lambda: None,
        wait_timeout: float = ACQUISITION_TIMEOUT_SECONDS,
    ) -> None:
        self._load = load
        self._clock = clock
        self._schedule = schedule
        self._jitter = jitter
        self._on_failure = on_failure
        self._wait_timeout = wait_timeout
        self._lock = threading.RLock()
        self._entry: CacheEntry[T] | None = None
        self._inflight: Future[T] | None = None
        self._timer: ScheduledCall | None = None
        self._retry_at = 0
        self._failures = 0
        self._closed = False

    def get(self) -> T:
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

    def refresh(self) -> Future[T]:
        with self._lock:
            if self._closed or self._retry_at > self._clock():
                raise ValueError("provider credential unavailable")
            return self._begin_refresh()

    def _begin_refresh(self) -> Future[T]:
        if self._inflight is not None:
            return self._inflight
        if self._timer is not None:
            self._timer.cancel()
            self._timer = None
        future: Future[T] = Future()
        self._inflight = future
        threading.Thread(target=self._run_refresh, args=(future,), daemon=True).start()
        return future

    def _run_refresh(self, future: Future[T]) -> None:
        with self._lock:
            if self._closed:
                self._inflight = None
                return
        entry: CacheEntry[T] | None = None
        try:
            entry = self._load()
            if (not isinstance(entry, CacheEntry) or not math.isfinite(entry.expires_at)
                    or entry.expires_at <= self._clock() or not math.isfinite(entry.refresh_at)):
                raise ValueError("provider credential unavailable")
        except Exception:
            entry = None
        with self._lock:
            if self._closed:
                if not future.done():
                    future.set_exception(ValueError("provider credential unavailable"))
                self._inflight = None
                return
            if entry is None:
                self._failures += 1
                exponent = min(self._failures - 1, MAX_RETRY_EXPONENT)
                backoff = min(MAX_RETRY_DELAY_SECONDS, INITIAL_RETRY_DELAY_SECONDS * 2 ** exponent)
                self._retry_at = self._clock() + backoff * (1 + self._jitter() * RETRY_JITTER_RATIO)
                self._on_failure()
            else:
                self._entry = entry
                self._failures = 0
                self._retry_at = 0
            self._inflight = None
            next_refresh = self._retry_at if entry is None else entry.refresh_at
            delay = min(MAX_TIMER_DELAY_SECONDS, next_refresh - self._clock())
            self._timer = self._schedule(max(MIN_REFRESH_DELAY_SECONDS, delay), self._scheduled_refresh)
            if entry is None:
                future.set_exception(ValueError("provider credential unavailable"))
            else:
                future.set_result(entry.value)

    def _scheduled_refresh(self) -> None:
        with self._lock:
            self._timer = None
            if not self._closed:
                self._begin_refresh()

    def close(self) -> None:
        with self._lock:
            self._closed = True
            if self._timer is not None:
                self._timer.cancel()
                self._timer = None
            self._entry = None
            if self._inflight is not None and not self._inflight.done():
                self._inflight.set_exception(ValueError("provider credential unavailable"))


def token_entry(token: Token, now: float) -> CacheEntry[Token]:
    value = getattr(token, "token", None)
    expiry = getattr(token, "expires_on", None)
    if (not isinstance(value, str) or not value.strip()
            or not isinstance(expiry, (int, float)) or isinstance(expiry, bool)
            or not math.isfinite(expiry) or expiry <= now + TOKEN_EXPIRY_SKEW_SECONDS):
        raise ValueError("provider credential unavailable")
    expires_at = expiry - TOKEN_EXPIRY_SKEW_SECONDS
    refresh_at = expiry - TOKEN_REFRESH_LEAD_SECONDS
    hint = getattr(token, "refresh_on", None)
    if isinstance(hint, (int, float)) and not isinstance(hint, bool) and math.isfinite(hint):
        refresh_at = min(refresh_at, hint)
    if refresh_at <= now:
        delay = min(MAX_REFRESH_DELAY_SECONDS, (expires_at - now) / 2)
        refresh_at = now + max(MIN_REFRESH_DELAY_SECONDS, delay)
    return CacheEntry(token, expires_at, refresh_at)
