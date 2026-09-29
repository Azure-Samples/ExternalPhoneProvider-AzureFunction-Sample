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
from src.credentials import ApiKeyCache, AccessTokenCache, ProviderCredentials, is_cache_enabled
from src.dispatch import DispatchEngine, ProviderRegistry
from src.providers.soprano import SopranoProvider
from src.providers.telesign import TelesignProvider

AUTH = {"mode": "apiKey", "key_vault_secret_name": "key", "identity_key_vault_secret_name": "id"}
CONFIG = read_config({"KEY_VAULT_URL": "https://unit.vault.azure.net", "EPP_KEY_VAULT_CACHE_ENABLED": "true",
                      "EPP_ACCESS_TOKEN_CACHE_ENABLED": "false"})


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


@pytest.mark.parametrize(("value", "expected"), [(None, True), ("true", True), (" TRUE ", True),
                                                ("false", False), (" FaLsE ", False)])
def test_cache_switches_default_to_enabled_and_parse_boolean_strings(value, expected):
    env = {} if value is None else {"EPP_KEY_VAULT_CACHE_ENABLED": value, "EPP_ACCESS_TOKEN_CACHE_ENABLED": value}
    config = read_config(env)
    assert is_cache_enabled(AUTH, config) is expected
    assert is_cache_enabled({"mode": "oauth"}, config) is expected


@pytest.mark.parametrize("value", ["", "1", "0", "yes", "PRIVATE-INVALID"])
@pytest.mark.parametrize("mode", ["apiKey", "oauth"])
def test_invalid_cache_switch_fails_before_acquisition_or_scheduling(value, mode):
    secrets, failures = Mock(), []
    config = read_config({"EPP_KEY_VAULT_CACHE_ENABLED": value, "EPP_ACCESS_TOKEN_CACHE_ENABLED": value})
    manager = ProviderCredentials(secrets, report_failure=failures.append)
    try:
        with pytest.raises(ValueError, match="^provider credential unavailable$"):
            manager.resolve({**AUTH, "mode": mode}, config)
        assert failures == ["configuration"]
        assert manager.cache is None and manager._pending is None and not manager._requests
        secrets.resolve.assert_not_called()
    finally:
        manager.close()


def test_disabled_key_vault_cache_reads_each_bundle_without_polling_stale_fallback_or_cooldown(monkeypatch):
    clock = Clock()
    version, fail = 1, False

    def read(name):
        if fail and name == "id":
            raise ValueError("PRIVATE-FAILURE")
        return f"{name}-{version}"

    secrets, failures = Mock(resolve=Mock(side_effect=read)), []
    manager = ProviderCredentials(secrets, cache_options=clock.options, report_failure=failures.append)
    loop = Mock(side_effect=AssertionError("Disabled cache must not poll"))
    monkeypatch.setattr(manager, "_loop", loop)
    config = read_config({"EPP_KEY_VAULT_CACHE_ENABLED": "false", "EPP_ACCESS_TOKEN_CACHE_ENABLED": "PRIVATE-UNUSED"})
    try:
        assert manager.resolve(AUTH, config)["secret"] == "key-1"
        version = 2
        assert manager.resolve(AUTH, config) == {"mode": "apiKey", "secret": "key-2", "identity": "id-2"}
        fail = True
        with pytest.raises(ValueError, match="unavailable"):
            manager.resolve(AUTH, config)
        fail, version = False, 3
        assert manager.resolve(AUTH, config)["identity"] == "id-3"
        assert secrets.resolve.call_count == 8 and failures == ["key_vault"]
        assert manager.cache is None and manager._pending is None and not manager._requests
        loop.assert_not_called()
        clock.advance(300)
        with pytest.raises(ValueError, match="unavailable"):
            manager.refresh()
        assert secrets.resolve.call_count == 8
    finally:
        manager.close()


def test_disabled_access_token_cache_creates_and_closes_request_scoped_sdk_clients(monkeypatch):
    clock = Clock()
    identities, clients = [], []

    def create_identity(**_):
        client = Mock(spec=["get_token_info", "close"], get_token_info=Mock(
            return_value=SimpleNamespace(token="assertion", expires_on=clock.now + 3600)))
        identities.append(client)
        return client

    def create_credential(**kwargs):
        generation = len(clients) + 1

        def get_token_info(_):
            assert kwargs["func"]() == "assertion"
            return SimpleNamespace(token=f"PRIVATE-TOKEN-{generation}", expires_on=clock.now + 3600)

        client = Mock(spec=["get_token_info", "close"], get_token_info=Mock(side_effect=get_token_info))
        clients.append(client)
        return client

    monkeypatch.setattr(credentials_module, "ManagedIdentityCredential", create_identity)
    monkeypatch.setattr(credentials_module, "ClientAssertionCredential", create_credential)
    config = read_config({"EPP_PROVIDER_TENANT_ID": "tenant", "EPP_OUTBOUND_CLIENT_ID": "app",
                          "EPP_OUTBOUND_MI_CLIENT_ID": "identity", "EPP_PROVIDER_SCOPE": "scope",
                          "EPP_ACCESS_TOKEN_CACHE_ENABLED": "false", "EPP_KEY_VAULT_CACHE_ENABLED": "PRIVATE-UNUSED"})
    secrets = Mock()
    manager = ProviderCredentials(secrets, cache_options=clock.options)
    loop = Mock(side_effect=AssertionError("Disabled cache must not poll"))
    monkeypatch.setattr(manager, "_loop", loop)
    try:
        assert manager.resolve({"mode": "oauth"}, config)["access_token"] == "PRIVATE-TOKEN-1"
        assert manager.resolve({"mode": "oauth"}, config)["access_token"] == "PRIVATE-TOKEN-2"
        assert len(clients) == len(identities) == 2
        for client in clients:
            client.get_token_info.assert_called_once()
        for client in clients + identities:
            client.close.assert_called_once()
        assert manager.cache is None and not manager._requests
        secrets.resolve.assert_not_called()
        loop.assert_not_called()
    finally:
        manager.close()


