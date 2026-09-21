import base64
import json
import logging
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from threading import Event
from types import SimpleNamespace
from unittest.mock import Mock

import azure.functions as func
import pytest
from jwcrypto import jwe, jwk

import function_app
import src.dispatch as dispatch_module
from src.request_log import RequestLog

_KEY = jwk.JWK.generate(kty="RSA", size=2048)
_PRIVATE_PEM = _KEY.export_to_pem(private_key=True, password=None).decode()
_CORRELATION = "2b65f5e5-9628-4894-8ba6-8785c3a9c010"
_NONCE = "test-nonce"
_PHONE = "+14255551234"
_MESSAGE = "  Your code is 123456; keep 7890 unchanged.\nCafé.  "
_CONTEXT = {"nonce": _NONCE, "phoneNumber": _PHONE, "message": _MESSAGE, "locale": "en-US"}
_FIXTURES = json.loads((Path(__file__).resolve().parents[2] / "tests/fixtures/contract.json").read_text(encoding="utf-8"))

# get_functions() cannot be called twice on the same app.
_FUNCTION = function_app.app.get_functions()[0]
_HANDLER = _FUNCTION.get_user_function()
_FUNCTION_NAME = _FUNCTION.get_function_name()


@pytest.fixture(autouse=True)
def _isolate(monkeypatch):
    monkeypatch.delenv("EPP_ENCRYPTION_KEY_ID", raising=False)
    monkeypatch.setenv("EPP_PROVIDER_NAME", "SOPRANO")
    monkeypatch.setattr(function_app, "_key_provider", Mock(return_value=_PRIVATE_PEM))
    engine = dispatch_module.DispatchEngine(
        function_app._registry, Mock(resolve=Mock(return_value="test-key")),
        {"EPP_PROVIDER_NAME": "soprano", "EPP_PROVIDER_ENDPOINT": "https://qa4.example/oauth/messages",
         "EPP_PROVIDER_AUTH_MODE": "oauth"},
    )
    engine._resolve_credential = Mock(return_value={"mode": "oauth", "access_token": "provider-token"})
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


def _records(caplog):
    return [json.loads(record.getMessage()) for record in caplog.records]


def _summary(caplog):
    records = _records(caplog)
    summaries = [record for record in records if record["logType"] == "request"]
    assert len(summaries) == 1
    summary = summaries[0]
    assert summary == records[-1]
    assert summary["eventName"] == "request_completed"
    assert set(summary) == set(_FIXTURES["logging"]["summaryFields"])
    assert all(record["logType"] == "service" for record in records[:-1])
    assert all(record["functionRequestId"] == summary["functionRequestId"] for record in records)
    assert all(record["functionInvocationId"] == summary["functionInvocationId"] for record in records)
    assert all(record["functionName"] == _FUNCTION_NAME for record in records)
    assert summary["elapsedMs"] >= 0
    prepared = [record for record in records if record["eventName"] == "response_prepared"]
    assert len(prepared) == 1 and prepared[0] == records[-2]
    assert prepared[0]["httpStatus"] == summary["httpStatus"]
    assert prepared[0]["responseContainsNonce"] is summary["responseContainsNonce"]
    assert prepared[0]["responseContainsCorrelationId"] is summary["responseContainsCorrelationId"]
    assert summary["responseContainsNonce"] is (summary["httpStatus"] == 200)
    for private in (_NONCE, _PHONE, _MESSAGE, "PRIVATE", "test-key", "provider-token"):
        assert private not in caplog.text
    return summary


def test_jwe_tag_tampering_and_missing_segments_fail_before_provider_io(monkeypatch, caplog):
    monkeypatch.setenv("EPP_ENCRYPTION_KEY_ID", "configured-key-id")
    segments = _encrypt().split(".")
    tag = segments[-1]
    segments[-1] = ("A" if tag[0] != "A" else "B") + tag[1:]
    for compact in (".".join(segments), ".".join(segments[:4])):
        response = _HANDLER(_request(_envelope(encryptedDeliveryContext=compact)))
        assert response.status_code == 400 and json.loads(response.get_body())["error"] == "decryption_failed"
    assert "encryption_key_id_mismatch" not in caplog.text
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


