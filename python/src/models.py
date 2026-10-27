from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum


CHANNEL_BY_CODE = {1: "sms", 2: "voice"}
CHANNEL_BY_NAME = {"sms": 1, "voice": 2}
MODE_LIVE = 1
MODE_EVALUATION = 2
MODE_BY_NAME = {"live": MODE_LIVE, "evaluation": MODE_EVALUATION}


def _normalize_channel(channel: object) -> int | None:
    if type(channel) is int:
        return channel if channel in CHANNEL_BY_CODE else None
    if isinstance(channel, str):
        return CHANNEL_BY_NAME.get(channel.lower())
    return None


def _normalize_mode(mode: object) -> int | None:
    if type(mode) is int:
        return mode if mode in (MODE_LIVE, MODE_EVALUATION) else None
    if isinstance(mode, str):
        return MODE_BY_NAME.get(mode.lower())
    return None


@dataclass(frozen=True, repr=False)
class EntraSendOtpPayload:
    type: str
    tenant_id: str | None
    correlation_id: str | None
    channel: int
    mode: int
    ttl_seconds: int | None
    encrypted_delivery_context: str

    @classmethod
    def from_payload(cls, payload: object) -> tuple["EntraSendOtpPayload | None", str | None]:
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
            if type(ttl_seconds) is not int or ttl_seconds > 2147483647:
                return None, "invalid ttlSeconds"
            if ttl_seconds <= 0:
                return None, "ttlSeconds expired"
        return cls(
            type=payload.get("type"),
            tenant_id=payload.get("tenantId") if isinstance(payload.get("tenantId"), str) else None,
            correlation_id=(
                payload.get("correlationId")
                if isinstance(payload.get("correlationId"), str) and payload.get("correlationId")
                else None
            ),
            channel=channel,
            mode=mode,
            ttl_seconds=ttl_seconds,
            encrypted_delivery_context=encrypted,
        ), None

    @property
    def channel_name(self) -> str:
        return CHANNEL_BY_CODE[self.channel]

    @property
    def is_evaluation(self) -> bool:
        return self.mode == MODE_EVALUATION


@dataclass(frozen=True, repr=False)
class RiskContext:
    scenario: str | None = None
    ip_address: str | None = None
    additional_properties: dict[str, object] = field(default_factory=dict)

    def __post_init__(self):
        if any(value is not None and not isinstance(value, str)
               for value in (self.scenario, self.ip_address)):
            raise ValueError("invalid risk context field")

    @classmethod
    def from_payload(cls, payload: object) -> "RiskContext | None":
        if payload is None or isinstance(payload, cls):
            return payload
        if not isinstance(payload, dict):
            raise ValueError("invalid risk context")
        return cls(
            scenario=payload.get("scenario"),
            ip_address=payload.get("ipAddress"),
            additional_properties={
                key: value for key, value in payload.items() if key not in ("scenario", "ipAddress")
            },
        )

    def to_payload(self) -> dict[str, object]:
        payload = dict(self.additional_properties)
        if self.scenario is not None:
            payload["scenario"] = self.scenario
        if self.ip_address is not None:
            payload["ipAddress"] = self.ip_address
        return payload


@dataclass(frozen=True, repr=False)
class DeliveryContext:
    # Keep required strings and OTP raw until is_complete validates their types.
    nonce: object
    phone_number: object
    message: object
    locale: object = None
    extension: object = None
    risk_context: RiskContext | None = None
    otp: object = None

    @classmethod
    def from_payload(cls, payload: object) -> "DeliveryContext | None":
        if not isinstance(payload, dict):
            return None
        risk_context = payload.get("riskContext")
        if risk_context is not None and not isinstance(risk_context, dict):
            return None
        return cls(
            nonce=payload.get("nonce"),
            phone_number=payload.get("phoneNumber"),
            message=payload.get("message"),
            locale=payload.get("locale") if isinstance(payload.get("locale"), str) else None,
            extension=payload.get("extension"),
            risk_context=RiskContext.from_payload(risk_context),
            otp=payload.get("otp"),
        )

    @property
    def is_complete(self) -> bool:
        return all(
            isinstance(value, str) and value.strip()
            for value in (self.nonce, self.phone_number, self.message)
        ) and (self.otp is None or isinstance(self.otp, str))


@dataclass(frozen=True, repr=False)
class OtpDelivery:
    phone_number: str
    message: str | None
    channel: str
    message_id: str
    correlation_id: str | None
    locale: str | None
    otp: str | None = None
    risk_context: RiskContext | None = None


class Outcome(str, Enum):
    CONTINUE = "Continue"
    FAIL = "Fail"
    BLOCK = "Block"


@dataclass(frozen=True, repr=False)
class ProviderResult:
    outcome: Outcome
    status_recognized: bool
    provider_http_status: int
    provider_message_id: str | None = None
    provider_status_name: str | None = None
    provider_status_code: str | None = None
    provider_status_description: str | None = None
    failure_reason: str | None = None