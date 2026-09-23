from __future__ import annotations

import json
import logging
import threading
import time
from collections.abc import Callable, Mapping
from concurrent.futures import Future, wait
from contextvars import ContextVar
from dataclasses import dataclass, field
from typing import Literal, Protocol, TypedDict, TypeVar

from azure.core.credentials import TokenCredential
from azure.identity import ClientAssertionCredential, ManagedIdentityCredential

from .config import AppConfig
from .refreshing_cache import (
    ACQUISITION_TIMEOUT_SECONDS,
    SECRET_REFRESH_INTERVAL_SECONDS,
    SECRET_TTL_SECONDS,
    CacheEntry,
    CacheOptions,
    RefreshingCache,
    Token,
    token_entry,
)

_acquiring = ContextVar("epp_credential_acquisition", default=False)
T = TypeVar("T")


class SecretReader(Protocol):
    def resolve(self, secret_name: str) -> str: ...


class ApiKeyCredential(TypedDict):
    mode: Literal["apiKey"]
    secret: str
    identity: str


class OAuthCredential(TypedDict):
    mode: Literal["oauth"]
    access_token: str


@dataclass(repr=False)
class _ApiKeyState:
    bundle: RefreshingCache[ApiKeyCredential]


@dataclass(repr=False)
class _OAuthState:
    assertion: RefreshingCache[Token]
    credential: TokenCredential
    tokens: dict[str, RefreshingCache[Token]] = field(default_factory=dict)


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


class ProviderCredentials:
    def __init__(
        self,
        secrets: SecretReader,
        *,
        cache_options: CacheOptions | None = None,
        report_failure: Callable[[str], None] = report_refresh_failure,
    ) -> None:
        self._secrets = secrets
        self._options: CacheOptions = cache_options or {}
        self._clock = self._options.get("clock", time.time)
        self._report_failure = report_failure
        self._lock = threading.RLock()
        self._key: tuple[str | None, ...] | None = None
        self._state: _ApiKeyState | _OAuthState | None = None
        self._closed = False

    def _cache(self, kind: str, load: Callable[[], CacheEntry[T]]) -> RefreshingCache[T]:
        options = self._options.copy()
        options["on_failure"] = lambda: self._report_failure(kind)
        return RefreshingCache(lambda: _private_acquisition(load), **options)

    def resolve(self, auth: Mapping[str, str], config: AppConfig) -> ApiKeyCredential | OAuthCredential:
        mode = auth.get("mode")
        scope = config.provider_scope
        with self._lock:
            if self._closed:
                raise ValueError("provider credential unavailable")
            if mode == "oauth" and not all((
                config.provider_tenant_id, scope,
                config.outbound_client_id, config.outbound_managed_identity_client_id,
            )):
                self._clear()
                raise ValueError("provider OAuth token unavailable")
            if mode not in ("apiKey", "oauth"):
                self._clear()
                raise ValueError("provider credential unavailable")
            key: tuple[str | None, ...]
            if mode == "apiKey":
                key = (
                    mode, config.env.get("KEY_VAULT_URL"), config.env.get("AZURE_CLIENT_ID"),
                    auth.get("key_vault_secret_name"), auth.get("identity_key_vault_secret_name"),
                )
            else:
                key = (
                    mode, config.provider_tenant_id,
                    config.outbound_client_id, config.outbound_managed_identity_client_id,
                )
            if self._key != key:
                self._clear()
                if mode == "apiKey":
                    self._state = self._api_key_state(auth)
                else:
                    self._state = _private_acquisition(lambda: self._oauth_state(config))
                self._key = key
            state = self._state
            if isinstance(state, _OAuthState) and scope not in state.tokens:
                credential = state.credential
                state.tokens[scope] = self._cache("provider_token", lambda: self._load_token(credential, scope))
        try:
            if isinstance(state, _ApiKeyState):
                return state.bundle.get().copy()
            if isinstance(state, _OAuthState):
                return {"mode": "oauth", "access_token": state.tokens[scope].get().token}
            raise ValueError("provider credential unavailable")
        except Exception:
            reason = "provider OAuth token unavailable" if mode == "oauth" else "provider credential unavailable"
            raise ValueError(reason) from None

    def _start_secret_read(self, name: str) -> Future[str]:
        future: Future[str] = Future()

        def read() -> None:
            try:
                with self._lock:
                    if self._closed:
                        raise ValueError("provider credential unavailable")
                value = _private_acquisition(lambda: self._secrets.resolve(name))
                future.set_result(value)
            except Exception:
                future.set_exception(ValueError("provider credential unavailable"))

        # Executor workers are joined before atexit, even when their parent is a daemon.
        threading.Thread(target=read, daemon=True).start()
        return future

    def _api_key_state(self, auth: Mapping[str, str]) -> _ApiKeyState:
        def load() -> CacheEntry[ApiKeyCredential]:
            key_name = auth.get("key_vault_secret_name")
            identity_name = auth.get("identity_key_vault_secret_name")
            if not key_name:
                raise ValueError("provider credential unavailable")
            key_future = self._start_secret_read(key_name)
            identity_future = self._start_secret_read(identity_name) if identity_name else None
            pending = [key_future]
            if identity_future is not None:
                pending.append(identity_future)
            # Keep one refresh in flight until both reads finish, even after a caller stops waiting.
            wait(pending)
            secret = key_future.result()
            identity = identity_future.result() if identity_future is not None else ""
            if not isinstance(secret, str) or not secret.strip() or (identity_name and (
                    not isinstance(identity, str) or not identity.strip())):
                raise ValueError("provider credential unavailable")
            now = self._clock()
            value: ApiKeyCredential = {"mode": "apiKey", "secret": secret, "identity": identity}
            return CacheEntry(value, now + SECRET_TTL_SECONDS, now + SECRET_REFRESH_INTERVAL_SECONDS)
        return _ApiKeyState(self._cache("key_vault", load))

    def _load_token(self, credential: TokenCredential, scope: str) -> CacheEntry[Token]:
        get_token_info = getattr(credential, "get_token_info", None)
        if callable(get_token_info):
            token = get_token_info(scope)
        else:
            # Older supported SDKs expose only expiry metadata through get_token.
            token = credential.get_token(scope, logging_enable=False)
        return token_entry(token, self._clock())

    def _oauth_state(self, config: AppConfig) -> _OAuthState:
        identity = ManagedIdentityCredential(
            client_id=config.outbound_managed_identity_client_id,
            retry_total=0, connection_timeout=ACQUISITION_TIMEOUT_SECONDS,
            read_timeout=ACQUISITION_TIMEOUT_SECONDS, logging_enable=False,
        )
        assertion = self._cache(
            "managed_identity", lambda: self._load_token(identity, "api://AzureADTokenExchange/.default"),
        )
        credential = ClientAssertionCredential(
            tenant_id=config.provider_tenant_id, client_id=config.outbound_client_id,
            func=lambda: assertion.get().token, authority="https://login.microsoftonline.com",
            retry_total=0, connection_timeout=ACQUISITION_TIMEOUT_SECONDS,
            read_timeout=ACQUISITION_TIMEOUT_SECONDS, logging_enable=False,
        )
        return _OAuthState(assertion, credential)

    def _clear(self) -> None:
        state = self._state
        if isinstance(state, _ApiKeyState):
            state.bundle.close()
        elif isinstance(state, _OAuthState):
            state.assertion.close()
            for cache in state.tokens.values():
                cache.close()
        self._state = None
        self._key = None

    def close(self) -> None:
        with self._lock:
            self._closed = True
            self._clear()