def test_evaluation_decrypts_without_provider_configuration_or_work(monkeypatch, caplog):
    caplog.set_level(logging.INFO)
    monkeypatch.setenv("EPP_ENCRYPTION_KEY_ID", "configured-key-id")
    monkeypatch.delenv("EPP_PROVIDER_NAME")
    function_app._engine.env.clear()
    lookup = Mock()
    monkeypatch.setattr(function_app._registry, "get", lookup)
    response = _HANDLER(_request(_envelope(mode="Evaluation", provider="untrusted-body-provider")))
    assert response.status_code == 200
    assert json.loads(response.get_body()) == {
        "nonce": _NONCE, "correlationId": _CORRELATION, "providerStatus": "accepted",
    }
    function_app._key_provider.assert_called_once_with("test-kid")
    warnings = [json.loads(record.getMessage())["eventName"] for record in caplog.records if record.levelno == logging.WARNING]
    assert warnings == ["encryption_key_id_mismatch"]
    assert [record["eventName"] for record in _records(caplog)
            if record["eventName"] != "encryption_key_id_mismatch"] == _FIXTURES["logging"]["evaluationEvents"]
    summary = _summary(caplog)
    assert summary["encryptionKeyIdMismatch"] is True
    assert summary["evaluation"] is True and summary["result"] == "evaluated"
    assert summary["providerName"] is None and summary["providerAttempted"] is False
    assert summary["providerHttpStatus"] is None and summary["providerElapsedMs"] is None
    assert summary["providerCredentialSource"] is None and summary["providerCredentialElapsedMs"] is None
    assert summary["providerEndpoint"] is None
    assert all(value not in caplog.text for value in ("configured-key-id", "test-kid", "untrusted-body-provider"))
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
    monkeypatch.setattr(dispatch_module.requests, "request", send)
    speech = {"beforePasswordText": "Your code is", "password": "001234", "language": "en-US"}
    with ThreadPoolExecutor(max_workers=1) as executor:
        request = _request(_envelope(channel=2, encryptedDeliveryContext=_encrypt(
            context={**_CONTEXT, "textToVoice": speech})), {"x-ms-client-request-id": "wire-message"})
        pending = executor.submit(_HANDLER, request)
        try:
            assert entered.wait(5), "handler did not reach provider"
            assert not pending.done()
            assert not any(record["logType"] == "request" for record in _records(caplog))
            assert _records(caplog)[-1]["eventName"] == "provider_request_started"
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
    assert wire["voice"] == {"text2voice": {
        "beforePasswordText": "  Your code is ",
        "password": "123456",
        "afterPasswordText": "; keep 7890 unchanged.\nCafé.  ",
        "language": "en-US",
        "gender": 1,
        "loop": 2,
    }}
    assert "text" not in wire and wire["messageTypes"] == ["voice"] and wire["correlationId"] == _CORRELATION
    summary = _summary(caplog)
    assert [record["eventName"] for record in _records(caplog)] == _FIXTURES["logging"]["liveEvents"]
    assert summary["x-ms-correlation-id"] == _CORRELATION
    assert summary["x-ms-client-request-id"] == "wire-message"
    assert summary["providerName"] == "soprano" and summary["providerAuthMode"] == "oauth"
    assert summary["providerHttpStatus"] == 202 and summary["providerStatus"] == "ENROUTE"
    assert summary["providerOutcome"] == "Continue" and summary["providerAttempted"] is True
    assert summary["channel"] == "voice" and summary["failureStage"] is None
    assert summary["providerTimeoutMs"] == 1500
    assert 0 <= summary["providerElapsedMs"] <= summary["elapsedMs"]
    for private in (_NONCE, _PHONE, _MESSAGE, "123456", "001234", "test-key"):
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


def test_unexpected_handler_error_is_generic_and_does_not_send(monkeypatch, caplog):
    caplog.set_level(logging.INFO)
    monkeypatch.setattr(function_app, "read_config", Mock(side_effect=RuntimeError("PRIVATE-ERROR")))
    response = _HANDLER(_request({}))
    body = json.loads(response.get_body())
    assert response.status_code == 500 and body["error"] == "delivery_failed"
    assert set(body) == {"error", "correlationId", "requestId"}
    assert "PRIVATE-ERROR" not in response.get_body().decode() + caplog.text
    assert _summary(caplog)["failureStage"] == "handler"
    assert _summary(caplog)["failureReason"] == "unexpected_error"
    dispatch_module.requests.request.assert_not_called()


