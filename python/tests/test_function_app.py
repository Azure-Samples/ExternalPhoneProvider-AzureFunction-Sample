"""Trigger-level tests for the SendOtp HTTP handler.

The import + route assertions are the regression guard for module-level breakage: a bad `from src...`
line makes the whole Function App fail to start, and the engine-level tests never import this module,
so they stay green while nothing can run.
"""
import json
import os

import azure.functions as func
import pytest
from jwcrypto import jwe, jwk

import src.dispatch as dispatch_module

# Set before importing function_app: it builds its engine and key provider at module load.
_KEY = jwk.JWK.generate(kty="RSA", size=2048, kid="test-key")
os.environ["EPP_DECRYPTION_KEY_PEM"] = _KEY.export_to_pem(private_key=True, password=None).decode("utf-8")
os.environ["EPP_PROVIDER_NAME"] = "infobip"
os.environ["EPP_PROVIDER_ENDPOINT"] = "https://api.infobip.com"

import function_app  # noqa: E402

# Resolved once: app.get_functions() rebuilds bindings and rejects a second call.
_FUNCTIONS = function_app.app.get_functions()
_HANDLER = _FUNCTIONS[0].get_user_function()


class _FakeSecrets:
    def resolve(self, name):
        return "ib"


class _FakeResponse:
    def __init__(self, status_code, body):
        self.status_code = status_code
        self._body = body

    def json(self):
        return self._body


class _InlineThread:
    """Runs the background delivery inline so assertions don't race the worker thread."""

    def __init__(self, target=None, name=None, daemon=None):
        self._target = target

    def start(self):
        self._target()


@pytest.fixture(autouse=True)
def _wire(monkeypatch):
    monkeypatch.setattr(function_app._engine, "secrets", _FakeSecrets())
    monkeypatch.setattr(function_app.threading, "Thread", _InlineThread)


def _request(body):
    raw = body if isinstance(body, bytes) else json.dumps(body).encode("utf-8")
    return func.HttpRequest(method="POST", url="/api/SendOtp", headers={}, params={}, body=raw)


def _envelope(**overrides):
    context = {
        "nonce": "nonce-abc",
        "phoneNumber": "+14255551234",
        "locale": "en-US",
        "message": "Your code is 123456",
    }
    protected = {"alg": "RSA-OAEP-256", "enc": "A256GCM", "kid": "test-key"}
    token = jwe.JWE(json.dumps(context).encode("utf-8"), protected=json.dumps(protected))
    token.add_recipient(_KEY)

    envelope = {
        "type": "microsoft.mfa.otpDeliver.v1",
        "tenantId": "tenant-1",
        "correlationId": "corr-1",
        "channel": 1,
        "mode": 1,
        "ttlSeconds": 60,
        "encryptedDeliveryContext": token.serialize(compact=True),
    }
    envelope.update(overrides)
    return envelope


def test_app_imports_and_registers_the_route():
    assert [f.get_function_name() for f in _FUNCTIONS] == ["send_otp"]


def test_invalid_json_is_400():
    response = _HANDLER(_request(b"{ not json"))
    assert response.status_code == 400


def test_live_envelope_echoes_the_nonce(monkeypatch):
    sent = {}

    def fake_request(method, url, headers=None, data=None, timeout=None):
        sent["url"] = url
        return _FakeResponse(200, {"messages": [{"status": {"groupName": "PENDING"}, "messageId": "x"}]})

    monkeypatch.setattr(dispatch_module.requests, "request", fake_request)

    response = _HANDLER(_request(_envelope()))
    body = json.loads(response.get_body())

    assert response.status_code == 200
    assert body["nonce"] == "nonce-abc"
    assert body["correlationId"] == "corr-1"
    assert sent["url"].startswith("https://")


def test_evaluation_mode_does_not_send(monkeypatch):
    def fail(*args, **kwargs):
        raise AssertionError("evaluation mode must not send")

    monkeypatch.setattr(dispatch_module.requests, "request", fail)

    response = _HANDLER(_request(_envelope(mode=2)))

    assert response.status_code == 200
    assert json.loads(response.get_body())["nonce"] == "nonce-abc"
