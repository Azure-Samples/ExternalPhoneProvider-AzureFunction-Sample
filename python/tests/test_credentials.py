import subprocess
import sys
import textwrap
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from threading import Event
from types import SimpleNamespace
from unittest.mock import Mock

import pytest

import src.credentials as credentials_module
from src.config import read_config
from src.credentials import CredentialTokenService
from src.providers.infobip import InfobipProvider
from src.providers.sinch import SinchProvider
from src.providers.soprano import SopranoProvider
from src.providers.telesign import TelesignProvider

AUTH = {"mode": "apiKey", "key_vault_secret_name": "key", "identity_key_vault_secret_name": "id"}
CONFIG = read_config({"KEY_VAULT_URL": "https://unit.vault.azure.net"})
OAUTH = read_config({
    "EPP_PROVIDER_TENANT_ID": "tenant", "EPP_OUTBOUND_CLIENT_ID": "app",
    "EPP_OUTBOUND_MI_CLIENT_ID": "identity", "EPP_PROVIDER_SCOPE": "scope",
})
NOW = 1700000000.0


def wait_until(predicate):
    deadline = time.monotonic() + 3
    while not predicate():
        assert time.monotonic() < deadline, "request did not reach the expected state"
        time.sleep(0.005)


def token(value):
    return SimpleNamespace(token=value, expires_on=NOW + 3600)


@pytest.mark.parametrize("message,expected", [
    ("PRIVATE-FAILURE", "provider credential unavailable"), ("AADSTS70025: PRIVATE-FAILURE", "AADSTS70025"),
])
def test_api_keys_are_read_per_request_without_warmup_stale_fallback_or_failure_cooldown(monkeypatch, message, expected):
    version, fail = 1, False

    def read(name):
        if fail and name == "id":
            raise ValueError(message)
        return f"{name}-{version}"

    monkeypatch.setattr(credentials_module, "ClientAssertionCredential",
                        Mock(side_effect=AssertionError("API-key requests must not acquire OAuth tokens")))
    secrets = Mock(resolve=Mock(side_effect=read))
    manager = CredentialTokenService(secrets)
    try:
        secrets.resolve.assert_not_called()
        assert manager.resolve(AUTH, CONFIG)["secret"] == "key-1"
        version = 2
        assert manager.resolve(AUTH, CONFIG) == {"mode": "apiKey", "secret": "key-2", "identity": "id-2"}
        fail = True
        with pytest.raises(ValueError, match=f"^{expected}$"):
            manager.resolve(AUTH, CONFIG)
        fail, version = False, 3
        assert manager.resolve(AUTH, CONFIG)["identity"] == "id-3"
        assert secrets.resolve.call_count == 8
        assert not manager._requests
        assert "key-3" not in repr(manager)
    finally:
        manager.close()


def test_concurrent_requests_are_independent_and_shutdown_rejects_all_waiters():
    release, calls = Event(), []

    def read(name):
        calls.append(name)
        assert release.wait(3)
        return "PRIVATE-LATE-KEY"

    manager = CredentialTokenService(Mock(resolve=read))
    try:
        with ThreadPoolExecutor(max_workers=3) as pool:
            requests = [pool.submit(manager.resolve, AUTH, CONFIG) for _ in range(3)]
            wait_until(lambda: len(calls) == 6)
            manager.close()
            for request in requests:
                with pytest.raises(ValueError, match="unavailable"):
                    request.result(timeout=1)
            release.set()
        wait_until(lambda: not manager._requests)
        with pytest.raises(ValueError, match="unavailable"):
            manager.resolve(AUTH, CONFIG)
    finally:
        release.set()
        manager.close()


