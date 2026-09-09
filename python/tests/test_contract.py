"""Representative provider wire contracts and fail-closed outcome mapping."""
import base64
import json
from urllib.parse import parse_qs

import pytest

from src.dispatch import (
    BLOCK,
    CONTINUE,
    FAIL,
    STEP_UP,
    DispatchRequest,
    resolve_outcome,
    to_http_status,
)
from src.providers.infobip import InfobipProvider
from src.providers.telesign import TelesignProvider
from src.providers.soprano import SopranoProvider
from src.providers.sinch import SinchProvider


def _dispatch(channel="sms"):
    return DispatchRequest(
        destination="+15551234567", message="code 918273", channel=channel,
        message_id="m", correlation_id="c", locale=None,
    )


@pytest.mark.parametrize("adapter,body,status,expected", [
    (InfobipProvider(), {"messages": [{"status": {"name": "DELIVERED"}}]}, 401, 401),
    (TelesignProvider(), {"status": {"code": 290}}, 429, 429),
    (SopranoProvider(), {"status": "ENROUTE"}, 500, 502),
    (SinchProvider(), {"status": "Dispatched"}, 401, 401),
])
def test_http_failure_overrides_success_body(adapter, body, status, expected):
    assert resolve_outcome(adapter.manifest, adapter.parse_response(200, True, body)) == CONTINUE
    outcome = resolve_outcome(adapter.manifest, adapter.parse_response(status, False, body))
    assert outcome == FAIL
    assert to_http_status(outcome, status) == expected


@pytest.mark.parametrize("status,outcome,http_status", [("BLOCKED", BLOCK, 403), ("RISK", STEP_UP, 409)])
def test_policy_outcomes_survive_http_failure(status, outcome, http_status):
    manifest = {"response_mapping": {"BLOCKED": BLOCK, "RISK": STEP_UP, "default": FAIL}}
    resolved = resolve_outcome(manifest, {"success": False, "provider_status_name": status})
    assert resolved == outcome
    assert to_http_status(resolved, 500) == http_status


def test_infobip_builds_https_sms_request():
    request = InfobipProvider().build_request(
        "sms", "https://api.infobip.com", _dispatch(),
        {"mode": "apiKey", "secret": "ib"}, {"EPP_PROVIDER_ACCOUNT_NAME": "EPP"},
    )
    assert (request["method"], request["url"]) == ("POST", "https://api.infobip.com/sms/3/messages")
    assert request["headers"]["Authorization"] == "App ib"
    message = json.loads(request["body"])["messages"][0]
    assert message["sender"] == "EPP"
    assert message["content"]["text"] == "code 918273"


def test_telesign_basic_auth_and_form_payload():
    request = TelesignProvider().build_request(
        "sms", "https://rest-api.telesign.com", _dispatch(),
        {"mode": "apiKey", "secret": "key", "identity": "cust"}, {},
    )
    assert request["headers"]["Authorization"] == "Basic " + base64.b64encode(b"cust:key").decode()
    assert request["url"] == "https://rest-api.telesign.com/v1/messaging"
    assert parse_qs(request["body"])["message"] == ["code 918273"]


@pytest.mark.parametrize("channel", ["sms", "voice"])
def test_soprano_api_key_and_omnimsg_payload(channel):
    request = SopranoProvider().build_request(
        channel, "https://qa.example.com/cgpapi", _dispatch(channel),
        {"mode": "apiKey", "secret": "k", "identity": "id"}, {},
    )
    assert (request["method"], request["url"]) == ("POST", "https://qa.example.com/cgpapi/messages/omnimsg")
    assert request["headers"]["X-MEMS-API-ID"] == "id"
    assert request["headers"]["X-MEMS-API-Key"] == "k"
    assert "Authorization" not in request["headers"]
    assert json.loads(request["body"]) == {
        "messageTypes": [channel], "destination": "15551234567", "text": "code 918273",
        "correlationId": "c", "shutterMode": False,
    }


def test_sinch_bearer_and_sms_payload():
    request = SinchProvider().build_request(
        "sms", "https://sms.api.sinch.com", _dispatch(),
        {"mode": "apiKey", "secret": "st"}, {"SINCH_SERVICE_PLAN_ID": "plan"},
    )
    assert request["url"] == "https://sms.api.sinch.com/xms/v1/plan/batches"
    assert request["headers"]["Authorization"] == "Bearer st"
    assert json.loads(request["body"])["body"] == "code 918273"
