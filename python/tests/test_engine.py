import json
import io
import logging
import time
from concurrent.futures import ThreadPoolExecutor
from threading import Event
from types import SimpleNamespace
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
    result = DispatchEngine(registry, Mock(resolve=Mock(return_value="test-key")), {
        "EPP_PROVIDER_NAME": " SOPRANO ",
        "EPP_PROVIDER_ENDPOINT": "https://qa4.example/oauth/messages",
        "EPP_PROVIDER_AUTH_MODE": "oauth",
        "EPP_PROVIDER_CHANNEL": "sms",
    })
    result._resolve_credential = Mock(return_value={"mode": "oauth", "access_token": "provider-token"})
    return result


def test_missing_oauth_configuration_never_sends(engine):
    engine._resolve_credential = DispatchEngine._resolve_credential.__get__(engine, DispatchEngine)
    status, body = engine.dispatch(_request(), "r")
    assert status == 502 and body["reason"] == "provider credential unavailable"
    dispatch_module.requests.request.assert_not_called()


def _oauth_settings():
    return {"EPP_PROVIDER_NAME": "soprano", "EPP_PROVIDER_AUTH_MODE": "oauth", "EPP_PROVIDER_CHANNEL": "sms",
            "EPP_PROVIDER_ENDPOINT": "https://provider.example/full/sms/url/",
            "EPP_PROVIDER_TENANT_ID": "provider-tenant", "EPP_PROVIDER_SCOPE": "api://provider/.default",
            "EPP_OUTBOUND_CLIENT_ID": "calling-app", "EPP_OUTBOUND_MI_CLIENT_ID": "outbound-identity",
            "AZURE_CLIENT_ID": "different-vault-identity"}


def test_soprano_oauth_uses_setup_settings_and_rejects_unusable_tokens(engine, monkeypatch):
    engine.env = _oauth_settings()
    engine._resolve_credential = DispatchEngine._resolve_credential.__get__(engine, DispatchEngine)
    assertion = SimpleNamespace(token="private-assertion", expires_on=time.time() + 3600)
    access = SimpleNamespace(token="private-token", expires_on=time.time() + 3600)
    managed = Mock(get_token=Mock(side_effect=lambda *args, **kwargs: assertion))
    identity_factory = Mock(return_value=managed)
    clients = []

    def create_client(**kwargs):
        assert kwargs["tenant_id"] == engine.env["EPP_PROVIDER_TENANT_ID"]
        assert kwargs["client_id"] == engine.env["EPP_OUTBOUND_CLIENT_ID"]
        assert kwargs["retry_total"] == 0 and kwargs["connection_timeout"] == kwargs["read_timeout"] == 2.5
        assert kwargs["logging_enable"] is False

        def get_token(*args, **options):
            assert args == (engine.env["EPP_PROVIDER_SCOPE"],) and options == {"logging_enable": False}
            assert kwargs["func"]() == "private-assertion"
            return access

        client = Mock(get_token=Mock(side_effect=get_token))
        clients.append(client)
        return client

    monkeypatch.setattr(dispatch_module, "ManagedIdentityCredential", identity_factory)
    monkeypatch.setattr(dispatch_module, "ClientAssertionCredential", create_client)
    dispatch_module.requests.request.return_value = Mock(status_code=201, json=Mock(return_value={"status": "ENROUTE"}))
    for scope in ("api://provider/.default", "api://second/.default"):
        engine.env["EPP_PROVIDER_SCOPE"] = scope
        assert engine.dispatch(_request(), "request")[0] == 200
    assert len(clients) == 1
    sent = dispatch_module.requests.request.call_args
    assert sent.args[1] == engine.env["EPP_PROVIDER_ENDPOINT"]
    assert sent.kwargs["headers"] == {"Content-Type": "application/json", "Accept": "application/json",
                                     "Authorization": "Bearer private-token"}
    identity_factory.assert_called_once_with(client_id="outbound-identity", retry_total=0,
        connection_timeout=2.5, read_timeout=2.5, logging_enable=False)
    managed.get_token.assert_called_with("api://AzureADTokenExchange/.default", logging_enable=False)
    engine.env["EPP_OUTBOUND_CLIENT_ID"] = "second-calling-app"
    assert engine.dispatch(_request(), "request")[0] == 200
    assert len(clients) == 2
    dispatch_module.requests.request.reset_mock()
    for stage in ("access", "assertion"):
        for invalid in (None, SimpleNamespace(token=""), SimpleNamespace(token=" "),
                        SimpleNamespace(token="private-token"),
                        SimpleNamespace(token="private-token", expires_on=time.time() + 5)):
            if stage == "access":
                access = invalid
            else:
                access = SimpleNamespace(token="private-token", expires_on=time.time() + 3600)
                assertion = invalid
            status, body = engine.dispatch(_request(), "request")
            assert status == 502 and body["reason"] == "provider credential unavailable"
            assert "private" not in json.dumps(body)
    engine.secrets.resolve.assert_not_called()
    dispatch_module.requests.request.assert_not_called()


