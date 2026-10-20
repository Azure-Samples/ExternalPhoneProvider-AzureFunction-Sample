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
    monkeypatch.delenv("EPP_PROVIDER_ENDPOINT", raising=False)
    monkeypatch.setenv("EPP_PROVIDER_SMS_ENDPOINT", "https://qa4.example/oauth/messages")
    monkeypatch.setenv("EPP_PROVIDER_VOICE_ENDPOINT", "https://qa4.example/oauth/messages")
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


@pytest.mark.parametrize("channel", [1, 2])
@pytest.mark.parametrize("fields,expected", [
    ({"otp": "001234"}, "001234"), ({}, None), ({"otp": None}, None),
])
def test_optional_otp_reaches_provider_without_evaluation_io(
    monkeypatch, caplog, channel, fields, expected
):
    caplog.set_level(logging.INFO)
    provider = function_app._providers["soprano"]
    build_request = Mock(wraps=provider.build_request)
    monkeypatch.setattr(provider, "build_request", build_request)
    provider_module.requests.request.return_value = Mock(
        status_code=201, json=Mock(return_value={"status": "ENROUTE"}))
    context = {**_CONTEXT, "message": _MESSAGE.replace("123456", "001234"), **fields}
    payload = _envelope(channel=channel, encryptedDeliveryContext=_encrypt(context=context))
    response_body = {
        "nonce": _NONCE, "correlationId": _CORRELATION, "providerStatus": "accepted",
    }

    evaluated = _HANDLER(_request({**payload, "mode": 2}))
    assert evaluated.status_code == 200
    assert json.loads(evaluated.get_body()) == response_body
    build_request.assert_not_called()
    function_app._credentials.get_credentials.assert_not_called()
    provider_module.requests.request.assert_not_called()

    response = _HANDLER(_request(payload))
    assert response.status_code == 200
    assert json.loads(response.get_body()) == response_body
    build_request.assert_called_once()
    delivery = build_request.call_args.args[2]
    assert delivery.otp == expected
    assert delivery.message == context["message"]
    assert delivery.channel == ("sms" if channel == 1 else "voice")
    provider_module.requests.request.assert_called_once()
    assert "001234" not in caplog.text
    assert all("otp" not in record.__dict__ for record in _events(caplog))


@pytest.mark.parametrize("channel", [1, 2])
@pytest.mark.parametrize("fixture", _FIXTURES["riskContexts"], ids=lambda case: case["name"])
def test_risk_context_dictionary_reaches_adapter_without_changing_provider_payload(
    monkeypatch, caplog, channel, fixture
):
    caplog.set_level(logging.INFO)
    provider = function_app._providers["soprano"]
    build_request = Mock(wraps=provider.build_request)
    monkeypatch.setattr(provider, "build_request", build_request)
    provider_module.requests.request.return_value = Mock(
        status_code=201, json=Mock(return_value={"status": "ENROUTE"}))
    context = {**_CONTEXT, **fixture["overrides"]}
    payload = _envelope(channel=channel, encryptedDeliveryContext=_encrypt(context=context))
    expected = {"nonce": _NONCE, "correlationId": _CORRELATION, "providerStatus": "accepted"}

    evaluated = _HANDLER(_request({**payload, "mode": 2}))
    assert evaluated.status_code == 200
    assert json.loads(evaluated.get_body()) == expected
    build_request.assert_not_called()
    function_app._credentials.get_credentials.assert_not_called()
    provider_module.requests.request.assert_not_called()

    response = _HANDLER(_request(payload))
    assert response.status_code == 200
    assert json.loads(response.get_body()) == expected
    build_request.assert_called_once()
    delivery = build_request.call_args.args[2]
    assert json.dumps(delivery.risk_context) == json.dumps(context.get("riskContext"))
    assert delivery.message == _MESSAGE
    assert delivery.channel == ("sms" if channel == 1 else "voice")
    assert "PRIVATE-RISK" not in repr(delivery)
    provider_module.requests.request.assert_called_once()
    sent_body = provider_module.requests.request.call_args.kwargs["data"]
    assert _HANDLER(_request(_envelope(channel=channel))).status_code == 200
    assert provider_module.requests.request.call_args.kwargs["data"] == sent_body
    assert "riskContext" not in sent_body
    assert "PRIVATE-RISK" not in caplog.text
    assert "PRIVATE-RISK" not in json.dumps([vars(record) for record in _events(caplog)], default=str)
    assert all("riskContext" not in record.__dict__ and "risk_context" not in record.__dict__
               for record in _events(caplog))


