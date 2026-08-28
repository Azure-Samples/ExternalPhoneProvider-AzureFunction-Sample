"""Conformance tests for the pure contract logic (see /docs/CONTRACT.md §6)."""
from src.dispatch import (
    BLOCK,
    CONTINUE,
    FAIL,
    STEP_UP,
    DispatchRequest,
    ProviderRegistry,
    resolve_outcome,
    to_http_status,
)
from src.providers.infobip import InfobipProvider
from src.providers.telesign import TelesignProvider
from src.providers.soprano import SopranoProvider
from src.providers.sinch import SinchProvider


def _dispatch(channel="sms", message=None):
    return DispatchRequest(
        destination="+15551234567", message=message, channel=channel,
        message_id="m", correlation_id="c", locale=None,
    )


def test_outcome_and_http_status():
    manifest = InfobipProvider.manifest
    assert resolve_outcome(manifest, {"success": True, "provider_status_name": "DELIVERED"}) == CONTINUE
    # Unknown status fails closed even on HTTP 200.
    assert resolve_outcome(manifest, {"success": True, "provider_status_name": "WATWAT"}) == FAIL
    assert to_http_status(CONTINUE, 200) == 200
    assert to_http_status(BLOCK, 200) == 403
    assert to_http_status(STEP_UP, 200) == 409
    assert to_http_status(FAIL, 429) == 429
    assert to_http_status(FAIL, 403) == 401
    assert to_http_status(FAIL, 422) == 400
    assert to_http_status(FAIL, 500) == 502


def test_infobip_builds_https_sms_request():
    env = {"INFOBIP_SENDER_ID": "EPP"}
    request = InfobipProvider().build_request(
        "sms", "https://api.infobip.com",
        _dispatch(message="Use verification code 918273 for Microsoft authentication."),
        {"mode": "apiKey", "secret": "ib"}, env,
    )
    assert request["url"].startswith("https://")
    assert request["url"].endswith("/sms/3/messages")
    assert request["headers"]["Authorization"].startswith("App ")
    assert "918273" in request["body"]


def test_telesign_basic_auth_and_voice_mapping():
    request = TelesignProvider().build_request(
        "sms", "https://rest-api.telesign.com", _dispatch(message="code 918273"),
        {"mode": "apiKey", "secret": "key", "identity": "cust"}, {},
    )
    assert request["headers"]["Authorization"].startswith("Basic ")
    assert request["url"].endswith("/v1/messaging")
    assert resolve_outcome(TelesignProvider.manifest, {"success": True, "provider_status_code": "100"}) == CONTINUE


def test_registry_resolves_by_id():
    registry = ProviderRegistry([InfobipProvider(), TelesignProvider(), SopranoProvider(), SinchProvider()])
    assert registry.get("TELESIGN").manifest["id"] == "telesign"
    assert registry.get("nope") is None
