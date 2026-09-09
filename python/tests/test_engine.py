"""Representative dispatch failures and provider OAuth; all I/O is mocked."""
import logging
from unittest.mock import Mock

import pytest

import src.dispatch as dispatch_module
from src.dispatch import DispatchEngine, DispatchRequest, ProviderRegistry
from src.providers.infobip import InfobipProvider
from src.providers.soprano import SopranoProvider


_DEFAULT_ENV = {"EPP_PROVIDER_ENDPOINT": "https://api.infobip.com"}
_OAUTH_ENV = {
    "EPP_PROVIDER_ENDPOINT": "https://api.soprano.com", "EPP_PROVIDER_AUTH_MODE": "oauth2",
    "EPP_PROVIDER_TENANT_ID": "tenant", "EPP_PROVIDER_CLIENT_ID": "client",
    "EPP_PROVIDER_SCOPE": "api://provider/.default", "EPP_PROVIDER_CLIENT_SECRET": "s",
}


@pytest.fixture(autouse=True)
def send(monkeypatch):
    monkeypatch.setattr(dispatch_module, "_provider_token_cache", {})
    request = Mock(side_effect=AssertionError("unexpected provider request"))
    monkeypatch.setattr(dispatch_module.requests, "request", request)
    return request


def make_engine(env=None, secret="key"):
    registry = ProviderRegistry([InfobipProvider(), SopranoProvider()])
    secrets = Mock(resolve=Mock(return_value=secret))
    return DispatchEngine(registry, secrets, _DEFAULT_ENV if env is None else env)


def dispatch_request():
    return DispatchRequest(
        destination="+15551234567", message="Your code is 918273", channel="sms",
        message_id="m", correlation_id="c", locale=None,
    )


@pytest.mark.parametrize("env,secret,reason", [
    (_DEFAULT_ENV, "", "provider credential unavailable"),
    ({}, "key", "provider endpoint must be an absolute HTTPS URL"),
    ({"EPP_PROVIDER_ENDPOINT": "http://api.example.com"}, "key", "provider endpoint must be an absolute HTTPS URL"),
])
def test_invalid_provider_config_does_not_send(send, env, secret, reason):
    status, body = make_engine(env, secret).dispatch(dispatch_request(), "infobip", False, "r", logging)
    assert status == 502 and body["reason"] == reason
    send.assert_not_called()


def test_shutter_does_not_need_credentials_or_endpoint(send):
    status, body = make_engine(env={}, secret="").dispatch(
        dispatch_request(), "infobip", True, "r", logging
    )
    assert status == 200 and body["shutterProcessed"] is True
    send.assert_not_called()


def test_unknown_provider_status_fails_closed(send):
    send.side_effect = None
    send.return_value = Mock(status_code=200, json=Mock(return_value={"messages": [{
        "status": {"name": "UNRECOGNIZED"},
    }]}))
    status, body = make_engine().dispatch(dispatch_request(), "infobip", False, "r", logging)
    assert (status, body["outcome"]) == (502, "Fail")
    assert send.call_args.kwargs["timeout"] == 1.5


@pytest.mark.parametrize("error,status,reason", [
    (dispatch_module.requests.exceptions.Timeout, 504, "provider request timed out"),
    (dispatch_module.requests.exceptions.ConnectionError, 502, "provider request failed"),
])
def test_timeout_and_network_failure_remain_distinct(send, error, status, reason):
    engine = make_engine(env={**_DEFAULT_ENV, "EPP_PROVIDER_TIMEOUT_MS": "999999"})
    send.side_effect = error("private provider exception")
    actual, body = engine.dispatch(dispatch_request(), "infobip", False, "r", logging)
    assert actual == status and body["reason"] == reason
    assert send.call_args.kwargs["timeout"] == 2.5


def test_oauth_sends_and_caches_minted_bearer(monkeypatch, send):
    send.side_effect = None
    send.return_value = Mock(status_code=201, json=Mock(return_value={"status": "ENROUTE"}))
    credential = Mock(get_token=Mock(return_value=Mock(token="minted-token-secret", expires_on=9999999999)))
    factory = Mock(return_value=credential)
    monkeypatch.setattr(dispatch_module, "ClientSecretCredential", factory)
    engine = make_engine(env=_OAUTH_ENV)
    first = engine.dispatch(dispatch_request(), "soprano", False, "r1", logging)
    second = engine.dispatch(dispatch_request(), "soprano", False, "r2", logging)
    assert first[0] == second[0] == 200
    assert send.call_count == 2
    headers = send.call_args_list[0].kwargs["headers"]
    assert headers == send.call_args_list[1].kwargs["headers"]
    assert headers["Authorization"] == "Bearer minted-token-secret"
    assert "X-MEMS-API-Key" not in headers
    factory.assert_called_once_with("tenant", "client", "s")
    credential.get_token.assert_called_once_with("api://provider/.default")


@pytest.mark.parametrize("configured", [False, True])
def test_oauth_fails_closed_without_token(monkeypatch, send, configured):
    credential = Mock(get_token=Mock(return_value=Mock(token="", expires_on=9999999999)))
    monkeypatch.setattr(dispatch_module, "ClientSecretCredential", Mock(return_value=credential))
    env = _OAUTH_ENV if configured else {"EPP_PROVIDER_AUTH_MODE": "oauth2"}
    status, body = make_engine(env=env).dispatch(dispatch_request(), "soprano", False, "r", logging)
    assert status == 502 and body["reason"] == "provider credential unavailable"
    send.assert_not_called()
