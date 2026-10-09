import atexit
import json
import logging
import os
import time
import uuid
from threading import Thread

import azure.functions as func

from src import otp_log
from src.config import read_config
from src.credentials import CredentialTokenService, report_refresh_failure, is_cache_enabled
from src.jwe import JweDecryptor
from src.models import EntraSendOtpPayload, OtpDelivery
from src.provider import (
    ProviderSendError,
    is_https_endpoint,
    provider_timeout_ms,
    to_endpoint_http_status,
)
from src.providers.infobip import InfobipProvider
from src.providers.sinch import SinchProvider
from src.providers.soprano import SopranoProvider
from src.providers.telesign import TelesignProvider
from src.secrets import SecretResolver

app = func.FunctionApp()

_providers = {
    provider.name: provider
    for provider in (InfobipProvider(), TelesignProvider(), SopranoProvider(), SinchProvider())
}
_credentials = CredentialTokenService(SecretResolver())
_decryptor = JweDecryptor(os.environ)
_logger = logging.getLogger("epp.send_otp")


class InvalidRequest(Exception):
    def __init__(self, status_code, error, reason=None, correlation_id=None):
        super().__init__(error)
        self.status_code = status_code
        self.error = error
        self.reason = reason
        self.correlation_id = correlation_id


def _select_provider(name):
    return _providers.get(name.lower()) if isinstance(name, str) and name else None


def _failure(log, status, stage, reason):
    otp_log.request_failed(
        log,
        logging.ERROR if status >= 500 else logging.WARNING,
        stage,
        reason,
        status,
    )
    return status


def _send_to_provider(delivery, log):
    config = read_config()
    provider = _select_provider(config.provider_name)
    if provider is None:
        return _failure(log, 400, "provider_selection", "unknown_provider"), log

    log = log.with_context({"providerName": provider.name})
    otp_log.provider_selected(log, provider.name, provider.authentication_mode)
    channel = (delivery.channel or "sms").lower()
    if channel not in ("sms", "voice"):
        return _failure(log, 400, "provider_configuration", "unsupported_channel"), log
    if config.provider_channel and config.provider_channel != channel:
        return _failure(log, 400, "provider_configuration", "channel_not_configured"), log
    if config.provider_auth_mode and config.provider_auth_mode != provider.authentication_mode:
        return _failure(log, 502, "provider_configuration", "authentication_mode_mismatch"), log

    credential_source = (
        "managed_identity_client_assertion"
        if provider.authentication_mode == "oauth"
        else "key_vault"
    )
    credential_started = time.monotonic()
    try:
        otp_log.credential_resolution_started(log, provider.name, credential_source)
        credential = _credentials.get_credentials(provider, config)
    except Exception:
        return _failure(log, 502, "provider_credentials", "credential_unavailable"), log
    otp_log.credential_resolved(
        log, provider.name, int((time.monotonic() - credential_started) * 1000))

    if not is_https_endpoint(config.provider_endpoint):
        return _failure(log, 502, "provider_configuration", "invalid_provider_endpoint"), log

    try:
        result = provider.send_otp(
            channel,
            config.provider_endpoint,
            delivery,
            credential,
            config.env,
            provider_timeout_ms(config.provider_timeout_ms),
            log,
        )
    except ProviderSendError as error:
        return error.status_code, log
    status = to_endpoint_http_status(result)
    if status >= 400:
        _failure(
            log,
            status,
            "provider_response",
            result.failure_reason or "provider_rejected",
        )
    return status, log


