"""Soprano Connect (MEMS): POST {base}/messages/{sms|voice}.
Auth: X-MEMS-API-ID + X-MEMS-API-Key."""
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
        message_type = "voice" if channel == "voice" else "sms"
        headers = {"Content-Type": "application/json", "Accept": "application/json"}
        if credential["mode"] == "oauth2":
            headers["Authorization"] = f"Bearer {credential['token']}"
        else:
            headers["X-MEMS-API-ID"] = credential.get("identity") or ""
            headers["X-MEMS-API-Key"] = credential.get("secret") or ""

        client_reference = dispatch.correlation_id or dispatch.message_id
        body = {"messageType": message_type, "destination": dispatch.destination, "clientReference": client_reference}

        # Sender: a provisioned source endpoint is what Soprano accepts; free-text source is a fallback.
        # Soprano wants a provisioned source endpoint (endpoints:[{type,id}]), which is numeric. A
        # non-numeric account name is sent as a free-text source instead.
        account = env.get("EPP_PROVIDER_ACCOUNT_NAME")
        if account and str(account).isdigit():
            source_type = int(env.get("SOPRANO_SOURCE_TYPE") or 1)
            body["endpoints"] = [{"type": source_type, "id": int(account)}]
        elif account:
            body["source"] = account

        if message_type == "voice":
            locale = dispatch.locale or ""
            voice_language = env.get("SOPRANO_VOICE_LANGUAGE") or (locale if "-" in locale else "en-US")
            body["voice"] = {"text2voice": {
                "beforePasswordText": dispatch.message or "",
                "password": "",
                "afterPasswordText": "",
                "language": voice_language,
                "gender": int(env.get("SOPRANO_VOICE_GENDER") or 1),
                "loop": 1,
            }}
        else:
            body["text"] = dispatch.message

        return {"url": f"{endpoint}/messages/{message_type}", "method": "POST", "headers": headers, "body": json.dumps(body)}

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
