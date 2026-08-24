"""Soprano Connect (MEMS): POST {base}/messages/omnimsg.
One endpoint for every channel - `messageTypes` picks it and Soprano does the TTS for voice.
Auth: an Entra ID v2.0 Bearer JWT (audience = Soprano's app id), or X-MEMS-API-ID + X-MEMS-API-Key."""
import json


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
            "FAILED": "Fail", "REJECTED": "Fail", "BLOCKED": "Block", "default": "Fail",
        },
    }

    def build_request(self, channel, endpoint, dispatch, credential, env):
        headers = {"Content-Type": "application/json", "Accept": "application/json"}
        if credential["mode"] == "oauth2":
            headers["Authorization"] = f"Bearer {credential['token']}"
        else:
            headers["X-MEMS-API-ID"] = credential.get("identity") or ""
            headers["X-MEMS-API-Key"] = credential.get("secret") or ""

        body = {
            "text": dispatch.message,
            "destination": str(dispatch.destination or "").lstrip("+"),  # E.164 without the leading +
            "messageTypes": ["voice" if channel == "voice" else "sms"],
            "correlationId": dispatch.correlation_id or dispatch.message_id,
            # Soprano processes the request but delivers nothing - connectivity/credential testing.
            "shutterMode": str(env.get("SOPRANO_SHUTTER_MODE") or "").lower() == "true",
        }

        return {"url": f"{endpoint}/messages/omnimsg", "method": "POST", "headers": headers, "body": json.dumps(body)}

    def parse_response(self, http_status, ok, json_body):
        payload = json_body[0] if isinstance(json_body, list) and json_body else json_body
        payload = payload if isinstance(payload, dict) else {}
        identifier = payload.get("id")
        identifier = str(identifier) if identifier is not None else payload.get("messageId")
        status = payload.get("status") or payload.get("state")
        status = status.upper() if status else ("SUBMITTED" if ok else None)
        return {
            "success": ok,
            "provider_http_status": http_status,
            "provider_message_id": identifier,
            "provider_status_name": status,
            "provider_status_code": None,
            "provider_status_description": payload.get("errorDescription") or payload.get("statusText") or payload.get("description"),
        }
