"""POST /api/SendOtp — the SAS → External Phone Provider delivery endpoint. Validates the caller, parses
the cleartext routing envelope, decrypts the JWE delivery context, dispatches to the provider, and
echoes the nonce to prove decryption. Every line is tagged [EPP] so one filter pulls a whole delivery.
"""
import base64
import json
import logging
import os
import threading
import time
import uuid

import azure.functions as func

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
from src.security import validate_token

TAG = "[EPP]"

app = func.FunctionApp()

_registry = ProviderRegistry([InfobipProvider(), TelesignProvider(), SopranoProvider(), SinchProvider()])
_secrets = SecretResolver()
_engine = DispatchEngine(_registry, _secrets)
_key_provider = make_key_provider(os.environ)


def _json(status_code, body):
    return func.HttpResponse(json.dumps(body), status_code=status_code, mimetype="application/json")


def _log(label, value):
    logging.info("%s %-18s: %s", TAG, label, value)


def _read_caller_app_id(req):
    """Easy Auth has already validated the token; this records which identity arrived."""
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
    started = time.time()
    request_id = uuid.uuid4().hex
    client_request_id = req.headers.get("x-ms-client-request-id") or request_id
    header_correlation_id = req.headers.get("x-ms-correlation-id")
    log_plaintext = (os.environ.get("EPP_LOG_PLAINTEXT") or "").lower() == "true"
    expected_key_id = os.environ.get("EPP_ENCRYPTION_KEY_ID")
    expected_client_id = os.environ.get("EPP_EXPECTED_CLIENT_ID")

    logging.info("%s ======== delivery received ========", TAG)
    _log("invocation", request_id)

    correlation_id = None
    try:
        caller_app_id = _read_caller_app_id(req)
        _log("caller appid", caller_app_id or "none (Easy Auth off, or called directly)")

        if caller_app_id and expected_client_id and caller_app_id != expected_client_id:
            logging.error("%s caller %s is not %s. Easy Auth allowedApplications is not doing its job.",
                          TAG, caller_app_id, expected_client_id)
            return _json(403, {"error": "unexpected_caller"})

        auth_ok, reason, _caller_object_id = validate_token(req.headers.get("Authorization"))
        if not auth_ok:
            logging.error("%s token rejected: %s", TAG, reason)
            return _json(401, {"error": "unauthorized", "reason": reason, "requestId": request_id})

        try:
            payload = req.get_json()
        except ValueError:
            logging.error("%s body is not JSON", TAG)
            return _json(400, {"error": "bad_request", "reason": "invalid JSON body", "requestId": request_id})

        envelope, error = parse_envelope(payload)
        if error:
            logging.error("%s envelope rejected: %s", TAG, error)
            return _json(400, {"error": "bad_request", "reason": error, "requestId": request_id})

        _log("type", envelope["type"])
        _log("tenantId", envelope["tenant_id"])
        _log("correlationId", envelope["correlation_id"])
        _log("channel", envelope["channel"])
        _log("mode", envelope["mode"])
        _log("ttlSeconds", envelope["ttl_seconds"])

        correlation_id = envelope["correlation_id"] or header_correlation_id or request_id

        # Surfaced rather than swallowed: the passcode expires before it can be used.
        ttl_seconds = envelope["ttl_seconds"]
        if isinstance(ttl_seconds, (int, float)) and not isinstance(ttl_seconds, bool) and ttl_seconds <= 0:
            logging.warning("%s ttlSeconds is %s; the passcode has expired.", TAG, ttl_seconds)

        try:
            header, delivery = decrypt_delivery_context(envelope["encrypted_delivery_context"], _key_provider)
        except Exception as err:
            logging.error("%s decryption failed: %s", TAG, err)
            return _json(400, {"error": "decryption_failed", "correlationId": correlation_id, "requestId": request_id})

        kid = header.get("kid")
        kid_matches = not expected_key_id or kid == expected_key_id
        _log("kid", f"{kid}{'' if kid_matches else ' (DOES NOT match EPP_ENCRYPTION_KEY_ID)'}")
        _log("alg / enc", f"{header.get('alg')} / {header.get('enc')}")
        _log("decrypted", "OK")
        _log("nonce", delivery.get("nonce"))

        if log_plaintext:
            # DIAGNOSTICS ONLY — writes the phone number and passcode to the log.
            _log("phoneNumber", delivery.get("phoneNumber"))
            _log("extension", delivery.get("extension") or "(none)")
            _log("locale", delivery.get("locale"))
            _log("message", delivery.get("message"))
            _log("riskContext", json.dumps(delivery["riskContext"]) if delivery.get("riskContext") else "(none)")
        else:
            logging.info("%s plaintext suppressed (EPP_LOG_PLAINTEXT=false)", TAG)

        if not delivery.get("nonce") or not delivery.get("phoneNumber") or not delivery.get("message"):
            logging.error("%s delivery context is incomplete (nonce/phoneNumber/message)", TAG)
            return _json(400, {"error": "bad_request", "reason": "incomplete delivery context",
                               "correlationId": correlation_id, "requestId": request_id})

        evaluation = envelope["mode"] == MODE_EVALUATION
        dispatch = context_to_dispatch(delivery, envelope, client_request_id)

        # Microsoft allows 3.2 s for the whole call, so the provider is called after the response.
        def _deliver():
            try:
                status, body = _engine.dispatch(dispatch, None, evaluation, request_id, logging)
                logging.info(
                    "%s provider result   : httpStatus=%s outcome=%s providerStatus=%s providerMessageId=%s correlationId=%s",
                    TAG, status, body.get("outcome") or "n/a", body.get("providerStatus") or "n/a",
                    body.get("providerMessageId") or "n/a", correlation_id)
            except Exception as delivery_error:
                logging.error("%s provider delivery failed: %s", TAG, delivery_error)

        # daemon so a stalled provider call cannot hold up worker shutdown.
        threading.Thread(target=_deliver, name="epp-delivery", daemon=True).start()

        # Echoing the nonce is the whole contract: a 2xx without it is treated as a failed delivery and
        # Microsoft re-sends over its own telephony, so the user gets the code twice.
        _log("responding", f"200, nonce echoed, {(time.time() - started) * 1000:.0f} ms")
        logging.info("%s ======== done ========", TAG)

        return _json(200, {
            "nonce": delivery["nonce"],
            "correlationId": correlation_id,
            "providerStatus": "accepted",
        })
    except Exception as error:
        # Verbose on purpose: this endpoint exists to diagnose onboarding.
        logging.error("%s FAILED after %.0f ms: %s", TAG, (time.time() - started) * 1000, error)
        logging.info("%s ======== failed ========", TAG)
        return _json(500, {"error": "delivery_failed", "detail": str(error), "correlationId": correlation_id})
