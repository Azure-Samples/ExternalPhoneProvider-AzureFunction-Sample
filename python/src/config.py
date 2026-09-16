from __future__ import annotations

import os
from collections.abc import Mapping
from dataclasses import dataclass


@dataclass(repr=False)
class AppConfig:
    decryption_key_pem: str
    expected_key_id: str | None
    provider_name: str
    provider_endpoint: str | None
    provider_channel: str
    provider_auth_mode: str
    provider_tenant_id: str
    provider_scope: str
    outbound_client_id: str
    outbound_managed_identity_client_id: str
    provider_timeout_ms: str | None
    env: Mapping[str, str]


def read_config(env: Mapping[str, str] | None = None) -> AppConfig:
    env = os.environ if env is None else env
    return AppConfig(
        decryption_key_pem=env.get("EPP_DECRYPTION_KEY_PEM") or "",
        expected_key_id=env.get("EPP_ENCRYPTION_KEY_ID"),
        provider_name=(env.get("EPP_PROVIDER_NAME") or "").strip().lower(),
        provider_endpoint=env.get("EPP_PROVIDER_ENDPOINT"),
        provider_channel=(env.get("EPP_PROVIDER_CHANNEL") or "").strip().lower(),
        provider_auth_mode=(env.get("EPP_PROVIDER_AUTH_MODE") or "").strip(),
        provider_tenant_id=(env.get("EPP_PROVIDER_TENANT_ID") or "").strip(),
        provider_scope=(env.get("EPP_PROVIDER_SCOPE") or "").strip(),
        outbound_client_id=(env.get("EPP_OUTBOUND_CLIENT_ID") or "").strip(),
        outbound_managed_identity_client_id=(env.get("EPP_OUTBOUND_MI_CLIENT_ID") or "").strip(),
        provider_timeout_ms=env.get("EPP_PROVIDER_TIMEOUT_MS"),
        env=env,  # Preserve raw adapter settings and the injected environment.
    )