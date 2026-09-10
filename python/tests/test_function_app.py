import base64
import hashlib
import json
import logging
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from threading import Event
from unittest.mock import Mock

import azure.functions as func
import pytest
from jwcrypto import jwe, jwk

import function_app
import src.dispatch as dispatch_module
from src.provider_tokens import ProviderTokenError

_KEY = jwk.JWK.generate(kty="RSA", size=2048)
_PRIVATE_PEM = _KEY.export_to_pem(private_key=True, password=None).decode()
_CORRELATION = "2b65f5e5-9628-4894-8ba6-8785c3a9c010"
_NONCE = "test-nonce"
_PHONE = "+14255551234"
_MESSAGE = "  Your code is 123456; keep 7890 unchanged.\nCafé.  "
_CONTEXT = {"nonce": _NONCE, "phoneNumber": _PHONE, "message": _MESSAGE, "locale": "en-US"}
_FIXTURES = json.loads((Path(__file__).resolve().parents[2] / "tests/fixtures/contract.json").read_text(encoding="utf-8"))

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
        token_acquirer=Mock(),
    )
    monkeypatch.setattr(function_app, "_engine", engine)
    monkeypatch.setattr(dispatch_module.requests, "request", Mock())


def _request(body, headers=None):
    raw = body if isinstance(body, bytes) else json.dumps(body).encode()
    return func.HttpRequest(method="POST", url="/api/SendOtp", headers=headers or {}, params={}, body=raw)


def _encrypt(alg="RSA-OAEP-256", kid="test-kid", enc="A256GCM", context=None):
    token = jwe.JWE(json.dumps(_CONTEXT if context is None else context).encode(),
                    protected=json.dumps({"alg": alg, "enc": enc, "kid": kid}))
    token.add_recipient(_KEY)
    return token.serialize(compact=True)


def _envelope(**overrides):
    payload = {"type": "microsoft.mfa.otpDeliver.v1",
               "correlationId": _CORRELATION, "channel": 1, "mode": 1, "ttlSeconds": 60}
    payload.update(overrides)
    if "encryptedDeliveryContext" not in payload:
        payload["encryptedDeliveryContext"] = _encrypt()
    return payload


def test_jwe_tag_tampering_and_missing_segments_fail_before_provider_io(monkeypatch, caplog):
    monkeypatch.setenv("EPP_ENCRYPTION_KEY_ID", "configured-key-id")
    segments = _encrypt().split(".")
    tag = segments[-1]
    segments[-1] = ("A" if tag[0] != "A" else "B") + tag[1:]
    for compact in (".".join(segments), ".".join(segments[:4])):
        response = _HANDLER(_request(_envelope(encryptedDeliveryContext=compact)))
        assert response.status_code == 400 and json.loads(response.get_body())["error"] == "decryption_failed"
    assert not any(record.getMessage() == "encryption_key_id_mismatch" for record in caplog.records)
    function_app._engine.secrets.resolve.assert_not_called()
    dispatch_module.requests.request.assert_not_called()


def test_shared_invalid_requests_return_safe_reasons_before_provider_io():
    valid = _envelope(encryptedDeliveryContext="unused")
    for fixture in _FIXTURES["badRequests"]:
        payload = fixture["rawBody"].encode() if "rawBody" in fixture else {**valid, **fixture["overrides"]}
        response = _HANDLER(_request(payload))
        result = json.loads(response.get_body())
        assert response.status_code == 400 and result["requestId"]
        assert result == {"error": "bad_request", "reason": fixture["reason"],
                          "requestId": result["requestId"]}, fixture["name"]
    contexts = [{**_CONTEXT, **changes} for changes in _FIXTURES["incompleteContexts"]]
    for context in (*contexts, False, []):
        payload = _envelope(mode=2, encryptedDeliveryContext=_encrypt(context=context))
        response = _HANDLER(_request(payload))
        result = json.loads(response.get_body())
        assert response.status_code == 400
        assert result == {"error": "bad_request", "reason": "incomplete delivery context",
                          "correlationId": _CORRELATION, "requestId": result["requestId"]}
    function_app._engine.secrets.resolve.assert_not_called()
    dispatch_module.requests.request.assert_not_called()


def test_shared_jwe_policy_permits_only_rsa_oaep_256_with_a256gcm():
    for fixture in _FIXTURES["jwe"]:
        compact = _encrypt(alg=fixture["alg"], enc=fixture["enc"])
        response = _HANDLER(_request(_envelope(mode=2, encryptedDeliveryContext=compact)))
        result = json.loads(response.get_body())
        assert response.status_code == (200 if fixture["accepted"] else 400)
        if fixture["accepted"]:
            assert result["nonce"] == _NONCE
        else:
            assert result == {"error": "decryption_failed", "correlationId": _CORRELATION,
                              "requestId": result["requestId"]}
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


