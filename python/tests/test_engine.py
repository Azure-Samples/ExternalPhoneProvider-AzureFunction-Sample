"""Engine-level conformance tests (CONTRACT.md §6) with mocked HTTP + Key Vault."""
import json

import pytest

import src.dispatch as dispatch_module
from src.dispatch import DispatchEngine, DispatchRequest, ProviderRegistry
from src.providers.infobip import InfobipProvider
from src.providers.sinch import SinchProvider
from src.providers.soprano import SopranoProvider
from src.providers.telesign import TelesignProvider


class FakeSecrets:
    def __init__(self, values):
        self._values = values

    def resolve(self, name):
        return self._values.get(name, "")


class FakeResponse:
    def __init__(self, status_code, body):
        self.status_code = status_code
        self._body = body

    def json(self):
        return self._body


class CapturingLog:
    def __init__(self):
        self.lines = []

    def _record(self, fmt, *args):
        self.lines.append(fmt % args if args else fmt)

    info = _record
    warning = _record
    error = _record


_DEFAULT_SECRETS = {
    "infobip-api-key": "ib",
    "telesign-api-key": "ts", "telesign-customer-id": "cust",
    "soprano-api-key": "sp", "soprano-api-id": "spid",
}
_DEFAULT_ENV = {
    "EPP_PROVIDER_ENDPOINT": "https://api.infobip.com",
}


def make_engine(secret_values=None, env=None):
    registry = ProviderRegistry([InfobipProvider(), TelesignProvider(), SopranoProvider(), SinchProvider()])
    secrets = FakeSecrets(_DEFAULT_SECRETS if secret_values is None else secret_values)
    return DispatchEngine(registry, secrets, _DEFAULT_ENV if env is None else env)


def dispatch_request(**overrides):
    base = dict(
        destination="+15551234567", message="Your code is 918273", channel="sms",
        message_id="m", correlation_id="c", locale=None,
    )
    base.update(overrides)
    return DispatchRequest(**base)


def _mock_send(monkeypatch, response=None, raise_error=None, capture=None):
    def fake_request(method, url, headers=None, data=None, timeout=None):
        if capture is not None:
            capture["url"] = url
            capture["data"] = data
        if raise_error is not None:
            raise raise_error
        return response
    monkeypatch.setattr(dispatch_module.requests, "request", fake_request)


def test_unknown_provider_400():
    status, body = make_engine().dispatch(dispatch_request(), "nope", False, "r", CapturingLog())
    assert status == 400 and body["reason"] == "unknown provider"


def test_missing_credential_502():
    status, body = make_engine(secret_values={}).dispatch(dispatch_request(), "infobip", False, "r", CapturingLog())
    assert status == 502 and body["reason"] == "provider credential unavailable"


def test_missing_endpoint_502():
    engine = make_engine(env={})  # no *_ENDPOINT set
    status, body = engine.dispatch(dispatch_request(), "infobip", False, "r", CapturingLog())
    assert status == 502 and body["reason"] == "provider endpoint not configured"


def test_shutter_does_not_send(monkeypatch):
    _mock_send(monkeypatch, raise_error=AssertionError("should not send"))
    status, body = make_engine().dispatch(dispatch_request(), "infobip", True, "r", CapturingLog())
    assert status == 200 and body["shutterProcessed"] is True


def test_success_renders_code_and_keeps_privacy(monkeypatch):
    capture = {}
    _mock_send(monkeypatch, response=FakeResponse(200, {"messages": [{"status": {"name": "DELIVERED"}, "messageId": "x"}]}), capture=capture)
    log = CapturingLog()
    status, body = make_engine().dispatch(dispatch_request(), "infobip", False, "r", log)

    assert status == 200 and body["status"] == "accepted"
    assert "918273" in capture["data"]  # the message (with the code) IS sent to the provider (that's the delivery)
    serialized = json.dumps(body)
    assert "918273" not in serialized and "5551234567" not in serialized  # never in the response body
    assert all("918273" not in line and "5551234567" not in line for line in log.lines)  # never logged


def test_unknown_status_fails_closed(monkeypatch):
    _mock_send(monkeypatch, response=FakeResponse(200, {"messages": [{"status": {"name": "WATWAT"}}]}))
    status, body = make_engine().dispatch(dispatch_request(), "infobip", False, "r", CapturingLog())
    assert body["outcome"] == "Fail" and body["status"] == "failed"


def test_timeout_maps_to_504(monkeypatch):
    _mock_send(monkeypatch, raise_error=dispatch_module.requests.exceptions.Timeout())
    status, _ = make_engine().dispatch(dispatch_request(), "infobip", False, "r", CapturingLog())
    assert status == 504


def test_network_error_maps_to_502(monkeypatch):
    _mock_send(monkeypatch, raise_error=dispatch_module.requests.exceptions.ConnectionError())
    status, _ = make_engine().dispatch(dispatch_request(), "infobip", False, "r", CapturingLog())
    assert status == 502
