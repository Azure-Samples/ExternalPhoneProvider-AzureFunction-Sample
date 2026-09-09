import base64
import json
from urllib.parse import parse_qs

import pytest

from src.dispatch import DispatchRequest, parse_envelope
from src.providers.infobip import InfobipProvider
from src.providers.sinch import SinchProvider
from src.providers.soprano import SopranoProvider
from src.providers.telesign import TelesignProvider

MESSAGE = "  Use 918273; then 1234.\nDo not rewrite + or café.  "


def _dispatch(channel="sms"):
    return DispatchRequest("+15551234567", MESSAGE, channel, "message-id", "correlation-id", "en-US")


@pytest.mark.parametrize("channel", ["sms", "voice"])
def test_soprano_exact_sms_and_voice_contract(channel):
    request = SopranoProvider().build_request(
        channel, "https://qa4.example/cgpapi///", _dispatch(channel),
        {"mode": "apiKey", "identity": "test-id", "secret": "test-key"},
        {},
    )
    assert request["url"] == "https://qa4.example/cgpapi/messages/omnimsg" and request["method"] == "POST"
    assert request["headers"] == {
        "X-MEMS-API-ID": "test-id", "X-MEMS-API-Key": "test-key",
        "Content-Type": "application/json", "Accept": "application/json",
    }
    assert json.loads(request["body"]) == {
        "text": MESSAGE, "destination": "15551234567", "messageTypes": [channel],
        "correlationId": "correlation-id", "shutterMode": False,
    }


def test_infobip_sms_contract():
    request = InfobipProvider().build_request(
        "sms", "https://infobip.example", _dispatch(),
        {"mode": "apiKey", "secret": "ib"}, {"EPP_PROVIDER_ACCOUNT_NAME": "EPP"},
    )
    assert request["method"] == "POST" and request["url"] == "https://infobip.example/sms/3/messages"
    assert request["headers"]["Authorization"] == "App ib"
    assert json.loads(request["body"])["messages"] == [{
        "sender": "EPP", "destinations": [{"to": "+15551234567", "messageId": "correlation-id"}],
        "content": {"text": MESSAGE},
    }]


def test_telesign_sms_contract():
    request = TelesignProvider().build_request(
        "sms", "https://telesign.example", _dispatch(),
        {"mode": "apiKey", "secret": "key", "identity": "customer"}, {},
    )
    assert request["method"] == "POST" and request["url"] == "https://telesign.example/v1/messaging"
    assert request["headers"]["Authorization"] == "Basic " + base64.b64encode(b"customer:key").decode()
    assert request["headers"]["Content-Type"] == "application/x-www-form-urlencoded"
    form = parse_qs(request["body"])
    assert form["phone_number"] == ["+15551234567"] and form["message"] == [MESSAGE]
    assert form["message_type"] == ["OTP"] and form["external_id"] == ["correlation-id"]


def test_sinch_sms_static_token_contract():
    request = SinchProvider().build_request(
        "sms", "https://sinch.example", _dispatch(),
        {"mode": "apiKey", "secret": "static-api-token"},
        {"SINCH_SERVICE_PLAN_ID": "plan", "EPP_PROVIDER_ACCOUNT_NAME": "EPP"},
    )
    assert request["method"] == "POST" and request["url"] == "https://sinch.example/xms/v1/plan/batches"
    assert request["headers"]["Authorization"] == "Bearer static-api-token"
    assert json.loads(request["body"]) == {
        "from": "EPP", "to": ["+15551234567"], "body": MESSAGE, "client_reference": "correlation-id",
    }


def test_envelope_routing_and_ttl_validation():
    payload = {"type": "microsoft.mfa.otpDeliver.v1", "channel": 1, "mode": 1, "encryptedDeliveryContext": "jwe"}
    for channel, mode, expected in ((1, 1, (1, 1)), ("VOICE", "Evaluation", (2, 2))):
        envelope, error = parse_envelope({**payload, "channel": channel, "mode": mode})
        assert error is None and (envelope["channel"], envelope["mode"]) == expected
    for changes in ({"channel": True}, {"mode": False}, {"channel": "1"}, {"mode": None}):
        envelope, error = parse_envelope({**payload, **changes})
        assert envelope is None and error
    for ttl in (None, True, "60", 0, 2147483648):
        envelope, error = parse_envelope({**payload, "ttlSeconds": ttl})
        assert envelope is None and "ttlSeconds" in error
    for ttl in (1, 2147483647):
        envelope, error = parse_envelope({**payload, "ttlSeconds": ttl})
        assert error is None and envelope["ttl_seconds"] == ttl
    assert parse_envelope(payload)[0]["ttl_seconds"] is None
