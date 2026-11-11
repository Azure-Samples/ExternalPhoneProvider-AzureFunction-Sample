import json
from dataclasses import replace
from pathlib import Path

import pytest

from src.models import DeliveryContext, EntraSendOtpPayload, Outcome, OtpDelivery, ProviderResult, RiskContext
from src.provider import to_endpoint_http_status
from src.providers.infobip import InfobipProvider
from src.providers.soprano import SopranoProvider
from src.providers.telesign import TelesignProvider

MESSAGE = "  Use 918273; then 1234.\nDo not rewrite + or café.  "
VOICE_MESSAGE = (
    "  Use 9, 1, 8, 2, 7, 3; then 1234.\nDo not rewrite + or café.   "
    "  Use 9, 1, 8, 2, 7, 3; then 1234.\nDo not rewrite + or café.  "
)


def _delivery(channel="sms"):
    return OtpDelivery(
        "+15551234567", MESSAGE, channel, "message-id", "correlation-id", "en-US", otp="918273")


@pytest.mark.parametrize("fields,expected", [
    ({}, None), ({"otp": None}, None), ({"otp": ""}, ""),
    ({"otp": "001234"}, "001234"), ({"otp": "000000"}, "000000"),
])
def test_delivery_models_preserve_optional_otp_without_coercion_or_message_extraction(fields, expected):
    context = DeliveryContext.from_payload({
        "nonce": "nonce", "phoneNumber": "+15551234567", "message": MESSAGE, **fields,
    })
    assert context.is_complete
    assert context.otp == expected
    assert context.message == MESSAGE
    delivery = OtpDelivery(
        context.phone_number, context.message, "sms", "message-id", "correlation-id", None,
        otp=context.otp)
    assert delivery.otp == expected
    for value in (context, delivery):
        assert MESSAGE not in repr(value)
        if expected:
            assert expected not in repr(value)


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


@pytest.mark.parametrize("region", ["global", "eu"])
@pytest.mark.parametrize("channel", ["sms", "voice"])
def test_infobip_uses_configured_urls_unchanged_with_oauth_on_both_setup_routes(region, channel):
    profile = json.loads((Path(__file__).parents[2] / "setup" / "providers" / "infobip.json").read_text())
    provider = InfobipProvider()
    assert provider.authentication_mode == "oauth"
    assert provider.credential_spec == {"mode": "oauth"}
    endpoint = profile["deployment"]["routes"][region][f"{channel}Endpoint"]
    request = provider.build_request(
        channel, endpoint, _delivery(channel),
        {"mode": "oauth", "access_token": "provider-token"},
        {"INFOBIP_VOICE_SENDER_ID": profile["deployment"]["environmentVariables"]["INFOBIP_VOICE_SENDER_ID"]["default"]})
    assert request.url == endpoint
    assert request.method == "POST"
    assert request.headers == {
        "Authorization": " ".join(("Bearer", "provider-token")),
        "Content-Type": "application/json",
        "Accept": "application/json",
    }
    destinations = [{"to": "+15551234567", "messageId": "correlation-id"}]
    expected = {
        "to": "+15551234567",
        "text": VOICE_MESSAGE,
        "language": "en",
        "voice": {"name": "Joanna", "gender": "female"},
        "from": "Microsoft",
    } if channel == "voice" else {
        "destinations": destinations,
        "content": {"text": MESSAGE},
    }
    assert json.loads(request.body) == (expected if channel == "voice" else {"messages": [expected]})


@pytest.mark.parametrize("locale,language", [
    ("en-us", "en"), ("FR-fr", "fr"), ("zh-Hans-CN", "zh"), ("pt", "pt"),
    ("  DE-de  ", "de"), (None, "en"), ("", "en"), ("   ", "en"),
])
@pytest.mark.parametrize("env,sender", [
    ({"INFOBIP_VOICE_SENDER_ID": "Microsoft"}, "Microsoft"),
    ({"INFOBIP_VOICE_SENDER_ID": "  41793026700  "}, "41793026700"),
])
def test_infobip_voice_sender_and_locale_language(locale, language, env, sender):
    request = InfobipProvider().build_request(
        "voice", "https://api.infobip.com/tts/3/single",
        replace(_delivery("voice"), locale=locale), {"access_token": "token"}, env)
    assert json.loads(request.body) == {
        "to": "+15551234567",
        "text": VOICE_MESSAGE,
        "language": language,
        "voice": {"name": "Joanna", "gender": "female"},
        "from": sender,
    }


@pytest.mark.parametrize("env", [{}, {"INFOBIP_VOICE_SENDER_ID": ""}, {"INFOBIP_VOICE_SENDER_ID": "   "}])
def test_infobip_requires_sender_for_voice_but_not_sms(env):
    provider = InfobipProvider()
    credential = {"access_token": "token"}
    with pytest.raises(ValueError, match="INFOBIP_VOICE_SENDER_ID is required"):
        provider.build_request(
            "voice", "https://api.infobip.com/tts/3/single", _delivery("voice"), credential, env)
    request = provider.build_request(
        "sms", "https://api.infobip.com/sms/3/messages", _delivery(), credential, env)
    assert json.loads(request.body)["messages"][0]["content"]["text"] == MESSAGE


