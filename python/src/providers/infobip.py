import json

from ..models import Outcome, ProviderResult
from ..provider import OutboundRequest, PhoneProviderBase, classify_failure


class InfobipProvider(PhoneProviderBase):
    name = "infobip"
    authentication_mode = "apiKey"

    @property
    def credential_spec(self):
        return {"mode": self.authentication_mode, "key_vault_secret_name": "infobip-api-key"}

    def build_request(self, channel, endpoint, delivery, credential, env):
        sender_id = env.get("EPP_PROVIDER_ACCOUNT_NAME") or "Verify"
        authorization = f"App {credential['secret']}"
        headers = {"Authorization": authorization, "Content-Type": "application/json", "Accept": "application/json"}
        message_id = delivery.correlation_id or delivery.message_id

        if channel == "voice":
            body = {"messages": [{
                "from": sender_id,
                "destinations": [{"to": delivery.phone_number, "messageId": message_id}],
                "text": delivery.message,
                "language": delivery.locale or "en",
                "voice": {"name": "Joanna", "gender": "female"},
            }]}
            return OutboundRequest("POST", f"{endpoint}/tts/3/advanced", headers, json.dumps(body))

        body = {"messages": [{
            "sender": sender_id,
            "destinations": [{"to": delivery.phone_number, "messageId": message_id}],
            "content": {"text": delivery.message},
        }]}
        return OutboundRequest("POST", f"{endpoint}/sms/3/messages", headers, json.dumps(body))

    def map_response(self, payload, http_status):
        messages = payload.get("messages") if isinstance(payload, dict) else None
        first_message = messages[0] if messages else {}
        status = first_message.get("status") or {}
        status_name = (status.get("groupName") or status.get("name") or "").upper() or None
        recognized = status_name in {"ACCEPTED", "PENDING", "DELIVERED", "REJECTED", "EXPIRED", "UNDELIVERABLE"}
        outcome = Outcome.CONTINUE if status_name in {"ACCEPTED", "PENDING", "DELIVERED"} else Outcome.FAIL
        final_outcome = outcome if 200 <= http_status < 300 else Outcome.FAIL
        return ProviderResult(
            outcome=final_outcome,
            status_recognized=recognized,
            provider_http_status=http_status,
            provider_message_id=first_message.get("messageId"),
            provider_status_name=status_name,
            provider_status_description=status.get("description"),
            failure_reason=classify_failure(http_status, final_outcome, recognized),
        )
