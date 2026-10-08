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
import src.provider as provider_module
from src.jwe import JweDecryptor
from src.credentials import CredentialTokenService

_KEY = jwk.JWK.generate(kty="RSA", size=2048)
_PRIVATE_PEM = _KEY.export_to_pem(True, None).decode()
_CORRELATION = "2b65f5e5-9628-4894-8ba6-8785c3a9c010"
_NONCE = "test-nonce"
_PHONE = "+14255551234"
_MESSAGE = "  Your code is 123456; keep 7890 unchanged.\nCafé.  "
_CONTEXT = {"nonce": _NONCE, "phoneNumber": _PHONE, "message": _MESSAGE, "locale": "en-US"}
_FIXTURES = json.loads(
    (Path(__file__).resolve().parents[2] / "tests/fixtures/contract.json")
    .read_text(encoding="utf-8"))

_FUNCTION = function_app.app.get_functions()[0]
_HANDLER = _FUNCTION.get_user_function()


@pytest.fixture(autouse=True)
def _isolate(monkeypatch):
    monkeypatch.setenv("EPP_DECRYPTION_KEY_PEM", _PRIVATE_PEM)
    monkeypatch.delenv("EPP_ENCRYPTION_KEY_ID", raising=False)
    monkeypatch.setenv("EPP_PROVIDER_NAME", "soprano")
    monkeypatch.setenv("EPP_PROVIDER_ENDPOINT", "https://qa4.example/oauth/messages")
    monkeypatch.setenv("EPP_PROVIDER_AUTH_MODE", "oauth")
    monkeypatch.delenv("EPP_PROVIDER_CHANNEL", raising=False)
    monkeypatch.delenv("EPP_KEY_VAULT_CACHE_ENABLED", raising=False)
    monkeypatch.delenv("EPP_ACCESS_TOKEN_CACHE_ENABLED", raising=False)
    monkeypatch.setattr(function_app, "_decryptor", JweDecryptor(function_app.os.environ))
    monkeypatch.setattr(function_app, "_credentials", Mock(
        get_credentials=Mock(return_value={"mode": "oauth", "access_token": "provider-token"})))
    monkeypatch.setattr(provider_module.requests, "request", Mock())


def _request(body, headers=None):
    raw = body if isinstance(body, bytes) else json.dumps(body).encode()
    return func.HttpRequest(
        method="POST", url="/api/SendOtp", headers=headers or {}, params={}, body=raw)


def _encrypt(alg="RSA-OAEP-256", enc="A256GCM", kid="test-kid", context=None):
    token = jwe.JWE(
        json.dumps(_CONTEXT if context is None else context).encode(),
        protected=json.dumps({"alg": alg, "enc": enc, "kid": kid}),
    )
    token.add_recipient(_KEY)
    return token.serialize(compact=True)


def _envelope(**overrides):
    payload = {
        "type": "microsoft.mfa.otpDeliver.v1",
        "correlationId": _CORRELATION,
        "channel": 1,
        "mode": 1,
        "ttlSeconds": 60,
        "encryptedDeliveryContext": _encrypt(),
    }
    payload.update(overrides)
    return payload


def _events(caplog):
    return [record for record in caplog.records if hasattr(record, "event_name")]


@pytest.mark.parametrize(("provider", "mode", "switch"), [
    ("telesign", "apiKey", "EPP_KEY_VAULT_CACHE_ENABLED"),
    ("soprano", "oauth", "EPP_ACCESS_TOKEN_CACHE_ENABLED"),
])
def test_disabled_cache_skips_startup_and_evaluation_but_not_live_credentials(monkeypatch, provider, mode, switch):
    monkeypatch.setenv("EPP_PROVIDER_NAME", provider)
    monkeypatch.setenv("EPP_PROVIDER_AUTH_MODE", mode)
    for name in ("EPP_KEY_VAULT_CACHE_ENABLED", "EPP_ACCESS_TOKEN_CACHE_ENABLED"):
        monkeypatch.setenv(name, "false" if name == switch else "PRIVATE-UNUSED")
    function_app._credentials.get_credentials.return_value = {
        "mode": mode, "secret": "key", "identity": "customer", "access_token": "token",
    }
    provider_module.requests.request.return_value = Mock(
        status_code=200, json=Mock(return_value={"status": {"code": 3001} if mode == "apiKey" else "ENROUTE"}))
    function_app._warm_selected_credentials()
    response = _HANDLER(_request(_envelope(mode=2)))
    assert response.status_code == 200 and json.loads(response.get_body())["nonce"] == _NONCE
    function_app._credentials.get_credentials.assert_not_called()
    provider_module.requests.request.assert_not_called()
    for _ in range(2):
        assert _HANDLER(_request(_envelope())).status_code == 200
    assert function_app._credentials.get_credentials.call_count == 2


