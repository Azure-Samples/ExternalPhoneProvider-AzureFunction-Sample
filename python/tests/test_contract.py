import base64
import json
from pathlib import Path

import pytest

from src.models import EntraSendOtpPayload, Outcome, OtpDelivery, ProviderResult
from src.providers.infobip import InfobipProvider
from src.providers.sinch import SinchProvider
from src.providers.soprano import SopranoProvider
from src.providers.telesign import TelesignProvider

MESSAGE = "  Use 918273; then 1234.\nDo not rewrite + or café.  "


def _delivery(channel="sms"):
    return OtpDelivery(
        "+15551234567", MESSAGE, channel, "message-id", "correlation-id", "en-US")


@pytest.mark.parametrize("channel", ["sms", "voice"])
def test_soprano_owns_request_and_response_contract(channel):
    delivery = _delivery(channel)
    request = SopranoProvider().build_request(
        channel,
        "https://qa4.example/oauth/messages",
        delivery,
        {"mode": "oauth", "access_token": "provider-token"},
        {},
    )
    assert request.url == "https://qa4.example/oauth/messages"
    assert request.method == "POST"
    assert request.headers["Authorization"] == "Bearer provider-token"
    body = json.loads(request.body)
    assert body["destination"] == "15551234567"
    assert body["messageTypes"] == [channel]
    assert body["correlationId"] == "correlation-id"
    if channel == "voice":
        assert body["voice"]["text2voice"] == {
            "beforePasswordText": "  Use ",
            "password": "918273",
            "afterPasswordText": "; then 1234.\nDo not rewrite + or café.  ",
            "language": "en-US",
            "gender": 1,
            "loop": 2,
        }
        assert "text" not in body
    else:
        assert body["text"] == MESSAGE

    result = SopranoProvider().map_response({"id": 123, "status": "ENROUTE"}, 201)
    assert result == ProviderResult(
        Outcome.CONTINUE, True, 201, "123", "ENROUTE")


@pytest.mark.parametrize("body,expected_status,recognized", [
    ({"status": "accepted", "id": 1}, "ACCEPTED", True),
    ([{"state": "queued", "messageId": "m"}], "QUEUED", True),
    ({"status": False, "state": "ACCEPTED"}, "UNKNOWN", False),
    ({}, "UNKNOWN", False),
])
def test_soprano_preserves_protocol_specific_mixed_response_shapes(body, expected_status, recognized):
    result = SopranoProvider().map_response(body, 200)
    assert result.provider_status_name == expected_status
    assert result.status_recognized is recognized
    assert result.failure_reason == (None if recognized else "unrecognized_provider_status")


def test_infobip_contract_is_strict_and_provider_owned():
    request = InfobipProvider().build_request(
        "sms", "https://infobip.example", _delivery(),
        {"mode": "apiKey", "secret": "ib"}, {"EPP_PROVIDER_ACCOUNT_NAME": "EPP"})
    assert request.url == "https://infobip.example/sms/3/messages"
    assert request.headers["Authorization"] == "App ib"
    assert json.loads(request.body)["messages"] == [{
        "sender": "EPP",
        "destinations": [{"to": "+15551234567", "messageId": "correlation-id"}],
        "content": {"text": MESSAGE},
    }]
    result = InfobipProvider().map_response({
        "messages": [{"messageId": "message-id", "status": {"groupName": "PENDING"}}],
    }, 200)
    assert result == ProviderResult(
        Outcome.CONTINUE, True, 200, "message-id", "PENDING")


def test_sinch_requires_a_provider_message_id_for_success():
    provider = SinchProvider()
    accepted = provider.map_response({"id": "message-id"}, 200)
    assert accepted.outcome == Outcome.CONTINUE
    assert accepted.provider_status_name == "Dispatched"
    missing = provider.map_response({}, 200)
    assert missing.outcome == Outcome.FAIL
    assert missing.failure_reason == "missing_provider_message_id"


@pytest.mark.parametrize("channel", ["sms", "voice"])
def test_telesign_request_contract(channel):
    request = TelesignProvider().build_request(
        channel,
        f"https://verify.telesign.com/epp/{channel}",
        _delivery(channel),
        {"mode": "apiKey", "secret": "key", "identity": "customer"},
        {},
    )
    assert request.headers["Authorization"] == (
        "Basic " + base64.b64encode(b"customer:key").decode())
    body = json.loads(request.body)
    assert body["recipient"] == {"phone_number": "+15551234567"}
    assert body["channels"] == [{"channel": channel}]
    assert body["correlation_id"] == "correlation-id"
    if channel == "voice":
        assert "9, 1, 8, 2, 7, 3" in body["message"]["text"]


def test_telesign_enforces_integer_status_codes():
    provider = TelesignProvider()
    for payload in ({}, {"status": {"code": True}}, {"status": {"code": "290"}}):
        result = provider.map_response(payload, 200)
        assert result.outcome == Outcome.FAIL
        assert result.status_recognized is False
        assert result.failure_reason == "unrecognized_provider_status"
    accepted = provider.map_response(
        {"reference_id": "message-id", "status": {"code": 290}}, 200)
    assert accepted == ProviderResult(
        Outcome.CONTINUE, True, 200, "message-id",
        provider_status_code="290")


def test_http_errors_override_provider_acceptance():
    result = SopranoProvider().map_response({"status": "ACCEPTED"}, 500)
    assert result.outcome == Outcome.FAIL
    assert result.failure_reason == "provider_http_error"


def test_telesign_validates_recipient_and_channel():
    provider = TelesignProvider()
    credential = {"identity": "customer", "secret": "key"}
    for destination in ("15551234567", "+0123", "+1", "+1234567890123456", None):
        delivery = _delivery()
        delivery = OtpDelivery(
            destination, delivery.message, delivery.channel, delivery.message_id,
            delivery.correlation_id, delivery.locale)
        with pytest.raises(ValueError, match="invalid recipient"):
            provider.build_request("sms", "https://verify.telesign.com", delivery, credential, {})
    with pytest.raises(ValueError, match="unsupported channel"):
        provider.build_request("email", "https://verify.telesign.com", _delivery(), credential, {})


def test_typed_payload_accepts_contract_values_and_rejects_bad_requests():
    valid = {
        "type": "microsoft.mfa.otpDeliver.v1",
        "channel": 1,
        "mode": 1,
        "encryptedDeliveryContext": "jwe",
    }
    for channel, mode, expected in ((1, 1, ("sms", False)), ("VOICE", "Evaluation", ("voice", True))):
        payload, error = EntraSendOtpPayload.from_payload(
            {**valid, "channel": channel, "mode": mode})
        assert error is None
        assert (payload.channel_name, payload.is_evaluation) == expected

    fixtures = json.loads(
        (Path(__file__).resolve().parents[2] / "tests/fixtures/contract.json")
        .read_text(encoding="utf-8"))
    for fixture in fixtures["badRequests"]:
        if fixture["reason"] == "invalid JSON body":
            continue
        value = (
            json.loads(fixture["rawBody"])
            if "rawBody" in fixture
            else {**valid, **fixture["overrides"]}
        )
        payload, error = EntraSendOtpPayload.from_payload(value)
        assert payload is None
        assert error == fixture["reason"]
