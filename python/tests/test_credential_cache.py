import time
from concurrent.futures import ThreadPoolExecutor
from threading import Event, Lock
from types import SimpleNamespace
from unittest.mock import Mock

import pytest

import src.credentials as credentials_module
from src.config import read_config
from src.credentials import ProviderCredentials
from src.dispatch import DispatchEngine, ProviderRegistry
from src.providers.telesign import TelesignProvider
from src.refreshing_cache import CacheEntry, RefreshingCache, token_entry


def wait_until(predicate):
    deadline = time.monotonic() + 3
    while not predicate():
        assert time.monotonic() < deadline, "background refresh did not reach the expected state"
        time.sleep(0.005)


class Clock:
    def __init__(self):
        self.now = 1700000000.0
        self.timers = []
        self.lock = Lock()

    def schedule(self, seconds, callback):
        timer = SimpleNamespace(at=self.now + seconds, callback=callback, canceled=False)
        timer.cancel = lambda: setattr(timer, "canceled", True)
        with self.lock:
            self.timers.append(timer)
        return timer

    @property
    def options(self):
        return {"clock": lambda: self.now, "schedule": self.schedule, "jitter": lambda: 0}

    @property
    def timer_count(self):
        with self.lock:
            return sum(not timer.canceled for timer in self.timers)

    def advance(self, seconds):
        self.now += seconds
        with self.lock:
            due = [timer for timer in self.timers if not timer.canceled and timer.at <= self.now]
            for timer in due:
                timer.canceled = True
        for timer in due:
            timer.callback()


def test_single_flight_and_scheduled_refresh_do_not_block_valid_cached_values():
    clock = Clock()
    first_started, release_first, refresh_started, release_refresh = Event(), Event(), Event(), Event()
    calls = []

    def load():
        calls.append(clock.now)
        if len(calls) == 1:
            first_started.set()
            assert release_first.wait(3)
            value = "PRIVATE-FIRST"
        else:
            refresh_started.set()
            assert release_refresh.wait(3)
            value = "PRIVATE-NEXT"
        return CacheEntry(value, clock.now + 300, clock.now + 240)

    cache = RefreshingCache(load, **clock.options)
    try:
        with ThreadPoolExecutor(max_workers=10) as pool:
            pending = [pool.submit(cache.get) for _ in range(10)]
            assert first_started.wait(3)
            assert len(calls) == 1
            release_first.set()
            assert all(item.result(3) == "PRIVATE-FIRST" for item in pending)
        clock.advance(240)
        assert refresh_started.wait(3)
        assert cache.get() == "PRIVATE-FIRST"
        release_refresh.set()
        wait_until(lambda: cache.get() == "PRIVATE-NEXT")
        assert len(calls) == 2
        assert clock.timer_count == 1
        assert "PRIVATE" not in repr(cache)
    finally:
        release_first.set()
        release_refresh.set()
        cache.close()
    assert clock.timer_count == 0


def test_failed_refresh_keeps_only_unexpired_entry_and_uses_backoff():
    clock = Clock()
    calls, failures = [], []
    fail = False

    def load():
        calls.append(clock.now)
        if fail:
            raise ValueError("PRIVATE-ERROR")
        return CacheEntry("value", clock.now + 300, clock.now + 240)

    cache = RefreshingCache(load, **clock.options, on_failure=lambda: failures.append("failed"))
    try:
        assert cache.get() == "value"
        fail = True
        clock.advance(240)
        wait_until(lambda: len(failures) == 1)
        assert cache.get() == "value"
        for _ in range(10):
            assert cache.get() == "value"
        assert len(calls) == 2
        clock.advance(60)
        wait_until(lambda: len(failures) == 2)
        with pytest.raises(ValueError, match="provider credential unavailable"):
            cache.get()
        fail = False
        clock.advance(10)
        wait_until(lambda: len(calls) == 4 and cache._inflight is None)
        assert cache.get() == "value"
    finally:
        cache.close()


def test_timed_out_waiter_does_not_cancel_refresh_and_shutdown_blocks_late_publication():
    clock = Clock()
    started, release = Event(), Event()

    def load():
        started.set()
        assert release.wait(3)
        return CacheEntry("late", clock.now + 300, clock.now + 240)

    cache = RefreshingCache(load, **clock.options, wait_timeout=0.02)
    try:
        with pytest.raises(ValueError, match="unavailable"):
            cache.get()
        assert started.is_set()
        future = cache.refresh()
        release.set()
        assert future.result(3) == "late"
        assert cache.get() == "late"
    finally:
        release.set()
        cache.close()
    with pytest.raises(ValueError, match="unavailable"):
        cache.get()
    assert clock.timer_count == 0

    release.clear()
    stopped = RefreshingCache(load, **clock.options)
    pending = stopped.refresh()
    stopped.close()
    release.set()
    with pytest.raises(ValueError, match="unavailable"):
        pending.result(3)
    assert clock.timer_count == 0


def test_token_entry_preserves_real_expiry_and_never_spins_on_sdk_cached_return():
    now = 1700000000
    token = SimpleNamespace(token="PRIVATE-TOKEN", expires_on=now + 3600)
    entry = token_entry(token, now)
    assert (entry.expires_at, entry.refresh_at) == (now + 3570, now + 3300)
    repeated = token_entry(token, now + 3300)
    assert repeated.expires_at == now + 3570
    assert repeated.refresh_at == now + 3360
    token.refresh_on = now + 600
    assert token_entry(token, now).refresh_at == now + 600
    for invalid in (None, SimpleNamespace(token=""), SimpleNamespace(token=" "),
                    SimpleNamespace(token="PRIVATE", expires_on=now + 30),
                    SimpleNamespace(token="PRIVATE", expires_on=float("inf")),
                    SimpleNamespace(token="PRIVATE", expires_on=True)):
        with pytest.raises(ValueError, match="unavailable"):
            token_entry(invalid, now)


