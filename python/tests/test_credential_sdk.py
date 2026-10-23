import json
import logging
import time
from concurrent.futures import ThreadPoolExecutor
from types import SimpleNamespace
from unittest.mock import Mock

import requests
import pytest
import src.credentials as credentials_module
from src.config import read_config
from src.credentials import CredentialTokenService
from src.credential_failure import CredentialResolutionError


@pytest.mark.parametrize("refresh_in", [None, 60])
def test_real_sdk_reuses_tokens_and_renews_expired_tokens_on_request(monkeypatch, refresh_in):
    token_endpoint_calls = []
    mi_calls = []

    def response(payload):
        result = requests.Response()
        result.status_code = 200
        result.headers["Content-Type"] = "application/json"
        result._content = json.dumps(payload).encode()
        result._content_consumed = True
        result.raw = SimpleNamespace(enforce_content_length=False)
        return result

    def send(_session, method, url, **kwargs):
        if method == "POST" and url.endswith("/oauth2/v2.0/token"):
            token_endpoint_calls.append(url)
            time.sleep(0.03)
            payload = {"access_token": "PRIVATE-PROVIDER", "expires_in": 3600, "token_type": "Bearer"}
            if refresh_in is not None:
                payload["refresh_in"] = refresh_in
            return response(payload)
        if method == "GET" and ".well-known/openid-configuration" in url:
            return response({
                "token_endpoint": "https://login.microsoftonline.com/11111111-1111-1111-1111-111111111111/oauth2/v2.0/token",
                "authorization_endpoint": "https://login.microsoftonline.com/11111111-1111-1111-1111-111111111111/oauth2/v2.0/authorize",
                "issuer": "https://login.microsoftonline.com/11111111-1111-1111-1111-111111111111/v2.0",
            })
        raise AssertionError("Unexpected HTTP in fake credential transport")

    def managed(*args, **kwargs):
        mi_calls.append(args)
        return SimpleNamespace(token="PRIVATE-ASSERTION", expires_on=time.time() + 3600)

    monkeypatch.setattr(requests.Session, "request", send)
    identity = Mock(spec=["get_token", "close"], get_token=Mock(side_effect=managed))
    create_identity = Mock(return_value=identity)
    monkeypatch.setattr(credentials_module, "ManagedIdentityCredential", create_identity)
    secrets = Mock()
    now = time.time()
    monkeypatch.setattr(time, "time", lambda: now)
    manager = CredentialTokenService(secrets, clock=lambda: now)
    config = read_config({
        "EPP_PROVIDER_TENANT_ID": "11111111-1111-1111-1111-111111111111",
        "EPP_OUTBOUND_CLIENT_ID": "22222222-2222-2222-2222-222222222222",
        "EPP_OUTBOUND_MI_CLIENT_ID": "33333333-3333-3333-3333-333333333333",
        "EPP_PROVIDER_SCOPE": "api://provider/.default",
    })
    try:
        create_identity.assert_not_called()
        assert not token_endpoint_calls
        assert manager.resolve({"mode": "oauth"}, config)["access_token"] == "PRIVATE-PROVIDER"
        with ThreadPoolExecutor(max_workers=10) as pool:
            results = list(pool.map(lambda _: manager.resolve({"mode": "oauth"}, config), range(10)))
        assert all(value["access_token"] == "PRIVATE-PROVIDER" for value in results)
        assert len(token_endpoint_calls) == 1
        assert len(mi_calls) == 1
        assert manager.resolve({"mode": "oauth"}, config)["access_token"] == "PRIVATE-PROVIDER"
        now += 3601
        assert manager.resolve({"mode": "oauth"}, config)["access_token"] == "PRIVATE-PROVIDER"
        assert len(token_endpoint_calls) == 2
        assert len(mi_calls) == 2
        create_identity.assert_called_once()
        identity.close.assert_not_called()
        secrets.resolve.assert_not_called()
    finally:
        manager.close()
    identity.close.assert_called_once()


@pytest.mark.parametrize("code,expected", [
    ("70025", "federated_credential_missing"),
    ("70021", "federated_credential_mismatch"),
    ("700016", "provider_application_not_found"),
])
def test_real_sdk_preserves_error_code_without_response_or_sdk_log_leakage(monkeypatch, caplog, code, expected):
    caplog.set_level(logging.DEBUG)
    token_calls = []

    def send(_session, method, url, **_kwargs):
        result = requests.Response()
        result.headers["Content-Type"] = "application/json"
        result._content_consumed = True
        result.raw = SimpleNamespace(enforce_content_length=False)
        if method == "POST" and url.endswith("/oauth2/v2.0/token"):
            token_calls.append(url)
            result.status_code = 400
            payload = {"error": "invalid_client", "error_codes": [int(code)],
                       "error_description": f"AADSTS{code}: PRIVATE-RESPONSE PRIVATE-ASSERTION PRIVATE-TOKEN"}
        elif method == "GET" and ".well-known/openid-configuration" in url:
            result.status_code = 200
            payload = {
                "token_endpoint": "https://login.microsoftonline.com/11111111-1111-1111-1111-111111111111/oauth2/v2.0/token",
                "authorization_endpoint": "https://login.microsoftonline.com/11111111-1111-1111-1111-111111111111/oauth2/v2.0/authorize",
                "issuer": "https://login.microsoftonline.com/11111111-1111-1111-1111-111111111111/v2.0",
            }
        else:
            raise AssertionError(f"Unexpected SDK request: {method} {url}")
        result._content = json.dumps(payload).encode()
        return result

    monkeypatch.setattr(requests.Session, "request", send)
    identity = Mock(spec=["get_token", "close"], get_token=Mock(return_value=SimpleNamespace(
        token="PRIVATE-ASSERTION", expires_on=time.time() + 3600)))
    monkeypatch.setattr(credentials_module, "ManagedIdentityCredential", Mock(return_value=identity))
    manager = CredentialTokenService(Mock())
    config = read_config({
        "EPP_PROVIDER_TENANT_ID": "11111111-1111-1111-1111-111111111111",
        "EPP_OUTBOUND_CLIENT_ID": "22222222-2222-2222-2222-222222222222",
        "EPP_OUTBOUND_MI_CLIENT_ID": "33333333-3333-3333-3333-333333333333",
        "EPP_PROVIDER_SCOPE": "api://provider/.default",
    })
    try:
        with pytest.raises(CredentialResolutionError) as failure:
            manager.resolve({"mode": "oauth"}, config)
        error = failure.value
        assert error.diagnostic.credential_stage == "provider_token_exchange"
        assert error.diagnostic.credential_failure == expected
        assert error.diagnostic.aadsts_code == code
        assert error.__cause__ is None and error.__context__ is None
        assert "PRIVATE" not in repr(error) + repr(error.__dict__) + caplog.text
        assert len(token_calls) == 1
        identity.get_token.assert_called_once()
    finally:
        manager.close()
