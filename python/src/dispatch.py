"""Delivery pipeline: parse the cleartext SAS envelope, decrypt the JWE that carries the PII, then
dispatch to the configured provider. Fail-closed — only a Continue outcome is "accepted"."""
import base64
import json
import os
import re
from dataclasses import dataclass

import requests
from jwcrypto import jwe as jwe_module
from jwcrypto import jwk

DEFAULT_TIMEOUT_MS = 1500
DEFAULT_CHANNELS = ["sms", "voice"]

# Outcomes (mirrors the other languages).
CONTINUE = "Continue"
FAIL = "Fail"
BLOCK = "Block"
STEP_UP = "StepUp"


@dataclass
class DispatchRequest:
    destination: str
    message: str | None
    channel: str
    message_id: str
    correlation_id: str | None
    locale: str | None


def resolve_outcome(manifest, parsed):
    """A recognized status wins; an unknown status is fail-closed; only a status-less response
    trusts the HTTP result."""
    mapping = manifest["response_mapping"]
    key = parsed.get("provider_status_name") or parsed.get("provider_status_code")
    if key:
        return mapping.get(key) or mapping.get("default", FAIL)
    return CONTINUE if parsed.get("success") else mapping.get("default", FAIL)


def to_http_status(outcome, provider_http_status):
    if outcome == CONTINUE:
        return 200
    if outcome == BLOCK:
        return 403
    if outcome == STEP_UP:
        return 409
    if outcome == FAIL:
        if provider_http_status == 429:
            return 429
        if provider_http_status in (401, 403):
            return 401
        if 400 <= provider_http_status < 500:
            return 400
    return 502


class ProviderRegistry:
    """One provider is active per deployment; request_provider is a test override."""

    def __init__(self, adapters):
        self._by_id = {adapter.manifest["id"].lower(): adapter for adapter in adapters}

    def get(self, provider_id):
        if not provider_id:
            return None
        return self._by_id.get(provider_id.lower())

    def resolve(self, request_provider):
        return self.get(request_provider or os.environ.get("EPP_PROVIDER_NAME"))


# Channel: 1=Sms, 2=Voice. DeliveryMode: 1=Live, 2=Evaluation (do NOT deliver).
CHANNEL_BY_CODE = {1: "sms", 2: "voice"}
CHANNEL_BY_NAME = {"sms": 1, "voice": 2}
MODE_LIVE = 1
MODE_EVALUATION = 2
MODE_BY_NAME = {"live": MODE_LIVE, "evaluation": MODE_EVALUATION}

MAX_JWE_LENGTH = 16384


def _normalize_channel(channel):
    if isinstance(channel, bool):
        return None
    if channel in CHANNEL_BY_CODE:
        return channel
    if isinstance(channel, str):
        return CHANNEL_BY_NAME.get(channel.lower())
    return None


def _normalize_mode(mode):
    if isinstance(mode, bool):
        return None
    if mode in (MODE_LIVE, MODE_EVALUATION):
        return mode
    if isinstance(mode, str):
        return MODE_BY_NAME.get(mode.lower())
    return None


def parse_envelope(payload):
    """Returns (envelope, None) or (None, error)."""
    if not isinstance(payload, dict):
        return None, "invalid envelope"
    encrypted = payload.get("encryptedDeliveryContext")
    if not isinstance(encrypted, str) or not encrypted:
        return None, "encryptedDeliveryContext is required"
    channel = _normalize_channel(payload.get("channel"))
    if channel is None:
        return None, f"unsupported channel '{payload.get('channel')}'"
    mode = _normalize_mode(payload.get("mode"))
    if mode is None:
        return None, f"unsupported mode '{payload.get('mode')}'"
    return {
        "type": payload.get("type"),
        "tenant_id": payload.get("tenantId"),
        "correlation_id": payload.get("correlationId"),
        "channel": channel,
        "mode": mode,
        "ttl_seconds": payload.get("ttlSeconds"),
        "encrypted_delivery_context": encrypted,
    }, None


