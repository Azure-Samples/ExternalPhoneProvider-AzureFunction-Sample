import base64
import hashlib
import json
import logging
from concurrent.futures import ThreadPoolExecutor
from threading import Event
from unittest.mock import Mock

import azure.functions as func
import pytest
from jwcrypto import jwe, jwk

import function_app
import src.dispatch as dispatch_module

_KEY = jwk.JWK.generate(kty="RSA", size=2048)
_PRIVATE_PEM = _KEY.export_to_pem(private_key=True, password=None).decode()
_CORRELATION = "2b65f5e5-9628-4894-8ba6-8785c3a9c010"
_NONCE = "test-nonce"
_PHONE = "+14255551234"
_MESSAGE = "  Your code is 123456; keep 7890 unchanged.\nCafé.  "
_CONTEXT = {"nonce": _NONCE, "phoneNumber": _PHONE, "message": _MESSAGE, "locale": "en-US"}

# get_functions() cannot be called twice on the same app.
_HANDLER = function_app.app.get_functions()[0].get_user_function()


@pytest.fixture(autouse=True)
def _isolate(monkeypatch):
    monkeypatch.delenv("EPP_ENCRYPTION_KEY_ID", raising=False)
    monkeypatch.setenv("EPP_PROVIDER_NAME", "SOPRANO")
    monkeypatch.setattr(function_app, "_key_provider", Mock(return_value=_PRIVATE_PEM))
    engine = dispatch_module.DispatchEngine(
        function_app._registry, Mock(resolve=Mock(return_value="test-key")),
        {"EPP_PROVIDER_NAME": "soprano", "EPP_PROVIDER_ENDPOINT": "https://qa4.example/cgpapi"},
    )
    monkeypatch.setattr(function_app, "_engine", engine)
    monkeypatch.setattr(dispatch_module.requests, "request", Mock())


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


def test_jwe_authenticates_original_protected_header_bytes():
    header = '{ "kid" : "test-key", "enc" : "A256GCM", "alg" : "RSA-OAEP-256" }'
    token = jwe.JWE(json.dumps(_CONTEXT).encode(), protected=header)
    token.add_recipient(_KEY)
    segments = token.serialize(compact=True).split('.')
    original = base64.urlsafe_b64encode(header.encode()).decode().rstrip('=')
    assert segments[0] == original
    response = _HANDLER(_request(_envelope(mode=2, encryptedDeliveryContext='.'.join(segments))))
    assert response.status_code == 200 and json.loads(response.get_body())["nonce"] == _NONCE
    segments[0] = base64.urlsafe_b64encode(json.dumps(json.loads(header), separators=(',', ':')).encode()).decode().rstrip('=')
    response = _HANDLER(_request(_envelope(mode=2, encryptedDeliveryContext='.'.join(segments))))
    assert response.status_code == 400 and json.loads(response.get_body())["error"] == "decryption_failed"
    function_app._engine.secrets.resolve.assert_not_called()
    dispatch_module.requests.request.assert_not_called()


def test_evaluation_decrypts_without_provider_configuration_or_work(monkeypatch, caplog):
    caplog.set_level(logging.INFO)
    monkeypatch.setenv("EPP_ENCRYPTION_KEY_ID", "configured-key-id")
    monkeypatch.delenv("EPP_PROVIDER_NAME")
    function_app._engine.env.clear()
    lookup = Mock()
    monkeypatch.setattr(function_app._registry, "get", lookup)
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
