"""Resolves Key Vault secret names to values via the Function's managed identity
(user-assigned when AZURE_CLIENT_ID is set, else system-assigned), cached briefly."""
import os
import time

from azure.identity import ManagedIdentityCredential
from azure.keyvault.secrets import SecretClient

CACHE_TTL_SECONDS = 5 * 60


class SecretResolver:
    def __init__(self):
        self._client = None
        self._cache = {}

    def _get_client(self):
        if self._client is None:
            vault_url = os.environ.get("KEY_VAULT_URL")
            if not vault_url:
                return None
            client_id = os.environ.get("AZURE_CLIENT_ID")
            credential = (
                ManagedIdentityCredential(client_id=client_id)
                if client_id
                else ManagedIdentityCredential()
            )
            self._client = SecretClient(vault_url=vault_url, credential=credential)
        return self._client

    def resolve(self, secret_name):
        if not secret_name:
            return ""
        cached = self._cache.get(secret_name)
        if cached and cached[1] > time.time():
            return cached[0]
        client = self._get_client()
        if client is None:
            raise RuntimeError("KEY_VAULT_URL not set")
        value = client.get_secret(secret_name).value or ""
        self._cache[secret_name] = (value, time.time() + CACHE_TTL_SECONDS)
        return value
