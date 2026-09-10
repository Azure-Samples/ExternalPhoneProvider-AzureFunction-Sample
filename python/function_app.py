import hashlib
import json
import logging
import os
import time
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
from src.secrets import SecretResolver

TAG = "[EPP]"

app = func.FunctionApp()

_registry = ProviderRegistry([InfobipProvider(), TelesignProvider(), SopranoProvider(), SinchProvider()])
_secrets = SecretResolver()
_engine = DispatchEngine(_registry, _secrets)
_key_provider = make_key_provider(os.environ)


# Azure Easy Auth must enforce authentication; local handler calls are anonymous.
@app.route(route="SendOtp", methods=["POST"], auth_level=func.AuthLevel.ANONYMOUS)
def send_otp(req: func.HttpRequest) -> func.HttpResponse:
    started = time.monotonic()
    request_id = str(uuid.uuid4())
    client_request_id = req.headers.get("x-ms-client-request-id") or request_id
    header_correlation_id = req.headers.get("x-ms-correlation-id")
    correlation_id = header_correlation_id or request_id
    http_status = 500
    evaluation = False

    def respond(status, body):
        nonlocal http_status
        response = func.HttpResponse(json.dumps(body), status_code=status, mimetype="application/json")
        http_status = status
        return response

    try:
        config = read_config()
        try:
            payload = req.get_json()
        except ValueError:
            return respond(400, {"error": "bad_request", "reason": "invalid JSON body", "requestId": request_id})

        envelope, error = parse_envelope(payload)
        if error:
            return respond(400, {"error": "bad_request", "reason": error, "requestId": request_id})

        correlation_id = envelope["correlation_id"] or header_correlation_id or request_id
        envelope["correlation_id"] = correlation_id
        evaluation = envelope["mode"] == MODE_EVALUATION

        try:
            header, delivery = decrypt_delivery_context(envelope["encrypted_delivery_context"], _key_provider)
        except Exception:
            return respond(400, {"error": "decryption_failed", "correlationId": correlation_id, "requestId": request_id})

        if config["expected_key_id"] and header.get("kid") != config["expected_key_id"]:
            logging.warning('encryption_key_id_mismatch')

        if not isinstance(delivery, dict) or not all(
            isinstance(delivery.get(field), str) and delivery[field].strip()
            for field in ("nonce", "phoneNumber", "message")
        ):
            return respond(400, {"error": "bad_request", "reason": "incomplete delivery context",
                                 "correlationId": correlation_id, "requestId": request_id})

        # Evaluation skips provider lookup, configuration, secrets and HTTP.
        if not evaluation:
            dispatch = context_to_dispatch(delivery, envelope, client_request_id)
            status, _ = _engine.dispatch(dispatch, request_id)
            if status != 200:
                return respond(status, {"error": "provider_delivery_failed",
                                        "correlationId": correlation_id, "requestId": request_id})

        # Live delivery must finish before nonce acceptance.
        return respond(200, {
            "nonce": delivery["nonce"],
            "correlationId": correlation_id,
            "providerStatus": "accepted",
        })
    except Exception:
        return respond(500, {"error": "provider_delivery_failed", "correlationId": correlation_id, "requestId": request_id})
    finally:
        # Hash even generated correlations; wire IDs stay raw.
        logging.info("%s result %s", TAG, json.dumps({
            "requestId": request_id,
            "correlationId": hashlib.sha256(str(correlation_id).encode("utf-8")).hexdigest()[:16],
            "httpStatus": http_status,
            "elapsedMs": int((time.monotonic() - started) * 1000),
            "evaluation": evaluation,
        }))