def test_infobip_contract_is_strict_and_provider_owned():
    result = InfobipProvider().map_response({
        "messages": [{"messageId": "message-id", "status": {"groupName": "PENDING"}}],
    }, 200)
    assert result == ProviderResult(
        Outcome.CONTINUE, True, 200, "message-id", "PENDING")


@pytest.mark.parametrize("channel", ["sms", "voice"])
def test_telesign_request_contract(channel):
    provider = TelesignProvider()
    request = provider.build_request(
        channel,
        f"https://verify.telesign.com/epp/{channel}",
        _delivery(channel),
        {"mode": "oauth", "access_token": "provider-token"},
        {},
    )
    assert request.headers["Authorization"] == "Bearer provider-token"
    assert provider.credential_spec == {"mode": "oauth"}
    body = json.loads(request.body)
    assert body["recipient"] == {"phone_number": "+15551234567"}
    assert body["channels"] == [{"channel": channel}]
    assert body["correlation_id"] == "correlation-id"
    if channel == "voice":
        assert body["message"]["text"] == VOICE_MESSAGE
    else:
        assert body["message"]["text"] == MESSAGE


@pytest.mark.parametrize("provider_type", [InfobipProvider, TelesignProvider])
@pytest.mark.parametrize("message,otp,expected_voice", [
    ("001234", "001234", "0, 0, 1, 2, 3, 4 0, 0, 1, 2, 3, 4"),
    ("Tenant 654321: code 001234; repeat 001234.", "001234",
     "Tenant 654321: code 0, 0, 1, 2, 3, 4; repeat 0, 0, 1, 2, 3, 4. "
     "Tenant 654321: code 0, 0, 1, 2, 3, 4; repeat 0, 0, 1, 2, 3, 4."),
    ("Code 1234.", "1234", "Code 1, 2, 3, 4. Code 1, 2, 3, 4."),
    ("Code 00123456.", "00123456", "Code 0, 0, 1, 2, 3, 4, 5, 6. Code 0, 0, 1, 2, 3, 4, 5, 6."),
    ("Code a.b; tenant axb.", "a.b", "Code a, ., b; tenant axb. Code a, ., b; tenant axb."),
    ("Tenant 654321.", "999999", "Tenant 654321. Tenant 654321."),
    ("Tenant 654321.", None, "Tenant 654321. Tenant 654321."),
    ("Tenant 654321.", "", "Tenant 654321. Tenant 654321."),
])
def test_voice_paces_only_supplied_otp_and_repeats_without_changing_sms(
    provider_type, message, otp, expected_voice,
):
    provider = provider_type()
    for channel in ("sms", "voice"):
        request = provider.build_request(
            channel, "https://provider.example",
            replace(_delivery(channel), message=message, otp=otp),
            {"access_token": "token"}, {"INFOBIP_VOICE_SENDER_ID": "Microsoft"})
        body = json.loads(request.body)
        if provider_type is TelesignProvider:
            text = body["message"]["text"]
        elif channel == "voice":
            text = body["text"]
        else:
            text = body["messages"][0]["content"]["text"]
        assert text == (expected_voice if channel == "voice" else message)


@pytest.mark.parametrize("channel", ["sms", "voice"])
@pytest.mark.parametrize("risk_context,expected", [
    (None, {}), ({"scenario": None, "ipAddress": None}, {}),
    ({"scenario": "signin"}, {"account_lifecycle_event": "signin"}),
    ({"scenario": "signIn", "ipAddress": "2001:db8::1", "other": "PRIVATE-RISK"},
     {"account_lifecycle_event": "signIn", "originating_ip": "2001:db8::1"}),
    ({"scenario": "", "ipAddress": ""}, {"account_lifecycle_event": "", "originating_ip": ""}),
])
def test_telesign_maps_optional_risk_strings_unchanged(channel, risk_context, expected):
    provider = TelesignProvider()
    credential = {"mode": "oauth", "access_token": "provider-token"}
    endpoint = "https://verify.telesign.com/integration/msft/cyot"
    baseline = provider.build_request(channel, endpoint, _delivery(channel), credential, {})
    request = provider.build_request(
        channel, endpoint, replace(_delivery(channel), risk_context=RiskContext.from_payload(risk_context)),
        credential, {})
    assert json.loads(request.body) == {**json.loads(baseline.body), **expected}


@pytest.mark.parametrize("http_status,outcome,endpoint_status,reason", [
    (200, Outcome.BLOCK, 422, "provider_blocked"),
    (500, Outcome.FAIL, 502, "provider_http_error"),
    (429, Outcome.FAIL, 429, "provider_http_error"),
])
def test_telesign_recognizes_risk_blocks_without_overriding_http_failures(
    http_status, outcome, endpoint_status, reason,
):
    result = TelesignProvider().map_response({"status": {"code": 3072}}, http_status)
    assert result.outcome == outcome
    assert result.status_recognized is True
    assert result.failure_reason == reason
    assert to_endpoint_http_status(result) == endpoint_status


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
    credential = {"mode": "oauth", "access_token": "provider-token"}
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