def read_protected_header(compact_jwe):
    header_segment = compact_jwe.split(".")[0]
    header_segment += "=" * (-len(header_segment) % 4)
    return json.loads(base64.urlsafe_b64decode(header_segment))


def make_key_provider(env):
    def key_provider(_kid):
        return env.get("EPP_DECRYPTION_KEY_PEM") or ""

    return key_provider


def _assert_well_formed_jwe(compact_jwe):
    # Reject oversized or malformed input before decoding or allocating buffers.
    if not isinstance(compact_jwe, str) or not compact_jwe:
        raise ValueError("malformed JWE")
    if len(compact_jwe) > MAX_JWE_LENGTH:
        raise ValueError("delivery context exceeds size limit")
    segments = compact_jwe.split(".")
    if len(segments) != 5 or not all(segments):
        raise ValueError("malformed JWE: expected five non-empty segments")


# Imported once: a per-delivery RSA import would sit inside the response budget.
_key_cache = {}


def _normalize_pem(value):
    """The setup script stores the key as base64 over the PEM so its newlines survive being carried as
    an app setting, so accept either form."""
    text = value if isinstance(value, str) else value.decode("utf-8")
    if "-----BEGIN" in text:
        return text
    return base64.b64decode(text).decode("utf-8")


def _load_private_key(pem):
    if not pem:
        raise ValueError("private key unavailable (EPP_DECRYPTION_KEY_PEM is not set)")
    cached = _key_cache.get(pem)
    if cached is None:
        cached = jwk.JWK.from_pem(_normalize_pem(pem).encode("utf-8"))
        _key_cache.clear()
        _key_cache[pem] = cached
    return cached


def decrypt_delivery_context(compact_jwe, key_provider):
    """key_provider(kid) -> PEM string. Returns (header, delivery context dict)."""
    _assert_well_formed_jwe(compact_jwe)
    header = read_protected_header(compact_jwe)
    key = _load_private_key(key_provider(header.get("kid")))
    # Pin alg/enc so a tampered header can't downgrade the crypto.
    token = jwe_module.JWE(algs=["RSA-OAEP-256", "A256GCM"])
    token.deserialize(compact_jwe, key=key)
    return header, json.loads(token.payload.decode("utf-8"))


def _space_passcode_for_voice(message):
    """Left alone, TTS reads 641895 as "six hundred forty-one thousand...", which no user can type."""
    return re.sub(r"\b\d{4,8}\b", lambda m: " ".join(m.group(0)), message or "", count=1)


def context_to_dispatch(context, envelope, message_id):
    """The message is pre-rendered and already contains the passcode, so there is no separate code."""
    return DispatchRequest(
        destination=context.get("phoneNumber"),
        message=(_space_passcode_for_voice(context.get("message"))
                 if CHANNEL_BY_CODE[envelope["channel"]] == "voice" else context.get("message")),
        channel=CHANNEL_BY_CODE[envelope["channel"]],
        message_id=message_id,
        correlation_id=envelope["correlation_id"],
        locale=context.get("locale"),
    )


