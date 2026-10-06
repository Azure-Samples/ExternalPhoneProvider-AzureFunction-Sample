from __future__ import annotations

import logging
import time
from abc import ABC, abstractmethod
from dataclasses import dataclass
from urllib.parse import urlsplit, urlunsplit

import requests
from urllib3.exceptions import ReadTimeoutError

from . import otp_log
from .models import Outcome, OtpDelivery, ProviderResult

DEFAULT_TIMEOUT_MS = 1500


@dataclass(frozen=True)
class OutboundRequest:
    method: str
    url: str
    headers: dict[str, str]
    body: str


class ProviderSendError(Exception):
    def __init__(self, status_code: int) -> None:
        super().__init__("provider delivery failed")
        self.status_code = status_code


class PhoneProviderBase(ABC):
    name: str
    authentication_mode: str

    @abstractmethod
    def build_request(self, channel, endpoint, delivery, credential, env) -> OutboundRequest:
        raise NotImplementedError

    @abstractmethod
    def map_response(self, payload: object, http_status: int) -> ProviderResult:
        raise NotImplementedError

    @property
    @abstractmethod
    def credential_spec(self) -> dict[str, str]:
        raise NotImplementedError

    def send_otp(self, channel: str, endpoint: str, delivery: OtpDelivery, credential: dict,
                 env, timeout_ms: int, log) -> ProviderResult:
        stage = "provider_request_build"
        response = None

        def fail(status: int, reason: str, failure_stage: str | None = None):
            current_stage = failure_stage or stage
            otp_log.request_failed(
                log, logging.ERROR if status >= 500 else logging.WARNING,
                current_stage, reason, status)
            raise ProviderSendError(status)

        try:
            otp_log.provider_request_build_started(log)
            request = self.build_request(channel, endpoint, delivery, credential, env)
            if not is_https_endpoint(request.url):
                fail(502, "invalid_provider_request_url")
            otp_log.provider_request_built(log, normalize_http_method(request.method), sanitize_endpoint(request.url))

            stage = "provider_transport"
            started = time.monotonic()
            otp_log.provider_request_started(log, timeout_ms)
            response = requests.request(
                request.method,
                request.url,
                headers=request.headers,
                data=request.body,
                timeout=timeout_ms / 1000,
                allow_redirects=False,
                stream=True,
            )
            otp_log.provider_response_received(log, response.status_code)
            try:
                payload = response.json()
            except ValueError:
                otp_log.provider_response_invalid_json(log)
                result = ProviderResult(
                    Outcome.FAIL, False, response.status_code,
                    failure_reason="invalid_provider_json")
            else:
                stage = "provider_response"
                try:
                    result = self.map_response(payload, response.status_code)
                except Exception:
                    fail(502, "response_parse_failed")

            elapsed_ms = int((time.monotonic() - started) * 1000)
            status = to_endpoint_http_status(result)
            provider_status = (
                result.provider_status_name or result.provider_status_code or "unmapped"
                if result.status_recognized else "unmapped"
            )
            otp_log.provider_response_processed(
                log,
                logging.ERROR if status >= 500 else logging.INFO if status == 200 else logging.WARNING,
                result.provider_http_status,
                provider_status,
                result.outcome.value,
                result.failure_reason,
                elapsed_ms,
            )
            return result
        except requests.exceptions.RequestException as error:
            if isinstance(error, requests.exceptions.Timeout) or (
                isinstance(error, requests.exceptions.ConnectionError) and has_read_timeout(error)
            ):
                fail(504, "provider_timeout", "provider_transport")
            fail(502, "provider_network_error", "provider_transport")
        except ProviderSendError:
            raise
        except Exception:
            reason = "request_build_failed" if stage == "provider_request_build" else "provider_network_error"
            fail(502, reason)
        finally:
            close = getattr(response, "close", None)
            if callable(close):
                try:
                    close()
                except Exception:
                    pass


def classify_failure(http_status: int, outcome: Outcome, status_recognized: bool) -> str | None:
    if not 200 <= http_status < 300:
        return "provider_http_error"
    if outcome != Outcome.FAIL:
        return None
    return "provider_rejected" if status_recognized else "unrecognized_provider_status"


def to_endpoint_http_status(result: ProviderResult) -> int:
    if result.outcome == Outcome.CONTINUE:
        return 200
    if result.outcome == Outcome.BLOCK:
        return 403
    if result.provider_http_status == 429:
        return 429
    if result.provider_http_status in (401, 403):
        return 401
    if 400 <= result.provider_http_status < 500:
        return 400
    return 502


def is_https_endpoint(value: object) -> bool:
    if not isinstance(value, str) or not value or "#" in value:
        return False
    if any(character.isspace() or ord(character) < 32 or ord(character) == 127 for character in value):
        return False
    try:
        parsed = urlsplit(value)
        port = parsed.port
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


def sanitize_endpoint(value: str) -> str:
    parsed = urlsplit(value)
    host = f"[{parsed.hostname}]" if ":" in parsed.hostname else parsed.hostname
    authority = host if parsed.port in (None, 443) else f"{host}:{parsed.port}"
    return urlunsplit((parsed.scheme, authority, parsed.path or "/", "", ""))


def normalize_http_method(method: object) -> str:
    value = method.upper() if isinstance(method, str) else None
    return value if value in {"GET", "HEAD", "POST", "PUT", "DELETE", "CONNECT", "OPTIONS", "TRACE", "PATCH"} else "other"


def provider_timeout_ms(value: object) -> int:
    digits = value.strip() if isinstance(value, str) else ""
    if not digits or not digits.isascii() or not digits.isdecimal():
        return DEFAULT_TIMEOUT_MS
    digits = digits.lstrip("0")
    if not digits:
        return DEFAULT_TIMEOUT_MS
    if len(digits) > 4 or (len(digits) == 4 and digits > "2500"):
        return 2500
    return int(digits)


def has_read_timeout(error: Exception) -> bool:
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
