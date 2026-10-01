import logging
from unittest.mock import Mock

import pytest
from urllib3.exceptions import ReadTimeoutError

import src.provider as provider_module
from src.models import Outcome, OtpDelivery
from src.otp_log import RequestLogger
from src.provider import (
    ProviderSendError,
    is_https_endpoint,
    provider_timeout_ms,
    to_endpoint_http_status,
)
from src.providers.soprano import SopranoProvider


def _delivery(channel="sms"):
    return OtpDelivery(
        "+15551234567", "Your code is 918273", channel,
        "message", "correlation", "en-US")


def _log():
    return RequestLogger(logging.getLogger("test.provider"), {
        "function_request_id": "request",
    })


def _send(provider, monkeypatch, response):
    monkeypatch.setattr(provider_module.requests, "request", Mock(return_value=response))
    return provider.send_otp(
        "sms",
        "https://provider.example/messages",
        _delivery(),
        {"mode": "oauth", "access_token": "provider-token"},
        {},
        1500,
        _log(),
    )


@pytest.mark.parametrize("value,valid", [
    ("https://api.example/path", True),
    ("https://api.example:443/path?key=private", True),
    ("http://api.example", False),
    ("https://api.example:0", False),
    ("https://user:password@api.example", False),
    ("https://api.example/path#fragment", False),
])
def test_https_endpoint_guard(value, valid):
    assert is_https_endpoint(value) is valid


@pytest.mark.parametrize("value,expected", [
    (None, 1500), ("", 1500), ("1500", 1500), ("0001", 1),
    ("2501", 2500), ("999999999999999999", 2500), ("1.5", 1500),
])
def test_provider_timeout_normalization(value, expected):
    assert provider_timeout_ms(value) == expected


def test_shared_transport_maps_response_and_closes_it(monkeypatch):
    response = Mock(status_code=201, json=Mock(return_value={"status": "ENROUTE", "id": 123}))
    result = _send(SopranoProvider(), monkeypatch, response)
    assert result.outcome == Outcome.CONTINUE
    assert result.provider_message_id == "123"
    request = provider_module.requests.request.call_args
    assert request.args[:2] == ("POST", "https://provider.example/messages")
    assert request.kwargs["allow_redirects"] is False
    assert request.kwargs["stream"] is True
    response.close.assert_called_once()


@pytest.mark.parametrize("upstream,payload,expected_status,reason", [
    (500, {"status": "ACCEPTED"}, 502, "provider_http_error"),
    (200, {"status": "FAILED"}, 502, "provider_rejected"),
    (200, {}, 502, "unrecognized_provider_status"),
    (200, {"status": "BLOCKED"}, 403, None),
])
def test_provider_outcomes_fail_closed(monkeypatch, upstream, payload, expected_status, reason):
    response = Mock(status_code=upstream, json=Mock(return_value=payload))
    result = _send(SopranoProvider(), monkeypatch, response)
    assert to_endpoint_http_status(result) == expected_status
    assert result.failure_reason == reason


def test_invalid_json_is_a_classified_provider_failure(monkeypatch, caplog):
    caplog.set_level(logging.INFO)
    response = Mock(status_code=200, json=Mock(side_effect=ValueError("PRIVATE-BODY")))
    result = _send(SopranoProvider(), monkeypatch, response)
    assert result.outcome == Outcome.FAIL
    assert result.failure_reason == "invalid_provider_json"
    assert to_endpoint_http_status(result) == 502
    assert [record.event_name for record in caplog.records if hasattr(record, "event_name")][-2:] == [
        "provider_response_invalid_json",
        "provider_response_processed",
    ]
    assert "PRIVATE-BODY" not in caplog.text


@pytest.mark.parametrize("error,status", [
    (provider_module.requests.exceptions.Timeout("PRIVATE"), 504),
    (provider_module.requests.exceptions.ConnectionError("PRIVATE"), 502),
])
def test_transport_failures_are_sanitized(monkeypatch, error, status):
    monkeypatch.setattr(provider_module.requests, "request", Mock(side_effect=error))
    with pytest.raises(ProviderSendError) as raised:
        SopranoProvider().send_otp(
            "sms", "https://provider.example/messages", _delivery(),
            {"mode": "oauth", "access_token": "provider-token"}, {}, 1500, _log())
    assert raised.value.status_code == status


def test_wrapped_stream_read_timeout_is_504_and_response_is_closed(monkeypatch):
    wrapped = provider_module.requests.exceptions.ConnectionError(
        ReadTimeoutError(None, "https://provider.example", "PRIVATE"))
    response = Mock(status_code=200, json=Mock(side_effect=wrapped))
    monkeypatch.setattr(provider_module.requests, "request", Mock(return_value=response))
    with pytest.raises(ProviderSendError) as raised:
        SopranoProvider().send_otp(
            "sms", "https://provider.example/messages", _delivery(),
            {"mode": "oauth", "access_token": "provider-token"}, {}, 1500, _log())
    assert raised.value.status_code == 504
    response.close.assert_called_once()
