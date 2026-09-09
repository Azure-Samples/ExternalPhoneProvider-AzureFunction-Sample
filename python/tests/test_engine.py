from unittest.mock import Mock

import pytest
from urllib3.exceptions import ReadTimeoutError

import src.dispatch as dispatch_module
from src.dispatch import DispatchEngine, DispatchRequest, ProviderRegistry
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
        status, body = engine.dispatch(_request(), "soprano", False, "r")
        assert status == 502 and body["reason"] == "provider credential unavailable"
    dispatch_module.requests.request.assert_not_called()


def test_base_and_sinch_voice_final_url_guards(engine):
    for url in ("http://api.example", "https://api.example:0"):
        engine.env["EPP_PROVIDER_ENDPOINT"] = url
        status, body = engine.dispatch(_request(), "soprano", False, "r")
        assert status == 502 and body["reason"] == "invalid provider endpoint"
    engine.env["EPP_PROVIDER_ENDPOINT"] = "https://api.example"
    for url in ("http://voice.example", "https://voice.example:0"):
        engine.env["SINCH_VOICE_ENDPOINT"] = url
        status, body = engine.dispatch(_request("voice"), "sinch", False, "r")
        assert status == 502 and body["reason"] == "invalid provider request URL"
    dispatch_module.requests.request.assert_not_called()


def test_provider_outcomes_fail_closed(engine, monkeypatch):
    monkeypatch.setenv("EPP_PROVIDER_NAME", "sinch")  # The injected provider setting must win.
    assert engine.registry.resolve(None, {}) is None
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
        status, body = engine.dispatch(_request(), None, False, "r")
        assert (status, body["outcome"], body["provider"]) == (expected, outcome, "soprano")
        send.assert_called_once()
        response.close.assert_called_once()


def test_transport_failures_and_wrapped_read_timeout(engine, monkeypatch):
    errors = dispatch_module.requests.exceptions
    for error, expected in ((errors.Timeout("offline"), 504), (errors.ConnectionError("offline"), 502)):
        send = Mock(side_effect=error)
        monkeypatch.setattr(dispatch_module.requests, "request", send)
        status, body = engine.dispatch(_request(), "soprano", False, "r")
        assert status == expected and body["outcome"] == "Fail"
        send.assert_called_once()

    # requests can wrap a streamed body-read timeout in ConnectionError.
    wrapped = errors.ConnectionError(ReadTimeoutError(None, "https://provider.example", "offline"))
    response = Mock(status_code=200, json=Mock(side_effect=wrapped))
    send = Mock(return_value=response)
    monkeypatch.setattr(dispatch_module.requests, "request", send)
    status, body = engine.dispatch(_request(), "soprano", False, "r")
    assert status == 504 and body["reason"] == "provider timeout"
    send.assert_called_once()
    response.close.assert_called_once()