@pytest.mark.parametrize(("provider", "mode"), [("telesign", "apiKey"), ("soprano", "oauth")])
def test_invalid_cache_setting_fails_live_but_not_evaluation(monkeypatch, caplog, provider, mode):
    monkeypatch.setenv("EPP_PROVIDER_NAME", provider)
    monkeypatch.setenv("EPP_PROVIDER_AUTH_MODE", mode)
    monkeypatch.setenv("EPP_KEY_VAULT_CACHE_ENABLED", "PRIVATE-INVALID")
    monkeypatch.setenv("EPP_ACCESS_TOKEN_CACHE_ENABLED", "PRIVATE-INVALID")
    secrets = Mock()
    service = CredentialTokenService(secrets)
    monkeypatch.setattr(function_app, "_credentials", service)
    try:
        function_app._warm_selected_credentials()
        assert _HANDLER(_request(_envelope(mode=2))).status_code == 200
        response = _HANDLER(_request(_envelope()))
        assert response.status_code == 502 and "nonce" not in json.loads(response.get_body())
        secrets.resolve.assert_not_called()
        provider_module.requests.request.assert_not_called()
        assert any(record.event_name == "credential_refresh_failed" for record in _events(caplog))
        assert "PRIVATE" not in caplog.text
    finally:
        service.close()


def test_invalid_requests_return_contract_reasons_before_provider_work(caplog):
    caplog.set_level(logging.INFO)
    valid = _envelope(encryptedDeliveryContext="unused")
    for fixture in _FIXTURES["badRequests"]:
        caplog.clear()
        payload = (
            fixture["rawBody"].encode()
            if "rawBody" in fixture
            else {**valid, **fixture["overrides"]}
        )
        response = _HANDLER(_request(payload))
        result = json.loads(response.get_body())
        assert response.status_code == 400
        assert result == {
            "error": "bad_request",
            "reason": fixture["reason"],
            "requestId": result["requestId"],
        }
        assert _events(caplog)[-2].event_name == "response_prepared"
    function_app._credentials.get_credentials.assert_not_called()
    provider_module.requests.request.assert_not_called()


@pytest.mark.parametrize("context", [
    {"nonce": "", "phoneNumber": _PHONE, "message": _MESSAGE},
    {"nonce": _NONCE, "phoneNumber": "", "message": _MESSAGE},
    {"nonce": _NONCE, "phoneNumber": _PHONE, "message": ""},
    False,
    [],
])
def test_incomplete_delivery_context_fails_before_provider_work(context):
    response = _HANDLER(_request(_envelope(
        mode=2, encryptedDeliveryContext=_encrypt(context=context))))
    result = json.loads(response.get_body())
    assert response.status_code == 400
    assert result["error"] == "bad_request"
    assert result["reason"] == "incomplete delivery context"
    assert "nonce" not in result
    function_app._credentials.get_credentials.assert_not_called()


def test_evaluation_validates_and_decrypts_without_provider_work(monkeypatch, caplog):
    caplog.set_level(logging.INFO)
    monkeypatch.delenv("EPP_PROVIDER_NAME")
    monkeypatch.setenv("EPP_ENCRYPTION_KEY_ID", "configured-key")
    selection = Mock(side_effect=AssertionError("evaluation must not select a provider"))
    monkeypatch.setattr(function_app, "_select_provider", selection)
    response = _HANDLER(_request(_envelope(mode="Evaluation")))
    assert response.status_code == 200
    assert json.loads(response.get_body()) == {
        "nonce": _NONCE,
        "correlationId": _CORRELATION,
        "providerStatus": "accepted",
    }
    selection.assert_not_called()
    function_app._credentials.get_credentials.assert_not_called()
    provider_module.requests.request.assert_not_called()
    assert [record.event_name for record in _events(caplog)] == [
        "request_received",
        "payload_validated",
        "delivery_context_decrypted",
        "encryption_key_id_mismatch",
        "evaluation_completed",
        "response_prepared",
        "request_completed",
    ]


