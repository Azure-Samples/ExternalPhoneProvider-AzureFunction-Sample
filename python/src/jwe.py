from __future__ import annotations

import base64
import json
from dataclasses import dataclass

from jwcrypto import jwe as jwe_module
from jwcrypto import jwk

from .config import read_config
from .models import DeliveryContext

MAX_JWE_LENGTH = 16384


@dataclass(frozen=True)
class DecryptedPayload:
    key_id: str | None
    value: DeliveryContext | None


class JweDecryptor:
    def __init__(self, env=None) -> None:
        self._env = env
        self._cached_pem: str | None = None
        self._cached_key: jwk.JWK | None = None

    def decrypt(self, encrypted_content: str) -> DecryptedPayload:
        self._assert_well_formed(encrypted_content)
        header = self._read_protected_header(encrypted_content)
        token = jwe_module.JWE(algs=["RSA-OAEP-256", "A256GCM"])
        token.deserialize(encrypted_content, key=self._get_private_key())
        payload = json.loads(token.payload.decode("utf-8"))
        return DecryptedPayload(header.get("kid"), DeliveryContext.from_payload(payload))

    def _get_private_key(self) -> jwk.JWK:
        pem = read_config(self._env).decryption_key_pem
        if not pem:
            raise ValueError("private key unavailable")
        if self._cached_key is None or self._cached_pem != pem:
            self._cached_key = jwk.JWK.from_pem(self._normalize_pem(pem).encode("utf-8"))
            self._cached_pem = pem
        return self._cached_key

    @staticmethod
    def _assert_well_formed(encrypted_content: str) -> None:
        if not isinstance(encrypted_content, str) or not encrypted_content:
            raise ValueError("malformed JWE")
        if len(encrypted_content) > MAX_JWE_LENGTH:
            raise ValueError("delivery context exceeds size limit")
        segments = encrypted_content.split(".")
        if len(segments) != 5 or not all(segments):
            raise ValueError("malformed JWE")

    @staticmethod
    def _read_protected_header(encrypted_content: str) -> dict:
        segment = encrypted_content.split(".", 1)[0]
        segment += "=" * (-len(segment) % 4)
        value = json.loads(base64.urlsafe_b64decode(segment))
        if not isinstance(value, dict):
            raise ValueError("invalid protected header")
        return value

    @staticmethod
    def _normalize_pem(value: str) -> str:
        if "-----BEGIN" in value:
            return value
        return base64.b64decode(value).decode("utf-8")
