import subprocess
import sys
import textwrap
import time
from concurrent.futures import ThreadPoolExecutor
from threading import Event
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock

import pytest

import src.credentials as credentials_module
from src.config import read_config
from src.credentials import ApiKeyCache, AccessTokenCache, ProviderCredentials
from src.dispatch import DispatchEngine, ProviderRegistry
from src.providers.telesign import TelesignProvider

AUTH = {"mode": "apiKey", "key_vault_secret_name": "key", "identity_key_vault_secret_name": "id"}
CONFIG = read_config({"KEY_VAULT_URL": "https://unit.vault.azure.net"})


def wait_until(predicate):
    deadline = time.monotonic() + 3
    while not predicate():
        assert time.monotonic() < deadline, "background refresh did not reach the expected state"
        time.sleep(0.005)


class Clock:
    def __init__(self):
        self.now = 1700000000.0

    @property
    def options(self):
        return {"clock": lambda: self.now}

    def advance(self, seconds):
        self.now += seconds


def test_library_cache_shares_parallel_reads_and_serves_a_complete_pair_during_refresh(monkeypatch):
    clock = Clock()
    key_started, id_started, release = Event(), Event(), Event()
    version = 1

    def read(name):
        (key_started if name == "key" else id_started).set()
        assert release.wait(3)
        return f"PRIVATE-{name}-{version}"

    secrets = Mock(resolve=Mock(side_effect=read))
    oauth = Mock(side_effect=AssertionError("API-key mode must not create an OAuth credential"))
    monkeypatch.setattr(credentials_module, "ClientAssertionCredential", oauth)
    manager = ProviderCredentials(secrets, cache_options=clock.options)
    try:
        with ThreadPoolExecutor(max_workers=10) as pool:
            pending = [pool.submit(manager.resolve, AUTH, CONFIG) for _ in range(10)]
            assert key_started.wait(3) and id_started.wait(3)
            assert secrets.resolve.call_count == 2
            release.set()
            assert all(item.result(3)["secret"] == "PRIVATE-key-1" for item in pending)
        assert isinstance(manager.cache, ApiKeyCache)
        oauth.assert_not_called()
        release.clear()
        version = 2
        clock.advance(240)
        pending = manager.refresh()
        wait_until(lambda: secrets.resolve.call_count == 4)
        assert manager.resolve(AUTH, CONFIG)["identity"] == "PRIVATE-id-1"
        release.set()
        pending.result(timeout=3)
        assert manager.resolve(AUTH, CONFIG)["secret"] == "PRIVATE-key-2"
        assert manager.resolve(AUTH, CONFIG)["identity"] == "PRIVATE-id-2"
        assert "PRIVATE" not in repr(manager) + repr(manager.cache)
    finally:
        release.set()
        manager.close()
    assert manager.cache.get() is None


def test_failed_refresh_never_extends_ttl_or_publishes_a_partial_pair():
    clock = Clock()
    fail = False
    failures = []

    def read(name):
        if fail and name == "id":
            raise ValueError("PRIVATE-ERROR")
        return name

    secrets = Mock(resolve=Mock(side_effect=read))
    manager = ProviderCredentials(secrets, cache_options=clock.options, report_failure=failures.append)
    try:
        manager.resolve(AUTH, CONFIG)
        fail = True
        clock.advance(240)
        with pytest.raises(ValueError, match="unavailable"):
            manager.refresh().result(timeout=3)
        wait_until(lambda: failures == ["key_vault"])
        for _ in range(10):
            assert manager.resolve(AUTH, CONFIG)["identity"] == "id"
        assert secrets.resolve.call_count == 4
        clock.advance(60)
        with pytest.raises(ValueError, match="unavailable"):
            manager.refresh().result(timeout=3)
        wait_until(lambda: len(failures) == 2)
        for _ in range(10):
            with pytest.raises(ValueError, match="unavailable"):
                manager.resolve(AUTH, CONFIG)
        assert secrets.resolve.call_count == 6
        for delay in (30, 30, 30, 30, 30):
            calls = secrets.resolve.call_count
            clock.advance(delay - 0.5)
            with pytest.raises(ValueError, match="unavailable"):
                manager.resolve(AUTH, CONFIG)
            assert secrets.resolve.call_count == calls
            clock.advance(0.5)
            with pytest.raises(ValueError, match="unavailable"):
                manager.refresh().result(timeout=3)
            assert secrets.resolve.call_count == calls + 2
        fail = False
        clock.advance(30)
        manager.refresh().result(timeout=3)
        assert manager.resolve(AUTH, CONFIG)["secret"] == "key"
        assert secrets.resolve.call_count == 18
    finally:
        manager.close()


