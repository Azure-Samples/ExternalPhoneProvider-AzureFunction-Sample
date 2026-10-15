import json
import time
from concurrent.futures import ThreadPoolExecutor
from types import SimpleNamespace
from unittest.mock import Mock

import requests
import pytest
import src.credentials as credentials_module
from src.config import read_config
from src.credentials import CredentialTokenService
from src.providers.soprano import SopranoProvider
from src.providers.telesign import TelesignProvider


@pytest.mark.parametrize("refresh_in", [None, 60])
@pytest.mark.parametrize("cache_enabled", [None, " TrUe ", "false"])
@pytest.mark.parametrize("provider", [SopranoProvider(), TelesignProvider("oauth")], ids=["soprano", "telesign"])
def test_real_provider_sdk_honors_cache_setting_and_refresh_metadata(monkeypatch, refresh_in, cache_enabled, provider):
    token_endpoint_calls = []
    mi_calls = []
    token_tenant = "44444444-4444-4444-4444-444444444444"
    authority = f"https://login.microsoftonline.com/{token_tenant}"

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
            assert url == f"{authority}/oauth2/v2.0/token"
            assert kwargs["data"]["scope"] == "api://provider/.default"
            assert kwargs["data"]["client_id"] == "22222222-2222-2222-2222-222222222222"
            assert kwargs["data"]["client_assertion"] == "PRIVATE-ASSERTION"
            token_endpoint_calls.append(url)
            time.sleep(0.03)
            payload = {"access_token": "PRIVATE-PROVIDER", "expires_in": 3600, "token_type": "Bearer"}
            if refresh_in is not None:
                payload["refresh_in"] = refresh_in
            return response(payload)
        if method == "GET" and ".well-known/openid-configuration" in url:
            assert url.startswith(authority + "/")
            return response({
                "token_endpoint": f"{authority}/oauth2/v2.0/token",
                "authorization_endpoint": f"{authority}/oauth2/v2.0/authorize",
                "issuer": f"{authority}/v2.0",
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
    manager = CredentialTokenService(secrets, cache_options={
        "clock": lambda: now,
    })
    config = read_config({
        "EPP_PROVIDER_TENANT_ID": token_tenant,
        "EPP_OUTBOUND_CLIENT_ID": "22222222-2222-2222-2222-222222222222",
        "EPP_OUTBOUND_MI_CLIENT_ID": "33333333-3333-3333-3333-333333333333",
        "EPP_PROVIDER_SCOPE": "api://provider/.default",
        **({"EPP_ACCESS_TOKEN_CACHE_ENABLED": cache_enabled} if cache_enabled is not None else {}),
        "EPP_KEY_VAULT_CACHE_ENABLED": "PRIVATE-UNUSED",
    })
    try:
        with ThreadPoolExecutor(max_workers=10) as pool:
            results = list(pool.map(lambda _: manager.get_credentials(provider, config), range(10)))
        assert all(value["access_token"] == "PRIVATE-PROVIDER" for value in results)
        enabled = cache_enabled != "false"
        assert len(token_endpoint_calls) == (1 if enabled else 10)
        assert len(mi_calls) == (2 if enabled else 20)
        assert manager.get_credentials(provider, config)["access_token"] == "PRIVATE-PROVIDER"
        now += 60
        assert manager.get_credentials(provider, config)["access_token"] == "PRIVATE-PROVIDER"
        if enabled:
            manager.refresh().result(timeout=3)
            assert len(token_endpoint_calls) == 1
            assert create_identity.call_count == 1
            identity.close.assert_not_called()
        else:
            assert len(token_endpoint_calls) == 12
            assert create_identity.call_count == identity.close.call_count == 12
            assert manager.cache is None and not manager._requests
        secrets.resolve.assert_not_called()
    finally:
        manager.close()