class DispatchEngine:
    def __init__(self, registry, secrets, env=None):
        self.registry = registry
        self.secrets = secrets
        self.env = env if env is not None else os.environ

    def dispatch(self, dispatch, request_provider, shutter, request_id, log):
        adapter = self.registry.resolve(request_provider)
        if adapter is None:
            log.warning("[DISPATCH_ERROR] requestId=%s unknown provider=%s", request_id, request_provider or "n/a")
            return 400, {"status": "error", "reason": "unknown provider", "requestId": request_id}

        manifest = adapter.manifest
        provider_id = manifest["id"]
        channel = (dispatch.channel or "sms").lower()

        if channel not in DEFAULT_CHANNELS:
            return 400, {"status": "error", "provider": provider_id, "reason": f"channel '{channel}' not supported", "requestId": request_id}

        # Credential (fail closed 502 if missing) — this is our credential, not the caller's token.
        credential = None
        try:
            credential = self._resolve_credential(manifest["auth"])
        except Exception as error:
            log.error("[DISPATCH_ERROR] requestId=%s provider=%s credential error=%s", request_id, provider_id, error)

        auth = manifest["auth"]
        identity_required = (
            credential is not None
            and credential["mode"] == "apiKey"
            and bool(auth.get("identity_key_vault_secret_name"))
        )
        credential_unavailable = (
            credential is None
            or (credential["mode"] == "oauth2" and not credential.get("token"))
            or (credential["mode"] == "apiKey" and not credential.get("secret"))
            or (identity_required and not credential.get("identity"))
        )
        if credential_unavailable:
            return 502, self._fail_body(provider_id, channel, "provider credential unavailable", dispatch, request_id)

        endpoint = self._resolve_endpoint(manifest)
        if not endpoint:
            return 502, self._fail_body(provider_id, channel, "provider endpoint not configured", dispatch, request_id)

        provider_request = adapter.build_request(channel, endpoint, dispatch, credential, self.env)
        log.info("[DISPATCH] requestId=%s provider=%s channel=%s shutter=%s", request_id, provider_id, channel, bool(shutter))

        if shutter:
            return 200, {"status": "accepted", "shutterProcessed": True, "provider": provider_id, "channel": channel, "correlationId": dispatch.correlation_id, "messageId": dispatch.message_id, "requestId": request_id}

        try:
            timeout_ms = int(self.env.get("EPP_PROVIDER_TIMEOUT_MS") or DEFAULT_TIMEOUT_MS)
        except (TypeError, ValueError):
            timeout_ms = DEFAULT_TIMEOUT_MS
        try:
            response = requests.request(
                provider_request["method"],
                provider_request["url"],
                headers=provider_request["headers"],
                data=provider_request["body"],
                timeout=timeout_ms / 1000,
            )
        except requests.exceptions.Timeout:
            log.warning("[DISPATCH_TIMEOUT] requestId=%s provider=%s", request_id, provider_id)
            return 504, self._fail_body(provider_id, channel, f"endpoint timeout after {timeout_ms}ms", dispatch, request_id)
        except requests.exceptions.RequestException as error:
            log.error("[DISPATCH_ERROR] requestId=%s provider=%s reason=%s", request_id, provider_id, error)
            return 502, self._fail_body(provider_id, channel, str(error), dispatch, request_id)

        try:
            body_json = response.json()
        except ValueError:
            body_json = {}

        ok = 200 <= response.status_code < 300
        parsed = adapter.parse_response(response.status_code, ok, body_json)
        outcome = resolve_outcome(manifest, parsed)
        http_status = to_http_status(outcome, parsed.get("provider_http_status") or response.status_code)

        log.info("[DISPATCH_RESULT] requestId=%s provider=%s channel=%s outcome=%s httpStatus=%s", request_id, provider_id, channel, outcome, http_status)

        return http_status, {
            "status": "accepted" if outcome == CONTINUE else "failed",
            "outcome": outcome,
            "provider": provider_id,
            "channel": channel,
            "messageId": dispatch.message_id,
            "correlationId": dispatch.correlation_id,
            "providerMessageId": parsed.get("provider_message_id"),
            "providerStatus": parsed.get("provider_status_name") or parsed.get("provider_status_code"),
            "providerStatusDescription": parsed.get("provider_status_description"),
            "requestId": request_id,
        }

    def _resolve_credential(self, auth):
        if auth.get("mode") == "oauth2":
            return {"mode": "oauth2", "token": None}  # not wired -> fails closed
        secret = self.secrets.resolve(auth.get("key_vault_secret_name"))
        identity = self.secrets.resolve(auth.get("identity_key_vault_secret_name")) if auth.get("identity_key_vault_secret_name") else ""
        return {"mode": "apiKey", "secret": secret, "identity": identity}

    def _resolve_endpoint(self, manifest):
        # One provider is active per deployment, so the endpoint is a single EPP_PROVIDER_ENDPOINT.
        return self.env.get("EPP_PROVIDER_ENDPOINT")

    def _fail_body(self, provider, channel, reason, dispatch, request_id):
        return {"status": "failed", "outcome": "Fail", "provider": provider, "channel": channel, "reason": reason, "correlationId": dispatch.correlation_id, "messageId": dispatch.message_id, "requestId": request_id}
