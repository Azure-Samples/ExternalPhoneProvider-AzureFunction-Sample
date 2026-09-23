import json
import time
from concurrent.futures import ThreadPoolExecutor
from types import SimpleNamespace
from unittest.mock import Mock

import requests

import src.credentials as credentials_module
from src.config import read_config
from src.credentials import ProviderCredentials


def test_real_provider_sdk_uses_one_exchange_for_concurrent_requests_and_no_exchange_when_warm(monkeypatch):
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
            return response({"access_token": "PRIVATE-PROVIDER", "expires_in": 3600, "token_type": "Bearer"})
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
    monkeypatch.setattr(credentials_module, "ManagedIdentityCredential", Mock(
        return_value=Mock(get_token=Mock(side_effect=managed))))
    secrets = Mock()
    manager = ProviderCredentials(secrets)
    config = read_config({
        "EPP_PROVIDER_TENANT_ID": "11111111-1111-1111-1111-111111111111",
        "EPP_OUTBOUND_CLIENT_ID": "22222222-2222-2222-2222-222222222222",
        "EPP_OUTBOUND_MI_CLIENT_ID": "33333333-3333-3333-3333-333333333333",
        "EPP_PROVIDER_SCOPE": "api://provider/.default",
    })
    try:
        with ThreadPoolExecutor(max_workers=10) as pool:
            results = list(pool.map(lambda _: manager.resolve({"mode": "oauth"}, config), range(10)))
        assert all(value["access_token"] == "PRIVATE-PROVIDER" for value in results)
        assert len(token_endpoint_calls) == 1
        assert len(mi_calls) == 1
        assert manager.resolve({"mode": "oauth"}, config)["access_token"] == "PRIVATE-PROVIDER"
        assert len(token_endpoint_calls) == len(mi_calls) == 1
        secrets.resolve.assert_not_called()
    finally:
        manager.close()
