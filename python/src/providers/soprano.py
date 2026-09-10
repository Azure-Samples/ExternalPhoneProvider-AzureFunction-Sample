import json

from ..models import ParsedResponse


class SopranoProvider:
    manifest = {
        "id": "soprano",
        "auth": {
            "mode": "apiKey",
            "key_vault_secret_name": "soprano-api-key",
            "identity_key_vault_secret_name": "soprano-api-id",
        },
        "response_mapping": {
            "ENROUTE": "Continue", "ACCEPTED": "Continue", "SUBMITTED": "Continue",
            "SENT": "Continue", "DELIVERED": "Continue", "QUEUED": "Continue",
            "FAILED": "Fail", "REJECTED": "Fail", "FILTERED": "Fail", "BLOCKED": "Block", "default": "Fail",
        },
    }

    def build_request(self, channel, endpoint, dispatch, credential, env):
        message_type = "voice" if channel == "voice" else "sms"
        headers = {
            "X-MEMS-API-ID": credential.get("identity") or "",
            "X-MEMS-API-Key": credential.get("secret") or "",
            "Content-Type": "application/json",
            "Accept": "application/json",
        }
        body = {
            "text": dispatch.message,
            "destination": str(dispatch.destination).lstrip("+"),
            "messageTypes": [message_type],
            "correlationId": dispatch.correlation_id or dispatch.message_id,
            "shutterMode": False,
        }
        return {"url": f"{endpoint.rstrip('/')}/messages/omnimsg", "method": "POST", "headers": headers, "body": json.dumps(body)}

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
