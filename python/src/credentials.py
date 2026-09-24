from __future__ import annotations

import json
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
from cachetools import TTLCache

from .config import AppConfig

API_KEY_MODE: Final = "apiKey"
OAUTH_MODE: Final = "oauth"
BUNDLE_KEY = "bundle"
TOKEN_EXCHANGE_SCOPE = "api://AzureADTokenExchange/.default"
CREDENTIAL_ERROR = "provider credential unavailable"
ACQUISITION_TIMEOUT_SECONDS = 2.5
REFRESH_POLL_SECONDS = 30
SECRET_TTL_SECONDS = 300
SECRET_REFRESH_SECONDS = 240
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


class RefreshOptions(TypedDict, total=False):
    clock: Callable[[], float]
    wait_timeout: float


class _CredentialLogFilter(logging.Filter):
    def filter(self, record: logging.LogRecord) -> bool:
        return not (_acquiring.get() and record.name.startswith(("azure.identity", "azure.core", "msal")))


_log_filter = _CredentialLogFilter()


def report_refresh_failure(kind: str) -> None:
    logging.warning("%s", json.dumps({"logType": "service", "eventName": "credential_refresh_failed",
                                     "cacheKind": kind, "failureReason": "credential_unavailable"}))


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


class ApiKeyCache:
    stage = "key_vault"

    def __init__(self, secrets: SecretReader, auth: Mapping[str, str], clock=time.time) -> None:
        self._secrets, self._auth, self._clock = secrets, dict(auth), clock
        self._values: TTLCache[str, ApiKeyCredential] = TTLCache(maxsize=1, ttl=SECRET_TTL_SECONDS, timer=clock)
        self._lock = threading.Lock()
        self._refresh_at = 0.0
        self._closed = False

    def get(self) -> ApiKeyCredential | None:
        with self._lock:
            value = None if self._closed else self._values.get(BUNDLE_KEY)
            return value.copy() if value is not None else None

    def _read(self, name: str) -> Future[str]:
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

    def refresh(self) -> None:
        if self.get() is not None and self._clock() < self._refresh_at:
            return
        key, account = self._auth.get("key_vault_secret_name"), self._auth.get("identity_key_vault_secret_name")
        if not key:
            raise ValueError(CREDENTIAL_ERROR)
        secret = self._read(key)
        identity = self._read(account) if account else None
        wait([secret, identity] if identity is not None else [secret])
        value, customer = secret.result(), identity.result() if identity is not None else ""
        if not value.strip() or (account and not customer.strip()):
            raise ValueError(CREDENTIAL_ERROR)
        with self._lock:
            if self._closed:
                raise ValueError(CREDENTIAL_ERROR)
            self._values[BUNDLE_KEY] = {"mode": API_KEY_MODE, "secret": value, "identity": customer}
            self._refresh_at = self._clock() + SECRET_REFRESH_SECONDS

    def stop(self) -> None:
        with self._lock:
            self._closed = True
            self._values.clear()


class AccessTokenCache:
    stage = "provider_token"

    def __init__(self, config: AppConfig, clock=time.time) -> None:
        if not all((config.provider_tenant_id, config.provider_scope, config.outbound_client_id,
                    config.outbound_managed_identity_client_id)):
            raise ValueError(CREDENTIAL_ERROR)
        self._clock, self._scope = clock, config.provider_scope
        self._lock = threading.Lock()
        self._closed = False
        self._token: Token | None = None
        self._identity = ManagedIdentityCredential(client_id=config.outbound_managed_identity_client_id,
            retry_total=0, logging_enable=False, connection_timeout=ACQUISITION_TIMEOUT_SECONDS,
            read_timeout=ACQUISITION_TIMEOUT_SECONDS)
        self._credential = ClientAssertionCredential(tenant_id=config.provider_tenant_id, client_id=config.outbound_client_id,
            func=lambda: self._load(self._identity, TOKEN_EXCHANGE_SCOPE).token,
            authority=AzureAuthorityHosts.AZURE_PUBLIC_CLOUD, retry_total=0, logging_enable=False,
            connection_timeout=ACQUISITION_TIMEOUT_SECONDS, read_timeout=ACQUISITION_TIMEOUT_SECONDS)

    def get(self) -> OAuthCredential | None:
        with self._lock:
            token = self._token
            return ({"mode": OAUTH_MODE, "access_token": token.token}
                    if not self._closed and token and token.expires_on > self._clock() + TOKEN_SKEW_SECONDS else None)

    def _load(self, credential: TokenCredential, scope: str) -> Token:
        info = getattr(credential, "get_token_info", None)
        token = info(scope) if callable(info) else credential.get_token(scope, logging_enable=False)
        if (not isinstance(token.token, str) or not token.token.strip() or not math.isfinite(token.expires_on)
                or token.expires_on <= self._clock() + TOKEN_SKEW_SECONDS):
            raise ValueError(CREDENTIAL_ERROR)
        return token

    def refresh(self) -> None:
        with self._lock:
            if self._closed:
                raise ValueError(CREDENTIAL_ERROR)
        self.stage = "managed_identity"
        self._load(self._identity, TOKEN_EXCHANGE_SCOPE)
        self.stage = "provider_token"
        token = self._load(self._credential, self._scope)
        with self._lock:
            if self._closed:
                raise ValueError(CREDENTIAL_ERROR)
            self._token = token

    def stop(self) -> None:
        with self._lock:
            self._closed = True
            self._token = None


