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


def make_engine(secret_values=None, env=None, token_acquirer=None):
    registry = ProviderRegistry([InfobipProvider(), TelesignProvider(), SopranoProvider(), SinchProvider()])
    secrets = FakeSecrets(_DEFAULT_SECRETS if secret_values is None else secret_values)
    return DispatchEngine(registry, secrets, _DEFAULT_ENV if env is None else env, token_acquirer=token_acquirer)


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
            capture["headers"] = headers
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


def test_oauth_mode_sends_minted_bearer(monkeypatch):
    capture = {}
    _mock_send(monkeypatch, response=FakeResponse(201, {"status": "ENROUTE"}), capture=capture)
    # EPP_PROVIDER_AUTH_MODE forces oauth2 over soprano's apiKey manifest default.
    env = {"EPP_PROVIDER_ENDPOINT": "https://api.soprano.com", "EPP_PROVIDER_AUTH_MODE": "oauth2"}
    engine = make_engine(env=env, token_acquirer=lambda: "JWT")
    status, body = engine.dispatch(dispatch_request(), "soprano", False, "r", CapturingLog())

    assert status == 200 and body["status"] == "accepted"
    assert capture["headers"]["Authorization"] == "Bearer JWT"
    assert "X-MEMS-API-Key" not in capture["headers"]  # api-key headers must not be sent in oauth2 mode


def test_oauth_mode_fails_closed_without_token(monkeypatch):
    _mock_send(monkeypatch, raise_error=AssertionError("should not send without a token"))

    def raising_acquirer():
        raise ValueError("oauth2 requires EPP_PROVIDER_TENANT_ID, EPP_PROVIDER_CLIENT_ID and EPP_PROVIDER_SCOPE")

    env = {"EPP_PROVIDER_ENDPOINT": "https://api.soprano.com", "EPP_PROVIDER_AUTH_MODE": "oauth2"}
    engine = make_engine(env=env, token_acquirer=raising_acquirer)
    status, body = engine.dispatch(dispatch_request(), "soprano", False, "r", CapturingLog())
    assert status == 502 and body["reason"] == "provider credential unavailable"


def test_acquire_provider_token_caches_and_uses_client_secret(monkeypatch):
    calls = {"n": 0}

    class FakeAccessToken:
        def __init__(self, token, expires_on):
            self.token = token
            self.expires_on = expires_on

    class FakeCredential:
        def get_token(self, scope):
            calls["n"] += 1
            assert scope == "api://resource/.default"
            return FakeAccessToken("MINTED", 9999999999)  # far-future expiry

    dispatch_module._provider_token_cache.clear()
    env = {
        "EPP_PROVIDER_TENANT_ID": "tenant", "EPP_PROVIDER_CLIENT_ID": "client",
        "EPP_PROVIDER_SCOPE": "api://resource/.default", "EPP_PROVIDER_CLIENT_SECRET": "s",
    }
    factory = lambda env, secrets, tenant, client: FakeCredential()

    first = dispatch_module.acquire_provider_token(env, FakeSecrets({}), credential_factory=factory)
    second = dispatch_module.acquire_provider_token(env, FakeSecrets({}), credential_factory=factory)
    assert first == "MINTED" and second == "MINTED"
    assert calls["n"] == 1  # cached on the second call
    dispatch_module._provider_token_cache.clear()
