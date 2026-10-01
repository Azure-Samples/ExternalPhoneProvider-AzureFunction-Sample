import base64
import json
import re

from ..models import Outcome, ProviderResult
from ..provider import OutboundRequest, PhoneProviderBase, classify_failure

VOICE_PASSCODE_PATTERN = re.compile(r"(?<![0-9])[0-9]{6}(?![0-9])")
VOICE_DIGIT_SEPARATOR = ", "
VOICE_REPEAT_COUNT = 2
VOICE_REPEAT_SEPARATOR = " "


def _build_voice_message(message):
    paced_message = VOICE_PASSCODE_PATTERN.sub(
        lambda match: VOICE_DIGIT_SEPARATOR.join(match.group(0)),
        message,
    )
    return VOICE_REPEAT_SEPARATOR.join([paced_message] * VOICE_REPEAT_COUNT)


class TelesignProvider(PhoneProviderBase):
    name = "telesign"
    authentication_mode = "apiKey"

    @property
    def credential_spec(self):
        return {
            "mode": self.authentication_mode,
            "key_vault_secret_name": "telesign-api-key",
            "identity_key_vault_secret_name": "telesign-customer-id",
        }

    def build_request(self, channel, endpoint, delivery, credential, env):
        if channel not in ("sms", "voice"):
            raise ValueError("unsupported channel")
        if not isinstance(delivery.phone_number, str) or not re.fullmatch(
            r"\+[1-9][0-9]{1,14}", delivery.phone_number
        ):
            raise ValueError("invalid recipient")
        raw = f"{credential['identity']}:{credential['secret']}".encode()
        authorization = "Basic " + base64.b64encode(raw).decode()
        correlation_id = delivery.correlation_id
        if not isinstance(correlation_id, str) or not correlation_id:
            correlation_id = delivery.message_id
        message = {
            "text": _build_voice_message(delivery.message) if channel == "voice" else delivery.message
        }
        if isinstance(delivery.locale, str) and delivery.locale.strip():
            message["language"] = delivery.locale
        body = {
            "recipient": {"phone_number": delivery.phone_number},
            "message": message,
            "channels": [{"channel": channel}],
            "correlation_id": correlation_id,
        }
        headers = {
            "Authorization": authorization,
            "Content-Type": "application/json",
            "Accept": "application/json",
        }
        return OutboundRequest("POST", endpoint, headers, json.dumps(body))

    def map_response(self, body, http_status):
        payload = body if isinstance(body, dict) else {}
        status = payload.get("status")
        status = status if isinstance(status, dict) else {}
        code = status.get("code")
        status_code = str(code) if type(code) is int else "UNKNOWN"
        recognized = status_code in {
            "200", "203", "290", "291", "292", "100", "101", "102", "103", "3001"
        }
        outcome = Outcome.CONTINUE if recognized else Outcome.FAIL
        final_outcome = outcome if 200 <= http_status < 300 else Outcome.FAIL
        reference_id = payload.get("reference_id")
        description = status.get("description")
        return ProviderResult(
            final_outcome,
            recognized,
            http_status,
            reference_id if isinstance(reference_id, str) else None,
            provider_status_code=status_code,
            provider_status_description=description if isinstance(description, str) else None,
            failure_reason=classify_failure(http_status, final_outcome, recognized),
        )
