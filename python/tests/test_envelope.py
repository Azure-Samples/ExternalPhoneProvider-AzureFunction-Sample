"""Essential envelope validation, authenticated JWE, and rendered message preservation."""
import json

import pytest
from jwcrypto import jwe, jwk

from src.dispatch import (
    context_to_dispatch,
    decrypt_delivery_context,
    parse_envelope,
)

_KEY = jwk.JWK.generate(kty="RSA", size=2048, kid="test-key")
_PRIVATE_PEM = _KEY.export_to_pem(private_key=True, password=None).decode("utf-8")
_CONTEXT = {"nonce": "nonce-1", "phoneNumber": "+14255551234", "message": "Your code is 123456", "locale": "en-US"}
_ENVELOPE = {"type": "microsoft.mfa.otpDeliver.v1", "channel": 1, "mode": 1, "encryptedDeliveryContext": "x"}


@pytest.mark.parametrize("payload,error", [
    ([], "invalid envelope"),
    ({**_ENVELOPE, "type": "unsupported"}, "unsupported type"),
    ({**_ENVELOPE, "encryptedDeliveryContext": None}, "encryptedDeliveryContext is required"),
    ({**_ENVELOPE, "channel": "1"}, "unsupported channel"),
    ({**_ENVELOPE, "mode": True}, "unsupported mode"),
])
def test_malformed_envelope_categories(payload, error):
    assert parse_envelope(payload) == (None, error)


@pytest.mark.parametrize("ttl_seconds,error", [
    (None, "ttlSeconds must be a positive integer"),
    (True, "ttlSeconds must be a positive integer"),
    (0.5, "ttlSeconds must be a positive integer"),
    ("60", "ttlSeconds must be a positive integer"),
    (0, "passcode has expired"),
])
def test_invalid_or_expired_ttl(ttl_seconds, error):
    assert parse_envelope({**_ENVELOPE, "ttlSeconds": ttl_seconds}) == (None, error)


@pytest.mark.parametrize("channel,mode,expected,ttl", [
    (1, 1, (1, 1), {}), ("VOICE", "EVALUATION", (2, 2), {"ttlSeconds": 60}),
])
def test_valid_routing_and_optional_ttl(channel, mode, expected, ttl):
    envelope, error = parse_envelope({**_ENVELOPE, "channel": channel, "mode": mode, **ttl})
    assert error is None
    assert (envelope["channel"], envelope["mode"]) == expected
    assert envelope["ttl_seconds"] == ttl.get("ttlSeconds")


@pytest.fixture
def encrypted_context():
    protected = {"alg": "RSA-OAEP-256", "enc": "A256GCM", "kid": "test-key"}
    token = jwe.JWE(json.dumps(_CONTEXT).encode("utf-8"), protected=json.dumps(protected))
    token.add_recipient(_KEY)
    return token.serialize(compact=True)


def test_real_jwe_round_trip(encrypted_context):
    header, context = decrypt_delivery_context(encrypted_context, lambda _kid: _PRIVATE_PEM)
    assert header == {"alg": "RSA-OAEP-256", "enc": "A256GCM", "kid": "test-key"}
    assert context == _CONTEXT


def test_tampered_ciphertext_is_rejected(encrypted_context):
    parts = encrypted_context.split(".")
    parts[3] = ("A" if parts[3][0] != "A" else "B") + parts[3][1:]
    with pytest.raises(jwe.InvalidJWEData):
        decrypt_delivery_context(".".join(parts), lambda _kid: _PRIVATE_PEM)


@pytest.mark.parametrize("channel,expected,message", [
    (1, "sms", "Réf. 2026/42: code 123456; appelez +33 (0)1 23 45 67 89!\r\n"),
    (2, "voice", "  Votre code : 1 2 3 4 5 6. Référence 987654; montant 12,50 €!  "),
])
def test_context_mapping_preserves_rendered_message_bytes(channel, expected, message):
    envelope, _ = parse_envelope({**_ENVELOPE, "channel": channel, "correlationId": "corr-1"})
    dispatch = context_to_dispatch({**_CONTEXT, "message": message}, envelope, "msg-1")
    assert dispatch.destination == _CONTEXT["phoneNumber"]
    assert dispatch.locale == _CONTEXT["locale"]
    assert dispatch.channel == expected
    assert dispatch.message_id == "msg-1" and dispatch.correlation_id == "corr-1"
    assert dispatch.message.encode("utf-8") == message.encode("utf-8")