@pytest.mark.parametrize("mode", [1, 2])
@pytest.mark.parametrize("risk_context", _FIXTURES["invalidRiskContexts"])
def test_non_object_risk_context_fails_before_provider_work(caplog, mode, risk_context):
    caplog.set_level(logging.INFO)
    response = _HANDLER(_request(_envelope(
        mode=mode, encryptedDeliveryContext=_encrypt(context={**_CONTEXT, "riskContext": risk_context}))))
    result = json.loads(response.get_body())
    assert response.status_code == 400
    assert result["error"] == "bad_request"
    assert result["reason"] == "incomplete delivery context"
    assert "nonce" not in result
    assert "PRIVATE-RISK" not in response.get_body().decode()
    assert "PRIVATE-RISK" not in caplog.text
    assert "PRIVATE-RISK" not in json.dumps([vars(record) for record in _events(caplog)], default=str)
    failure = next(record for record in _events(caplog) if record.event_name == "request_failed")
    assert failure.failureStage == "delivery_context_validation"
    function_app._credentials.get_credentials.assert_not_called()
    provider_module.requests.request.assert_not_called()


@pytest.mark.parametrize(("provider", "mode"), [
    ("telesign", "apiKey"),
    ("soprano", "oauth"),
])
def test_only_live_requests_acquire_credentials(monkeypatch, provider, mode):
    monkeypatch.setenv("EPP_PROVIDER_NAME", provider)
    monkeypatch.setenv("EPP_PROVIDER_AUTH_MODE", mode)
    for name in ("EPP_KEY_VAULT_CACHE_ENABLED", "EPP_ACCESS_TOKEN_CACHE_ENABLED"):
        monkeypatch.setenv(name, "PRIVATE-OBSOLETE")
    function_app._credentials.get_credentials.return_value = {
        "mode": mode, "secret": "key", "identity": "customer", "access_token": "token",
    }
    provider_module.requests.request.return_value = Mock(
        status_code=200, json=Mock(return_value={"status": {"code": 3001} if mode == "apiKey" else "ENROUTE"}))
    response = _HANDLER(_request(_envelope(mode=2)))
    assert response.status_code == 200 and json.loads(response.get_body())["nonce"] == _NONCE
    function_app._credentials.get_credentials.assert_not_called()
    provider_module.requests.request.assert_not_called()
    for _ in range(2):
        assert _HANDLER(_request(_envelope())).status_code == 200
    assert function_app._credentials.get_credentials.call_count == 2


def test_credential_failure_is_request_correlated_and_next_request_recovers(monkeypatch, caplog):
    caplog.set_level(logging.INFO)
    monkeypatch.setenv("EPP_PROVIDER_NAME", "telesign")
    monkeypatch.setenv("EPP_PROVIDER_AUTH_MODE", "apiKey")
    monkeypatch.setenv("EPP_KEY_VAULT_CACHE_ENABLED", "PRIVATE-OBSOLETE")
    monkeypatch.setenv("EPP_ACCESS_TOKEN_CACHE_ENABLED", "PRIVATE-OBSOLETE")
    secrets = Mock(resolve=Mock(side_effect=ValueError("PRIVATE-SDK-FAILURE")))
    service = CredentialTokenService(secrets)
    monkeypatch.setattr(function_app, "_credentials", service)
    try:
        assert _HANDLER(_request(_envelope(mode=2))).status_code == 200
        secrets.resolve.assert_not_called()
        response = _HANDLER(_request(_envelope()))
        assert response.status_code == 502 and "nonce" not in json.loads(response.get_body())
        provider_module.requests.request.assert_not_called()
        failure = next(record for record in _events(caplog) if record.event_name == "request_failed")
        assert failure.failureStage == "provider_credentials"
        assert failure.failureReason == "credential_unavailable"
        secrets.resolve.side_effect = None
        secrets.resolve.return_value = "key"
        provider_module.requests.request.return_value = Mock(
            status_code=200, json=Mock(return_value={"status": {"code": 3001}}))
        assert _HANDLER(_request(_envelope())).status_code == 200
        assert secrets.resolve.call_count == 4
        provider_module.requests.request.assert_called_once()
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
    {**_CONTEXT, "otp": 123456},
    {**_CONTEXT, "otp": True},
    {**_CONTEXT, "otp": []},
    {**_CONTEXT, "otp": {}},
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


