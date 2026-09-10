import base64
import json
import os
from urllib.parse import urlsplit

import requests
from jwcrypto import jwe as jwe_module
from jwcrypto import jwk
from urllib3.exceptions import ReadTimeoutError

from .config import read_config
from .models import DeliveryContext, DispatchRequest, Envelope

DEFAULT_TIMEOUT_MS = 1500
DEFAULT_CHANNELS = ["sms", "voice"]

CONTINUE = "Continue"
FAIL = "Fail"
BLOCK = "Block"
STEP_UP = "StepUp"


def resolve_outcome(manifest, parsed):
    mapping = manifest["response_mapping"]
    key = parsed.get("provider_status_name") or parsed.get("provider_status_code")
    if key:
        outcome = mapping.get(key) or mapping.get("default", FAIL)
    else:
        outcome = CONTINUE if parsed.get("success") else mapping.get("default", FAIL)
    return FAIL if outcome == CONTINUE and not parsed.get("success") else outcome


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
    def __init__(self, adapters):
        self._by_id = {adapter.manifest["id"].lower(): adapter for adapter in adapters}

    def get(self, provider_id):
        if not provider_id:
            return None
        return self._by_id.get(provider_id.lower())


CHANNEL_BY_CODE = {1: "sms", 2: "voice"}
CHANNEL_BY_NAME = {"sms": 1, "voice": 2}
MODE_LIVE = 1
MODE_EVALUATION = 2
MODE_BY_NAME = {"live": MODE_LIVE, "evaluation": MODE_EVALUATION}

MAX_JWE_LENGTH = 16384


def _normalize_channel(channel):
    if type(channel) is int:
        return channel if channel in CHANNEL_BY_CODE else None
    if isinstance(channel, str):
        return CHANNEL_BY_NAME.get(channel.lower())
    return None


def _normalize_mode(mode):
    if type(mode) is int:
        return mode if mode in (MODE_LIVE, MODE_EVALUATION) else None
    if isinstance(mode, str):
        return MODE_BY_NAME.get(mode.lower())
    return None


def parse_envelope(payload) -> tuple[Envelope | None, str | None]:
    if not isinstance(payload, dict):
        return None, "invalid envelope"
    if payload.get("type") != "microsoft.mfa.otpDeliver.v1":
        return None, "unsupported envelope type"
    encrypted = payload.get("encryptedDeliveryContext")
    if not isinstance(encrypted, str) or not encrypted.strip():
        return None, "encryptedDeliveryContext is required"
    channel = _normalize_channel(payload.get("channel"))
    if channel is None:
        return None, "unsupported channel"
    mode = _normalize_mode(payload.get("mode"))
    if mode is None:
        return None, "unsupported mode"
    ttl_seconds = payload.get("ttlSeconds")
    if "ttlSeconds" in payload:
        if type(ttl_seconds) is not int:
            return None, "invalid ttlSeconds"
        if ttl_seconds <= 0:
            return None, "ttlSeconds expired"
        if ttl_seconds > 2147483647:
            return None, "invalid ttlSeconds"
    return Envelope(
        type=payload.get("type"),
        tenant_id=payload.get("tenantId"),
        correlation_id=payload.get("correlationId"),
        channel=channel,
        mode=mode,
        ttl_seconds=ttl_seconds,
        encrypted_delivery_context=encrypted,
    ), None


def read_protected_header(compact_jwe):
    header_segment = compact_jwe.split(".")[0]
    header_segment += "=" * (-len(header_segment) % 4)
    return json.loads(base64.urlsafe_b64decode(header_segment))


def make_key_provider(env):
    def key_provider(_kid):
        return read_config(env).decryption_key_pem

    return key_provider


def _assert_well_formed_jwe(compact_jwe):
    if not isinstance(compact_jwe, str) or not compact_jwe:
        raise ValueError("malformed JWE")
    if len(compact_jwe) > MAX_JWE_LENGTH:
        raise ValueError("delivery context exceeds size limit")
    segments = compact_jwe.split(".")
    if len(segments) != 5 or not all(segments):
        raise ValueError("malformed JWE: expected five non-empty segments")


# Cache only the configured key to avoid repeated RSA imports.
_key_cache = {}


def _normalize_pem(value):
    # Base64 preserves PEM newlines in app settings.
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
    _assert_well_formed_jwe(compact_jwe)
    header = read_protected_header(compact_jwe)
    key = _load_private_key(key_provider(header.get("kid")))
    token = jwe_module.JWE(algs=["RSA-OAEP-256", "A256GCM"])
    token.deserialize(compact_jwe, key=key)
    payload = json.loads(token.payload.decode("utf-8"))
    return header, DeliveryContext.from_payload(payload)


def context_to_dispatch(context, envelope, message_id):
    return DispatchRequest(
        destination=context.phone_number,
        message=context.message,
        channel=CHANNEL_BY_CODE[envelope.channel],
        message_id=message_id,
        correlation_id=envelope.correlation_id,
        locale=context.locale,
    )


def _valid_provider_url(value):
    if not isinstance(value, str) or not value or "#" in value:
        return False
    # urlsplit strips controls; reject them before parsing.
    if any(character.isspace() or ord(character) < 32 or ord(character) == 127 for character in value):
        return False
    try:
        parsed = urlsplit(value)
        port = parsed.port  # Access validates the port's syntax and range.
        return (
            parsed.scheme == "https"
            and bool(parsed.hostname)
            and port != 0
            and parsed.username is None
            and parsed.password is None
            and not parsed.fragment
            and not parsed.netloc.endswith(":")
        )
    except ValueError:
        return False


