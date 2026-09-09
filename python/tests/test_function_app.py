import hashlib
import json
import logging
import time
from concurrent.futures import ThreadPoolExecutor
from threading import Event
from unittest.mock import Mock, call

import azure.functions as func
import jwt
import pytest
from jwcrypto import jwe, jwk

import function_app
import src.dispatch as dispatch_module
import src.security as security
from src.config import read_config

_KEY = jwk.JWK.generate(kty="RSA", size=2048)
_PRIVATE_PEM = _KEY.export_to_pem(private_key=True, password=None).decode()
_PUBLIC_PEM = _KEY.export_to_pem()
_CORRELATION = "2b65f5e5-9628-4894-8ba6-8785c3a9c010"
_NONCE = "test-nonce"
_PHONE = "+14255551234"
_MESSAGE = "  Your code is 123456; keep 7890 unchanged.\nCafé.  "
_CONTEXT = {"nonce": _NONCE, "phoneNumber": _PHONE, "message": _MESSAGE, "locale": "en-US"}

# get_functions() cannot be called twice on the same app.
_HANDLER = function_app.app.get_functions()[0].get_user_function()


@pytest.fixture(autouse=True)
def _isolate(monkeypatch):
    for name in ("WEBSITE_INSTANCE_ID", "WEBSITE_HOSTNAME", "WEBSITE_SITE_NAME", "EPP_REQUIRE_AUTH",
                 "EPP_EXPECTED_CLIENT_ID", "EPP_EXPECTED_AUDIENCE", "EPP_TENANT_ID", "EPP_EXPECTED_ISSUER",
                 "EPP_ENCRYPTION_KEY_ID"):
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setenv("EPP_PROVIDER_NAME", "SOPRANO")
    monkeypatch.setattr(function_app, "_key_provider", Mock(return_value=_PRIVATE_PEM))
    engine = dispatch_module.DispatchEngine(
        function_app._registry, Mock(resolve=Mock(return_value="test-key")),
        {"EPP_PROVIDER_NAME": "soprano", "EPP_PROVIDER_ENDPOINT": "https://qa4.example/cgpapi"},
    )
    monkeypatch.setattr(function_app, "_engine", engine)
    monkeypatch.setattr(dispatch_module.requests, "request", Mock())
    monkeypatch.setattr(security, "_jwks_client", Mock())


def _request(body, headers=None):
    raw = body if isinstance(body, bytes) else json.dumps(body).encode()
    return func.HttpRequest(method="POST", url="/api/SendOtp", headers=headers or {}, params={}, body=raw)


def _encrypt(alg="RSA-OAEP-256", kid="test-kid"):
    token = jwe.JWE(json.dumps(_CONTEXT).encode(), protected=json.dumps({"alg": alg, "enc": "A256GCM", "kid": kid}))
    token.add_recipient(_KEY)
    return token.serialize(compact=True)


def _envelope(**overrides):
    payload = {"type": "microsoft.mfa.otpDeliver.v1",
               "correlationId": _CORRELATION, "channel": 1, "mode": 1, "ttlSeconds": 60,
               "encryptedDeliveryContext": _encrypt()}
    payload.update(overrides)
    return payload


def test_bad_json_and_real_jwe_fail_before_provider_secrets(monkeypatch, caplog):
    monkeypatch.setenv("EPP_ENCRYPTION_KEY_ID", "configured-key-id")
    segments = _encrypt().split(".")
    tag = segments[-1]
    segments[-1] = ("A" if tag[0] != "A" else "B") + tag[1:]
    cases = (
        (b"{ not json", "bad_request"),
        (_envelope(encryptedDeliveryContext=".".join(segments)), "decryption_failed"),
        (_envelope(encryptedDeliveryContext=_encrypt(alg="RSA-OAEP")), "decryption_failed"),
    )
    for payload, error in cases:
        response = _HANDLER(_request(payload))
        assert response.status_code == 400 and json.loads(response.get_body())["error"] == error
    assert not any(record.getMessage() == "encryption_key_id_mismatch" for record in caplog.records)
    function_app._engine.secrets.resolve.assert_not_called()
    dispatch_module.requests.request.assert_not_called()


