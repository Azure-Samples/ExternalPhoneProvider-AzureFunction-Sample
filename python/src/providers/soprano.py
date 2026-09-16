import json

from ..models import ParsedResponse, TextToVoice


class SopranoProvider:
    manifest = {
        "id": "soprano",
        "requires_text_to_voice": True,
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
            voice = dispatch.text_to_voice
            if not isinstance(voice, TextToVoice) or not voice.is_complete:
                raise ValueError("incomplete voice context")
            body["voice"] = {"text2voice": {
                "beforePasswordText": voice.before_password_text,
                "password": voice.password,
                "language": voice.language,
            }}
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