# Azure Easy Auth must enforce authentication; local handler calls are anonymous.
@app.route(route="SendOtp", methods=["POST"], auth_level=func.AuthLevel.ANONYMOUS)
def send_otp(req: func.HttpRequest, context: func.Context = None) -> func.HttpResponse:
    started = time.monotonic()
    request_id = uuid.uuid4().hex
    ms_request_id = otp_log.safe_identifier(req.headers.get("x-ms-client-request-id"))
    header_correlation_id = otp_log.safe_identifier(req.headers.get("x-ms-correlation-id"))
    log = otp_log.RequestLogger(_logger, {
        "functionName": context.function_name if context else "send_otp",
        "functionRequestId": request_id,
        "functionInvocationId": context.invocation_id if context else None,
        "x-ms-client-request-id": ms_request_id,
        "x-ms-correlation-id": header_correlation_id,
        "msCorrelationIdSource": "header" if header_correlation_id else "none",
        "channel": None,
        "evaluation": None,
        "providerName": None,
    })
    status_code = 500
    body = None
    payload = None

    try:
        otp_log.request_received(log)
        try:
            raw_payload = req.get_json()
        except ValueError:
            _failure(log, 400, "request_validation", "invalid JSON body")
            raise InvalidRequest(400, "bad_request", "invalid JSON body")

        payload, payload_error = EntraSendOtpPayload.from_payload(raw_payload)
        if payload_error:
            _failure(log, 400, "request_validation", payload_error)
            raise InvalidRequest(400, "bad_request", payload_error)

        payload_correlation_id = otp_log.safe_identifier(payload.correlation_id)
        correlation_id = payload.correlation_id or header_correlation_id or request_id
        log = log.with_context({
            "x-ms-correlation-id": payload_correlation_id or header_correlation_id,
            "msCorrelationIdSource": (
                "envelope" if payload_correlation_id
                else "header" if header_correlation_id
                else "none"
            ),
            "channel": payload.channel_name,
            "evaluation": payload.is_evaluation,
        })
        otp_log.payload_validated(
            log, payload.type, payload.channel_name, payload.is_evaluation, payload.ttl_seconds)

        config = read_config()
        try:
            decrypted = _decryptor.decrypt(payload.encrypted_delivery_context)
        except Exception:
            _failure(log, 400, "decryption", "decryption_failed")
            raise InvalidRequest(400, "decryption_failed", correlation_id=correlation_id)
        otp_log.delivery_context_decrypted(log)

        if config.expected_key_id and config.expected_key_id != decrypted.key_id:
            otp_log.encryption_key_id_mismatch(log)
        delivery_context = decrypted.value
        if delivery_context is None or not delivery_context.is_complete:
            _failure(log, 400, "delivery_context_validation", "incomplete delivery context")
            raise InvalidRequest(
                400, "bad_request", "incomplete delivery context", correlation_id)

        if payload.is_evaluation:
            otp_log.evaluation_completed(log)
        else:
            delivery = OtpDelivery(
                delivery_context.phone_number,
                delivery_context.message,
                payload.channel_name,
                ms_request_id or request_id,
                correlation_id,
                delivery_context.locale,
            )
            provider_status, log = _send_to_provider(delivery, log)
            if provider_status >= 400:
                raise InvalidRequest(
                    provider_status, "provider_delivery_failed", correlation_id=correlation_id)

        status_code = 200
        body = {
            "nonce": delivery_context.nonce,
            "correlationId": correlation_id,
            "providerStatus": "accepted",
        }
    except InvalidRequest as error:
        status_code = error.status_code
        body = {"error": error.error, "requestId": request_id}
        if error.reason is not None:
            body["reason"] = error.reason
        if error.correlation_id is not None:
            body["correlationId"] = error.correlation_id
    except Exception:
        otp_log.unexpected_error(log)
        status_code = 500
        body = {
            "error": "delivery_failed",
            "correlationId": (
                payload.correlation_id if payload is not None
                else header_correlation_id or request_id
            ),
            "requestId": request_id,
        }

    otp_log.response_prepared(
        log, status_code, "nonce" in body, "correlationId" in body)
    otp_log.request_completed(
        log,
        status_code,
        "evaluated" if status_code == 200 and payload and payload.is_evaluation
        else "accepted" if status_code == 200
        else "failed",
        int((time.monotonic() - started) * 1000),
    )
    return func.HttpResponse(json.dumps(body), status_code=status_code, mimetype="application/json")


def _warm_selected_credentials():
    config = read_config()
    if not config.provider_name:
        return
    provider = _select_provider(config.provider_name)
    if provider is None or (
        config.provider_auth_mode
        and config.provider_auth_mode != provider.authentication_mode
    ):
        report_refresh_failure("configuration")
        return
    try:
        if not is_cache_enabled(provider.credential_spec, config):
            return
        _credentials.get_credentials(provider, config)
    except Exception:
        report_refresh_failure("initialization")


atexit.register(_credentials.close)
if os.environ.get("EPP_PROVIDER_NAME", "").strip():
    Thread(target=_warm_selected_credentials, daemon=True).start()