def test_identifier_sources_are_explicit_and_missing_microsoft_ids_are_not_generated(monkeypatch, caplog):
    caplog.set_level(logging.INFO)
    upstream = Mock(status_code=201, json=Mock(return_value={
        "status": "ENROUTE", "id": "provider-reference-id", "description": "PRIVATE-DESCRIPTION",
    }))
    monkeypatch.setattr(dispatch_module.requests, "request", Mock(return_value=upstream))
    headers = {"x-ms-client-request-id": "ms-request-id", "x-ms-correlation-id": "ms-header-correlation-id"}
    for correlation_id in ("ms-envelope-correlation-id", None):
        caplog.clear()
        context = SimpleNamespace(invocation_id="function-invocation-id", function_name=_FUNCTION_NAME)
        response = _HANDLER(_request(_envelope(correlationId=correlation_id), headers), context)
        assert response.status_code == 200
        summary = _summary(caplog)
        assert summary["x-ms-client-request-id"] == headers["x-ms-client-request-id"]
        assert summary["x-ms-correlation-id"] == (correlation_id or headers["x-ms-correlation-id"])
        assert summary["msCorrelationIdSource"] == ("envelope" if correlation_id else "header")
        assert _records(caplog)[0]["msCorrelationIdSource"] == "header"
        assert summary["functionInvocationId"] == "function-invocation-id"
        assert summary["providerMessageId"] == "provider-reference-id"
        assert summary["functionRequestId"] not in (summary["x-ms-client-request-id"], summary["functionInvocationId"])
    caplog.clear()
    response = _HANDLER(_request(_envelope(correlationId=None)))
    summary = _summary(caplog)
    assert json.loads(response.get_body())["correlationId"] == summary["functionRequestId"]
    assert summary["x-ms-client-request-id"] is None and summary["x-ms-correlation-id"] is None
    assert summary["msCorrelationIdSource"] == "none" and summary["functionInvocationId"] is None


@pytest.mark.parametrize("scenario,status,stage,reason,attempted", [
    ("invalid_json", 400, "request_validation", "invalid JSON body", False),
    ("invalid_envelope", 400, "request_validation", "unsupported envelope type", False),
    ("decryption", 400, "decryption", "decryption_failed", False),
    ("incomplete_context", 400, "delivery_context_validation", "incomplete delivery context", False),
    ("unknown_provider", 400, "provider_selection", "unknown_provider", False),
    ("wrong_channel", 400, "provider_configuration", "channel_not_configured", False),
    ("authentication_mismatch", 502, "provider_configuration", "authentication_mode_mismatch", False),
    ("invalid_endpoint", 502, "provider_configuration", "invalid_provider_endpoint", False),
    ("credentials", 502, "provider_credentials", "credential_unavailable", False),
    ("request_build", 502, "provider_request_build", "request_build_failed", False),
    ("timeout", 504, "provider_transport", "provider_timeout", True),
    ("body_timeout", 504, "provider_transport", "provider_timeout", True),
    ("network", 502, "provider_transport", "provider_network_error", True),
    ("response_parse", 502, "provider_response", "response_parse_failed", True),
    ("http_rejection", 429, "provider_response", "provider_rejected", True),
])
def test_failures_emit_separate_events_and_complete_summaries(monkeypatch, caplog, scenario, status, stage, reason, attempted):
    caplog.set_level(logging.INFO)
    payload = _envelope()
    upstream = Mock(status_code=201, json=Mock(return_value={"status": "ENROUTE"}))
    send = Mock(return_value=upstream)
    monkeypatch.setattr(dispatch_module.requests, "request", send)
    engine = function_app._engine
    adapter = engine.registry.get("soprano")
    if scenario == "invalid_json":
        payload = b"{"
    elif scenario == "invalid_envelope":
        payload = {}
    elif scenario == "decryption":
        payload["encryptedDeliveryContext"] = "PRIVATE-NOT-A-JWE"
    elif scenario == "incomplete_context":
        payload["encryptedDeliveryContext"] = _encrypt(context={**_CONTEXT, "nonce": ""})
    elif scenario == "unknown_provider":
        engine.env["EPP_PROVIDER_NAME"] = "PRIVATE-UNKNOWN-PROVIDER"
    elif scenario == "wrong_channel":
        engine.env["EPP_PROVIDER_CHANNEL"] = "voice"
    elif scenario == "authentication_mismatch":
        engine.env["EPP_PROVIDER_AUTH_MODE"] = "apiKey"
    elif scenario == "invalid_endpoint":
        engine.env["EPP_PROVIDER_ENDPOINT"] = "http://PRIVATE-ENDPOINT"
    elif scenario == "credentials":
        engine._resolve_credential.side_effect = RuntimeError("PRIVATE-CREDENTIAL-ERROR")
    elif scenario == "request_build":
        monkeypatch.setattr(adapter, "build_request", Mock(side_effect=RuntimeError("PRIVATE-BUILD-ERROR")))
    elif scenario == "timeout":
        send.side_effect = dispatch_module.requests.exceptions.Timeout("PRIVATE-TIMEOUT")
    elif scenario == "body_timeout":
        upstream.json.side_effect = dispatch_module.requests.exceptions.Timeout("PRIVATE-BODY-TIMEOUT")
    elif scenario == "network":
        send.side_effect = dispatch_module.requests.exceptions.ConnectionError("PRIVATE-NETWORK-ERROR")
    elif scenario == "response_parse":
        monkeypatch.setattr(adapter, "parse_response", Mock(side_effect=RuntimeError("PRIVATE-PARSE-ERROR")))
    elif scenario == "http_rejection":
        upstream.status_code = 429
    headers = {"x-ms-client-request-id": "ms-request-id", "x-ms-correlation-id": "ms-header-correlation-id"}
    response = _HANDLER(_request(payload, headers))
    summary = _summary(caplog)
    assert response.status_code == status == summary["httpStatus"]
    assert summary["functionRequestId"] == json.loads(response.get_body())["requestId"]
    assert summary["failureStage"] == stage and summary["failureReason"] == reason
    assert summary["x-ms-client-request-id"] == headers["x-ms-client-request-id"]
    assert summary["msCorrelationIdSource"] == ("header" if stage == "request_validation" else "envelope")
    assert summary["x-ms-correlation-id"] == (
        headers["x-ms-correlation-id"] if stage == "request_validation" else _CORRELATION)
    assert summary["providerAttempted"] is attempted and send.call_count == int(attempted)
    assert summary["result"] == "failed"
    assert _records(caplog)[-3]["eventName"] == ("provider_response_processed" if scenario == "http_rejection" else f"{stage}_failed")
    assert summary["responseContainsNonce"] is False
    assert summary["responseContainsCorrelationId"] is ("correlationId" in json.loads(response.get_body()))
    if scenario == "credentials":
        assert summary["providerCredentialSource"] == "managed_identity_client_assertion"
        assert 0 <= summary["providerCredentialElapsedMs"] <= summary["elapsedMs"]
        assert not any(record["eventName"] == "provider_credential_resolved" for record in _records(caplog))
    assert any(record.levelno == (logging.ERROR if status >= 500 else logging.WARNING) for record in caplog.records)
    if attempted:
        assert summary["providerTimeoutMs"] == 1500
        assert 0 <= summary["providerElapsedMs"] <= summary["elapsedMs"]
    if scenario == "body_timeout":
        assert summary["providerHttpStatus"] == 201 and summary["providerStatus"] is None


