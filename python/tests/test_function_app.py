"""Real Function handler smoke tests and minimal mocked inbound JWT validation."""
import json
import logging
from unittest.mock import Mock

import azure.functions as func
import pytest
from jwcrypto import jwe, jwk

import src.dispatch as dispatch_module
import src.security as security
import function_app

_KEY = jwk.JWK.generate(kty="RSA", size=2048, kid="test-key")

# Resolved once: app.get_functions() rebuilds bindings and rejects a second call.
_HANDLER = function_app.app.get_functions()[0].get_user_function()

_CONTEXT = {
    "nonce": "nonce-secret",
    "phoneNumber": "+14255551234",
    "locale": "locale-secret",
    "message": "message-secret code 123456",
}
_CORRELATION = "correlation-secret"


@pytest.fixture(autouse=True)
def send(monkeypatch, caplog):
    caplog.set_level(logging.INFO)
    request = Mock(return_value=Mock(status_code=200, json=Mock(return_value={
        "messages": [{"status": {"name": "DELIVERED"}}],
    })))
    monkeypatch.setattr(dispatch_module.requests, "request", request)
    monkeypatch.setattr(function_app._engine, "secrets", Mock(resolve=Mock(return_value="key-secret")))
    monkeypatch.setattr(security, "_jwks_client", Mock(side_effect=AssertionError("unexpected JWKS lookup")))
    monkeypatch.setenv("EPP_REQUIRE_AUTH", "false")
    monkeypatch.setenv("EPP_LOG_PLAINTEXT", "true")
    monkeypatch.setenv("EPP_PROVIDER_NAME", "infobip")
    monkeypatch.setenv("EPP_PROVIDER_ENDPOINT", "https://api.infobip.com")
    monkeypatch.setenv("EPP_PROVIDER_AUTH_MODE", "apiKey")
    monkeypatch.setenv("EPP_DECRYPTION_KEY_PEM", _KEY.export_to_pem(private_key=True, password=None).decode("utf-8"))
    for setting in ("WEBSITE_INSTANCE_ID", "WEBSITE_HOSTNAME", "EPP_EXPECTED_CLIENT_ID"):
        monkeypatch.delenv(setting, raising=False)
    return request


def _request(body, headers=None):
    raw = body if isinstance(body, bytes) else json.dumps(body).encode("utf-8")
    return func.HttpRequest(method="POST", url="/api/SendOtp", headers=headers or {}, params={}, body=raw)


def _envelope(**overrides):
    protected = {"alg": "RSA-OAEP-256", "enc": "A256GCM", "kid": "kid-secret"}
    token = jwe.JWE(json.dumps(_CONTEXT).encode("utf-8"), protected=json.dumps(protected))
    token.add_recipient(_KEY)

    envelope = {
        "type": "microsoft.mfa.otpDeliver.v1",
        "tenantId": "tenant-secret",
        "correlationId": _CORRELATION,
        "channel": 1,
        "mode": 1,
        "ttlSeconds": 60,
        "encryptedDeliveryContext": token.serialize(compact=True),
    }
    envelope.update(overrides)
    return envelope


def test_acceptance_preserves_wire_correlation_without_logging_pii(caplog, send):
    envelope = _envelope()
    response = _HANDLER(_request(envelope, {
        "x-ms-correlation-id": "ignored-header-secret", "Authorization": "Bearer token-secret",
    }))
    assert response.status_code == 200
    assert json.loads(response.get_body()) == {
        "nonce": _CONTEXT["nonce"], "correlationId": _CORRELATION, "providerStatus": "accepted",
    }
    send.assert_called_once()
    message = json.loads(send.call_args.kwargs["data"])["messages"][0]
    assert message["destinations"][0] == {"to": _CONTEXT["phoneNumber"], "messageId": _CORRELATION}
    assert message["content"]["text"] == _CONTEXT["message"]
    assert "[EPP] " in caplog.text
    assert "secret" not in caplog.text.lower()
    assert "4255551234" not in caplog.text and "123456" not in caplog.text
    assert "-----BEGIN" not in caplog.text
    assert envelope["encryptedDeliveryContext"] not in caplog.text
    assert all(record.exc_info is None for record in caplog.records)


def test_evaluation_mode_decrypts_but_does_not_send(send):
    response = _HANDLER(_request(_envelope(mode=2)))
    assert response.status_code == 200
    assert json.loads(response.get_body())["nonce"] == _CONTEXT["nonce"]
    send.assert_not_called()


def test_provider_failure_is_generic_for_sas_fallback(caplog, send):
    send.return_value = Mock(status_code=401, json=Mock(return_value={"messages": [{
        "status": {"name": "REJECTED", "description": "provider-error-secret code 123456"},
    }]}))
    response = _HANDLER(_request(_envelope()))
    body = json.loads(response.get_body())
    assert response.status_code == 401
    assert body == {
        "error": "provider_delivery_failed", "status": "failed", "outcome": "Fail",
        "correlationId": _CORRELATION, "requestId": body["requestId"],
    }
    assert "secret" not in caplog.text.lower() and "123456" not in caplog.text


def test_invalid_json_stops_before_delivery(send):
    response = _HANDLER(_request(b"{ malformed"))
    assert response.status_code == 400
    assert json.loads(response.get_body())["reason"] == "invalid JSON body"
    send.assert_not_called()


def test_azure_auth_guard_cannot_be_disabled(monkeypatch, send):
    monkeypatch.setenv("WEBSITE_INSTANCE_ID", "azure-instance")
    response = _HANDLER(_request(_envelope()))
    assert response.status_code == 401
    body = json.loads(response.get_body())
    assert (body["error"], body["reason"]) == ("unauthorized", "token validation failed")
    send.assert_not_called()


@pytest.mark.parametrize("failure", [None, "issuer", "audience"])
def test_token_validation_checks_issuer_and_audience(monkeypatch, failure):
    monkeypatch.setenv("EPP_REQUIRE_AUTH", "true")
    monkeypatch.setenv("EPP_TENANT_ID", "tenant")
    monkeypatch.setenv("EPP_EXPECTED_AUDIENCE", "audience")
    monkeypatch.setenv("EPP_EXPECTED_ISSUER", "issuer")
    client = Mock()
    client.get_signing_key_from_jwt.return_value.key = "signing-key-secret"
    decode = Mock(return_value={
        "iss": "wrong-issuer" if failure == "issuer" else "issuer", "oid": "object-secret",
    })
    if failure == "audience":
        decode.side_effect = security.jwt.InvalidAudienceError("wrong audience")
    monkeypatch.setattr(security, "_jwks_client", Mock(return_value=client))
    monkeypatch.setattr(security.jwt, "decode", decode)
    assert security.validate_token("Bearer token-secret") == (
        (True, None, "object-secret") if failure is None else (False, "token validation failed", None)
    )
    security._jwks_client.assert_called_once_with("tenant")
    client.get_signing_key_from_jwt.assert_called_once_with("token-secret")
    decode.assert_called_once_with(
        "token-secret", "signing-key-secret", algorithms=["RS256"],
        audience="audience", options={"verify_iss": False},
    )