def test_waiter_timeouts_and_partial_failures_do_not_start_overlapping_secret_reads():
    clock = Clock()
    started, release = Event(), Event()
    calls = []

    def read(name):
        calls.append(name)
        if name == "key":
            raise ValueError("PRIVATE-FAILURE")
        started.set()
        assert release.wait(3)
        return "PRIVATE-IDENTITY"

    manager = ProviderCredentials(Mock(resolve=read), cache_options={**clock.options, "wait_timeout": 0.02},
                                  report_failure=lambda _: None)
    try:
        for _ in range(3):
            with pytest.raises(ValueError, match="unavailable"):
                manager.resolve(AUTH, CONFIG)
            clock.advance(60)
        assert started.is_set()
        assert sorted(calls) == ["id", "key"]
        pending = manager.refresh()
        manager.close()
        with pytest.raises(ValueError, match="unavailable"):
            pending.result(timeout=0.1)
        release.set()
        with pytest.raises(ValueError, match="unavailable"):
            manager.resolve(AUTH, CONFIG)
        assert manager.cache.get() is None
    finally:
        manager.close()
        release.set()


def test_access_token_cache_uses_sdk_refresh_metadata_and_preserves_original_expiry(monkeypatch):
    clock = Clock()
    expiry = clock.now + 3600
    identity = Mock(spec=["get_token", "get_token_info"], get_token_info=Mock(
        side_effect=lambda _: SimpleNamespace(token="PRIVATE-ASSERTION", expires_on=expiry, refresh_on=clock.now + 10)))
    monkeypatch.setattr(credentials_module, "ManagedIdentityCredential", Mock(return_value=identity))
    clients = []

    def create(**kwargs):
        def get_token_info(_):
            assert kwargs["func"]() == "PRIVATE-ASSERTION"
            return SimpleNamespace(token="PRIVATE-TOKEN", expires_on=expiry, refresh_on=clock.now + 10)
        client = Mock(spec=["get_token", "get_token_info"], get_token_info=Mock(side_effect=get_token_info))
        clients.append(client)
        return client

    monkeypatch.setattr(credentials_module, "ClientAssertionCredential", create)
    secrets = Mock(resolve=Mock(side_effect=AssertionError("OAuth must not read Key Vault")))
    manager = ProviderCredentials(secrets, cache_options=clock.options, report_failure=lambda _: None)
    config = read_config({"EPP_PROVIDER_TENANT_ID": "tenant", "EPP_OUTBOUND_CLIENT_ID": "app",
                          "EPP_OUTBOUND_MI_CLIENT_ID": "identity", "EPP_PROVIDER_SCOPE": "scope"})
    try:
        with ThreadPoolExecutor(max_workers=10) as pool:
            results = list(pool.map(lambda _: manager.resolve({"mode": "oauth"}, config), range(10)))
        assert all(value["access_token"] == "PRIVATE-TOKEN" for value in results)
        assert clients[0].get_token_info.call_count == 1
        assert identity.get_token_info.call_count == 2  # Warmup plus the SDK callback, not HTTP requests.
        assert isinstance(manager.cache, AccessTokenCache)
        secrets.resolve.assert_not_called()
        manager.resolve({"mode": "oauth"}, config)
        assert clients[0].get_token_info.call_count == 1
        clock.advance(30)
        manager.refresh().result(timeout=3)
        assert clients[0].get_token_info.call_count == 2
        identity.get_token.assert_not_called()
        clients[0].get_token.assert_not_called()
        assert len(clients) == 1
        clock.advance(3540)
        with pytest.raises(ValueError, match="unavailable"):
            manager.refresh().result(timeout=3)
        with pytest.raises(ValueError, match="unavailable"):
            manager.resolve({"mode": "oauth"}, config)
    finally:
        manager.close()