@pytest.mark.parametrize("alg,enc,accepted", [
    ("RSA-OAEP-256", "A256GCM", True),
    ("RSA-OAEP", "A256GCM", False),
    ("RSA-OAEP-256", "A128GCM", False),
])
def test_jwe_algorithms_are_pinned(alg, enc, accepted):
    compact = _encrypt(alg=alg, enc=enc)
    response = _HANDLER(_request(_envelope(mode=2, encryptedDeliveryContext=compact)))
    assert response.status_code == (200 if accepted else 400)
    result = json.loads(response.get_body())
    assert ("nonce" in result) is accepted
    if not accepted:
        assert result["error"] == "decryption_failed"


def test_jwe_tampering_fails_before_provider_work():
    segments = _encrypt().split(".")
    segments[-1] = ("A" if segments[-1][0] != "A" else "B") + segments[-1][1:]
    for compact in (".".join(segments), ".".join(segments[:4])):
        response = _HANDLER(_request(_envelope(
            encryptedDeliveryContext=compact)))
        assert response.status_code == 400
        assert json.loads(response.get_body())["error"] == "decryption_failed"
    function_app._credentials.get_credentials.assert_not_called()
    provider_module.requests.request.assert_not_called()


def test_live_acceptance_waits_for_provider_and_preserves_wire_message(monkeypatch, caplog):
    caplog.set_level(logging.INFO)
    entered, release = Event(), Event()
    upstream = Mock(
        status_code=202,
        json=Mock(return_value={"status": "ENROUTE", "id": "provider-id"}),
    )

    def wait_for_acceptance(*args, **kwargs):
        entered.set()
        assert release.wait(5)
        return upstream

    send = Mock(side_effect=wait_for_acceptance)
    monkeypatch.setattr(provider_module.requests, "request", send)
    with ThreadPoolExecutor(max_workers=1) as executor:
        pending = executor.submit(
            _HANDLER,
            _request(
                _envelope(channel=2),
                {"x-ms-client-request-id": "wire-message"},
            ),
        )
        try:
            assert entered.wait(5)
            assert not pending.done()
        finally:
            release.set()
        response = pending.result(timeout=5)

    assert response.status_code == 200
    wire = json.loads(send.call_args.kwargs["data"])
    assert wire["voice"]["text2voice"] == {
        "beforePasswordText": "  Your code is ",
        "password": "123456",
        "afterPasswordText": "; keep 7890 unchanged.\nCafé.  ",
        "language": "en-US",
        "gender": 1,
        "loop": 2,
    }
    assert wire["correlationId"] == _CORRELATION
    assert [record.event_name for record in _events(caplog)] == [
        "request_received",
        "payload_validated",
        "delivery_context_decrypted",
        "provider_selected",
        "provider_credential_resolution_started",
        "provider_credential_resolved",
        "provider_request_build_started",
        "provider_request_built",
        "provider_request_started",
        "provider_response_received",
        "provider_response_processed",
        "response_prepared",
        "request_completed",
    ]
    for private in (_NONCE, _PHONE, _MESSAGE, "123456", "provider-token"):
        assert private not in caplog.text


@pytest.mark.parametrize("status,payload,expected,reason", [
    (429, {"status": "ENROUTE"}, 429, "provider_http_error"),
    (200, {"status": "FAILED"}, 502, "provider_rejected"),
    (200, {}, 502, "unrecognized_provider_status"),
])
def test_provider_failures_preserve_safe_classification(
    monkeypatch, caplog, status, payload, expected, reason
):
    caplog.set_level(logging.INFO)
    monkeypatch.setattr(provider_module.requests, "request", Mock(return_value=Mock(
        status_code=status, json=Mock(return_value=payload))))
    response = _HANDLER(_request(_envelope()))
    result = json.loads(response.get_body())
    assert response.status_code == expected
    assert result["error"] == "provider_delivery_failed"
    assert "nonce" not in result
    processed = next(
        record for record in _events(caplog)
        if record.event_name == "provider_response_processed")
    assert processed.failureReason == reason
    assert processed.providerStatus in ("ENROUTE", "FAILED", "unmapped")
    failure = next(
        record for record in _events(caplog)
        if record.event_name == "request_failed")
    assert failure.failureStage == "provider_response"
    assert failure.failureReason == reason