@pytest.mark.parametrize("auth_mode,jwt_enabled", [("apiKey", "true"), ("oauth2", "true"), ("oauth2", "invalid")])
def test_evaluation_decrypts_without_provider_configuration_or_work(monkeypatch, caplog, auth_mode, jwt_enabled):
    caplog.set_level(logging.INFO)
    monkeypatch.setenv("EPP_ENCRYPTION_KEY_ID", "configured-key-id")
    monkeypatch.delenv("EPP_PROVIDER_NAME")
    monkeypatch.setenv("EPP_PROVIDER_AUTH_MODE", auth_mode)
    monkeypatch.setenv("EPP_PROVIDER_JWT_ENABLED", jwt_enabled)
    function_app._engine.env.clear()
    function_app._engine.env.update(EPP_PROVIDER_AUTH_MODE=auth_mode, EPP_PROVIDER_JWT_ENABLED=jwt_enabled)
    lookup = Mock()
    monkeypatch.setattr(function_app._registry, "get", lookup)
    response = _HANDLER(_request(_envelope(channel=2, mode="Evaluation", provider="untrusted-body-provider")))
    assert response.status_code == 200
    assert json.loads(response.get_body()) == {
        "nonce": _NONCE, "correlationId": _CORRELATION, "providerStatus": "accepted",
    }
    function_app._key_provider.assert_called_once_with("test-kid")
    warnings = [record.getMessage() for record in caplog.records if record.levelno == logging.WARNING]
    assert warnings == ["encryption_key_id_mismatch"]
    assert all(value not in caplog.text for value in ("configured-key-id", "test-kid", "untrusted-body-provider"))
    lookup.assert_not_called()
    function_app._engine.secrets.resolve.assert_not_called()
    function_app._engine.token_acquirer.acquire.assert_not_called()
    dispatch_module.requests.request.assert_not_called()


@pytest.mark.parametrize("auth_mode,jwt_enabled", [("apiKey", "false"), ("apiKey", "true"), ("oauth2", "true")])
@pytest.mark.parametrize("channel", ["sms", "voice"])
def test_live_acceptance_waits_and_preserves_wire_data_but_not_plaintext_logs(monkeypatch, caplog, auth_mode, jwt_enabled, channel):
    caplog.set_level(logging.INFO)
    monkeypatch.setenv("EPP_LOG_PLAINTEXT", "true")  # Must not bypass privacy.
    function_app._engine.env.update({
        "EPP_PROVIDER_AUTH_MODE": auth_mode, "EPP_PROVIDER_JWT_ENABLED": jwt_enabled, "EPP_PROVIDER_TENANT_ID": "tenant-id",
        "EPP_PROVIDER_CLIENT_ID": "client-id", "EPP_PROVIDER_SCOPE": "api://provider/.default",
        "EPP_PROVIDER_MI_CLIENT_ID": "mi-id",
    })
    function_app._engine.token_acquirer.acquire.return_value = "provider-token"
    entered, release = Event(), Event()
    upstream = Mock(status_code=202, json=Mock(return_value={"status": "ENROUTE"}))

    def wait_for_acceptance(*args, **kwargs):
        entered.set()
        assert release.wait(5), "test did not release provider acceptance"
        return upstream

    send = Mock(side_effect=wait_for_acceptance)
    monkeypatch.setattr(dispatch_module.requests, "request", send)
    with ThreadPoolExecutor(max_workers=1) as executor:
        compact = _encrypt(context={**_CONTEXT, "voice": {"text2voice": _FIXTURES["textToVoice"]}})
        request = _request(_envelope(channel=channel, encryptedDeliveryContext=compact), {"x-ms-client-request-id": "wire-message"})
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
    content = {"voice": {"text2voice": _FIXTURES["textToVoice"]}} if channel == "voice" else {"text": _MESSAGE}
    assert wire == {"destination": _PHONE.lstrip("+"), "messageTypes": [channel], "correlationId": _CORRELATION,
                    "shutterMode": False, **content}
    headers = {"Content-Type": "application/json", "Accept": "application/json"}
    if jwt_enabled == "true":
        function_app._engine.token_acquirer.acquire.assert_called_once()
        headers["Authorization"] = "Bearer provider-token"
    else:
        function_app._engine.token_acquirer.acquire.assert_not_called()
    if auth_mode == "oauth2":
        function_app._engine.secrets.resolve.assert_not_called()
    else:
        headers.update({"X-MEMS-API-ID": "test-key", "X-MEMS-API-Key": "test-key"})
        assert function_app._engine.secrets.resolve.call_count == 2
    assert send.call_args.kwargs["headers"] == headers
    summary = json.loads(caplog.records[-1].getMessage().removeprefix("[EPP] result "))
    assert len(caplog.records) == 1
    assert set(summary) == {"requestId", "correlationId", "httpStatus", "elapsedMs", "evaluation"}
    assert summary["correlationId"] == hashlib.sha256(_CORRELATION.encode()).hexdigest()[:16]
    for private in (_NONCE, _PHONE, _MESSAGE, "123456", _CORRELATION, "wire-message", "test-key", "provider-token"):
        assert private not in caplog.text
    for private in _FIXTURES["textToVoice"].values():
        assert private not in caplog.text + response.get_body().decode()


