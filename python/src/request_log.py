import json
import logging
import re
import time
from urllib.parse import urlsplit, urlunsplit

_CONTEXT_FIELDS = (
    "functionName", "functionRequestId", "functionInvocationId",
    "x-ms-client-request-id", "x-ms-correlation-id", "msCorrelationIdSource", "omittedIdFields",
    "channel", "evaluation", "providerName",
)
_CREDENTIAL_FIELDS = (
    "providerAuthMode", "providerCredentialSource", "providerTenantId",
    "functionOutboundClientId", "functionOutboundManagedIdentityClientId",
)
_HTTP_METHODS = {"GET", "HEAD", "POST", "PUT", "DELETE", "CONNECT", "OPTIONS", "TRACE", "PATCH"}


_IDENTIFIER_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,127}")


class RequestLog:
    """Request-scoped, explicitly selected metadata; never serialize delivery/provider models."""

    def __init__(self, request_id, invocation_id, ms_request_id, ms_correlation_id, function_name="send_otp"):
        self.started = time.monotonic()
        self.provider_started = None
        self.credential_started = None
        self.data = {
            "functionName": function_name,
            "functionRequestId": request_id,
            "functionInvocationId": invocation_id or None,
            "x-ms-client-request-id": None,
            "x-ms-correlation-id": None,
            "msCorrelationIdSource": "none",
            "omittedIdFields": [],
            "envelopeType": None,
            "ttlSeconds": None,
            "channel": None,
            "evaluation": None,
            "encryptionKeyIdMismatch": False,
            "providerName": None,
            "providerAuthMode": None,
            "providerCredentialSource": None,
            "providerCredentialElapsedMs": None,
            "providerTenantId": None,
            "functionOutboundClientId": None,
            "functionOutboundManagedIdentityClientId": None,
            "providerHttpMethod": None,
            "providerEndpoint": None,
            "providerAttempted": False,
            "providerHttpStatus": None,
            "providerStatus": None,
            "providerOutcome": None,
            "providerMessageId": None,
            "providerElapsedMs": None,
            "providerTimeoutMs": None,
            "failureStage": None,
            "failureReason": None,
            "responseContainsNonce": None,
            "responseContainsCorrelationId": None,
        }
        self._set_identifier("x-ms-client-request-id", ms_request_id)
        self._set_identifier("x-ms-correlation-id", ms_correlation_id)
        self.data["msCorrelationIdSource"] = "header" if self.data["x-ms-correlation-id"] else "none"

    def _set_identifier(self, field, value):
        valid = isinstance(value, str) and len(value) <= 128 and _IDENTIFIER_PATTERN.fullmatch(value) is not None
        self.data[field] = value if valid else None
        self.data["omittedIdFields"] = [name for name in self.data["omittedIdFields"] if name != field]
        if not valid and value is not None and not (isinstance(value, str) and not value.strip()):
            self.data["omittedIdFields"].append(field)

    def service(self, event_name, details=None, level=logging.INFO):
        record = {
            "logType": "service", "eventName": event_name,
            **{key: self.data[key] for key in _CONTEXT_FIELDS},
            **(details or {}),
            "elapsedMs": int((time.monotonic() - self.started) * 1000),
        }
        logging.log(level, "%s", json.dumps(record))

    def envelope_validated(self, envelope, correlation_id, source):
        self.data["envelopeType"] = envelope.type
        self.data["ttlSeconds"] = envelope.ttl_seconds
        self.data["channel"] = "sms" if envelope.channel == 1 else "voice"
        self.data["evaluation"] = envelope.mode == 2
        self._set_identifier("x-ms-correlation-id", correlation_id)
        self.data["msCorrelationIdSource"] = source if self.data["x-ms-correlation-id"] else "none"
        self.service("envelope_validated", {
            "envelopeType": self.data["envelopeType"],
            "ttlSeconds": self.data["ttlSeconds"],
            "encryptedDeliveryContextPresent": True,
        })

    def key_id_mismatch(self):
        self.data["encryptionKeyIdMismatch"] = True
        self.service("encryption_key_id_mismatch", level=logging.WARNING)

    def provider_selected(self, manifest):
        self.data["providerName"] = manifest["id"]
        mode = manifest["auth"].get("mode")
        self.data["providerAuthMode"] = mode if mode in ("apiKey", "oauth") else "unsupported"
        self.service("provider_selected", {"providerAuthMode": self.data["providerAuthMode"]})

    def credential_resolution_started(self, config):
        self.credential_started = time.monotonic()
        oauth = self.data["providerAuthMode"] == "oauth"
        self.data["providerCredentialSource"] = ("managed_identity_client_assertion" if oauth
            else "key_vault" if self.data["providerAuthMode"] == "apiKey" else "unsupported")
        if oauth:
            self._set_identifier("providerTenantId", config.provider_tenant_id)
            self._set_identifier("functionOutboundClientId", config.outbound_client_id)
            self._set_identifier("functionOutboundManagedIdentityClientId", config.outbound_managed_identity_client_id)
        self.service("provider_credential_resolution_started", self._credential_details())

    def _credential_details(self):
        return {key: self.data[key] for key in _CREDENTIAL_FIELDS}

    def _credential_resolution_finished(self):
        if self.credential_started is not None:
            self.data["providerCredentialElapsedMs"] = int((time.monotonic() - self.credential_started) * 1000)
            self.credential_started = None

    def credential_resolved(self):
        self._credential_resolution_finished()
        self.service("provider_credential_resolved", {
            **self._credential_details(),
            "providerCredentialElapsedMs": self.data["providerCredentialElapsedMs"],
        })

    def provider_request_built(self, method, endpoint):
        normalized = method.upper() if isinstance(method, str) else None
        self.data["providerHttpMethod"] = normalized if normalized in _HTTP_METHODS else "other"
        url = urlsplit(endpoint)
        host = f"[{url.hostname}]" if ":" in url.hostname else url.hostname
        authority = host if url.port in (None, 443) else f"{host}:{url.port}"
        self.data["providerEndpoint"] = urlunsplit((url.scheme, authority, url.path or "/", "", ""))
        self.service("provider_request_built", {
            "providerHttpMethod": self.data["providerHttpMethod"],
            "providerEndpoint": self.data["providerEndpoint"],
            "providerScheme": "https",
            "redirectsAllowed": False,
        })

    def provider_request_started(self, timeout_ms):
        self.provider_started = time.monotonic()
        self.data["providerAttempted"] = True
        self.data["providerTimeoutMs"] = timeout_ms
        self.service("provider_request_started", {
            "providerTimeoutMs": timeout_ms,
            "providerHttpMethod": self.data["providerHttpMethod"],
            "providerEndpoint": self.data["providerEndpoint"],
        })

    def provider_response_received(self, status):
        self.data["providerHttpStatus"] = status
        self.service("provider_response_received", {"providerHttpStatus": status})

    def provider_request_finished(self):
        if self.provider_started is not None:
            self.data["providerElapsedMs"] = int((time.monotonic() - self.provider_started) * 1000)
            self.provider_started = None

    def provider_response_processed(self, manifest, parsed, outcome, http_status, valid_json):
        status = parsed.provider_status_name or parsed.provider_status_code
        known = type(status) in (str, int) and status != "default" and status in manifest["response_mapping"]
        self.data["providerStatus"] = str(status) if known else "unmapped"
        self.data["providerOutcome"] = outcome
        self._set_identifier("providerMessageId", parsed.provider_message_id)
        if outcome != "Continue":
            self.data["failureStage"] = "provider_response"
            self.data["failureReason"] = "provider_rejected" if valid_json else "invalid_provider_json"
        self.service("provider_response_processed", {
            "providerHttpStatus": self.data["providerHttpStatus"],
            "providerStatus": self.data["providerStatus"],
            "providerOutcome": outcome,
            "providerMessageId": self.data["providerMessageId"],
            "providerElapsedMs": self.data["providerElapsedMs"],
            "httpStatus": http_status,
            "failureReason": self.data["failureReason"],
        }, logging.ERROR if http_status >= 500 else logging.INFO if http_status == 200 else logging.WARNING)

    def failure(self, stage, reason, http_status):
        self._credential_resolution_finished()
        self.provider_request_finished()
        self.data["failureStage"] = stage
        self.data["failureReason"] = reason
        self.service(f"{stage}_failed", {"failureReason": reason, "httpStatus": http_status},
                     logging.ERROR if http_status >= 500 else logging.WARNING)

    def response_prepared(self, http_status, contains_nonce, contains_correlation_id):
        self.data["responseContainsNonce"] = contains_nonce
        self.data["responseContainsCorrelationId"] = contains_correlation_id
        self.service("response_prepared", {
            "httpStatus": http_status,
            "responseContainsNonce": contains_nonce,
            "responseContainsCorrelationId": contains_correlation_id,
        })

    def complete(self, http_status):
        self._credential_resolution_finished()
        self.provider_request_finished()
        logging.info("%s", json.dumps({
            "logType": "request", "eventName": "request_completed",
            **self.data,
            "httpStatus": http_status,
            "result": ("evaluated" if self.data["evaluation"] else "accepted") if http_status == 200 else "failed",
            "elapsedMs": int((time.monotonic() - self.started) * 1000),
        }))