def test_acquisition_timeout_discards_late_values_and_does_not_delay_the_next_request():
    release = Event()
    secrets = Mock(resolve=Mock(side_effect=lambda _: release.wait(3) and "late"))
    manager = CredentialTokenService(secrets, wait_timeout=0.05)
    try:
        with pytest.raises(ValueError, match="unavailable"):
            manager.resolve(AUTH, CONFIG)
        secrets.resolve.side_effect = lambda _: "new"
        assert manager.resolve(AUTH, CONFIG)["secret"] == "new"
        release.set()
        wait_until(lambda: not manager._requests)
        assert manager.resolve(AUTH, CONFIG)["secret"] == "new"
        assert secrets.resolve.call_count == 6
    finally:
        release.set()
        manager.close()


@pytest.mark.parametrize("empty_secret", ["key", "id"])
def test_empty_secrets_do_not_return_a_previous_or_partial_bundle(empty_secret):
    secrets = Mock(resolve=Mock(return_value="valid"))
    manager = CredentialTokenService(secrets)
    try:
        manager.resolve(AUTH, CONFIG)
        secrets.resolve.side_effect = lambda name: " " if name == empty_secret else "new"
        with pytest.raises(ValueError, match="unavailable"):
            manager.resolve(AUTH, CONFIG)
    finally:
        manager.close()


@pytest.mark.parametrize("provider", [SopranoProvider(), InfobipProvider(), TelesignProvider()])
def test_oauth_calls_one_sdk_client_per_request_and_only_the_sdk_requests_assertions(monkeypatch, provider):
    identity = Mock(spec=["get_token", "close"], get_token=Mock(return_value=token("PRIVATE-ASSERTION")))
    create_identity = Mock(return_value=identity)
    monkeypatch.setattr(credentials_module, "ManagedIdentityCredential", create_identity)
    calls = 0

    def create(**kwargs):
        def get_token_info(scope):
            nonlocal calls
            assert scope == "scope"
            calls += 1
            if calls == 1:
                assert kwargs["func"]() == "PRIVATE-ASSERTION"
            return token(f"PRIVATE-TOKEN-{calls}")
        return Mock(spec=["get_token_info", "close"], get_token_info=Mock(side_effect=get_token_info))

    create_credential = Mock(side_effect=create)
    monkeypatch.setattr(credentials_module, "ClientAssertionCredential", create_credential)
    secrets = Mock()
    manager = CredentialTokenService(secrets, clock=lambda: NOW)
    try:
        create_identity.assert_not_called()
        create_credential.assert_not_called()
        assert manager.get_credentials(provider, OAUTH)["access_token"] == "PRIVATE-TOKEN-1"
        assert manager.get_credentials(provider, OAUTH)["access_token"] == "PRIVATE-TOKEN-2"
        create_identity.assert_called_once()
        create_credential.assert_called_once()
        identity.get_token.assert_called_once()
        assert manager._credential.get_token_info.call_count == 2
        secrets.resolve.assert_not_called()
        identity.close.assert_not_called()
        credential = manager._credential
    finally:
        manager.close()
    credential.close.assert_called_once()
    identity.close.assert_called_once()
    manager.close()
    identity.close.assert_called_once()


@pytest.mark.parametrize("message,expected", [
    ("PRIVATE-SDK-FAILURE", "provider credential unavailable"),
    ("AADSTS70025: PRIVATE-SDK-FAILURE", "AADSTS70025"),
    ("AADSTS70021: PRIVATE-SDK-FAILURE", "AADSTS70021"),
    ("AADSTS700016: PRIVATE-SDK-FAILURE", "AADSTS700016"),
    ("AADSTS500011: PRIVATE-SDK-FAILURE", "AADSTS500011"),
    ("AADSTS501051: PRIVATE-SDK-FAILURE", "AADSTS501051"),
    ("AADSTS700213: PRIVATE-SDK-FAILURE", "AADSTS700213"),
    ("AADSTS999999: PRIVATE-SDK-FAILURE", "AADSTS999999"),
    ("AADSTS500011suffix: PRIVATE-SDK-FAILURE", "provider credential unavailable"),
    ("AADSTSnot-a-code: PRIVATE-SDK-FAILURE", "provider credential unavailable"),
])
def test_oauth_failure_can_retry_immediately_using_the_same_sdk_client(monkeypatch, message, expected):
    identity = Mock(spec=["get_token", "close"])
    credential = Mock(spec=["get_token", "close"], get_token=Mock(side_effect=[
        ValueError(message), token("PRIVATE-TOKEN"),
    ]))
    monkeypatch.setattr(credentials_module, "ManagedIdentityCredential", Mock(return_value=identity))
    create = Mock(return_value=credential)
    monkeypatch.setattr(credentials_module, "ClientAssertionCredential", create)
    manager = CredentialTokenService(Mock(), clock=lambda: NOW)
    try:
        with pytest.raises(ValueError, match=f"^{expected}$"):
            manager.resolve({"mode": "oauth"}, OAUTH)
        assert manager.resolve({"mode": "oauth"}, OAUTH)["access_token"] == "PRIVATE-TOKEN"
        create.assert_called_once()
        assert credential.get_token.call_count == 2
        identity.get_token.assert_not_called()
    finally:
        manager.close()


