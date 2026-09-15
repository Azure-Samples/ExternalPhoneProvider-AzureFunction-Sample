import json
import logging
import time
from contextvars import ContextVar
from threading import Lock

from azure.identity import ManagedIdentityCredential, ClientAssertionCredential

from ..models import ParsedResponse, TextToVoice

_token_request = ContextVar("soprano_token_request", default=False)


class _TokenLogFilter(logging.Filter):
    def filter(self, record):
        return not (_token_request.get() and record.name.startswith(("azure.identity", "azure.core", "msal")))


_token_log_filter = _TokenLogFilter()


def _jwt_enabled(env):
    flag = env.get("EPP_PROVIDER_JWT_ENABLED")
    return isinstance(flag, str) and flag.strip().lower() == "true"


class SopranoProvider:
    manifest = {
        "id": "soprano",
        "requires_text_to_voice": True,
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

    def __init__(self):
        self._credential = None
        self._credential_settings = None
        self._credential_lock = Lock()

    def acquire_token(self, env):
        if not _jwt_enabled(env):
            return ""
        scope = env.get("EPP_PROVIDER_SCOPE")
        settings = tuple(env.get(name) for name in ("EPP_PROVIDER_TENANT_ID", "EPP_PROVIDER_APPLICATION_ID", "EPP_PROVIDER_MI_CLIENT_ID"))
        if not all(isinstance(value, str) and value.strip() for value in (scope, *settings)):
            return ""
        settings = tuple(value.strip() for value in settings)
        loggers = (logging.getLogger(), *logging.Logger.manager.loggerDict.copy().values())
        for logger in loggers:
            if isinstance(logger, logging.Logger):
                for handler in logger.handlers:
                    if _token_log_filter not in handler.filters:
                        handler.addFilter(_token_log_filter)
        context_token = _token_request.set(True)
        try:
            with self._credential_lock:
                if self._credential is None or self._credential_settings != settings:
                    tenant, application_id, identity = settings
                    managed_identity = ManagedIdentityCredential(client_id=identity, retry_total=0,
                        connection_timeout=2.5, read_timeout=2.5, logging_enable=False)
                    def get_assertion():
                        assertion = managed_identity.get_token("api://AzureADTokenExchange/.default", logging_enable=False)
                        if assertion.expires_on <= time.time() + 30 or not isinstance(assertion.token, str) or not assertion.token.strip():
                            raise ValueError("managed identity assertion unavailable")
                        return assertion.token
                    self._credential = ClientAssertionCredential(tenant, application_id, get_assertion,
                        authority="https://login.microsoftonline.com", retry_total=0,
                        connection_timeout=2.5, read_timeout=2.5, logging_enable=False)
                    self._credential_settings = settings
                credential = self._credential
            result = credential.get_token(scope.strip(), logging_enable=False)
            return result.token if result.expires_on > time.time() + 30 and isinstance(result.token, str) and result.token.strip() else ""
        except Exception:
            return ""
        finally:
            _token_request.reset(context_token)

    def build_request(self, channel, endpoint, dispatch, credential, env):
        message_type = "voice" if channel == "voice" else "sms"
        headers = {
            "X-MEMS-API-ID": credential.get("identity") or "",
            "X-MEMS-API-Key": credential.get("secret") or "",
            "Content-Type": "application/json",
            "Accept": "application/json",
        }
        token = credential.get("token")
        if _jwt_enabled(env) and isinstance(token, str) and token.strip():
            headers["Authorization"] = "Bearer " + token
        body = {
            "destination": str(dispatch.destination).lstrip("+"),
            "messageTypes": [message_type],
            "correlationId": dispatch.correlation_id or dispatch.message_id,
            "shutterMode": False,
        }
        if channel == "voice":
            voice = dispatch.text_to_voice
            if not isinstance(voice, TextToVoice) or not voice.is_complete:
                raise ValueError("incomplete voice context")
            body["voice"] = {"text2voice": {
                "beforePasswordText": voice.before_password_text,
                "password": voice.password,
                "language": voice.language,
            }}
        else:
            body["text"] = dispatch.message
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
