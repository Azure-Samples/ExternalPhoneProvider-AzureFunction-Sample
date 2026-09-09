"""Parse, decrypt, and dispatch OTP delivery; only a Continue outcome succeeds."""
import base64
import hashlib
import json
import os
import time
import uuid
from dataclasses import dataclass
from urllib.parse import urlparse

import requests
from azure.identity import (
    ClientAssertionCredential,
    ClientSecretCredential,
    ManagedIdentityCredential,
)
from jwcrypto import jwe as jwe_module
from jwcrypto import jwk

DEFAULT_TIMEOUT_MS = 1500
MAX_PROVIDER_TIMEOUT_MS = 2500
DEFAULT_CHANNELS = ["sms", "voice"]
ENVELOPE_TYPE = "microsoft.mfa.otpDeliver.v1"

CONTINUE = "Continue"
FAIL = "Fail"
BLOCK = "Block"
STEP_UP = "StepUp"
OUTCOMES = (CONTINUE, FAIL, BLOCK, STEP_UP)
PROVIDER_IDS = ("infobip", "telesign", "sinch", "soprano")


@dataclass
class DispatchRequest:
    destination: str
    message: str | None
    channel: str
    message_id: str
    correlation_id: str | None
    locale: str | None


def safe_trace_id(value):
    """Normalize GUIDs or label a truncated SHA256 hash; never alter wire correlation."""
    if value is None:
        return "none"
    if isinstance(value, str):
        try:
            return str(uuid.UUID(value))
        except ValueError:
            pass
    else:
        value = json.dumps(value, sort_keys=True, separators=(",", ":"))
    return "sha256:" + hashlib.sha256(value.encode("utf-8", errors="replace")).hexdigest()[:16]


def resolve_outcome(manifest, parsed):
    """A success-looking body must never override an HTTP failure."""
    mapping = manifest["response_mapping"]
    key = parsed.get("provider_status_name") or parsed.get("provider_status_code")
    if key:
        outcome = mapping.get(key) or mapping.get("default", FAIL)
        return FAIL if outcome == CONTINUE and not parsed.get("success") else outcome
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


def normalize_provider_timeout_ms(value):
    try:
        parsed = int(value)
    except (TypeError, ValueError):
        return DEFAULT_TIMEOUT_MS
    if isinstance(value, bool) or parsed <= 0 or str(parsed) != str(value).strip():
        return DEFAULT_TIMEOUT_MS
    return min(parsed, MAX_PROVIDER_TIMEOUT_MS)


def is_valid_provider_endpoint(value):
    try:
        parsed = urlparse(value)
        return parsed.scheme == "https" and bool(parsed.netloc)
    except (TypeError, ValueError):
        return False


class ProviderRegistry:
    """One provider is active per deployment; request_provider overrides EPP_PROVIDER_NAME when set."""

    def __init__(self, adapters):
        self._by_id = {adapter.manifest["id"].lower(): adapter for adapter in adapters}

    def get(self, provider_id):
        if not isinstance(provider_id, str) or not provider_id:
            return None
        return self._by_id.get(provider_id.lower())

    def resolve(self, request_provider):
        return self.get(request_provider or os.environ.get("EPP_PROVIDER_NAME"))


# Channel: 1=sms, 2=voice. Mode: 1=live (deliver), 2=evaluation (do not deliver).
CHANNEL_BY_CODE = {1: "sms", 2: "voice"}
CHANNEL_BY_NAME = {"sms": 1, "voice": 2}
MODE_LIVE = 1
MODE_EVALUATION = 2
MODE_BY_NAME = {"live": MODE_LIVE, "evaluation": MODE_EVALUATION}

MAX_JWE_LENGTH = 16384


def _normalize_channel(channel):
    if type(channel) is int and channel in CHANNEL_BY_CODE:
        return channel
    if isinstance(channel, str):
        return CHANNEL_BY_NAME.get(channel.lower())
    return None


def _normalize_mode(mode):
    if type(mode) is int and mode in (MODE_LIVE, MODE_EVALUATION):
        return mode
    if isinstance(mode, str):
        return MODE_BY_NAME.get(mode.lower())
    return None


