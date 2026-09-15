import json
import logging
from concurrent.futures import ThreadPoolExecutor
from unittest.mock import Mock

import pytest
from azure.core.credentials import AccessToken
from urllib3.exceptions import ReadTimeoutError

import src.dispatch as dispatch_module
from src.config import AppConfig, read_config
from src.dispatch import DispatchEngine, DispatchRequest, ProviderRegistry
from src.models import DeliveryContext, Envelope, TextToVoice
from src.providers.sinch import SinchProvider
from src.providers.soprano import SopranoProvider
import src.providers.soprano as soprano_module


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
    speech = {"beforePasswordText": "Your code is", "password": "001234", "language": "en-US"}
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


def test_soprano_reuses_federated_credentials_and_requests_provider_scope(monkeypatch):
    adapter = SopranoProvider()
    token = "opaque-access-token-from-entra"
    env = {"EPP_PROVIDER_JWT_ENABLED": " TRUE ", "EPP_PROVIDER_SCOPE": "api://provider-application-id/.default",
        "EPP_PROVIDER_TENANT_ID": "11111111-1111-4111-8111-111111111111",
        "EPP_PROVIDER_APPLICATION_ID": "22222222-2222-4222-8222-222222222222",
        "EPP_PROVIDER_MI_CLIENT_ID": "33333333-3333-4333-8333-333333333333"}
    managed_identity = Mock(get_token=Mock(return_value=AccessToken("private-exchange-assertion", 3700)))
    identity_factory = Mock(return_value=managed_identity)
    def exchange(*args, **kwargs):
        assert factory.call_args.args[2]() == "private-exchange-assertion"
        return AccessToken(token, 3700)
    credential = Mock(get_token=Mock(side_effect=exchange))
    factory = Mock(return_value=credential)
    monkeypatch.setattr(soprano_module, "ManagedIdentityCredential", identity_factory)
    monkeypatch.setattr(soprano_module, "ClientAssertionCredential", factory)
    monkeypatch.setattr(soprano_module.time, "time", lambda: 100)
    for flag in (None, "false", "1", "yes", True):
        assert adapter.acquire_token({**env, "EPP_PROVIDER_JWT_ENABLED": flag}) == ""
    for name in ("EPP_PROVIDER_SCOPE", "EPP_PROVIDER_TENANT_ID", "EPP_PROVIDER_APPLICATION_ID", "EPP_PROVIDER_MI_CLIENT_ID"):
        for value in (None, "", " "):
            assert adapter.acquire_token({**env, name: value}) == ""
    factory.assert_not_called()
    identity_factory.assert_not_called()
    assert adapter.acquire_token(env) == token
    identity_factory.assert_called_once_with(client_id=env["EPP_PROVIDER_MI_CLIENT_ID"], retry_total=0, connection_timeout=2.5, read_timeout=2.5, logging_enable=False)
    assert factory.call_args.args[:2] == (env["EPP_PROVIDER_TENANT_ID"], env["EPP_PROVIDER_APPLICATION_ID"])
    managed_identity.get_token.assert_called_once_with("api://AzureADTokenExchange/.default", logging_enable=False)
    credential.get_token.assert_called_once_with(env["EPP_PROVIDER_SCOPE"], logging_enable=False)
    assert adapter.acquire_token(env) == token
    assert factory.call_count == 1
    assert identity_factory.call_count == 1
    assert adapter.acquire_token({**env, "EPP_PROVIDER_MI_CLIENT_ID": "44444444-4444-4444-8444-444444444444"}) == token
    assert factory.call_count == 2 and identity_factory.call_args.kwargs["client_id"] == "44444444-4444-4444-8444-444444444444"
    assert adapter.acquire_token({**env, "EPP_PROVIDER_SCOPE": "api://another-provider/.default"}) == token
    assert credential.get_token.call_args.args == ("api://another-provider/.default",)
    for assertion in (None, AccessToken("", 3700), AccessToken("assertion", 100)):
        managed_identity.get_token.return_value = assertion
        assert adapter.acquire_token(env) == ""
    managed_identity.get_token.side_effect = RuntimeError("private assertion failure")
    assert adapter.acquire_token(env) == ""
    credential.get_token.side_effect = None
    for result in (None, AccessToken(token, 100), AccessToken("", 3700), AccessToken(" ", 3700), AccessToken(False, 3700)):
        credential.get_token.return_value = result
        assert adapter.acquire_token(env) == ""


@pytest.mark.parametrize("failure_stage", ["assertion", "exchange"])
def test_soprano_token_failure_diagnostics_are_request_scoped(monkeypatch, caplog, failure_stage):
    caplog.set_level(logging.DEBUG)
    env = {"EPP_PROVIDER_JWT_ENABLED": "true", "EPP_PROVIDER_SCOPE": "api://provider/.default",
        "EPP_PROVIDER_TENANT_ID": "11111111-1111-4111-8111-111111111111",
        "EPP_PROVIDER_APPLICATION_ID": "22222222-2222-4222-8222-222222222222",
        "EPP_PROVIDER_MI_CLIENT_ID": "33333333-3333-4333-8333-333333333333"}
    sdk_logs = [logging.getLogger(name) for name in ("azure.identity._internal.decorators",
        "azure.identity._internal.get_token_mixin", "msal.managed_identity", "azure.core.pipeline")]
    def fail(*args, **kwargs):
        for logger in sdk_logs:
            logger.warning("PRIVATE SDK account/exception data")
        with ThreadPoolExecutor(max_workers=1) as executor:
            executor.submit(sdk_logs[0].warning, "other-request-diagnostic").result()
        logging.info("application-log-remains-visible")
        raise RuntimeError("PRIVATE-TOKEN-ERROR")
    monkeypatch.setattr(soprano_module, "ManagedIdentityCredential", Mock(return_value=Mock(get_token=Mock(side_effect=fail))))
    factory = Mock()
    factory.return_value.get_token.side_effect = fail if failure_stage == "exchange" else lambda *args, **kwargs: factory.call_args.args[2]()
    monkeypatch.setattr(soprano_module, "ClientAssertionCredential", factory)
    sdk_output = []
    handler = logging.Handler()
    handler.emit = lambda record: sdk_output.append(record.getMessage())
    sdk_logs[0].addHandler(handler)
    try:
        assert SopranoProvider().acquire_token(env) == ""
        sdk_logs[0].warning("after-token-request")
    finally:
        sdk_logs[0].removeHandler(handler)
        handler.close()
    assert sdk_output == ["other-request-diagnostic", "after-token-request"]
    assert "PRIVATE" not in caplog.text
    assert "other-request-diagnostic" in caplog.text and "application-log-remains-visible" in caplog.text
    assert "after-token-request" in caplog.text


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
