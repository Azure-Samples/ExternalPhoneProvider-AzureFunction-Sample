"""Infobip: SMS via /sms/3/messages, voice via /tts/3/advanced. Auth: App API key."""
import json


class InfobipProvider:
    manifest = {
        "id": "infobip",
        "auth": {"mode": "apiKey", "key_vault_secret_name": "infobip-api-key"},
        "response_mapping": {
            "ACCEPTED": "Continue",
            "PENDING": "Continue",
            "DELIVERED": "Continue",
            "REJECTED": "Fail",
            "EXPIRED": "Fail",
            "UNDELIVERABLE": "Fail",
            "default": "Fail",
        },
    }

    def build_request(self, channel, endpoint, dispatch, credential, env):
        sender_id = env.get("EPP_PROVIDER_ACCOUNT_NAME") or "Verify"
        authorization = f"Bearer {credential['token']}" if credential["mode"] == "oauth2" else f"App {credential['secret']}"
        headers = {"Authorization": authorization, "Content-Type": "application/json", "Accept": "application/json"}
        message_id = dispatch.correlation_id or dispatch.message_id

        if channel == "voice":
            body = {"messages": [{
                "from": sender_id,
                "destinations": [{"to": dispatch.destination, "messageId": message_id}],
                "text": dispatch.message,
                "language": dispatch.locale or "en",
                "voice": {"name": "Joanna", "gender": "female"},
            }]}
            return {"url": f"{endpoint}/tts/3/advanced", "method": "POST", "headers": headers, "body": json.dumps(body)}

        body = {"messages": [{
            "sender": sender_id,
            "destinations": [{"to": dispatch.destination, "messageId": message_id}],
            "content": {"text": dispatch.message},
        }]}
        return {"url": f"{endpoint}/sms/3/messages", "method": "POST", "headers": headers, "body": json.dumps(body)}

    def parse_response(self, http_status, ok, json_body):
        messages = json_body.get("messages") if isinstance(json_body, dict) else None
        first_message = messages[0] if messages else {}
        status = first_message.get("status") or {}
        status_name = (status.get("groupName") or status.get("name") or "").upper() or None
        return {
            "success": ok,
            "provider_http_status": http_status,
            "provider_message_id": first_message.get("messageId"),
            "provider_status_name": status_name,
            "provider_status_code": None,
            "provider_status_description": status.get("description"),
        }
