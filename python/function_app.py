"""POST /api/SendOtp: validate, decrypt, dispatch, and echo the nonce with a PII-safe summary."""
import base64
import json
import logging
import os
import time
import uuid

import azure.functions as func

from src.dispatch import (
    CHANNEL_BY_CODE,
    CONTINUE,
    FAIL,
    MODE_EVALUATION,
    OUTCOMES,
    PROVIDER_IDS,
    DispatchEngine,
    ProviderRegistry,
    context_to_dispatch,
    decrypt_delivery_context,
    make_key_provider,
    parse_envelope,
    safe_trace_id,
)
from src.providers.infobip import InfobipProvider
from src.providers.sinch import SinchProvider
from src.providers.soprano import SopranoProvider
from src.providers.telesign import TelesignProvider
from src.secrets import SecretResolver
from src.security import validate_token

TAG = "[EPP]"

app = func.FunctionApp()

_registry = ProviderRegistry([InfobipProvider(), TelesignProvider(), SopranoProvider(), SinchProvider()])
_secrets = SecretResolver()
_engine = DispatchEngine(_registry, _secrets)
_key_provider = make_key_provider(os.environ)


def _read_caller_app_id(req):
    """Easy Auth has already validated the token; check its caller against the allowlist."""
    encoded = req.headers.get("x-ms-client-principal")
    if not encoded:
        return None
    try:
        principal = json.loads(base64.b64decode(encoded).decode("utf-8"))
        for claim in principal.get("claims") or []:
            if claim.get("typ") in ("appid", "azp"):
                return claim.get("val")
    except Exception:
        return None
    return None


@app.route(route="SendOtp", methods=["POST"], auth_level=func.AuthLevel.ANONYMOUS)
def send_otp(req: func.HttpRequest) -> func.HttpResponse:
    started = time.perf_counter()
    request_id = str(uuid.uuid4())
    correlation_id = request_id
    provider = channel = mode = "unknown"
    status, outcome = 500, FAIL
    nonce_echo = shutter_processed = False

    def reply(code, body):
        nonlocal status, nonce_echo
        response = func.HttpResponse(json.dumps(body), status_code=code, mimetype="application/json")
        status, nonce_echo = code, code == 200 and "nonce" in body
        return response

    try:
        client_request_id = req.headers.get("x-ms-client-request-id") or request_id
        header_correlation_id = req.headers.get("x-ms-correlation-id")
        correlation_id = header_correlation_id or request_id
        configured_provider = (os.environ.get("EPP_PROVIDER_NAME") or "").lower()
        provider = configured_provider if configured_provider in PROVIDER_IDS else "unknown"
        expected_client_id = os.environ.get("EPP_EXPECTED_CLIENT_ID")
        caller_app_id = _read_caller_app_id(req)
        if caller_app_id and expected_client_id and caller_app_id != expected_client_id:
            return reply(403, {"error": "unexpected_caller", "requestId": request_id})

        auth_ok, _reason, _caller_object_id = validate_token(req.headers.get("Authorization"))
        if not auth_ok:
            return reply(401, {"error": "unauthorized", "reason": "token validation failed",
                               "requestId": request_id})

        try:
            payload = req.get_json()
        except ValueError:
            return reply(400, {"error": "bad_request", "reason": "invalid JSON body",
                               "requestId": request_id})

        envelope, error = parse_envelope(payload)
        if error:
            return reply(400, {"error": "bad_request", "reason": error,
                               "requestId": request_id})

        correlation_id = envelope["correlation_id"] or header_correlation_id or request_id
        channel = CHANNEL_BY_CODE[envelope["channel"]]
        evaluation = envelope["mode"] == MODE_EVALUATION
        mode = "evaluation" if evaluation else "live"

        try:
            _header, delivery = decrypt_delivery_context(envelope["encrypted_delivery_context"], _key_provider)
        except Exception:
            return reply(400, {"error": "decryption_failed", "correlationId": correlation_id,
                               "requestId": request_id})

        if not delivery.get("nonce") or not delivery.get("phoneNumber") or not delivery.get("message"):
            return reply(400, {"error": "bad_request", "reason": "incomplete delivery context",
                               "correlationId": correlation_id, "requestId": request_id})

        dispatch = context_to_dispatch(delivery, envelope, client_request_id)
        dispatch.correlation_id = correlation_id

        provider_status, provider_body = _engine.dispatch(dispatch, None, evaluation, request_id, logging)
        if type(provider_status) is not int or not 100 <= provider_status <= 599:
            provider_status = 502
        if provider_status != 200:
            candidate = provider_body.get("outcome")
            outcome = candidate if candidate in OUTCOMES and candidate != CONTINUE else FAIL
            return reply(provider_status, {
                "error": "provider_delivery_failed", "status": "failed", "outcome": outcome,
                "correlationId": correlation_id, "requestId": request_id,
            })

        # The nonce proves decryption on the wire; logs record only its presence.
        response = reply(200, {
            "nonce": delivery["nonce"],
            "correlationId": correlation_id,
            "providerStatus": "accepted",
        })
        outcome = CONTINUE
        shutter_processed = evaluation and provider_body.get("shutterProcessed") is True
        return response
    except Exception:
        outcome = FAIL
        return reply(500, {"error": "delivery_failed", "correlationId": correlation_id, "requestId": request_id})
    finally:
        logging.info("%s %s", TAG, json.dumps({
            "requestId": request_id,
            "correlationId": safe_trace_id(correlation_id),
            "provider": provider, "channel": channel, "mode": mode,
            "httpStatus": status, "outcome": outcome,
            "nonceEcho": nonce_echo, "shutterProcessed": shutter_processed,
            "elapsedMs": round((time.perf_counter() - started) * 1000),
        }))
