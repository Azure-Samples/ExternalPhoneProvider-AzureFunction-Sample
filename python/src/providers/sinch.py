import json

from ..models import Outcome, ProviderResult
from ..provider import OutboundRequest, PhoneProviderBase, classify_failure


class SinchProvider(PhoneProviderBase):
    name = "sinch"
    authentication_mode = "apiKey"

    @property
    def credential_spec(self):
        return {"mode": self.authentication_mode, "key_vault_secret_name": "sinch-api-token"}

    def build_request(self, channel, endpoint, delivery, credential, env):
        headers = {
            "Authorization": f"Bearer {credential['secret']}",
            "Content-Type": "application/json",
            "Accept": "application/json",
        }
        reference = delivery.correlation_id or delivery.message_id

        if channel == "voice":
            voice_base = env.get("SINCH_VOICE_ENDPOINT") or "https://calling.api.sinch.com"
            body = {"method": "ttsCallout", "ttsCallout": {
                "destination": {"type": "number", "endpoint": delivery.phone_number},
                "text": delivery.message,
                "locale": delivery.locale or "en-US",
                "custom": reference,
            }}
            return OutboundRequest("POST", f"{voice_base}/calling/v1/callouts", headers, json.dumps(body))

        service_plan_id = env.get("SINCH_SERVICE_PLAN_ID") or ""
        body = {
            "from": env.get("EPP_PROVIDER_ACCOUNT_NAME") or "Verify",
            "to": [delivery.phone_number],
            "body": delivery.message,
            "client_reference": reference,
        }
        return OutboundRequest("POST", f"{endpoint}/xms/v1/{service_plan_id}/batches", headers, json.dumps(body))

    def map_response(self, payload, http_status):
        identifier = payload.get("id") or payload.get("callId") if isinstance(payload, dict) else None
        status = payload.get("status") if isinstance(payload, dict) else None
        description = payload.get("text") if isinstance(payload, dict) else None
        successful = 200 <= http_status < 300
        if status is None and successful and isinstance(identifier, str) and identifier.strip():
            status = "Dispatched"
        recognized = status in {"Dispatched", "Delivered", "Queued", "Failed", "Rejected"}
        outcome = Outcome.CONTINUE if status in {"Dispatched", "Delivered", "Queued"} else Outcome.FAIL
        has_message_id = isinstance(identifier, str) and bool(identifier.strip())
        final_outcome = outcome if successful and has_message_id else Outcome.FAIL
        failure_reason = (
            "missing_provider_message_id"
            if successful and not has_message_id
            else classify_failure(http_status, final_outcome, recognized)
        )
        return ProviderResult(
            final_outcome,
            recognized,
            http_status,
            identifier if isinstance(identifier, str) else None,
            status if isinstance(status, str) else None,
            provider_status_description=description if isinstance(description, str) else None,
            failure_reason=failure_reason,
        )