@pytest.mark.parametrize("correlation", [42, {"detail": "support-correlation-id"}, ["support-correlation-id"], ""])
def test_invalid_correlation_metadata_cannot_leak_or_prevent_summary(caplog, correlation):
    caplog.set_level(logging.INFO)
    response = _HANDLER(_request(_envelope(mode=2, correlationId=correlation)))
    assert response.status_code == 200
    summary = _summary(caplog)
    assert summary["x-ms-correlation-id"] is None and summary["msCorrelationIdSource"] == "none"


@pytest.mark.parametrize("valid_json", [True, False])
def test_provider_diagnostics_never_log_unknown_statuses_or_response_bodies(monkeypatch, caplog, valid_json):
    caplog.set_level(logging.INFO)
    upstream = Mock(status_code=200, json=Mock(return_value={
        "status": "PRIVATE-STATUS\nFORGED", "id": "provider-reference-id", "description": "PRIVATE-DESCRIPTION",
    }))
    if not valid_json:
        upstream.json.side_effect = ValueError("PRIVATE-RESPONSE")
    monkeypatch.setattr(dispatch_module.requests, "request", Mock(return_value=upstream))
    response = _HANDLER(_request(_envelope()))
    summary = _summary(caplog)
    assert response.status_code == 502
    assert summary["providerStatus"] == "unmapped" and summary["providerOutcome"] == "Fail"
    assert summary["failureReason"] == ("provider_rejected" if valid_json else "invalid_provider_json")
    assert "FORGED" not in caplog.text