def test_soprano_oauth_sdk_logs_stay_private_without_muting_other_requests(engine, monkeypatch, caplog):
    engine.env = _oauth_settings()
    engine._resolve_credential = DispatchEngine._resolve_credential.__get__(engine, DispatchEngine)
    started, release = Event(), Event()
    logger = logging.getLogger("azure.identity.test_setup_oauth")
    output = io.StringIO()
    handler = logging.StreamHandler(output)
    logger.addHandler(handler)

    def fail(*args, **kwargs):
        logger.warning("PRIVATE-SDK-TOKEN")
        started.set()
        assert release.wait(5)
        logger.warning("PRIVATE-ACCOUNT-ERROR")
        raise RuntimeError("PRIVATE-TOKEN-EXCEPTION")

    monkeypatch.setattr(dispatch_module, "ManagedIdentityCredential", Mock())
    monkeypatch.setattr(dispatch_module, "ClientAssertionCredential", Mock(return_value=Mock(get_token=fail)))
    try:
        with ThreadPoolExecutor(max_workers=1) as pool:
            pending = pool.submit(engine.dispatch, _request(), "request")
            try:
                assert started.wait(5)
                logger.warning("unrelated request")
            finally:
                release.set()
            status, body = pending.result(timeout=5)
        assert status == 502 and body["reason"] == "provider credential unavailable"
        logger.warning("after acquisition")
        assert "PRIVATE" not in output.getvalue() + caplog.text + json.dumps(body)
        assert "unrelated request" in output.getvalue() and "after acquisition" in output.getvalue()
        engine.secrets.resolve.assert_not_called()
        dispatch_module.requests.request.assert_not_called()
    finally:
        logger.removeHandler(handler)


def test_soprano_voice_payload_uses_oauth(engine):
    engine.env["EPP_PROVIDER_CHANNEL"] = "voice"
    speech = {"beforePasswordText": "Your code is", "password": "001234", "language": "en-US"}
    context = DeliveryContext.from_payload({"nonce": "n", "phoneNumber": "+15551234567",
                                            "message": "Your code is 001234", "locale": "fr-FR",
                                            "textToVoice": speech})
    envelope = Envelope("microsoft.mfa.otpDeliver.v1", "tenant", "correlation", 2, 1, None, "encrypted")
    request = dispatch_module.context_to_dispatch(context, envelope, "message")
    dispatch_module.requests.request.return_value = Mock(status_code=200, json=Mock(return_value={"status": "ACCEPTED"}))
    status, body = engine.dispatch(request, "r")
    assert status == 200 and body["outcome"] == "Continue"
    sent = dispatch_module.requests.request.call_args.kwargs
    payload = json.loads(sent["data"])
    assert payload["voice"] == {"text2voice": {
        "beforePasswordText": "Your code is ",
        "password": "001234",
        "afterPasswordText": "",
        "language": "fr-FR",
        "gender": 1,
        "loop": 2,
    }}
    assert payload["messageTypes"] == ["voice"] and payload["destination"] == "15551234567"
    assert "text" not in payload
    assert sent["headers"]["Authorization"] == "Bear" + "er provider-token"
    assert "001234" not in repr(request.text_to_voice)


def test_soprano_voice_without_six_digit_passcode_never_sends(engine):
    engine.env["EPP_PROVIDER_CHANNEL"] = "voice"
    request = _request("voice")
    request.message = "Your code is unavailable."
    status, body = engine.dispatch(request, "r")
    assert status == 502 and body["reason"] == "provider request failed"
    engine.secrets.resolve.assert_not_called()
    dispatch_module.requests.request.assert_not_called()


def test_base_and_sinch_voice_final_url_guards(engine):
    for url in ("http://api.example", "https://api.example:0"):
        engine.env["EPP_PROVIDER_ENDPOINT"] = url
        status, body = engine.dispatch(_request(), "r")
        assert status == 502 and body["reason"] == "invalid provider endpoint"
    engine.env["EPP_PROVIDER_ENDPOINT"] = "https://api.example"
    engine.env["EPP_PROVIDER_NAME"] = "sinch"
    engine.env.pop("EPP_PROVIDER_CHANNEL", None)
    engine.env.pop("EPP_PROVIDER_AUTH_MODE", None)
    engine._resolve_credential = Mock(return_value={"mode": "apiKey", "secret": "test-key", "identity": ""})
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
