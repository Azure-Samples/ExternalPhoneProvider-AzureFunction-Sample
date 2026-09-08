"""Offline regressions for hostile envelope types and contradictory provider responses."""
import pytest

from src.dispatch import parse_envelope, resolve_outcome, to_http_status
from src.providers.infobip import InfobipProvider
from src.providers.telesign import TelesignProvider
from src.providers.soprano import SopranoProvider
from src.providers.sinch import SinchProvider


def envelope(**overrides):
    return {"type": "microsoft.mfa.otpDeliver.v1", "channel": 1, "mode": 1,
            "encryptedDeliveryContext": "unused", **overrides}


@pytest.mark.parametrize("field", ["channel", "mode"])
@pytest.mark.parametrize("value", [[], [1], {}, True, False, None, "__proto__", "constructor", "1"])
def test_invalid_routing_types(field, value):
    parsed, error = parse_envelope(envelope(**{field: value}))
    assert parsed is None and error


def test_ttl_may_be_omitted_but_not_null():
    assert parse_envelope(envelope())[0] is not None
    assert parse_envelope(envelope(ttlSeconds=None))[1]


@pytest.mark.parametrize("adapter,body", [
    (InfobipProvider(), {"messages": [{"status": {"name": "DELIVERED"}}]}),
    (TelesignProvider(), {"status": {"code": 290}}),
    (SopranoProvider(), {"status": "ENROUTE"}),
    (SinchProvider(), {"status": "Dispatched"}),
])
@pytest.mark.parametrize("status,expected", [(401, 401), (429, 429), (500, 502)])
def test_http_failure_overrides_success_body(adapter, body, status, expected):
    parsed = adapter.parse_response(status, False, body)
    outcome = resolve_outcome(adapter.manifest, parsed)
    assert outcome == "Fail"
    assert to_http_status(outcome, status) == expected


def test_block_and_stepup_are_preserved():
    manifest = {"response_mapping": {"BLOCKED": "Block", "RISK": "StepUp", "default": "Fail"}}
    for status, expected in [("BLOCKED", "Block"), ("RISK", "StepUp")]:
        assert resolve_outcome(manifest, {"success": False, "provider_status_name": status}) == expected