import base64
import json
from pathlib import Path
from urllib.parse import parse_qs

import pytest

from src.dispatch import DispatchRequest, ProviderRegistry, context_to_dispatch, parse_envelope
from src.models import DeliveryContext, Envelope, ParsedResponse, TextToVoice
from src.providers.infobip import InfobipProvider
from src.providers.sinch import SinchProvider
from src.providers.soprano import SopranoProvider
from src.providers.telesign import TelesignProvider

MESSAGE = "  Use 918273; then 1234.\nDo not rewrite + or café.  "


def _dispatch(channel="sms"):
    return DispatchRequest("+15551234567", MESSAGE, channel, "message-id", "correlation-id", "en-US",
                           TextToVoice("Your code is", "001234", "en") if channel == "voice" else None)


@pytest.mark.parametrize("channel", ["sms", "voice"])
def test_soprano_exact_sms_and_voice_contract(channel):
    request = ProviderRegistry([SopranoProvider()]).get("SOPRANO").build_request(
        channel, "https://qa4.example/cgpapi///", _dispatch(channel),
        {"mode": "apiKey", "identity": "test-id", "secret": "test-key"},
        {},
    )
    assert request["url"] == "https://qa4.example/cgpapi/messages/omnimsg" and request["method"] == "POST"
    assert request["headers"] == {
        "X-MEMS-API-ID": "test-id", "X-MEMS-API-Key": "test-key",
        "Content-Type": "application/json", "Accept": "application/json",
    }
    expected = {
        "destination": "15551234567", "messageTypes": [channel],
        "correlationId": "correlation-id", "shutterMode": False,
    }
    if channel == "voice":
        expected["voice"] = {"text2voice": {"beforePasswordText": "Your code is", "password": "001234", "language": "en"}}
    else:
        expected["text"] = MESSAGE
    assert json.loads(request["body"]) == expected
    response = SopranoProvider().parse_response(201, True, {"id": 123, "status": "ENROUTE"})
    assert response == ParsedResponse(True, 201, provider_message_id="123", provider_status_name="ENROUTE")
    assert "ENROUTE" not in repr(response)


def test_infobip_sms_request_and_response_contract():
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
    response = InfobipProvider().parse_response(200, True, {
        "messages": [{"messageId": "message-id", "status": {"groupName": "PENDING"}}],
    })
    assert response == ParsedResponse(True, 200, provider_message_id="message-id", provider_status_name="PENDING")


def test_telesign_sms_request_and_response_contract():
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
    response = TelesignProvider().parse_response(200, True, {"reference_id": "message-id", "status": {"code": 290}})
    assert response == ParsedResponse(True, 200, provider_message_id="message-id", provider_status_code="290")


def test_sinch_sms_request_and_response_contract():
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
    response = SinchProvider().parse_response(200, True, {"id": "message-id"})
    assert response == ParsedResponse(True, 200, provider_message_id="message-id", provider_status_name="Dispatched")


def test_request_models_preserve_content_and_accept_valid_routing_and_ttl():
    payload = {"type": "microsoft.mfa.otpDeliver.v1", "channel": 1, "mode": 1, "encryptedDeliveryContext": "jwe"}
    for channel, mode, expected in ((1, 1, (1, 1)), ("VOICE", "Evaluation", (2, 2))):
        envelope, error = parse_envelope({**payload, "channel": channel, "mode": mode})
        assert error is None and isinstance(envelope, Envelope)
        assert (envelope.channel, envelope.mode) == expected
    for ttl in (1, 2147483647):
        envelope, error = parse_envelope({**payload, "ttlSeconds": ttl})
        assert error is None and envelope.ttl_seconds == ttl
    envelope, error = parse_envelope(payload)
    assert error is None and envelope.ttl_seconds is None

    context = DeliveryContext.from_payload({
        "nonce": " nonce ", "phoneNumber": "+15551234567", "message": MESSAGE,
        "locale": {"opaque": "metadata"},
    })
    assert isinstance(context, DeliveryContext) and context.is_complete
    dispatch = context_to_dispatch(context, envelope, "message-id")
    assert isinstance(dispatch, DispatchRequest)
    assert context.nonce == " nonce " and dispatch.message == MESSAGE
    assert dispatch.destination == context.phone_number and dispatch.locale is context.locale
    assert MESSAGE not in repr(context) + repr(dispatch)
    assert "encrypted_delivery_context" not in repr(envelope)
    assert DeliveryContext.from_payload(None) is None


def test_envelope_parser_rejects_invalid_inputs_with_the_contract_reason():
    fixtures = json.loads((Path(__file__).resolve().parents[2] / "tests/fixtures/contract.json").read_text())
    valid = {"type": "microsoft.mfa.otpDeliver.v1", "channel": 1, "mode": 1, "encryptedDeliveryContext": "jwe"}
    for fixture in fixtures["badRequests"]:
        # Malformed JSON is handled before the parser receives an object.
        if fixture["reason"] == "invalid JSON body":
            continue
        payload = json.loads(fixture["rawBody"]) if "rawBody" in fixture else {**valid, **fixture["overrides"]}
        envelope, error = parse_envelope(payload)
        assert envelope is None and error == fixture["reason"], fixture["name"]