def _provider_timeout_ms(value):
    digits = value.strip() if isinstance(value, str) else ""
    if not digits or not digits.isascii() or not digits.isdecimal():
        return DEFAULT_TIMEOUT_MS
    digits = digits.lstrip("0")
    if not digits:
        return DEFAULT_TIMEOUT_MS
    # Clamp before int() to avoid its digit limit.
    if len(digits) > 4 or (len(digits) == 4 and digits > "2500"):
        return 2500
    return int(digits)


def _has_read_timeout(error):
    # requests wraps urllib3 body-read timeouts in ConnectionError.
    pending = [error]
    seen = set()
    while pending:
        current = pending.pop()
        if id(current) in seen:
            continue
        seen.add(id(current))
        if isinstance(current, ReadTimeoutError):
            return True
        pending.extend(
            nested for nested in (current.__cause__, current.__context__, *current.args)
            if isinstance(nested, Exception)
        )
    return False


class DispatchEngine:
    def __init__(self, registry, secrets, env=None):
        self.registry = registry
        self.secrets = secrets
        self.env = env if env is not None else os.environ

    def dispatch(self, dispatch, request_id):
        config = read_config(self.env)
        adapter = self.registry.get(config.provider_name)
        if adapter is None:
            return 400, {"status": "error", "reason": "unknown provider", "requestId": request_id}

        manifest = adapter.manifest
        provider_id = manifest["id"]
        channel = dispatch.channel if dispatch.channel is not None else "sms"
        if not isinstance(channel, str):
            return 400, {"status": "error", "provider": provider_id, "reason": "unsupported channel", "requestId": request_id}
        channel = channel.lower()

        if channel not in DEFAULT_CHANNELS:
            return 400, {"status": "error", "provider": provider_id, "reason": "unsupported channel", "requestId": request_id}

        auth = manifest["auth"]
        if auth.get("mode") != "apiKey":
            return 502, self._fail_body(provider_id, channel, "unsupported provider auth mode", dispatch, request_id)
        try:
            credential = self._resolve_credential(auth)
        except Exception:
            return 502, self._fail_body(provider_id, channel, "provider credential unavailable", dispatch, request_id)
        if not credential.get("secret") or (auth.get("identity_key_vault_secret_name") and not credential.get("identity")):
            return 502, self._fail_body(provider_id, channel, "provider credential unavailable", dispatch, request_id)

        endpoint = config.provider_endpoint
        if not endpoint:
            return 502, self._fail_body(provider_id, channel, "provider endpoint not configured", dispatch, request_id)
        if not _valid_provider_url(endpoint):
            return 502, self._fail_body(provider_id, channel, "invalid provider endpoint", dispatch, request_id)

        try:
            provider_request = adapter.build_request(channel, endpoint, dispatch, credential, config.env)
        except Exception:
            return 502, self._fail_body(provider_id, channel, "provider request failed", dispatch, request_id)
        if not _valid_provider_url(provider_request.get("url")):
            return 502, self._fail_body(provider_id, channel, "invalid provider request URL", dispatch, request_id)

        timeout_ms = _provider_timeout_ms(config.provider_timeout_ms)
        response = None
        try:
            response = requests.request(
                provider_request["method"],
                provider_request["url"],
                headers=provider_request["headers"],
                data=provider_request["body"],
                # Connect/read inactivity, not a total delivery deadline.
                timeout=timeout_ms / 1000,
                allow_redirects=False,  # Never forward credentials to a redirect target.
                stream=True,  # Own the response for cleanup if body reading fails.
            )

            try:
                body_json = response.json()
            except ValueError:
                body_json = {}

            ok = 200 <= response.status_code < 300
            parsed = adapter.parse_response(response.status_code, ok, body_json)
            outcome = resolve_outcome(manifest, parsed)
            http_status = to_http_status(outcome, parsed.get("provider_http_status") or response.status_code)

            return http_status, {
                "status": "accepted" if outcome == CONTINUE else "failed",
                "outcome": outcome,
                "provider": provider_id,
                "channel": channel,
                "messageId": dispatch.message_id,
                "correlationId": dispatch.correlation_id,
                "requestId": request_id,
            }
        except requests.exceptions.RequestException as error:
            if response is None:
                response = getattr(error, "response", None)
            if isinstance(error, requests.exceptions.Timeout) or (
                isinstance(error, requests.exceptions.ConnectionError) and _has_read_timeout(error)
            ):
                return 504, self._fail_body(provider_id, channel, "provider timeout", dispatch, request_id)
            return 502, self._fail_body(provider_id, channel, "provider request failed", dispatch, request_id)
        except Exception:
            return 502, self._fail_body(provider_id, channel, "provider response failed", dispatch, request_id)
        finally:
            close = getattr(response, "close", None)
            if callable(close):
                try:
                    close()
                except Exception:
                    pass

    def _resolve_credential(self, auth):
        secret = self.secrets.resolve(auth.get("key_vault_secret_name"))
        identity = self.secrets.resolve(auth.get("identity_key_vault_secret_name")) if auth.get("identity_key_vault_secret_name") else ""
        return {"mode": "apiKey", "secret": secret, "identity": identity}

    def _fail_body(self, provider, channel, reason, dispatch, request_id):
        return {"status": "failed", "outcome": "Fail", "provider": provider, "channel": channel, "reason": reason, "correlationId": dispatch.correlation_id, "messageId": dispatch.message_id, "requestId": request_id}
