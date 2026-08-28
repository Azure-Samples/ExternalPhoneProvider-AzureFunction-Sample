"""Sinch: SMS via XMS Batches (POST /xms/v1/{plan}/batches, Bearer).
Voice via the Calling TTS callout API."""
import json


class SinchProvider:
    manifest = {
        "id": "sinch",
        "auth": {"mode": "apiKey", "key_vault_secret_name": "sinch-api-token"},
        "response_mapping": {
            "Dispatched": "Continue", "Delivered": "Continue", "Queued": "Continue",
            "Failed": "Fail", "Rejected": "Fail", "default": "Fail",
        },
    }

    def build_request(self, channel, endpoint, dispatch, credential, env):
        bearer = credential["token"] if credential["mode"] == "oauth2" else credential["secret"]
        headers = {"Authorization": f"Bearer {bearer}", "Content-Type": "application/json", "Accept": "application/json"}
        reference = dispatch.correlation_id or dispatch.message_id

        if channel == "voice":
            voice_base = env.get("SINCH_VOICE_ENDPOINT") or "https://calling.api.sinch.com"
            body = {"method": "ttsCallout", "ttsCallout": {
                "destination": {"type": "number", "endpoint": dispatch.destination},
                "text": dispatch.message,
                "locale": dispatch.locale or "en-US",
                "custom": reference,
            }}
            return {"url": f"{voice_base}/calling/v1/callouts", "method": "POST", "headers": headers, "body": json.dumps(body)}

        service_plan_id = env.get("SINCH_SERVICE_PLAN_ID") or ""
        body = {
            "from": env.get("EPP_PROVIDER_ACCOUNT_NAME") or "Verify",
            "to": [dispatch.destination],
            "body": dispatch.message,
            "client_reference": reference,
        }
        return {"url": f"{endpoint}/xms/v1/{service_plan_id}/batches", "method": "POST", "headers": headers, "body": json.dumps(body)}

    def parse_response(self, http_status, ok, json_body):
        identifier = None
        if isinstance(json_body, dict):
            identifier = json_body.get("id") or json_body.get("callId")
        return {
            "success": ok,
            "provider_http_status": http_status,
            "provider_message_id": str(identifier) if identifier is not None else None,
            "provider_status_name": "Dispatched" if ok else None,
            "provider_status_code": None,
            "provider_status_description": json_body.get("text") if isinstance(json_body, dict) else None,
        }
