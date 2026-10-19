from __future__ import annotations

import logging
import math
import threading
import time
from collections.abc import Callable, Mapping
from concurrent.futures import Future, wait
from contextvars import ContextVar
from typing import Final, Literal, Protocol, TypedDict, TypeVar

from azure.core.credentials import TokenCredential
from azure.identity import AzureAuthorityHosts, ClientAssertionCredential, ManagedIdentityCredential

from .config import AppConfig

API_KEY_MODE: Final = "apiKey"
OAUTH_MODE: Final = "oauth"
TOKEN_EXCHANGE_SCOPE = "api://AzureADTokenExchange/.default"
CREDENTIAL_ERROR = "provider credential unavailable"
ACQUISITION_TIMEOUT_SECONDS = 2.5
TOKEN_SKEW_SECONDS = 30
_acquiring = ContextVar("epp_credential_acquisition", default=False)
T = TypeVar("T")


class Token(Protocol):
    @property
    def token(self) -> str: ...
    @property
    def expires_on(self) -> float: ...


class SecretReader(Protocol):
    def resolve(self, secret_name: str) -> str: ...


class ApiKeyCredential(TypedDict):
    mode: Literal["apiKey"]
    secret: str
    identity: str


class OAuthCredential(TypedDict):
    mode: Literal["oauth"]
    access_token: str


class _CredentialLogFilter(logging.Filter):
    def filter(self, record: logging.LogRecord) -> bool:
        return not (_acquiring.get() and record.name.startswith(("azure.identity", "azure.core", "msal")))


_log_filter = _CredentialLogFilter()


def _private_acquisition(load: Callable[[], T]) -> T:
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


class CredentialTokenService:
    """Acquires request credentials using reusable Azure SDK clients."""

    def __init__(self, secrets: SecretReader, *, clock: Callable[[], float] = time.time,
                 wait_timeout: float = ACQUISITION_TIMEOUT_SECONDS) -> None:
        self._secrets, self._clock, self._wait_timeout = secrets, clock, wait_timeout
        self._lock = threading.Lock()
        self._identity: ManagedIdentityCredential | None = None
        self._credential: ClientAssertionCredential | None = None
        self._requests: set[Future[ApiKeyCredential | OAuthCredential]] = set()
        self._closed = False

    def get_credentials(self, provider, config: AppConfig) -> ApiKeyCredential | OAuthCredential:
        return self.resolve(provider.credential_spec, config)

    def resolve(self, spec: Mapping[str, str], config: AppConfig) -> ApiKeyCredential | OAuthCredential:
        with self._lock:
            if self._closed or spec.get("mode") not in (API_KEY_MODE, OAUTH_MODE):
                raise ValueError(CREDENTIAL_ERROR)
            pending: Future[ApiKeyCredential | OAuthCredential] = Future()
            self._requests.add(pending)
        threading.Thread(target=self._run, args=(spec, config, pending), daemon=True).start()
        try:
            return pending.result(timeout=self._wait_timeout)
        except Exception:
            with self._lock:
                pending.cancel()
            # The handler logs the failure without exposing SDK error details.
            raise ValueError(CREDENTIAL_ERROR) from None

    def _run(self, spec: Mapping[str, str], config: AppConfig,
             pending: Future[ApiKeyCredential | OAuthCredential]) -> None:
        value = None
        try:
            value = _private_acquisition(
                lambda: self._fetch_api_key(spec) if spec["mode"] == API_KEY_MODE else self._fetch_token(config))
        except Exception:
            # Publish only the sanitized error to the waiting request.
            value = None
        with self._lock:
            self._requests.discard(pending)
            if not pending.done():
                if value is None:
                    pending.set_exception(ValueError(CREDENTIAL_ERROR))
                else:
                    pending.set_result(value)
            close_clients = self._closed and not self._requests
        if close_clients:
            self._close_clients()

    def _read_secret(self, name: str) -> Future[str]:
        result: Future[str] = Future()

        def read() -> None:
            try:
                with self._lock:
                    if self._closed:
                        raise ValueError(CREDENTIAL_ERROR)
                result.set_result(_private_acquisition(lambda: self._secrets.resolve(name)))
            except Exception:
                result.set_exception(ValueError(CREDENTIAL_ERROR))

        # Executor threads are joined at exit; unfinished SDK reads must not block shutdown.
        threading.Thread(target=read, daemon=True).start()
        return result

    def _fetch_api_key(self, spec: Mapping[str, str]) -> ApiKeyCredential:
        key, account = spec.get("key_vault_secret_name"), spec.get("identity_key_vault_secret_name")
        if not key:
            raise ValueError(CREDENTIAL_ERROR)
        secret = self._read_secret(key)
        identity = self._read_secret(account) if account else None
        wait([secret, identity] if identity is not None else [secret])
        value, customer = secret.result(), identity.result() if identity is not None else ""
        if not value.strip() or (account and not customer.strip()):
            raise ValueError(CREDENTIAL_ERROR)
        return {"mode": API_KEY_MODE, "secret": value, "identity": customer}

    def _get_token_credential(self, config: AppConfig) -> ClientAssertionCredential:
        if not all((config.provider_tenant_id, config.provider_scope, config.outbound_client_id,
                    config.outbound_managed_identity_client_id)):
            raise ValueError(CREDENTIAL_ERROR)
        with self._lock:
            if self._closed:
                raise ValueError(CREDENTIAL_ERROR)
            if self._credential is None:
                identity = ManagedIdentityCredential(client_id=config.outbound_managed_identity_client_id,
                    retry_total=0, logging_enable=False, connection_timeout=ACQUISITION_TIMEOUT_SECONDS,
                    read_timeout=ACQUISITION_TIMEOUT_SECONDS)
                try:
                    credential = ClientAssertionCredential(
                        tenant_id=config.provider_tenant_id, client_id=config.outbound_client_id,
                        func=lambda: self._load(identity, TOKEN_EXCHANGE_SCOPE).token,
                        authority=AzureAuthorityHosts.AZURE_PUBLIC_CLOUD, retry_total=0, logging_enable=False,
                        connection_timeout=ACQUISITION_TIMEOUT_SECONDS, read_timeout=ACQUISITION_TIMEOUT_SECONDS)
                except Exception:
                    identity.close()
                    raise
                self._identity, self._credential = identity, credential
            return self._credential

    def _load(self, credential: TokenCredential, scope: str) -> Token:
        info = getattr(credential, "get_token_info", None)
        token = info(scope) if callable(info) else credential.get_token(scope, logging_enable=False)
        if (not isinstance(token.token, str) or not token.token.strip() or not math.isfinite(token.expires_on)
                or token.expires_on <= self._clock() + TOKEN_SKEW_SECONDS):
            raise ValueError(CREDENTIAL_ERROR)
        return token

    def _fetch_token(self, config: AppConfig) -> OAuthCredential:
        token = self._load(self._get_token_credential(config), config.provider_scope)
        return {"mode": OAUTH_MODE, "access_token": token.token}

    def close(self) -> None:
        with self._lock:
            self._closed = True
            for future in self._requests:
                if not future.done():
                    future.set_exception(ValueError(CREDENTIAL_ERROR))
            close_clients = not self._requests
        if close_clients:
            self._close_clients()

    def _close_clients(self) -> None:
        with self._lock:
            credential, identity = self._credential, self._identity
            self._credential = self._identity = None
        try:
            if credential is not None:
                credential.close()
        finally:
            if identity is not None:
                identity.close()
