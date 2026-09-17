import json
import re

from ..models import ParsedResponse

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


class SopranoProvider:
    manifest = {
        "id": "soprano",
        "auth": {"mode": "oauth"},
        "response_mapping": {
            "ENROUTE": "Continue", "ACCEPTED": "Continue", "SUBMITTED": "Continue",
            "SENT": "Continue", "DELIVERED": "Continue", "QUEUED": "Continue",
            "FAILED": "Fail", "REJECTED": "Fail", "FILTERED": "Fail", "BLOCKED": "Block", "default": "Fail",
        },
    }

    def build_request(self, channel, endpoint, dispatch, credential, env):
        message_type = "voice" if channel == "voice" else "sms"
        headers = {
            "Authorization": f"Bearer {credential.get('access_token') or ''}",
            "Content-Type": "application/json",
            "Accept": "application/json",
        }
        body = {
            "destination": str(dispatch.destination).lstrip("+"),
            "messageTypes": [message_type],
            "correlationId": dispatch.correlation_id or dispatch.message_id,
            "shutterMode": False,
        }
        if channel == "voice":
            body["voice"] = {"text2voice": _build_text_to_voice(dispatch.message, dispatch.locale)}
        else:
            body["text"] = dispatch.message
        return {"url": endpoint, "method": "POST", "headers": headers, "body": json.dumps(body)}

    def parse_response(self, http_status, ok, json_body):
        payload = json_body[0] if isinstance(json_body, list) and json_body else json_body
        payload = payload if isinstance(payload, dict) else {}
        identifier = payload.get("id")
        identifier = str(identifier) if identifier is not None else payload.get("messageId")
        value = payload.get("status")
        if value is None:
            value = payload.get("state")
        status = value.upper() if isinstance(value, str) and value else "UNKNOWN"
        return ParsedResponse(
            success=ok,
            provider_http_status=http_status,
            provider_message_id=identifier,
            provider_status_name=status,
        )