def test_incomplete_encrypted_voice_fails_even_with_valid_outer_voice(caplog):
    caplog.set_level(logging.INFO)
    function_app._engine.env["EPP_PROVIDER_JWT_ENABLED"] = "true"
    for mode in ("apiKey", "oauth2"):
        function_app._engine.env["EPP_PROVIDER_AUTH_MODE"] = mode
        for changes in _FIXTURES["incompleteVoiceContexts"]:
            compact = _encrypt(context={**_CONTEXT, **changes})
            response = _HANDLER(_request(_envelope(channel=2, encryptedDeliveryContext=compact,
                                                  voice={"text2voice": _FIXTURES["textToVoice"]})))
            result = json.loads(response.get_body())
            assert response.status_code == 400
            assert result == {"error": "provider_delivery_failed", "correlationId": _CORRELATION,
                              "requestId": result["requestId"]}
    for private in (_NONCE, _PHONE, _MESSAGE, *_FIXTURES["textToVoice"].values()):
        assert private not in caplog.text
    function_app._engine.secrets.resolve.assert_not_called()
    function_app._engine.token_acquirer.acquire.assert_not_called()
    dispatch_module.requests.request.assert_not_called()


def test_provider_failure_preserves_status_without_retry_or_nonce(monkeypatch):
    function_app._engine.env.update({
        "EPP_PROVIDER_JWT_ENABLED": "true", "EPP_PROVIDER_TENANT_ID": "tenant-id",
        "EPP_PROVIDER_CLIENT_ID": "client-id", "EPP_PROVIDER_SCOPE": "api://provider/.default",
        "EPP_PROVIDER_MI_CLIENT_ID": "mi-id",
    })
    function_app._engine.token_acquirer.acquire.return_value = "provider-token"
    for provider_status, expected in ((429, 429), (401, 401)):
        upstream = Mock(status_code=provider_status, json=Mock(return_value={"status": "ENROUTE"}))
        send = Mock(return_value=upstream)
        monkeypatch.setattr(dispatch_module.requests, "request", send)
        response = _HANDLER(_request(_envelope()))
        body = json.loads(response.get_body())
        assert response.status_code == expected and body["error"] == "provider_delivery_failed"
        assert "nonce" not in body
        send.assert_called_once()  # No API-key-only resend after the optional bearer is rejected.
        assert send.call_args.kwargs["headers"]["Authorization"] == "Bearer provider-token"
        assert send.call_args.kwargs["headers"]["X-MEMS-API-Key"] == "test-key"
        assert send.call_args.kwargs["allow_redirects"] is False
        upstream.close.assert_called_once()
    function_app._engine.env["EPP_PROVIDER_AUTH_MODE"] = "oauth2"
    send.reset_mock()
    for timed_out, status in ((False, 502), (True, 504)):
        function_app._engine.token_acquirer.acquire.side_effect = ProviderTokenError(timed_out=timed_out)
        response = _HANDLER(_request(_envelope()))
        body = json.loads(response.get_body())
        assert response.status_code == status and body["error"] == "provider_delivery_failed"
        assert "nonce" not in body
    send.assert_not_called()


def test_unexpected_handler_error_is_generic_and_does_not_send(monkeypatch, caplog):
    monkeypatch.setattr(function_app, "read_config", Mock(side_effect=RuntimeError("PRIVATE-ERROR")))
    response = _HANDLER(_request({}))
    body = json.loads(response.get_body())
    assert response.status_code == 500 and body["error"] == "delivery_failed"
    assert set(body) == {"error", "correlationId", "requestId"}
    assert "PRIVATE-ERROR" not in response.get_body().decode() + caplog.text
    dispatch_module.requests.request.assert_not_called()
