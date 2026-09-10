import logging
import math
import time
from contextvars import ContextVar
from dataclasses import dataclass
from threading import Lock
from urllib.parse import urlsplit

from azure.identity import ClientAssertionCredential, ClientSecretCredential, ManagedIdentityCredential
from requests.exceptions import Timeout as RequestsTimeout
from urllib3.exceptions import TimeoutError as UrllibTimeout

TOKEN_EXCHANGE_SCOPE = "api://AzureADTokenExchange/.default"

# logging_enable=False controls HTTP tracing, not Identity's exception/account diagnostics.
# Filter only this synchronous acquisition's records, without muting concurrent invocations.
_acquiring_token = ContextVar("acquiring_provider_token", default=False)


class _SdkLogFilter(logging.Filter):
    def filter(self, record):
        return not _acquiring_token.get()


_sdk_log_filter = _SdkLogFilter()


def _filter_sdk_logs():
    for name, logger in tuple(logging.Logger.manager.loggerDict.items()):
        if isinstance(logger, logging.Logger) and (name.startswith("azure.") or name == "msal" or name.startswith("msal.")):
            logger.addFilter(_sdk_log_filter)


def valid_bearer_token(value):
    return isinstance(value, str) and bool(value) and all(32 < ord(character) < 127 for character in value)


def _valid_vault_url(value):
    if not isinstance(value, str) or not value.lower().startswith("https://") or any(
        character.isspace() or ord(character) < 32 or character in "\\#" for character in value
    ):
        return False
    try:
        url = urlsplit(value)
        return (url.scheme == "https" and bool(url.hostname) and url.username is None and url.password is None
                and not url.fragment and not url.netloc.endswith(":") and (url.port is None or url.port > 0))
    except ValueError:
        return False


@dataclass(frozen=True, repr=False)
class ProviderTokenConfig:
    provider_id: str
    endpoint: str
    tenant_id: str
    client_id: str
    scope: str
    client_secret_name: str
    mi_client_id: str
    vault_url: str
    vault_client_id: str
    timeout_seconds: float

    @classmethod
    def read(cls, config, provider_id, timeout_seconds):
        env = config.env
        tenant = env.get("EPP_PROVIDER_TENANT_ID") or ""
        client = env.get("EPP_PROVIDER_CLIENT_ID") or ""
        scope = env.get("EPP_PROVIDER_SCOPE") or ""
        secret_name = env.get("EPP_PROVIDER_CLIENT_SECRET_NAME") or ""
        mi_client = env.get("EPP_PROVIDER_MI_CLIENT_ID") or ""
        vault_url = env.get("KEY_VAULT_URL") or ""
        vault_client = env.get("AZURE_CLIENT_ID") or ""
        # Settings checks, not JWT verification; the SDK acquires/caches tokens, and the provider verifies them.
        required_settings = [tenant, client, scope, secret_name or mi_client]
        if vault_client:
            required_settings.append(vault_client)
        valid_settings = all(valid_bearer_token(value) for value in required_settings)

        valid_authority = valid_settings and (
            tenant.lower() not in ("common", "organizations", "consumers", "adfs")
            and all(character.isascii() and (character.isalnum() or character in "-.") for character in tenant)
            and scope.endswith("/.default") and scope != "/.default"
        )

        valid_credentials = (
            bool(secret_name) != bool(mi_client)
            and "EPP_PROVIDER_CLIENT_SECRET" not in env
            and "EPP_PROVIDER_TOKEN_EXCHANGE_AUDIENCE" not in env
            and (not secret_name or _valid_vault_url(vault_url))
        )

        if not (valid_settings and valid_authority and valid_credentials):
            raise ValueError("invalid provider token configuration")
        return cls(provider_id, config.provider_endpoint, tenant, client, scope, secret_name,
                   mi_client, vault_url, vault_client, timeout_seconds)


class ProviderTokenError(Exception):
    def __init__(self, timed_out=False):
        super().__init__("provider token unavailable")
        self.timed_out = timed_out


def _is_timeout(error):
    pending, seen = [error], set()
    while pending:
        current = pending.pop()
        if id(current) in seen:
            continue
        seen.add(id(current))
        if isinstance(current, (TimeoutError, RequestsTimeout, UrllibTimeout)):
            return True
        pending.extend(nested for nested in (
            current.__cause__, current.__context__, getattr(current, "inner_exception", None), *current.args
        ) if isinstance(nested, Exception))
    return False


def _validated_token(result):
    token = getattr(result, "token", None)
    expires_on = getattr(result, "expires_on", None)
    if (not valid_bearer_token(token) or type(expires_on) not in (int, float)
            or not math.isfinite(expires_on) or expires_on <= time.time() + 60):
        raise ProviderTokenError()
    return token


class ProviderTokenAcquirer:
    """One active credential (and its SDK token cache), never a custom token cache."""

    def __init__(self):
        self._lock = Lock()
        self._key = None
        self._credential = None
        self._managed_identity = None

    def _clear(self):
        for credential in (self._credential, self._managed_identity):
            if credential is not None:
                try:
                    credential.close()
                except Exception:
                    pass
        self._key = self._credential = self._managed_identity = None

    def acquire(self, config: ProviderTokenConfig, secrets):
        _filter_sdk_logs()
        logging_context = _acquiring_token.set(True)
        try:
            # Serialize use/replacement so a configuration change cannot close an in-flight credential.
            if not self._lock.acquire(timeout=config.timeout_seconds):
                raise ProviderTokenError(timed_out=True)
            try:
                secret = secrets.resolve(config.client_secret_name) if config.client_secret_name else ""
                if config.client_secret_name and (not isinstance(secret, str) or not secret.strip()):
                    raise ProviderTokenError()
                key = (config, secret)  # Includes the resolved secret so rotation replaces the SDK cache.
                if key != self._key:
                    self._clear()
                    # Synchronous connect/read limits, not a total wall-clock deadline. Provider HTTP is separate.
                    options = dict(connection_timeout=config.timeout_seconds, read_timeout=config.timeout_seconds,
                                   retry_total=0, logging_enable=False)
                    try:
                        if config.client_secret_name:
                            self._credential = ClientSecretCredential(
                                tenant_id=config.tenant_id, client_id=config.client_id, client_secret=secret,
                                authority="https://login.microsoftonline.com", **options,
                            )
                        else:
                            self._managed_identity = ManagedIdentityCredential(client_id=config.mi_client_id, **options)
                            identity = self._managed_identity

                            def assertion():
                                return _validated_token(identity.get_token(TOKEN_EXCHANGE_SCOPE))

                            self._credential = ClientAssertionCredential(
                                tenant_id=config.tenant_id, client_id=config.client_id, func=assertion,
                                authority="https://login.microsoftonline.com", **options,
                            )
                    except Exception:
                        self._clear()
                        raise
                    self._key = key
                _filter_sdk_logs()  # Include any loggers initialized by the credential constructors.
                return _validated_token(self._credential.get_token(config.scope))
            finally:
                self._lock.release()
        except ProviderTokenError:
            raise
        except Exception as error:
            raise ProviderTokenError(timed_out=_is_timeout(error)) from None
        finally:
            _acquiring_token.reset(logging_context)


# Reused even when callers construct an engine for each invocation. No I/O during construction.
default_token_acquirer = ProviderTokenAcquirer()