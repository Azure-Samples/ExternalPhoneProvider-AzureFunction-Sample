import base64
import json
import re

from ..models import ParsedResponse


class TelesignProvider:
    manifest = {
        "id": "telesign",
        "auth": {
            "mode": "apiKey",
            "key_vault_secret_name": "telesign-api-key",
            "identity_key_vault_secret_name": "telesign-customer-id",
        },
        "response_mapping": {
            "200": "Continue", "203": "Continue", "290": "Continue", "291": "Continue", "292": "Continue",
            "100": "Continue", "101": "Continue", "102": "Continue", "103": "Continue",
            "3001": "Continue",
            "default": "Fail",
        },
    }

    def build_request(self, channel, endpoint, dispatch, credential, env):
        if channel not in ("sms", "voice"):
            raise ValueError("unsupported channel")
        if not isinstance(dispatch.destination, str) or not re.fullmatch(r"\+[1-9][0-9]{1,14}", dispatch.destination):
            raise ValueError("invalid recipient")
        raw = f"{credential['identity']}:{credential['secret']}".encode()
        authorization = "Basic " + base64.b64encode(raw).decode()
        correlation_id = dispatch.correlation_id
        if not isinstance(correlation_id, str) or not correlation_id:
            correlation_id = dispatch.message_id
        message = {"text": dispatch.message}
        if isinstance(dispatch.locale, str) and dispatch.locale.strip():
            message["language"] = dispatch.locale
        body = {
            "recipient": {"phone_number": dispatch.destination},
            "message": message,
            "channels": [{"channel": channel}],
            "correlation_id": correlation_id,
        }
        headers = {
            "Authorization": authorization,
            "Content-Type": "application/json",
            "Accept": "application/json",
        }
        return {
            "url": f"{endpoint.rstrip('/')}/integration/msft/cyot",
            "method": "POST",
            "headers": headers,
            "body": json.dumps(body),
        }

    def parse_response(self, http_status, ok, json_body):
        payload = json_body if isinstance(json_body, dict) else {}
        status = payload.get("status")
        status = status if isinstance(status, dict) else {}
        code = status.get("code")
        reference_id = payload.get("reference_id")
        description = status.get("description")
        return ParsedResponse(
            success=ok,
            provider_http_status=http_status,
            provider_message_id=reference_id if isinstance(reference_id, str) else None,
            provider_status_code=str(code) if type(code) is int else "UNKNOWN",
            provider_status_description=description if isinstance(description, str) else None,
        )
