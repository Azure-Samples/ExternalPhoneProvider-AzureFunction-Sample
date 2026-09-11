import json
from unittest.mock import Mock

import pytest
from urllib3.exceptions import ReadTimeoutError

import src.dispatch as dispatch_module
from src.config import AppConfig, read_config
from src.dispatch import DispatchEngine, DispatchRequest, ProviderRegistry
from src.models import DeliveryContext, Envelope, TextToVoice
from src.providers.sinch import SinchProvider
from src.providers.soprano import SopranoProvider


def _request(channel="sms"):
    return DispatchRequest("+15551234567", "Your code is 918273", channel, "message", "correlation", "en-US")


@pytest.fixture
def engine(monkeypatch):
    registry = ProviderRegistry([SopranoProvider(), SinchProvider()])
    monkeypatch.setattr(dispatch_module.requests, "request", Mock())
    return DispatchEngine(registry, Mock(resolve=Mock(return_value="test-key")),
                          {"EPP_PROVIDER_NAME": " SOPRANO ", "EPP_PROVIDER_ENDPOINT": "https://qa4.example/cgpapi/"})


def test_missing_key_or_identity_never_sends(engine):
    for missing in ("soprano-api-key", "soprano-api-id"):
        engine.secrets.resolve.side_effect = lambda name: None if name == missing else "test-key"
        status, body = engine.dispatch(_request(), "r")
        assert status == 502 and body["reason"] == "provider credential unavailable"
    dispatch_module.requests.request.assert_not_called()


def test_soprano_voice_payload_uses_api_key_only(engine):
    speech = {"beforePasswordText": "Your code is", "password": "001234", "language": "en"}
    context = DeliveryContext.from_payload({"nonce": "n", "phoneNumber": "+15551234567",
                                            "message": "Your code is 001234", "textToVoice": speech})
    envelope = Envelope("microsoft.mfa.otpDeliver.v1", "tenant", "correlation", 2, 1, None, "encrypted")
    request = dispatch_module.context_to_dispatch(context, envelope, "message")
    dispatch_module.requests.request.return_value = Mock(status_code=200, json=Mock(return_value={"status": "ACCEPTED"}))
    status, body = engine.dispatch(request, "r")
    assert status == 200 and body["outcome"] == "Continue"
    sent = dispatch_module.requests.request.call_args.kwargs
    payload = json.loads(sent["data"])
    assert payload["voice"] == {"text2voice": speech}
    assert payload["messageTypes"] == ["voice"] and payload["destination"] == "15551234567"
    assert "text" not in payload
    assert sent["headers"]["X-MEMS-API-Key"] == "test-key"
    assert sent["headers"]["X-MEMS-API-ID"] == "test-key"
    assert "Authorization" not in sent["headers"]
    assert "001234" not in repr(request.text_to_voice)


@pytest.mark.parametrize("speech", [None, {}, [], "invalid",
    {"beforePasswordText": "Code", "password": 1234, "language": "en"},
    {"beforePasswordText": "Code", "password": "1234", "language": " "},
    {"password": "1234", "language": "en"}])
def test_incomplete_soprano_voice_never_sends(engine, speech):
    request = _request("voice")
    request.text_to_voice = TextToVoice.from_payload(speech)
    status, body = engine.dispatch(request, "r")
    assert status == 400 and body["reason"] == "incomplete voice context"
    engine.secrets.resolve.assert_not_called()
    dispatch_module.requests.request.assert_not_called()


def test_base_and_sinch_voice_final_url_guards(engine):
    for url in ("http://api.example", "https://api.example:0"):
        engine.env["EPP_PROVIDER_ENDPOINT"] = url
        status, body = engine.dispatch(_request(), "r")
        assert status == 502 and body["reason"] == "invalid provider endpoint"
    engine.env["EPP_PROVIDER_ENDPOINT"] = "https://api.example"
    engine.env["EPP_PROVIDER_NAME"] = "sinch"
    for url in ("http://voice.example", "https://voice.example:0"):
        engine.env["SINCH_VOICE_ENDPOINT"] = url
        status, body = engine.dispatch(_request("voice"), "r")
        assert status == 502 and body["reason"] == "invalid provider request URL"
    dispatch_module.requests.request.assert_not_called()


def test_provider_outcomes_fail_closed(engine, monkeypatch):
    monkeypatch.setenv("EPP_PROVIDER_NAME", "sinch")  # The injected provider setting must win.
    engine.env["EPP_DECRYPTION_KEY_PEM"] = "test-private-pem"
    config = read_config(engine.env)
    assert isinstance(config, AppConfig) and config.provider_name == "soprano"
    assert config.env is engine.env and config.decryption_key_pem == "test-private-pem"
    assert "test-private-pem" not in repr(config) and "EPP_PROVIDER_NAME" not in repr(config)
    assert engine.registry.get(None) is None
    cases = (
        (202, {"state": "accepted"}, 200, "Continue"),
        (500, {"status": "ACCEPTED"}, 502, "Fail"),
        (200, {"status": "FAILED"}, 502, "Fail"),
        (200, {"status": "FILTERED"}, 502, "Fail"),
        (200, {}, 502, "Fail"),
        (200, {"status": False, "state": "ACCEPTED"}, 502, "Fail"),
        (200, {"status": "BLOCKED"}, 403, "Block"),
    )
    for upstream_status, payload, expected, outcome in cases:
        response = Mock(status_code=upstream_status, json=Mock(return_value=payload))
        send = Mock(return_value=response)
        monkeypatch.setattr(dispatch_module.requests, "request", send)
        status, body = engine.dispatch(_request(), "r")
        assert (status, body["outcome"], body["provider"]) == (expected, outcome, "soprano")
        send.assert_called_once()
        response.close.assert_called_once()


def test_transport_failures_and_wrapped_read_timeout(engine, monkeypatch):
    errors = dispatch_module.requests.exceptions
    for error, expected in ((errors.Timeout("offline"), 504), (errors.ConnectionError("offline"), 502)):
        send = Mock(side_effect=error)
        monkeypatch.setattr(dispatch_module.requests, "request", send)
        status, body = engine.dispatch(_request(), "r")
        assert status == expected and body["outcome"] == "Fail"
        send.assert_called_once()

    # requests can wrap a streamed body-read timeout in ConnectionError.
    wrapped = errors.ConnectionError(ReadTimeoutError(None, "https://provider.example", "offline"))
    response = Mock(status_code=200, json=Mock(side_effect=wrapped))
    send = Mock(return_value=response)
    monkeypatch.setattr(dispatch_module.requests, "request", send)
    status, body = engine.dispatch(_request(), "r")
    assert status == 504 and body["reason"] == "provider timeout"
    send.assert_called_once()
    response.close.assert_called_once()
