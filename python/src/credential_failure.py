from __future__ import annotations

import re
from concurrent.futures import CancelledError, TimeoutError as FutureTimeoutError
from dataclasses import dataclass

_STAGES = {"unknown", "configuration", "managed_identity", "provider_token_exchange", "key_vault"}
_FAILURES = {"credential_unavailable", "configuration_invalid", "timeout", "cancelled",
             "federated_credential_missing", "federated_credential_mismatch", "provider_application_not_found"}
_CODES = {"70025": "federated_credential_missing", "70021": "federated_credential_mismatch",
          "700016": "provider_application_not_found"}
_CODE_PATTERN = re.compile(r"\bAADSTS(70025|70021|700016)\b", re.IGNORECASE)


@dataclass(frozen=True)
class CredentialDiagnostic:
    credential_stage: str
    credential_failure: str
    aadsts_code: str | None


class CredentialResolutionError(ValueError):
    def __init__(self, stage: str = "unknown", failure: str = "credential_unavailable",
                 code: str | None = None) -> None:
        super().__init__("provider credential unavailable")
        self.diagnostic = CredentialDiagnostic(
            stage if stage in _STAGES else "unknown",
            failure if failure in _FAILURES else "credential_unavailable",
            code if code in _CODES else None)


def credential_failure(error: BaseException | None, stage: str = "unknown") -> CredentialResolutionError:
    pending, seen = [error], set()
    code, message_code, failure = None, None, "credential_unavailable"
    while pending and len(seen) < 8:
        current = pending.pop(0)
        if not isinstance(current, BaseException) or id(current) in seen:
            continue
        seen.add(id(current))
        if isinstance(current, CredentialResolutionError):
            return current
        response = getattr(current, "error_response", None)
        codes = response.get("error_codes") if isinstance(response, dict) else getattr(current, "error_codes", None)
        if code is None and isinstance(codes, (list, tuple)):
            code = next((str(value) for value in codes[:8]
                         if isinstance(value, (str, int)) and str(value) in _CODES), None)
        message = getattr(current, "message", None)
        if not isinstance(message, str) and current.args:
            message = current.args[0]
        if message_code is None and isinstance(message, str):
            match = _CODE_PATTERN.search(message[:8192])
            message_code = match.group(1) if match else None
        if isinstance(current, (TimeoutError, FutureTimeoutError)):
            failure = "timeout"
        elif isinstance(current, CancelledError) and failure != "timeout":
            failure = "cancelled"
        pending.extend((current.__cause__, current.__context__))
    code = code or message_code
    if stage == "configuration":
        failure = "configuration_invalid"
    elif stage == "provider_token_exchange" and code:
        failure = _CODES[code]
    # Only fixed fields cross the worker boundary, never the SDK exception or its response.
    return CredentialResolutionError(stage, failure, code)
