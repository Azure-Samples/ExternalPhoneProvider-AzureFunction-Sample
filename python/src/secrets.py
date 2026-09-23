import os
from threading import Lock

from azure.identity import ManagedIdentityCredential
from azure.keyvault.secrets import SecretClient

class SecretResolver:
    def __init__(self, env=None):
        self._env = env if env is not None else os.environ
        self._client = None
        self._client_key = None
        self._lock = Lock()

    def _get_client(self):
        vault_url = self._env.get("KEY_VAULT_URL")
        client_id = self._env.get("AZURE_CLIENT_ID")
        if not vault_url:
            raise RuntimeError("KEY_VAULT_URL not set")
        with self._lock:
            if self._client_key != (vault_url, client_id):
                credential = ManagedIdentityCredential(client_id=client_id, logging_enable=False,
                    retry_total=0, connection_timeout=2.5, read_timeout=2.5)
                self._client = SecretClient(vault_url=vault_url, credential=credential,
                    retry_total=0, connection_timeout=2.5, read_timeout=2.5, logging_enable=False)
                self._client_key = (vault_url, client_id)
            return self._client

    def resolve(self, secret_name):
        if not secret_name:
            return ""
        # ProviderCredentials caches the complete credential bundle and owns refresh.
        return self._get_client().get_secret(secret_name, logging_enable=False).value or ""