def test_interleaved_invocations_keep_separate_log_contexts(monkeypatch, caplog):
    caplog.set_level(logging.INFO)
    monkeypatch.setattr(dispatch_module.requests, "request", Mock(
        side_effect=lambda *args, **kwargs: Mock(status_code=201, json=Mock(return_value={"status": "ENROUTE"}))))
    requests = [_request(_envelope(correlationId=value)) for value in ("correlation-first", "correlation-second")]
    with ThreadPoolExecutor(max_workers=2) as executor:
        results = list(executor.map(_HANDLER, requests))
    assert all(result.status_code == 200 for result in results)
    records = _records(caplog)
    summaries = [record for record in records if record["logType"] == "request"]
    assert len(summaries) == 2
    assert len({record["functionRequestId"] for record in summaries}) == 2
    assert {record["x-ms-correlation-id"] for record in summaries} == {"correlation-first", "correlation-second"}
    for summary in summaries:
        events = [record for record in records if record["functionRequestId"] == summary["functionRequestId"]]
        assert [record["eventName"] for record in events] == _FIXTURES["logging"]["liveEvents"]
        assert all(record["x-ms-correlation-id"] == summary["x-ms-correlation-id"] for record in events[1:])
    assert "PRIVATE" not in caplog.text


def test_successful_lifecycle_logs_only_allowed_body_fields_oauth_ids_and_final_endpoint(monkeypatch, caplog):
    caplog.set_level(logging.INFO)
    engine = function_app._engine
    engine.env.update({
        "EPP_PROVIDER_ENDPOINT": "https://provider.example/api/send?key=PRIVATE-QUERY",
        "EPP_PROVIDER_TENANT_ID": "provider-tenant-id",
        "EPP_OUTBOUND_CLIENT_ID": "outbound-client-id",
        "EPP_OUTBOUND_MI_CLIENT_ID": "outbound-mi-client-id",
    })
    monkeypatch.setattr(dispatch_module.requests, "request", Mock(return_value=Mock(
        status_code=201, json=Mock(return_value={"status": "ENROUTE"}))))
    payload = _envelope(tenantId="PRIVATE-TENANT", diagnosticData={"token": "PRIVATE-UNKNOWN-FIELD"})
    response = _HANDLER(_request(payload, {"authorization": "PRIVATE-INBOUND-AUTH"}))
    assert response.status_code == 200
    summary = _summary(caplog)
    records = _records(caplog)
    validated = next(record for record in records if record["eventName"] == "envelope_validated")
    assert validated["envelopeType"] == summary["envelopeType"] == payload["type"]
    assert validated["ttlSeconds"] == summary["ttlSeconds"] == 60
    assert validated["encryptedDeliveryContextPresent"] is True
    credentials = [record for record in records if record["eventName"] in (
        "provider_credential_resolution_started", "provider_credential_resolved")]
    assert len(credentials) == 2
    for record in [summary, *credentials]:
        assert record["providerCredentialSource"] == "managed_identity_client_assertion"
        assert record["providerTenantId"] == engine.env["EPP_PROVIDER_TENANT_ID"]
        assert record["functionOutboundClientId"] == engine.env["EPP_OUTBOUND_CLIENT_ID"]
        assert record["functionOutboundManagedIdentityClientId"] == engine.env["EPP_OUTBOUND_MI_CLIENT_ID"]
    assert 0 <= summary["providerCredentialElapsedMs"] <= summary["elapsedMs"]
    for record in [summary, *[record for record in records if record["eventName"] in (
        "provider_request_built", "provider_request_started")]]:
        assert record["providerHttpMethod"] == "POST"
        assert record["providerEndpoint"] == "https://provider.example/api/send"
    built = next(record for record in records if record["eventName"] == "provider_request_built")
    assert built["providerScheme"] == "https" and built["redirectsAllowed"] is False
    assert payload["encryptedDeliveryContext"] not in caplog.text
    assert summary["responseContainsNonce"] is True and summary["responseContainsCorrelationId"] is True
    assert [record["eventName"] for record in records] == _FIXTURES["logging"]["liveEvents"]