@pytest.mark.parametrize("invalid_assertion", [True, False])
@pytest.mark.parametrize("invalid", [
    token(" "), SimpleNamespace(token="expired", expires_on=NOW),
    SimpleNamespace(token="expiring", expires_on=NOW + 30),
    SimpleNamespace(token="invalid", expires_on=float("nan")),
])
def test_invalid_assertions_and_access_tokens_are_rejected(monkeypatch, invalid_assertion, invalid):
    identity = Mock(spec=["get_token", "close"], get_token=Mock(
        return_value=invalid if invalid_assertion else token("assertion")))
    monkeypatch.setattr(credentials_module, "ManagedIdentityCredential", Mock(return_value=identity))

    def create(**kwargs):
        def get_token(_scope, **_options):
            kwargs["func"]()
            return token("provider") if invalid_assertion else invalid
        return Mock(spec=["get_token", "close"], get_token=Mock(side_effect=get_token))

    monkeypatch.setattr(credentials_module, "ClientAssertionCredential", create)
    manager = CredentialTokenService(Mock(), clock=lambda: NOW)
    try:
        with pytest.raises(ValueError, match="unavailable"):
            manager.resolve({"mode": "oauth"}, OAUTH)
    finally:
        manager.close()


def test_invalid_configuration_does_not_poison_later_requests():
    secrets = Mock(resolve=Mock(return_value="key"))
    manager = CredentialTokenService(secrets)
    try:
        for spec in ({"mode": "unknown"}, {"mode": "apiKey"}, {"mode": "oauth"}):
            with pytest.raises(ValueError, match="unavailable"):
                manager.resolve(spec, CONFIG)
        secrets.resolve.assert_not_called()
        provider = SinchProvider()
        manager.get_credentials(provider, CONFIG)
        manager.get_credentials(provider, CONFIG)
        assert secrets.resolve.call_count == 2
    finally:
        manager.close()


def test_import_with_a_selected_provider_does_not_start_credential_work():
    script = textwrap.dedent("""
        import os
        from unittest.mock import Mock
        import src.credentials as credentials
        os.environ["EPP_PROVIDER_NAME"] = "soprano"
        credentials.threading.Thread = Mock(side_effect=AssertionError("Unexpected startup acquisition"))
        credentials.ManagedIdentityCredential = Mock(side_effect=AssertionError("Unexpected SDK creation"))
        import function_app
        print("import-complete")
    """)
    result = subprocess.run([sys.executable, "-c", script], cwd=Path(__file__).resolve().parents[1],
                            capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "import-complete"


def test_pending_secret_reads_do_not_block_process_shutdown():
    script = textwrap.dedent("""
        import atexit
        from threading import Event
        from types import SimpleNamespace
        from src.config import read_config
        from src.credentials import CredentialTokenService
        started, blocked = Event(), Event()
        def resolve(name):
            started.set()
            blocked.wait()
            return "synthetic-key"
        manager = CredentialTokenService(SimpleNamespace(resolve=resolve), wait_timeout=0.02)
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