class ProviderCredentials:
    """One selected cache and one refresh loop; configuration changes require a worker restart."""

    def __init__(self, secrets: SecretReader, *, cache_options: RefreshOptions | None = None,
                 report_failure: Callable[[str], None] = report_refresh_failure) -> None:
        options = cache_options or {}
        self._secrets, self._report_failure = secrets, report_failure
        self._clock = options.get("clock", time.time)
        self._wait_timeout = options.get("wait_timeout", ACQUISITION_TIMEOUT_SECONDS)
        self._lock = threading.RLock()
        self._stop = threading.Event()
        self.cache: ApiKeyCache | AccessTokenCache | None = None
        self._pending: Future[ApiKeyCredential | OAuthCredential] | None = None
        self._next_attempt = 0.0

    def resolve(self, auth: Mapping[str, str], config: AppConfig) -> ApiKeyCredential | OAuthCredential:
        with self._lock:
            if self._stop.is_set():
                raise ValueError(CREDENTIAL_ERROR)
            if self.cache is None:
                try:
                    if auth.get("mode") == API_KEY_MODE:
                        self.cache = ApiKeyCache(self._secrets, auth, self._clock)
                    elif auth.get("mode") == OAUTH_MODE:
                        self.cache = _private_acquisition(lambda: AccessTokenCache(config, self._clock))
                    else:
                        raise ValueError(CREDENTIAL_ERROR)
                except Exception:
                    self._report_failure("configuration")
                    raise ValueError(CREDENTIAL_ERROR) from None
                threading.Thread(target=self._loop, daemon=True).start()
            value = self.cache.get()
            if value is not None:
                return value
            pending = self.refresh()
        try:
            return pending.result(timeout=self._wait_timeout)
        except Exception:
            raise ValueError(CREDENTIAL_ERROR) from None

    def refresh(self) -> Future[ApiKeyCredential | OAuthCredential]:
        with self._lock:
            if self._stop.is_set() or self.cache is None:
                raise ValueError(CREDENTIAL_ERROR)
            if self._pending is not None:
                return self._pending
            if self._next_attempt > self._clock():
                raise ValueError(CREDENTIAL_ERROR)
            self._next_attempt = self._clock() + REFRESH_POLL_SECONDS
            future: Future[ApiKeyCredential | OAuthCredential] = Future()
            self._pending = future
            threading.Thread(target=self._run, args=(self.cache, future), daemon=True).start()
            return future

    def _run(self, cache: ApiKeyCache | AccessTokenCache, future: Future[ApiKeyCredential | OAuthCredential]) -> None:
        value = None
        try:
            _private_acquisition(cache.refresh)
            value = cache.get()
        except Exception:
            pass  # Report only the sanitized failure below.
        with self._lock:
            self._pending = None
            if not self._stop.is_set():
                if value is None:
                    self._report_failure(cache.stage)
                    future.set_exception(ValueError(CREDENTIAL_ERROR))
                else:
                    future.set_result(value)

    def _loop(self) -> None:
        while not self._stop.wait(REFRESH_POLL_SECONDS):
            try:
                self.refresh().result()
            except ValueError:
                pass  # Shared acquisition reports failures; cooldown is intentionally quiet.

    def close(self) -> None:
        with self._lock:
            self._stop.set()
            if self.cache is not None:
                self.cache.stop()
            if self._pending is not None and not self._pending.done():
                self._pending.set_exception(ValueError(CREDENTIAL_ERROR))