def test_evaluation_decrypts_without_provider_configuration_or_work(monkeypatch, caplog):
    caplog.set_level(logging.INFO)
    monkeypatch.setenv("EPP_ENCRYPTION_KEY_ID", "configured-key-id")
    monkeypatch.delenv("EPP_PROVIDER_NAME")
    function_app._engine.env.clear()
    lookup = Mock()
    monkeypatch.setattr(function_app._registry, "resolve", lookup)
    config_reader = Mock(wraps=function_app.read_config)
    monkeypatch.setattr(function_app, "read_config", config_reader)
    response = _HANDLER(_request(_envelope(mode="Evaluation", provider="untrusted-body-provider")))
    assert response.status_code == 200
    assert json.loads(response.get_body()) == {
        "nonce": _NONCE, "correlationId": _CORRELATION, "providerStatus": "accepted",
    }
    config_reader.assert_called_once_with()
    function_app._key_provider.assert_called_once_with("test-kid")
    warnings = [record.getMessage() for record in caplog.records if record.levelno == logging.WARNING]
    assert warnings == ["encryption_key_id_mismatch"]
    assert all(value not in caplog.text for value in ("configured-key-id", "test-kid", "untrusted-body-provider"))
    for provider_name in function_app._registry._by_id:
        monkeypatch.setenv("EPP_PROVIDER_NAME", provider_name)
        function_app._engine.env["EPP_PROVIDER_NAME"] = provider_name
        response = _HANDLER(_request(_envelope(mode=2)))
        assert response.status_code == 200 and json.loads(response.get_body())["nonce"] == _NONCE
    lookup.assert_not_called()
    function_app._engine.secrets.resolve.assert_not_called()
    dispatch_module.requests.request.assert_not_called()


def test_live_acceptance_waits_and_preserves_wire_data_but_not_plaintext_logs(monkeypatch, caplog):
    caplog.set_level(logging.INFO)
    monkeypatch.setenv("EPP_LOG_PLAINTEXT", "true")  # Must not bypass privacy.
    entered, release = Event(), Event()
    upstream = Mock(status_code=202, json=Mock(return_value={"status": "ENROUTE"}))

    def wait_for_acceptance(*args, **kwargs):
        entered.set()
        assert release.wait(5), "test did not release provider acceptance"
        return upstream

    send = Mock(side_effect=wait_for_acceptance)
    dispatch = Mock(wraps=function_app._engine.dispatch)
    monkeypatch.setattr(dispatch_module.requests, "request", send)
    monkeypatch.setattr(function_app._engine, "dispatch", dispatch)
    with ThreadPoolExecutor(max_workers=1) as executor:
        request = _request(_envelope(channel=2), {"x-ms-client-request-id": "wire-message"})
        pending = executor.submit(_HANDLER, request)
        try:
            assert entered.wait(5), "handler did not reach provider"
            assert not pending.done()
        finally:
            release.set()
        response = pending.result(timeout=5)
    assert response.status_code == 200
    assert json.loads(response.get_body()) == {
        "nonce": _NONCE, "correlationId": _CORRELATION, "providerStatus": "accepted",
    }
    send.assert_called_once()
    upstream.close.assert_called_once()
    wire = json.loads(send.call_args.kwargs["data"])
    assert wire["text"] == _MESSAGE and wire["messageTypes"] == ["voice"] and wire["correlationId"] == _CORRELATION
    assert dispatch.call_args.args[0].message_id == "wire-message"
    summary = json.loads(caplog.records[-1].getMessage().removeprefix("[EPP] result "))
    assert len(caplog.records) == 1
    assert set(summary) == {"requestId", "correlationId", "httpStatus", "elapsedMs", "evaluation"}
    assert summary["correlationId"] == hashlib.sha256(_CORRELATION.encode()).hexdigest()[:16]
    for private in (_NONCE, _PHONE, _MESSAGE, "123456", _CORRELATION, "wire-message", "test-key"):
        assert private not in caplog.text