def test_invalid_provider_json_has_specific_failure_reason(monkeypatch, caplog):
    caplog.set_level(logging.INFO)
    monkeypatch.setattr(provider_module.requests, "request", Mock(return_value=Mock(
        status_code=200, json=Mock(side_effect=ValueError("PRIVATE-RESPONSE")))))
    response = _HANDLER(_request(_envelope()))
    assert response.status_code == 502
    processed = next(
        record for record in _events(caplog)
        if record.event_name == "provider_response_processed")
    assert processed.failureReason == "invalid_provider_json"
    assert "PRIVATE-RESPONSE" not in caplog.text


@pytest.mark.parametrize("provider,status,stage,reason", [
    ("unknown", 400, "provider_selection", "unknown_provider"),
    ("soprano", 502, "provider_credentials", "credential_unavailable"),
])
def test_selection_and_credential_failures_are_safe(
    monkeypatch, caplog, provider, status, stage, reason
):
    caplog.set_level(logging.INFO)
    monkeypatch.setenv("EPP_PROVIDER_NAME", provider)
    if stage == "provider_credentials":
        function_app._credentials.get_credentials.side_effect = RuntimeError("PRIVATE")
    response = _HANDLER(_request(_envelope()))
    assert response.status_code == status
    failure = next(
        record for record in _events(caplog)
        if record.event_name == "request_failed")
    assert (failure.failureStage, failure.failureReason) == (stage, reason)
    assert "PRIVATE" not in caplog.text


def test_request_context_is_isolated_between_concurrent_invocations(monkeypatch, caplog):
    caplog.set_level(logging.INFO)
    monkeypatch.setattr(provider_module.requests, "request", Mock(
        side_effect=lambda *args, **kwargs: Mock(
            status_code=201,
            json=Mock(return_value={"status": "ENROUTE", "id": "provider-id"}))))
    requests = [
        _request(_envelope(correlationId=value))
        for value in ("correlation-first", "correlation-second")
    ]
    with ThreadPoolExecutor(max_workers=2) as executor:
        responses = list(executor.map(_HANDLER, requests))
    assert all(response.status_code == 200 for response in responses)
    completed = [
        record for record in _events(caplog)
        if record.event_name == "request_completed"
    ]
    assert len(completed) == 2
    assert len({record.functionRequestId for record in completed}) == 2
    assert {record.__dict__["x-ms-correlation-id"] for record in completed} == {
        "correlation-first", "correlation-second"}


def test_unexpected_handler_error_is_generic(monkeypatch, caplog):
    caplog.set_level(logging.INFO)
    monkeypatch.setattr(
        function_app, "read_config", Mock(side_effect=RuntimeError("PRIVATE-ERROR")))
    response = _HANDLER(_request(_envelope(mode=2)))
    result = json.loads(response.get_body())
    assert response.status_code == 500
    assert result["error"] == "delivery_failed"
    assert "PRIVATE-ERROR" not in response.get_body().decode() + caplog.text
    assert any(record.event_name == "unexpected_error" for record in _events(caplog))


def test_identifier_logging_accepts_only_safe_support_ids(monkeypatch, caplog):
    caplog.set_level(logging.INFO)
    response = _HANDLER(_request(
        _envelope(mode=2, correlationId={"PRIVATE": "VALUE"}),
        {"x-ms-client-request-id": "safe-request-id",
         "x-ms-correlation-id": "safe-header-correlation"},
    ))
    assert response.status_code == 200
    completed = next(
        record for record in _events(caplog)
        if record.event_name == "request_completed")
    assert completed.__dict__["x-ms-client-request-id"] == "safe-request-id"
    assert completed.__dict__["x-ms-correlation-id"] == "safe-header-correlation"
    assert completed.msCorrelationIdSource == "header"
    assert "VALUE" not in caplog.text
