from __future__ import annotations

import os
from collections.abc import Mapping
from threading import Lock

from azure.identity import ManagedIdentityCredential
from azure.keyvault.secrets import SecretClient

from .refreshing_cache import ACQUISITION_TIMEOUT_SECONDS


class SecretResolver:
    def __init__(self, env: Mapping[str, str] | None = None) -> None:
        self._env = env if env is not None else os.environ
        self._client: SecretClient | None = None
        self._client_key: tuple[str, str | None] | None = None
        self._lock = Lock()

    def _get_client(self) -> SecretClient:
        vault_url = self._env.get("KEY_VAULT_URL")
        client_id = self._env.get("AZURE_CLIENT_ID")
        if not vault_url:
            raise RuntimeError("KEY_VAULT_URL not set")
        with self._lock:
            if self._client is None or self._client_key != (vault_url, client_id):
                credential = ManagedIdentityCredential(
                    client_id=client_id, logging_enable=False, retry_total=0,
                    connection_timeout=ACQUISITION_TIMEOUT_SECONDS, read_timeout=ACQUISITION_TIMEOUT_SECONDS,
                )
                self._client = SecretClient(
                    vault_url=vault_url, credential=credential, retry_total=0, logging_enable=False,
                    connection_timeout=ACQUISITION_TIMEOUT_SECONDS, read_timeout=ACQUISITION_TIMEOUT_SECONDS,
                )
                self._client_key = (vault_url, client_id)
            return self._client

    def resolve(self, secret_name: str | None) -> str:
        if not secret_name:
            return ""
        # ProviderCredentials caches the complete credential bundle and owns refresh.
        return self._get_client().get_secret(secret_name, logging_enable=False).value or ""