def test_api_key_lifecycle_identifies_key_vault_resolution_without_logging_credentials(monkeypatch, caplog):
    caplog.set_level(logging.INFO)
    engine = function_app._engine
    engine.env.update({"EPP_PROVIDER_NAME": "telesign", "EPP_PROVIDER_AUTH_MODE": "apiKey"})
    monkeypatch.setattr(engine, "_resolve_credential",
                        dispatch_module.DispatchEngine._resolve_credential.__get__(engine))
    monkeypatch.setattr(dispatch_module.requests, "request", Mock(return_value=Mock(
        status_code=200, json=Mock(return_value={"status": {"code": 3001}}))))
    assert _HANDLER(_request(_envelope())).status_code == 200
    summary = _summary(caplog)
    assert summary["providerCredentialSource"] == "key_vault" and summary["providerAuthMode"] == "apiKey"
    assert summary["providerTenantId"] is None
    assert summary["functionOutboundClientId"] is None and summary["functionOutboundManagedIdentityClientId"] is None
    assert 0 <= summary["providerCredentialElapsedMs"] <= summary["elapsedMs"]
    assert [call.args[0] for call in engine.secrets.resolve.call_args_list] == ["telesign-api-key", "telesign-customer-id"]
    assert [record["eventName"] for record in _records(caplog)] == _FIXTURES["logging"]["liveEvents"]


def test_optional_ttl_stays_null_and_invalid_body_values_never_enter_metadata(caplog):
    caplog.set_level(logging.INFO)
    payload = _envelope(mode=2)
    del payload["ttlSeconds"]
    assert _HANDLER(_request(payload)).status_code == 200
    assert _summary(caplog)["ttlSeconds"] is None
    caplog.clear()
    assert _HANDLER(_request({**payload, "ttlSeconds": "PRIVATE-INVALID-TTL"})).status_code == 400
    summary = _summary(caplog)
    assert summary["ttlSeconds"] is None and summary["envelopeType"] is None
    assert not any(record["eventName"] == "envelope_validated" for record in _records(caplog))


def test_request_preparation_uses_the_adapter_final_url_and_allowlisted_method(monkeypatch, caplog):
    caplog.set_level(logging.INFO)
    adapter = function_app._engine.registry.get("soprano")
    build_request = adapter.build_request
    final_url = "https://different-provider.example/api/final?token=PRIVATE-TOKEN"
    monkeypatch.setattr(adapter, "build_request", lambda *args: {
        **build_request(*args), "url": final_url, "method": "PRIVATE-METHOD",
    })
    send = Mock(return_value=Mock(status_code=201, json=Mock(return_value={"status": "ENROUTE"})))
    monkeypatch.setattr(dispatch_module.requests, "request", send)
    assert _HANDLER(_request(_envelope())).status_code == 200
    summary = _summary(caplog)
    assert summary["providerEndpoint"] == "https://different-provider.example/api/final" and summary["providerHttpMethod"] == "other"
    assert summary["providerEndpoint"] != function_app._engine.env["EPP_PROVIDER_ENDPOINT"]
    assert send.call_args.args[:2] == ("PRIVATE-METHOD", final_url)


def test_shared_id_cases_preserve_raw_values_or_explicitly_omit_invalid_metadata(caplog):
    caplog.set_level(logging.INFO)
    fields = ["x-ms-client-request-id", "x-ms-correlation-id", "providerTenantId",
              "functionOutboundClientId", "functionOutboundManagedIdentityClientId", "providerMessageId"]
    manifest = function_app._registry.get("soprano").manifest
    for fixture in _FIXTURES["logging"]["identifiers"]:
        caplog.clear()
        value = "A" * fixture["length"] if "length" in fixture else fixture["value"]
        log = RequestLog("function-request", None, value, value)
        log.provider_selected(manifest)
        log.credential_resolution_started(SimpleNamespace(
            provider_tenant_id=value, outbound_client_id=value, outbound_managed_identity_client_id=value))
        log.provider_response_processed(manifest, SimpleNamespace(
            provider_status_name="ENROUTE", provider_status_code=None, provider_message_id=value), "Continue", 200, True)
        log.complete(200)
        records = _records(caplog)
        summary = records[-1]
        for field in fields:
            assert summary[field] == (value if fixture["accepted"] else None)
        assert summary["omittedIdFields"] == (fields if fixture.get("omitted") else [])
        assert not any(key.endswith("Hash") for record in records for key in record)
        assert "PRIVATE" not in caplog.text


def test_shared_endpoint_cases_keep_only_scheme_host_port_and_api_path(caplog):
    caplog.set_level(logging.INFO)
    for fixture in _FIXTURES["logging"]["endpoints"]:
        caplog.clear()
        log = RequestLog("function-request", None, None, None)
        log.provider_request_built("POST", fixture["url"])
        log.provider_request_started(1500)
        log.complete(200)
        assert all(record["providerEndpoint"] == fixture["logged"] for record in _records(caplog))
        assert "PRIVATE" not in caplog.text