def oauth_config():
    return read_config({
        "EPP_PROVIDER_TENANT_ID": "tenant", "EPP_PROVIDER_SCOPE": "api://provider/.default",
        "EPP_OUTBOUND_CLIENT_ID": "app", "EPP_OUTBOUND_MI_CLIENT_ID": "identity",
    })


def test_both_mi_and_provider_token_caches_refresh_independently_and_skip_warm_sdk_calls(monkeypatch):
    clock = Clock()
    identity = Mock(get_token=Mock(side_effect=lambda *args, **kwargs:
        SimpleNamespace(token="PRIVATE-ASSERTION", expires_on=clock.now + 3600)))
    monkeypatch.setattr(credentials_module, "ManagedIdentityCredential", Mock(return_value=identity))
    clients = []

    def create(**kwargs):
        def get_token(*args, **options):
            assert kwargs["func"]() == "PRIVATE-ASSERTION"
            assert kwargs["func"]() == "PRIVATE-ASSERTION"
            return SimpleNamespace(token="PRIVATE-TOKEN", expires_on=clock.now + 3600)
        client = Mock(get_token=Mock(side_effect=get_token))
        clients.append(client)
        return client

    monkeypatch.setattr(credentials_module, "ClientAssertionCredential", create)
    manager = ProviderCredentials(Mock(), cache_options=clock.options)
    config = oauth_config()
    try:
        with ThreadPoolExecutor(max_workers=10) as pool:
            results = list(pool.map(lambda _: manager.resolve({"mode": "oauth"}, config), range(10)))
        assert all(value["access_token"] == "PRIVATE-TOKEN" for value in results)
        assert identity.get_token.call_count == 1 and clients[0].get_token.call_count == 1
        assert manager.resolve({"mode": "oauth"}, config)["access_token"] == "PRIVATE-TOKEN"
        assert identity.get_token.call_count == 1 and clients[0].get_token.call_count == 1
        clock.advance(3300)
        wait_until(lambda: identity.get_token.call_count == 2 and clients[0].get_token.call_count == 2)
        wait_until(lambda: clock.timer_count == 2)
        config.provider_scope = "api://second/.default"
        manager.resolve({"mode": "oauth"}, config)
        assert len(clients) == 1 and clients[0].get_token.call_count == 3
        config.outbound_client_id = "different-app"
        manager.resolve({"mode": "oauth"}, config)
        assert len(clients) == 2
        assert clock.timer_count == 2
    finally:
        manager.close()
    assert clock.timer_count == 0


def test_keyvault_pair_is_parallel_single_flight_and_failed_partial_refresh_retains_old_pair():
    clock = Clock()
    key_started, id_started, release = Event(), Event(), Event()
    calls = []
    version = 1
    fail_identity = False

    def resolve(name):
        calls.append(name)
        (key_started if name == "key" else id_started).set()
        assert release.wait(3)
        if name == "id" and fail_identity:
            raise ValueError("PRIVATE-FAILURE")
        return f"{name}-{version}"

    failures = []
    manager = ProviderCredentials(Mock(resolve=Mock(side_effect=resolve)), cache_options=clock.options,
                                  report_failure=lambda kind: failures.append(kind))
    config = read_config({"KEY_VAULT_URL": "https://unit.vault.azure.net"})
    auth = {"mode": "apiKey", "key_vault_secret_name": "key", "identity_key_vault_secret_name": "id"}
    try:
        with ThreadPoolExecutor(max_workers=2) as pool:
            first = pool.submit(manager.resolve, auth, config)
            second = pool.submit(manager.resolve, auth, config)
            assert key_started.wait(3) and id_started.wait(3)
            release.set()
            assert first.result(3) == second.result(3) == {"mode": "apiKey", "secret": "key-1", "identity": "id-1"}
        assert sorted(calls) == ["id", "key"]
        version = 2
        fail_identity = True
        clock.advance(240)
        wait_until(lambda: failures == ["key_vault"])
        assert manager.resolve(auth, config) == {"mode": "apiKey", "secret": "key-1", "identity": "id-1"}
        fail_identity = False
        clock.advance(5)
        wait_until(lambda: manager.resolve(auth, config)["identity"] == "id-2")
        assert manager.resolve(auth, config)["secret"] == "key-2"
    finally:
        release.set()
        manager.close()


def test_startup_only_prepares_credentials_and_handles_missing_provider_or_failure():
    secrets = Mock(resolve=Mock(return_value="test-key"))
    engine = DispatchEngine(ProviderRegistry([TelesignProvider()]), secrets,
                            {"EPP_PROVIDER_NAME": "telesign", "EPP_PROVIDER_AUTH_MODE": "apiKey"})
    try:
        engine.start_credential_refresh()
        assert secrets.resolve.call_count == 2
        engine.start_credential_refresh()
        assert secrets.resolve.call_count == 2
    finally:
        engine.close()
    no_provider = DispatchEngine(ProviderRegistry([TelesignProvider()]), secrets, {})
    try:
        no_provider.start_credential_refresh()
        assert secrets.resolve.call_count == 2
    finally:
        no_provider.close()
    broken = DispatchEngine(ProviderRegistry([TelesignProvider()]), Mock(resolve=Mock(side_effect=ValueError("PRIVATE"))),
                            {"EPP_PROVIDER_NAME": "telesign"})
    try:
        broken.start_credential_refresh()
    finally:
        broken.close()
