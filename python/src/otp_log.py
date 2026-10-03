from __future__ import annotations

import logging
import re
from collections.abc import Mapping

_IDENTIFIER_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,127}")


def safe_identifier(value: object) -> str | None:
    return value if isinstance(value, str) and _IDENTIFIER_PATTERN.fullmatch(value) else None


class RequestLogger(logging.LoggerAdapter):
    def process(self, msg, kwargs):
        extra = dict(self.extra)
        extra.update(kwargs.pop("extra", {}))
        kwargs["extra"] = extra
        return msg, kwargs

    def with_context(self, values: Mapping[str, object]) -> "RequestLogger":
        return RequestLogger(self.logger, {**self.extra, **values})


def _emit(log: logging.LoggerAdapter, event_id: int, event_name: str, message: str,
          *, level: int = logging.INFO, **fields: object) -> None:
    log.log(level, message, extra={"event_id": event_id, "event_name": event_name, **fields})


def request_received(log): _emit(log, 1000, "request_received", "OTP request received")


def payload_validated(log, payload_type, channel, evaluation, ttl_seconds):
    _emit(log, 1001, "payload_validated", "OTP payload validated",
          payloadType=payload_type, channel=channel, evaluation=evaluation, ttlSeconds=ttl_seconds)


def delivery_context_decrypted(log):
    _emit(log, 1002, "delivery_context_decrypted", "Delivery context decrypted")


def encryption_key_id_mismatch(log):
    _emit(log, 1003, "encryption_key_id_mismatch",
          "Encrypted payload key identifier did not match the configured identifier",
          level=logging.WARNING)


def evaluation_completed(log): _emit(log, 1004, "evaluation_completed", "Evaluation request completed")


def provider_selected(log, provider_name, authentication_mode):
    _emit(log, 1100, "provider_selected", "Provider selected",
          providerName=provider_name, authenticationMode=authentication_mode)


def credential_resolution_started(log, provider_name, credential_source):
    _emit(log, 1101, "provider_credential_resolution_started", "Resolving provider credentials",
          providerName=provider_name, credentialSource=credential_source)


def credential_resolved(log, provider_name, elapsed_ms):
    _emit(log, 1102, "provider_credential_resolved", "Provider credentials resolved",
          providerName=provider_name, elapsedMs=elapsed_ms)


def provider_request_build_started(log):
    _emit(log, 1200, "provider_request_build_started", "Building provider request")


def provider_request_built(log, http_method, provider_endpoint):
    _emit(log, 1201, "provider_request_built", "Provider request built",
          httpMethod=http_method, providerEndpoint=provider_endpoint, redirectsAllowed=False)


def provider_request_started(log, timeout_ms):
    _emit(log, 1202, "provider_request_started", "Sending provider request", timeoutMs=timeout_ms)


def provider_response_received(log, provider_http_status):
    _emit(log, 1203, "provider_response_received", "Provider response received",
          providerHttpStatus=provider_http_status)


def provider_response_invalid_json(log):
    _emit(log, 1204, "provider_response_invalid_json", "Provider response was not valid JSON",
          level=logging.WARNING)


def provider_response_processed(log, level, provider_http_status, provider_status,
                                provider_outcome, failure_reason, elapsed_ms):
    _emit(log, 1205, "provider_response_processed", "Provider response processed", level=level,
          providerHttpStatus=provider_http_status, providerStatus=provider_status,
          providerOutcome=provider_outcome, failureReason=failure_reason, elapsedMs=elapsed_ms)


def request_failed(log, level, failure_stage, failure_reason, http_status):
    _emit(log, 1300, "request_failed", "OTP request failed", level=level,
          failureStage=failure_stage, failureReason=failure_reason, httpStatus=http_status)


def unexpected_error(log):
    _emit(log, 1301, "unexpected_error", "Unexpected OTP request failure", level=logging.ERROR)


def response_prepared(log, http_status, contains_nonce, contains_correlation_id):
    _emit(log, 1400, "response_prepared", "OTP response prepared",
          httpStatus=http_status, containsNonce=contains_nonce,
          containsCorrelationId=contains_correlation_id)


def request_completed(log, http_status, result, elapsed_ms):
    _emit(log, 1401, "request_completed", "OTP request completed",
          httpStatus=http_status, result=result, elapsedMs=elapsed_ms)


def credential_refresh_failed(log, cache_kind):
    _emit(log, 1500, "credential_refresh_failed", "Credential refresh failed",
          level=logging.WARNING, cacheKind=cache_kind, failureReason="credential_unavailable")
