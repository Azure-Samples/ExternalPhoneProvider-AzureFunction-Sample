import json
import os
import uuid

import azure.functions as func

from src.config import read_config
from src.dispatch import (
    MODE_EVALUATION,
    DispatchEngine,
    ProviderRegistry,
    context_to_dispatch,
    decrypt_delivery_context,
    make_key_provider,
    parse_envelope,
)
from src.providers.infobip import InfobipProvider
from src.providers.sinch import SinchProvider
from src.providers.soprano import SopranoProvider
from src.providers.telesign import TelesignProvider
from src.request_log import RequestLog
from src.secrets import SecretResolver

app = func.FunctionApp()

_registry = ProviderRegistry([InfobipProvider(), TelesignProvider(), SopranoProvider(), SinchProvider()])
_secrets = SecretResolver()
_engine = DispatchEngine(_registry, _secrets)
_key_provider = make_key_provider(os.environ)


# Azure Easy Auth must enforce authentication; local handler calls are anonymous.
@app.route(route="SendOtp", methods=["POST"], auth_level=func.AuthLevel.ANONYMOUS)
def send_otp(req: func.HttpRequest, context: func.Context = None) -> func.HttpResponse:
    request_id = str(uuid.uuid4())
    ms_request_id = req.headers.get("x-ms-client-request-id")
    client_request_id = ms_request_id or request_id
    header_correlation_id = req.headers.get("x-ms-correlation-id")
    log = RequestLog(request_id, context.invocation_id if context else None,
                     ms_request_id, header_correlation_id, context.function_name if context else "send_otp")
    correlation_id = header_correlation_id or request_id
    http_status = 500
    evaluation = False

    def respond(status, body):
        nonlocal http_status
        response = func.HttpResponse(json.dumps(body), status_code=status, mimetype="application/json")
        http_status = status
        log.response_prepared(status, "nonce" in body, "correlationId" in body)
        return response

    try:
        log.service("request_received")
        config = read_config()
        try:
            payload = req.get_json()
        except ValueError:
            log.failure("request_validation", "invalid JSON body", 400)
            return respond(400, {"error": "bad_request", "reason": "invalid JSON body", "requestId": request_id})

        envelope, error = parse_envelope(payload)
        if error:
            log.failure("request_validation", error, 400)
            return respond(400, {"error": "bad_request", "reason": error, "requestId": request_id})

        correlation_id = envelope.correlation_id or header_correlation_id or request_id
        log.envelope_validated(envelope, envelope.correlation_id or header_correlation_id,
                               "envelope" if envelope.correlation_id else "header")
        envelope.correlation_id = correlation_id
        evaluation = envelope.mode == MODE_EVALUATION

        try:
            header, delivery = decrypt_delivery_context(envelope.encrypted_delivery_context, _key_provider)
        except Exception:
            log.failure("decryption", "decryption_failed", 400)
            return respond(400, {"error": "decryption_failed", "correlationId": correlation_id, "requestId": request_id})
        log.service("delivery_context_decrypted")

        if config.expected_key_id and header.get("kid") != config.expected_key_id:
            log.key_id_mismatch()

        if delivery is None or not delivery.is_complete:
            log.failure("delivery_context_validation", "incomplete delivery context", 400)
            return respond(400, {"error": "bad_request", "reason": "incomplete delivery context",
                                 "correlationId": correlation_id, "requestId": request_id})

        # Evaluation skips provider lookup, configuration, secrets and HTTP.
        if not evaluation:
            dispatch = context_to_dispatch(delivery, envelope, client_request_id)
            status, _ = _engine.dispatch(dispatch, request_id, log)
            if status != 200:
                return respond(status, {"error": "provider_delivery_failed",
                                        "correlationId": correlation_id, "requestId": request_id})
        else:
            log.service("evaluation_completed")

        # Live delivery must finish before nonce acceptance.
        return respond(200, {
            "nonce": delivery.nonce,
            "correlationId": correlation_id,
            "providerStatus": "accepted",
        })
    except Exception:
        if not log.data["failureStage"]:
            log.failure("handler", "unexpected_error", 500)
        return respond(500, {"error": "delivery_failed", "correlationId": correlation_id, "requestId": request_id})
    finally:
        log.complete(http_status)