def test_disabled_cache_requests_are_independent_and_shutdown_rejects_all_late_results():
    release = Event()
    calls = []

    def read(name):
        calls.append(name)
        assert release.wait(3)
        return "PRIVATE-LATE-KEY"

    manager = ProviderCredentials(Mock(resolve=read))
    config = read_config({"EPP_KEY_VAULT_CACHE_ENABLED": "false"})
    try:
        with ThreadPoolExecutor(max_workers=5) as pool:
            requests = [pool.submit(manager.resolve, AUTH, config) for _ in range(5)]
            wait_until(lambda: len(calls) == 10)
            manager.close()
            for request in requests:
                with pytest.raises(ValueError, match="unavailable"):
                    request.result(timeout=1)
            release.set()
        wait_until(lambda: not manager._requests)
        assert manager.cache is None
        with pytest.raises(ValueError, match="unavailable"):
            manager.resolve(AUTH, config)
    finally:
        release.set()
        manager.close()


def test_disabled_cache_wait_timeout_discards_late_values_and_next_request_has_no_cooldown():
    release = Event()
    secrets = Mock(resolve=Mock(side_effect=lambda _: release.wait(3) and "value"))
    manager = ProviderCredentials(secrets, cache_options={"wait_timeout": 0.02}, report_failure=lambda _: None)
    config = read_config({"EPP_KEY_VAULT_CACHE_ENABLED": "false"})
    try:
        with pytest.raises(ValueError, match="unavailable"):
            manager.resolve(AUTH, config)
        release.set()
        wait_until(lambda: not manager._requests)
        assert manager.cache is None
        assert manager.resolve(AUTH, config)["secret"] == "value"
        assert secrets.resolve.call_count == 4
    finally:
        release.set()
        manager.close()


@pytest.mark.parametrize(("provider", "mode", "switch"), [
    ("telesign", "apiKey", "EPP_KEY_VAULT_CACHE_ENABLED"),
    ("soprano", "oauth", "EPP_ACCESS_TOKEN_CACHE_ENABLED"),
])
def test_disabled_cache_startup_never_calls_the_selected_credential_resolver(provider, mode, switch):
    engine = DispatchEngine(ProviderRegistry([TelesignProvider(), SopranoProvider()]), Mock(),
                            {"EPP_PROVIDER_NAME": provider, "EPP_PROVIDER_AUTH_MODE": mode, switch: "false"})
    engine._resolve_credential = Mock(side_effect=AssertionError("Disabled startup must not acquire credentials"))
    try:
        engine.start_credential_refresh()
        engine._resolve_credential.assert_not_called()
        assert engine._credentials.cache is None
    finally:
        engine.close()


def test_disabled_cache_skips_configured_provider_startup_and_independent_switches_are_respected():
    secrets = Mock(resolve=Mock(return_value="test-key"))
    config = {"EPP_PROVIDER_NAME": "telesign", "EPP_PROVIDER_AUTH_MODE": "apiKey",
              "EPP_KEY_VAULT_CACHE_ENABLED": "false", "EPP_ACCESS_TOKEN_CACHE_ENABLED": "true"}
    engine = DispatchEngine(ProviderRegistry([TelesignProvider()]), secrets, config)
    try:
        engine.start_credential_refresh()
        secrets.resolve.assert_not_called()
        assert engine._credentials.cache is None
        for _ in range(2):
            assert engine._resolve_credential(TelesignProvider.manifest["auth"], read_config(config))["secret"] == "test-key"
        assert secrets.resolve.call_count == 4
        assert not is_cache_enabled(AUTH, read_config(config))
        assert is_cache_enabled({"mode": "oauth"}, read_config(config))
    finally:
        engine.close()


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
                          "EPP_OUTBOUND_MI_CLIENT_ID": "identity", "EPP_PROVIDER_SCOPE": "scope",
                          "EPP_ACCESS_TOKEN_CACHE_ENABLED": "true", "EPP_KEY_VAULT_CACHE_ENABLED": "false"})
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
