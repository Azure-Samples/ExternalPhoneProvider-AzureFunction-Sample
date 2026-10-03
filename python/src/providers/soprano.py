import json
import re

from ..models import Outcome, ProviderResult
from ..provider import OutboundRequest, PhoneProviderBase, classify_failure

DEFAULT_VOICE_LANGUAGE = "en-US"
VOICE_GENDER = 1
VOICE_LOOP = 2


def _build_text_to_voice(message, locale):
    rendered_message = str(message or "")
    passcode_match = re.search(r"[0-9]{6}", rendered_message)
    if not passcode_match:
        raise ValueError("voice message does not contain a six-digit passcode")
    return {
        "beforePasswordText": rendered_message[:passcode_match.start()],
        "password": passcode_match.group(0),
        "afterPasswordText": rendered_message[passcode_match.end():],
        "language": locale if isinstance(locale, str) and locale.strip() else DEFAULT_VOICE_LANGUAGE,
        "gender": VOICE_GENDER,
        "loop": VOICE_LOOP,
    }


class SopranoProvider(PhoneProviderBase):
    name = "soprano"
    authentication_mode = "oauth"

    @property
    def credential_spec(self):
        return {"mode": self.authentication_mode}

    def build_request(self, channel, endpoint, delivery, credential, env):
        message_type = "voice" if channel == "voice" else "sms"
        headers = {
            "Authorization": f"Bearer {credential.get('access_token') or ''}",
            "Content-Type": "application/json",
            "Accept": "application/json",
        }
        body = {
            "destination": str(delivery.phone_number).lstrip("+"),
            "messageTypes": [message_type],
            "correlationId": delivery.correlation_id or delivery.message_id,
            "shutterMode": False,
        }
        if channel == "voice":
            body["voice"] = {"text2voice": _build_text_to_voice(delivery.message, delivery.locale)}
        else:
            body["text"] = delivery.message
        return OutboundRequest("POST", endpoint, headers, json.dumps(body))

    def map_response(self, body, http_status):
        payload = body[0] if isinstance(body, list) and body else body
        payload = payload if isinstance(payload, dict) else {}
        identifier = payload.get("id")
        identifier = (
            str(identifier)
            if isinstance(identifier, (str, int)) and not isinstance(identifier, bool)
            else payload.get("messageId")
        )
        value = payload.get("status")
        if value is None:
            value = payload.get("state")
        status = value.upper() if isinstance(value, str) and value else "UNKNOWN"
        continue_statuses = {"ENROUTE", "ACCEPTED", "SUBMITTED", "SENT", "DELIVERED", "QUEUED"}
        fail_statuses = {"FAILED", "REJECTED", "FILTERED"}
        recognized = status in continue_statuses | fail_statuses | {"BLOCKED"}
        outcome = (
            Outcome.CONTINUE if status in continue_statuses
            else Outcome.BLOCK if status == "BLOCKED"
            else Outcome.FAIL
        )
        final_outcome = outcome if 200 <= http_status < 300 else Outcome.FAIL
        return ProviderResult(
            final_outcome,
            recognized,
            http_status,
            identifier if isinstance(identifier, str) else None,
            status,
            failure_reason=classify_failure(http_status, final_outcome, recognized),
        )
