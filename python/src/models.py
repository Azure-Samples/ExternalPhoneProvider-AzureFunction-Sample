from dataclasses import dataclass


@dataclass(repr=False)
class Envelope:
    type: str
    tenant_id: object
    correlation_id: object
    channel: int
    mode: int
    ttl_seconds: int | None
    encrypted_delivery_context: str


@dataclass(repr=False)
class DeliveryContext:
    # Keep raw JSON values until is_complete validates the required strings.
    nonce: object
    phone_number: object
    message: object
    locale: object = None
    extension: object = None
    risk_context: object = None

    @classmethod
    def from_payload(cls, payload: object) -> "DeliveryContext | None":
        if not isinstance(payload, dict):
            return None
        return cls(
            nonce=payload.get("nonce"),
            phone_number=payload.get("phoneNumber"),
            message=payload.get("message"),
            locale=payload.get("locale"),
            extension=payload.get("extension"),
            risk_context=payload.get("riskContext"),
        )

    @property
    def is_complete(self) -> bool:
        return all(
            isinstance(value, str) and value.strip()
            for value in (self.nonce, self.phone_number, self.message)
        )


@dataclass(repr=False)
class DispatchRequest:
    destination: str
    message: str | None
    channel: str
    message_id: str
    correlation_id: str | None
    locale: str | None