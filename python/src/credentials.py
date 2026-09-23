import json
import logging
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from contextvars import ContextVar

from azure.identity import ClientAssertionCredential, ManagedIdentityCredential

from .refreshing_cache import CacheEntry, RefreshingCache, token_entry

_acquiring = ContextVar("epp_credential_acquisition", default=False)


class _CredentialLogFilter(logging.Filter):
    def filter(self, record):
        return not (_acquiring.get() and record.name.startswith(("azure.identity", "azure.core", "msal")))


_log_filter = _CredentialLogFilter()


def report_refresh_failure(kind):
    logging.warning("%s", json.dumps({"logType": "service", "eventName": "credential_refresh_failed",
                                     "cacheKind": kind, "failureReason": "credential_unavailable"}))


def _private_acquisition(load):
    for logger in (logging.getLogger(), *logging.Logger.manager.loggerDict.copy().values()):
        if isinstance(logger, logging.Logger):
            for handler in logger.handlers:
                if _log_filter not in handler.filters:
                    handler.addFilter(_log_filter)
    context = _acquiring.set(True)
    try:
        return load()
    finally:
        _acquiring.reset(context)


class ProviderCredentials:
    def __init__(self, secrets, *, cache_options=None, report_failure=report_refresh_failure):
        self._secrets = secrets
        self._options = cache_options or {}
        self._clock = self._options.get("clock", time.time)
        self._report_failure = report_failure
        self._lock = threading.RLock()
        self._key = None
        self._state = None

    def _cache(self, kind, load):
        return RefreshingCache(lambda: _private_acquisition(load), **{
            **self._options, "on_failure": lambda: self._report_failure(kind),
        })

    def resolve(self, auth, config):
        mode = auth.get("mode")
        if mode == "oauth" and not all((config.provider_tenant_id, config.provider_scope,
                                       config.outbound_client_id, config.outbound_managed_identity_client_id)):
            self.close()
            raise ValueError("provider OAuth token unavailable")
        if mode not in ("apiKey", "oauth"):
            self.close()
            raise ValueError("provider credential unavailable")
        key = ((mode, config.env.get("KEY_VAULT_URL"), config.env.get("AZURE_CLIENT_ID"),
                auth.get("key_vault_secret_name"), auth.get("identity_key_vault_secret_name")) if mode == "apiKey" else
               (mode, config.provider_tenant_id, config.outbound_client_id, config.outbound_managed_identity_client_id))
        with self._lock:
            if self._key != key:
                self.close()
                self._state = self._api_key_state(auth) if mode == "apiKey" else _private_acquisition(lambda: self._oauth_state(config))
                self._key = key
            state = self._state
            if mode == "apiKey":
                cache = state["bundle"]
            else:
                scope = config.provider_scope
                if scope not in state["tokens"]:
                    state["tokens"][scope] = self._cache("provider_token", lambda:
                        token_entry(state["credential"].get_token(scope, logging_enable=False), self._clock()))
                cache = state["tokens"][scope]
        try:
            value = cache.get()
        except Exception:
            raise ValueError("provider OAuth token unavailable" if mode == "oauth" else "provider credential unavailable") from None
        return dict(value) if mode == "apiKey" else {"mode": "oauth", "access_token": value.token}

    def _api_key_state(self, auth):
        def load():
            key_name = auth.get("key_vault_secret_name")
            identity_name = auth.get("identity_key_vault_secret_name")
            if not key_name:
                raise ValueError("provider credential unavailable")
            # Both secrets form one snapshot; do not publish a partial rotation.
            with ThreadPoolExecutor(max_workers=2) as pool:
                key_future = pool.submit(_private_acquisition, lambda: self._secrets.resolve(key_name))
                identity_future = pool.submit(_private_acquisition, lambda: self._secrets.resolve(identity_name)) if identity_name else None
                secret = key_future.result()
                identity = identity_future.result() if identity_future else ""
            if not isinstance(secret, str) or not secret.strip() or (identity_name and (
                    not isinstance(identity, str) or not identity.strip())):
                raise ValueError("provider credential unavailable")
            now = self._clock()
            return CacheEntry({"mode": "apiKey", "secret": secret, "identity": identity}, now + 300, now + 240)
        return {"bundle": self._cache("key_vault", load)}

    def _oauth_state(self, config):
        identity = ManagedIdentityCredential(client_id=config.outbound_managed_identity_client_id,
            retry_total=0, connection_timeout=2.5, read_timeout=2.5, logging_enable=False)
        assertion = self._cache("managed_identity", lambda:
            token_entry(identity.get_token("api://AzureADTokenExchange/.default", logging_enable=False), self._clock()))
        credential = ClientAssertionCredential(
            tenant_id=config.provider_tenant_id, client_id=config.outbound_client_id,
            func=lambda: assertion.get().token, authority="https://login.microsoftonline.com",
            retry_total=0, connection_timeout=2.5, read_timeout=2.5, logging_enable=False)
        return {"assertion": assertion, "credential": credential, "tokens": {}}

    def close(self):
        with self._lock:
            if self._state:
                if "bundle" in self._state:
                    self._state["bundle"].close()
                else:
                    self._state["assertion"].close()
                    for cache in self._state["tokens"].values():
                        cache.close()
            self._state = None
            self._key = None