@pytest.mark.parametrize("provider", ["telesign", "soprano"])
@pytest.mark.parametrize("legacy_channel", [None, "sms", "voice", "invalid"])
def test_request_selects_either_channel_regardless_of_legacy_setting(monkeypatch, provider, legacy_channel):
    mode = "apiKey" if provider == "telesign" else "oauth"
    monkeypatch.setenv("EPP_PROVIDER_NAME", provider)
    monkeypatch.setenv("EPP_PROVIDER_AUTH_MODE", mode)
    if legacy_channel is not None:
        monkeypatch.setenv("EPP_PROVIDER_CHANNEL", legacy_channel)
    function_app._credentials.get_credentials.return_value = {
        "mode": mode, "secret": "key", "identity": "customer", "access_token": "token",
    }
    provider_module.requests.request.return_value = Mock(
        status_code=200,
        json=Mock(return_value={"status": {"code": 3001} if provider == "telesign" else "ENROUTE"}),
    )

    for channel, channel_name in [(1, "sms"), ("SMS", "sms"), (2, "voice"), ("VOICE", "voice")]:
        response = _HANDLER(_request(_envelope(channel=channel)))
        assert response.status_code == 200
        assert json.loads(response.get_body())["nonce"] == _NONCE
        call = provider_module.requests.request.call_args
        endpoint_key = "EPP_PROVIDER_VOICE_ENDPOINT" if channel_name == "voice" else "EPP_PROVIDER_SMS_ENDPOINT"
        assert call.args[1] == function_app.os.environ[endpoint_key]
        body = json.loads(call.kwargs["data"])
        if provider == "telesign":
            assert body["channels"] == [{"channel": channel_name}]
        else:
            assert body["messageTypes"] == [channel_name]
    assert provider_module.requests.request.call_count == 4


@pytest.mark.parametrize("provider,payload,sms_path,voice_path", [
    ("telesign", {"status": {"code": 3001}}, "", ""),
    ("soprano", {"status": "ENROUTE"}, "", ""),
    ("infobip", {"messages": [{"status": {"groupName": "PENDING"}}]}, "/sms/3/messages", "/tts/3/advanced"),
    ("sinch", {"id": "provider-id"}, "/xms/v1/plan/batches", "/calling/v1/callouts"),
])
def test_request_channel_selects_distinct_configured_endpoints(monkeypatch, provider, payload, sms_path, voice_path):
    mode = "oauth" if provider == "soprano" else "apiKey"
    monkeypatch.setenv("EPP_PROVIDER_NAME", provider)
    monkeypatch.setenv("EPP_PROVIDER_AUTH_MODE", mode)
    monkeypatch.setenv("EPP_PROVIDER_SMS_ENDPOINT", "https://sms.provider.example/send")
    monkeypatch.setenv("EPP_PROVIDER_VOICE_ENDPOINT", "https://voice.provider.example/send")
    monkeypatch.setenv("SINCH_SERVICE_PLAN_ID", "plan")
    monkeypatch.setenv("SINCH_VOICE_ENDPOINT", "https://legacy.provider.example")
    function_app._credentials.get_credentials.return_value = {
        "mode": mode, "secret": "key", "identity": "customer", "access_token": "token",
    }
    provider_module.requests.request.return_value = Mock(status_code=200, json=Mock(return_value=payload))
    for legacy_endpoint in [None, "https://legacy.provider.example"]:
        if legacy_endpoint is None:
            monkeypatch.delenv("EPP_PROVIDER_ENDPOINT", raising=False)
        else:
            monkeypatch.setenv("EPP_PROVIDER_ENDPOINT", legacy_endpoint)
        for channel, endpoint, path in [
            (1, "https://sms.provider.example/send", sms_path),
            (2, "https://voice.provider.example/send", voice_path),
        ]:
            response = _HANDLER(_request(_envelope(channel=channel)))
            assert response.status_code == 200
            assert json.loads(response.get_body())["nonce"] == _NONCE
            assert provider_module.requests.request.call_args.args[1] == endpoint + path
    assert provider_module.requests.request.call_count == 4


@pytest.mark.parametrize("channel", ["sms", "voice"])
def test_channel_requires_its_endpoint_without_legacy_or_cross_channel_fallback(monkeypatch, channel):
    selected = "EPP_PROVIDER_SMS_ENDPOINT" if channel == "sms" else "EPP_PROVIDER_VOICE_ENDPOINT"
    other = "EPP_PROVIDER_VOICE_ENDPOINT" if channel == "sms" else "EPP_PROVIDER_SMS_ENDPOINT"
    monkeypatch.setenv("EPP_PROVIDER_ENDPOINT", "https://legacy.provider.example/send")
    monkeypatch.setenv(other, "https://other.provider.example/send")
    provider_module.requests.request.return_value = Mock(status_code=200, json=Mock(return_value={"status": "ENROUTE"}))
    for value in [None, "", "   ", "http://invalid.provider.example"]:
        if value is None:
            monkeypatch.delenv(selected, raising=False)
        else:
            monkeypatch.setenv(selected, value)
        response = _HANDLER(_request(_envelope(channel=channel)))
        assert response.status_code == 502
        assert "nonce" not in json.loads(response.get_body())
        assert _HANDLER(_request(_envelope(channel=channel, mode=2))).status_code == 200
    provider_module.requests.request.assert_not_called()

    monkeypatch.setenv(selected, "https://selected.provider.example/send")
    monkeypatch.setenv(other, "http://invalid.provider.example")
    assert _HANDLER(_request(_envelope(channel=channel))).status_code == 200
    assert provider_module.requests.request.call_args.args[1] == function_app.os.environ[selected]
    assert provider_module.requests.request.call_count == 1


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