def parse_envelope(payload):
    """Returns (envelope, None) or (None, error)."""
    if not isinstance(payload, dict):
        return None, "invalid envelope"
    if payload.get("type") != ENVELOPE_TYPE:
        return None, "unsupported type"
    encrypted = payload.get("encryptedDeliveryContext")
    if not isinstance(encrypted, str) or not encrypted:
        return None, "encryptedDeliveryContext is required"
    channel = _normalize_channel(payload.get("channel"))
    if channel is None:
        return None, "unsupported channel"
    mode = _normalize_mode(payload.get("mode"))
    if mode is None:
        return None, "unsupported mode"
    ttl_seconds = payload.get("ttlSeconds")
    if "ttlSeconds" in payload and type(ttl_seconds) is not int:
        return None, "ttlSeconds must be a positive integer"
    if ttl_seconds is not None and ttl_seconds <= 0:
        return None, "passcode has expired"
    return {
        "type": payload.get("type"),
        "tenant_id": payload.get("tenantId"),
        "correlation_id": payload.get("correlationId"),
        "channel": channel,
        "mode": mode,
        "ttl_seconds": ttl_seconds,
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


# Cache the imported key: re-importing RSA on every delivery would eat the response budget.
_key_cache = {}


def _normalize_pem(value):
    """The key may arrive as a PEM or as base64 over the PEM (the setup script uses base64 so newlines
    survive being stored as an app setting); accept either form."""
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
    # Pin alg/enc so a tampered header cannot downgrade the encryption.
    token = jwe_module.JWE(algs=["RSA-OAEP-256", "A256GCM"])
    token.deserialize(compact_jwe, key=key)
    return header, json.loads(token.payload.decode("utf-8"))


def context_to_dispatch(context, envelope, message_id):
    return DispatchRequest(
        destination=context.get("phoneNumber"),
        # The caller owns localization and voice digit spacing; preserve the rendered text.
        message=context.get("message"),
        channel=CHANNEL_BY_CODE[envelope["channel"]],
        message_id=message_id,
        correlation_id=envelope["correlation_id"],
        locale=context.get("locale"),
    )


# Mint a provider-scoped app-only token; never forward the caller's inbound token.
OAUTH_TOKEN_EXPIRY_SKEW_SECONDS = 5 * 60
_provider_token_cache = {}


def _build_oauth_credential(env, secrets, tenant_id, client_id):
    """Managed-identity federation (selected by EPP_PROVIDER_MI_CLIENT_ID) keeps the cross-tenant call
    secretless; otherwise use a client secret from Key Vault (or an env var for local runs)."""
    mi_client_id = env.get("EPP_PROVIDER_MI_CLIENT_ID")
    if mi_client_id:
        managed_identity = ManagedIdentityCredential(client_id=mi_client_id)
        audience = env.get("EPP_PROVIDER_TOKEN_EXCHANGE_AUDIENCE") or "api://AzureADTokenExchange"
        exchange_scope = audience if audience.endswith("/.default") else f"{audience}/.default"
        return ClientAssertionCredential(
            tenant_id,
            client_id,
            lambda: managed_identity.get_token(exchange_scope).token,
        )
    secret = env.get("EPP_PROVIDER_CLIENT_SECRET") or (
        secrets.resolve(env.get("EPP_PROVIDER_CLIENT_SECRET_NAME")) if env.get("EPP_PROVIDER_CLIENT_SECRET_NAME") else ""
    )
    if not secret:
        raise ValueError(
            "oauth2 requires EPP_PROVIDER_MI_CLIENT_ID (managed identity) or EPP_PROVIDER_CLIENT_SECRET_NAME"
        )
    return ClientSecretCredential(tenant_id, client_id, secret)


def acquire_provider_token(env, secrets):
    tenant_id = env.get("EPP_PROVIDER_TENANT_ID")
    client_id = env.get("EPP_PROVIDER_CLIENT_ID")
    scope = env.get("EPP_PROVIDER_SCOPE")
    if not (tenant_id and client_id and scope):
        raise ValueError("oauth2 requires EPP_PROVIDER_TENANT_ID, EPP_PROVIDER_CLIENT_ID and EPP_PROVIDER_SCOPE")
    cache_key = f"{tenant_id}|{client_id}|{scope}"
    cached = _provider_token_cache.get(cache_key)
    if cached and cached[1] - OAUTH_TOKEN_EXPIRY_SKEW_SECONDS > time.time():
        return cached[0]
    credential = _build_oauth_credential(env, secrets, tenant_id, client_id)
    access = credential.get_token(scope)
    _provider_token_cache[cache_key] = (access.token, access.expires_on)
    return access.token


class DispatchEngine:
    def __init__(self, registry, secrets, env=None):
        self.registry = registry
        self.secrets = secrets
        self.env = env if env is not None else os.environ

    def dispatch(self, dispatch, request_provider, shutter, request_id, log):
        log_request_id = safe_trace_id(request_id)
        adapter = self.registry.resolve(request_provider)
        if adapter is None:
            log.warning("[DISPATCH] requestId=%s provider=unknown", log_request_id)
            return 400, {"status": "error", "reason": "unknown provider", "requestId": request_id}

        manifest = adapter.manifest
        provider_id = manifest["id"]
        provider_log_id = provider_id.lower() if isinstance(provider_id, str) else "unknown"
        if provider_log_id not in PROVIDER_IDS:
            provider_log_id = "unknown"
        channel = dispatch.channel or "sms"
        channel = channel.lower() if isinstance(channel, str) else "unknown"

        if channel not in DEFAULT_CHANNELS:
            log.warning("[DISPATCH] requestId=%s provider=%s channel=unknown", log_request_id, provider_log_id)
            return 400, {"status": "error", "provider": provider_id, "reason": "unsupported channel", "requestId": request_id}

        if shutter:
            return 200, {"status": "accepted", "shutterProcessed": True, "provider": provider_id, "channel": channel, "correlationId": dispatch.correlation_id, "messageId": dispatch.message_id, "requestId": request_id}

        credential = None
        try:
            credential = self._resolve_credential(manifest["auth"])
        except Exception:
            log.error("[DISPATCH] requestId=%s provider=%s channel=%s credential unavailable", log_request_id, provider_log_id, channel)

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

        endpoint = self.env.get("EPP_PROVIDER_ENDPOINT")
        if not is_valid_provider_endpoint(endpoint):
            return 502, self._fail_body(provider_id, channel, "provider endpoint must be an absolute HTTPS URL", dispatch, request_id)

        provider_request = adapter.build_request(channel, endpoint, dispatch, credential, self.env)
        if not is_valid_provider_endpoint(provider_request["url"]):
            return 502, self._fail_body(
                provider_id, channel, "provider request URL must be absolute HTTPS", dispatch, request_id
            )

        timeout_ms = normalize_provider_timeout_ms(self.env.get("EPP_PROVIDER_TIMEOUT_MS"))
        try:
            response = requests.request(
                provider_request["method"],
                provider_request["url"],
                headers=provider_request["headers"],
                data=provider_request["body"],
                timeout=timeout_ms / 1000,
            )
        except requests.exceptions.Timeout:
            log.warning("[DISPATCH] requestId=%s provider=%s channel=%s timeout", log_request_id, provider_log_id, channel)
            return 504, self._fail_body(provider_id, channel, "provider request timed out", dispatch, request_id)
        except requests.exceptions.RequestException:
            log.error("[DISPATCH] requestId=%s provider=%s channel=%s request failed", log_request_id, provider_log_id, channel)
            return 502, self._fail_body(provider_id, channel, "provider request failed", dispatch, request_id)

        try:
            body_json = response.json()
        except ValueError:
            body_json = {}

        ok = 200 <= response.status_code < 300
        parsed = adapter.parse_response(response.status_code, ok, body_json)
        outcome = resolve_outcome(manifest, parsed)
        if outcome not in OUTCOMES:
            outcome = FAIL
        http_status = to_http_status(outcome, parsed.get("provider_http_status") or response.status_code)

        log.info("[DISPATCH] requestId=%s provider=%s channel=%s httpStatus=%d outcome=%s",
                  log_request_id, provider_log_id, channel, http_status, outcome)

        return http_status, {
            "status": "accepted" if outcome == CONTINUE else "failed",
            "outcome": outcome,
            "provider": provider_id,
            "channel": channel,
            "messageId": dispatch.message_id,
            "correlationId": dispatch.correlation_id,
            "providerMessageId": parsed.get("provider_message_id"),
            "providerStatus": parsed.get("provider_status_name") or parsed.get("provider_status_code"),
            "requestId": request_id,
        }

    def _resolve_credential(self, auth):
        mode = (self.env.get("EPP_PROVIDER_AUTH_MODE") or auth.get("mode") or "apiKey").lower()
        if mode == "oauth2":
            return {"mode": "oauth2", "token": acquire_provider_token(self.env, self.secrets)}
        secret = self.secrets.resolve(auth.get("key_vault_secret_name"))
        identity = self.secrets.resolve(auth.get("identity_key_vault_secret_name")) if auth.get("identity_key_vault_secret_name") else ""
        return {"mode": "apiKey", "secret": secret, "identity": identity}

    def _fail_body(self, provider, channel, reason, dispatch, request_id):
        return {"status": "failed", "outcome": "Fail", "provider": provider, "channel": channel, "reason": reason, "correlationId": dispatch.correlation_id, "messageId": dispatch.message_id, "requestId": request_id}