def test_provider_failure_preserves_status_without_retry_or_nonce(monkeypatch):
    upstream = Mock(status_code=429, json=Mock(return_value={"status": "ENROUTE"}))
    send = Mock(return_value=upstream)
    monkeypatch.setattr(dispatch_module.requests, "request", send)
    response = _HANDLER(_request(_envelope()))
    body = json.loads(response.get_body())
    assert response.status_code == 429 and body["error"] == "provider_delivery_failed"
    assert "nonce" not in body
    send.assert_called_once()
    assert send.call_args.kwargs["allow_redirects"] is False
    upstream.close.assert_called_once()


def test_azure_markers_require_auth_before_body_parsing(monkeypatch):
    for marker in ("WEBSITE_INSTANCE_ID", "WEBSITE_HOSTNAME", "WEBSITE_SITE_NAME"):
        for require_auth, client_id in (("false", "client"), ("true", " ")):
            with monkeypatch.context() as patch:
                patch.setenv(marker, "azure-site")
                patch.setenv("EPP_REQUIRE_AUTH", require_auth)
                patch.setenv("EPP_EXPECTED_CLIENT_ID", client_id)
                response = _HANDLER(_request(b"not-json"))
            assert response.status_code == 401 and json.loads(response.get_body())["error"] == "unauthorized"
    function_app._key_provider.assert_not_called()
    security._jwks_client.assert_not_called()


def test_real_signed_inbound_jwt_acceptance_and_rejections(monkeypatch):
    config = read_config({"EPP_REQUIRE_AUTH": "true", "EPP_EXPECTED_CLIENT_ID": "client",
                          "EPP_EXPECTED_AUDIENCE": "audience", "EPP_TENANT_ID": "tenant",
                          "WEBSITE_INSTANCE_ID": "azure-site"})
    monkeypatch.setattr(function_app, "read_config", Mock(return_value=config))
    # Only key discovery is mocked; PyJWT still verifies the actual signatures and claims.
    client = Mock(get_signing_key_from_jwt=Mock(return_value=Mock(key=_PUBLIC_PEM)))
    monkeypatch.setattr(security, "_jwks_client", Mock(return_value=client))
    other_key = jwk.JWK.generate(kty="RSA", size=2048).export_to_pem(private_key=True, password=None)
    now = int(time.time())
    variants = (
        ({}, _PRIVATE_PEM, "RS256", 200),
        ({"azp": "CLIENT"}, _PRIVATE_PEM, "RS256", 200),
        ({"tid": "untrusted-tenant"}, _PRIVATE_PEM, "RS256", 200),
        ({}, other_key, "RS256", 401),
        ({"exp": now - 3600}, _PRIVATE_PEM, "RS256", 401),
        ({"exp": None}, _PRIVATE_PEM, "RS256", 401),
        ({"aud": "wrong"}, _PRIVATE_PEM, "RS256", 401),
        ({"azp": "wrong", "appid": "client"}, _PRIVATE_PEM, "RS256", 401),
        ({"iss": "https://login.microsoftonline.com/untrusted-tenant/v2.0", "tid": "untrusted-tenant"},
         _PRIVATE_PEM, "RS256", 401),
        ({}, _PRIVATE_PEM, "RS512", 401),
    )
    for changes, key, algorithm, expected in variants:
        claims = {"iss": "https://login.microsoftonline.com/tenant/v2.0", "aud": "audience",
                  "azp": "client", "exp": now + 3600, **changes}
        if claims["exp"] is None:
            claims.pop("exp")
        token = jwt.encode(claims, key, algorithm=algorithm)
        function_app._key_provider.reset_mock()
        response = _HANDLER(_request(_envelope(mode=2, tenantId="untrusted-tenant"),
                                    {"Authorization": "Bearer " + token}))
        assert response.status_code == expected, (changes, algorithm)
        if expected == 200:
            assert json.loads(response.get_body())["nonce"] == _NONCE
        else:
            assert json.loads(response.get_body())["error"] == "unauthorized"
            function_app._key_provider.assert_not_called()
    assert security._jwks_client.call_args_list == [call("tenant")] * len(variants)
    dispatch_module.requests.request.assert_not_called()
