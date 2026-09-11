import base64
import json
from pathlib import Path

import pytest

from src.dispatch import DispatchRequest, ProviderRegistry, context_to_dispatch, parse_envelope, resolve_outcome
from src.models import DeliveryContext, Envelope, ParsedResponse
from src.providers.infobip import InfobipProvider
from src.providers.sinch import SinchProvider
from src.providers.soprano import SopranoProvider
from src.providers.telesign import TelesignProvider

MESSAGE = "  Use 918273; then 1234.\nDo not rewrite + or café.  "


def _dispatch(channel="sms"):
    return DispatchRequest("+15551234567", MESSAGE, channel, "message-id", "correlation-id", "en-US")


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
    assert json.loads(request["body"]) == {
        "text": MESSAGE, "destination": "15551234567", "messageTypes": [channel],
        "correlationId": "correlation-id", "shutterMode": False,
    }
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


@pytest.mark.parametrize("channel,locale", [
    ("sms", "en"), ("voice", "en"), ("sms", None), ("sms", ""), ("sms", {"untrusted": True}),
])
def test_telesign_epp_request_contract(channel, locale):
    dispatch = _dispatch(channel)
    dispatch.locale = locale
    request = TelesignProvider().build_request(
        channel, "https://verify.telesign.com///", dispatch,
        {"mode": "apiKey", "secret": "key", "identity": "customer"}, {},
    )
    assert request["method"] == "POST" and request["url"] == "https://verify.telesign.com/integration/msft/cyot"
    assert request["headers"] == {"Authorization": "Basic " + base64.b64encode(b"customer:key").decode(),
                                  "Content-Type": "application/json", "Accept": "application/json"}
    assert json.loads(request["body"]) == {
        "recipient": {"phone_number": "+15551234567"},
        "message": {"text": MESSAGE, "language": "en"} if locale == "en" else {"text": MESSAGE},
        "channels": [{"channel": channel}], "correlation_id": "correlation-id",
    }


def test_telesign_epp_validates_recipients_and_status():
    adapter = TelesignProvider()
    response = adapter.parse_response(200, True, {"reference_id": "message-id", "status": {"code": 290}})
    assert response == ParsedResponse(True, 200, provider_message_id="message-id", provider_status_code="290")
    credential = {"identity": "customer", "secret": "key"}
    for destination in ("15551234567", "+0123", "+1", "+1234567890123456", "+123\n", "+123\r", "+12 34", None):
        dispatch = _dispatch()
        dispatch.destination = destination
        with pytest.raises(ValueError, match="invalid recipient"):
            adapter.build_request("sms", "https://verify.telesign.com", dispatch, credential, {})
    with pytest.raises(ValueError, match="unsupported channel"):
        adapter.build_request("email", "https://verify.telesign.com", _dispatch(), credential, {})
    dispatch = _dispatch()
    for correlation_id in (None, "", 123, True, [], {"invalid": True}):
        dispatch.correlation_id = correlation_id
        request = adapter.build_request("sms", "https://verify.telesign.com", dispatch, credential, {})
        assert json.loads(request["body"])["correlation_id"] == dispatch.message_id
    for payload in (None, {}, {"status": []}, {"status": {"code": True}}, {"status": {"code": "290"}}, {"status": {"code": 999}}):
        assert resolve_outcome(adapter.manifest, adapter.parse_response(200, True, payload)) == "Fail"
    for code, ok, outcome in ((290, True, "Continue"), (100, True, "Continue"), (290, False, "Fail")):
        parsed = adapter.parse_response(200 if ok else 500, ok, {"status": {"code": code, "description": "status detail"}})
        assert parsed.provider_status_description == "status detail"
        assert resolve_outcome(adapter.manifest, parsed) == outcome


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