def test_startup_only_prepares_credentials_and_shutdown_is_terminal():
    secrets = Mock(resolve=Mock(return_value="test-key"))
    engine = DispatchEngine(ProviderRegistry([TelesignProvider()]), secrets,
                            {"EPP_PROVIDER_NAME": "telesign", "EPP_PROVIDER_AUTH_MODE": "apiKey"})
    try:
        engine.start_credential_refresh()
        engine.start_credential_refresh()
        assert secrets.resolve.call_count == 2
    finally:
        engine.close()
    with pytest.raises(ValueError, match="unavailable"):
        engine._credentials.resolve(AUTH, CONFIG)
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


def test_configuration_changes_require_a_new_worker_and_stopped_cache_cannot_restart():
    secrets = Mock(resolve=Mock(return_value="key"))
    manager = ProviderCredentials(secrets)
    manager.resolve(AUTH, CONFIG)
    manager.close()
    other = read_config({"KEY_VAULT_URL": "https://other.vault.azure.net"})
    manager = ProviderCredentials(secrets)
    manager.resolve(AUTH, other)
    assert secrets.resolve.call_count == 4
    manager.close()
    manager.close()
    for config in [CONFIG, other]:
        with pytest.raises(ValueError, match="unavailable"):
            manager.resolve(AUTH, config)
    assert secrets.resolve.call_count == 4


def test_periodic_refresh_uses_the_selected_cache_and_stops(monkeypatch):
    monkeypatch.setattr(credentials_module, "REFRESH_POLL_SECONDS", 0.02)
    monkeypatch.setattr(credentials_module, "SECRET_REFRESH_SECONDS", 0.02)
    secrets = Mock(resolve=Mock(return_value="key"))
    manager = ProviderCredentials(secrets)
    manager.resolve(AUTH, CONFIG)
    wait_until(lambda: secrets.resolve.call_count >= 4)
    manager.close()
    count = secrets.resolve.call_count
    time.sleep(0.06)
    assert secrets.resolve.call_count == count
    assert manager.cache.get() is None


def test_unknown_auth_mode_does_not_create_a_cache():
    secrets = Mock()
    manager = ProviderCredentials(secrets, report_failure=lambda _: None)
    try:
        with pytest.raises(ValueError, match="unavailable"):
            manager.resolve({"mode": "unknown"}, CONFIG)
        assert manager.cache is None
        secrets.resolve.assert_not_called()
    finally:
        manager.close()


def test_pending_secret_reads_do_not_block_process_shutdown():
    script = textwrap.dedent("""
        import atexit
        from threading import Event
        from types import SimpleNamespace
        from src.config import read_config
        from src.credentials import ProviderCredentials

        started, blocked = Event(), Event()
        def resolve(name):
            started.set()
            blocked.wait()
            return "synthetic-key"

        manager = ProviderCredentials(SimpleNamespace(resolve=resolve), cache_options={"wait_timeout": 0.02})
        atexit.register(lambda: print("shutdown-complete", flush=True))
        atexit.register(manager.close)
        try:
            manager.resolve({"mode": "apiKey", "key_vault_secret_name": "key"}, read_config({}))
        except ValueError:
            pass
        assert started.wait(1)
        manager.close()
        print("main-finished", flush=True)
    """)
    result = subprocess.run([sys.executable, "-c", script], cwd=Path(__file__).resolve().parents[1],
                            capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, result.stderr
    assert result.stdout.splitlines() == ["main-finished", "shutdown-complete"]
