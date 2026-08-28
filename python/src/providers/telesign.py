"""Telesign: SMS via /v1/messaging, voice via /v1/voice (form-urlencoded).
Auth: HTTP Basic (customer_id:api_key)."""
import base64
import urllib.parse


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
            "default": "Fail",
        },
    }

    def build_request(self, channel, endpoint, dispatch, credential, env):
        if credential["mode"] == "oauth2":
            authorization = f"Bearer {credential['token']}"
        else:
            raw = f"{credential['identity']}:{credential['secret']}".encode()
            authorization = "Basic " + base64.b64encode(raw).decode()

        external_id = dispatch.correlation_id or dispatch.message_id
        if channel == "voice":
            path = "/v1/voice"
            form = {
                "phone_number": dispatch.destination,
                "message": dispatch.message or "",
                "message_type": "OTP",
                "voice": env.get("TELESIGN_VOICE") or "f-en-US",
                "external_id": external_id,
            }
        else:
            path = "/v1/messaging"
            form = {
                "phone_number": dispatch.destination,
                "message": dispatch.message or "",
                "sender_id": env.get("EPP_PROVIDER_ACCOUNT_NAME") or "",
                "message_type": "OTP",
                "external_id": external_id,
                "is_primary": "true",
            }

        headers = {"Authorization": authorization, "Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json"}
        return {"url": f"{endpoint}{path}", "method": "POST", "headers": headers, "body": urllib.parse.urlencode(form)}

    def parse_response(self, http_status, ok, json_body):
        status = json_body.get("status") or {} if isinstance(json_body, dict) else {}
        code = status.get("code")
        return {
            "success": ok,
            "provider_http_status": http_status,
            "provider_message_id": json_body.get("reference_id") if isinstance(json_body, dict) else None,
            "provider_status_name": None,
            "provider_status_code": str(code) if code is not None else None,
            "provider_status_description": status.get("description"),
        }
