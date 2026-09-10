import logging
from types import SimpleNamespace
from unittest.mock import Mock, call

import pytest
from azure.core.exceptions import ServiceRequestError

import src.dispatch as dispatch_module
import src.provider_tokens as tokens
from src.config import read_config
from src.dispatch import DispatchEngine, DispatchRequest, ProviderRegistry
from src.providers.infobip import InfobipProvider
from src.providers.sinch import SinchProvider
from src.providers.soprano import SopranoProvider
from src.providers.telesign import TelesignProvider


def _token(value="provider-token", expires_on=4600):
    return SimpleNamespace(token=value, expires_on=expires_on)


@pytest.fixture
def oauth(monkeypatch):
    monkeypatch.setattr(tokens.time, "time", lambda: 1000)
    credentials = []

    def make_credential(**kwargs):
        def get_token(scope):
            if "func" in kwargs:
                assert kwargs["func"]() == "exchange-token"
            return _token("exchange-token" if scope == tokens.TOKEN_EXCHANGE_SCOPE else "provider-token")

        credential = Mock(get_token=Mock(side_effect=get_token))
        credentials.append(credential)
        return credential

    constructors = [Mock(side_effect=make_credential) for _ in range(3)]
    for name, constructor in zip(("ClientSecretCredential", "ManagedIdentityCredential", "ClientAssertionCredential"), constructors):
        monkeypatch.setattr(tokens, name, constructor)
    send = Mock(return_value=Mock(status_code=202, json=Mock(return_value={"status": "ENROUTE"})))
    monkeypatch.setattr(dispatch_module.requests, "request", send)
    env = {
        "EPP_PROVIDER_NAME": "soprano", "EPP_PROVIDER_AUTH_MODE": "OAUTH2",
        "EPP_PROVIDER_JWT_ENABLED": "true",
        "EPP_PROVIDER_ENDPOINT": "https://provider.example/cgpapi",
        "EPP_PROVIDER_TENANT_ID": "tenant-id", "EPP_PROVIDER_CLIENT_ID": "client-id",
        "EPP_PROVIDER_SCOPE": "api://provider/.default", "EPP_PROVIDER_CLIENT_SECRET_NAME": "provider-client-secret",
        "KEY_VAULT_URL": "https://vault.example", "AZURE_CLIENT_ID": "vault-identity",
    }
    secrets = Mock(resolve=Mock(return_value="resolved-client-secret"))
    registry = ProviderRegistry([SopranoProvider(), InfobipProvider(), SinchProvider(), TelesignProvider()])
    engine = DispatchEngine(registry, secrets, env, token_acquirer=tokens.ProviderTokenAcquirer())
    request = DispatchRequest("+15551234567", "Code: 1 2 3 4; keep 5678.", "sms", "message", "correlation", None)
    return SimpleNamespace(engine=engine, request=request, env=env, secrets=secrets, send=send,
                           constructors=constructors, credentials=credentials)


def test_api_key_defaults_and_disabled_gate_skip_all_token_work(oauth, monkeypatch):
    oauth.env.pop("EPP_PROVIDER_AUTH_MODE")
    oauth.env.pop("EPP_PROVIDER_JWT_ENABLED")
    oauth.env.update(EPP_PROVIDER_CLIENT_SECRET="forbidden", EPP_PROVIDER_TENANT_ID="")
    read, acquire = Mock(), Mock()
    monkeypatch.setattr(tokens.ProviderTokenConfig, "read", read)
    oauth.engine.token_acquirer.acquire = acquire
    for flag in (None, " FaLsE "):
        if flag is not None:
            oauth.env.update(EPP_PROVIDER_AUTH_MODE=" ApiKey ", EPP_PROVIDER_JWT_ENABLED=flag)
        assert read_config(oauth.env).provider_jwt_enabled is False
        assert oauth.engine.dispatch(oauth.request, "r")[0] == 200
    read.assert_not_called()
    acquire.assert_not_called()
    for constructor in oauth.constructors:
        constructor.assert_not_called()


def test_invalid_auth_modes_and_provider_gates_precede_all_io(oauth):
    invalid = [
        {"EPP_PROVIDER_AUTH_MODE": ""},
        {"EPP_PROVIDER_AUTH_MODE": "unsupported", "EPP_PROVIDER_JWT_ENABLED": "false"},
        {"EPP_PROVIDER_AUTH_MODE": "apiKey", "EPP_PROVIDER_JWT_ENABLED": "on"},
        {"EPP_PROVIDER_JWT_ENABLED": "false"},
        *({"EPP_PROVIDER_JWT_ENABLED": flag} for flag in ("", " ", "1", "0", "yes", "on", "false true")),
        *({"EPP_PROVIDER_NAME": name, "EPP_PROVIDER_AUTH_MODE": mode}
          for name in ("infobip", "sinch", "telesign") for mode in ("apiKey", "oauth2")),
    ]
    for changes in invalid:
        oauth.engine.env = {**oauth.env, **changes}
        status, body = oauth.engine.dispatch(oauth.request, "r")
        assert status == 502 and body["outcome"] == "Fail", changes
    oauth.secrets.resolve.assert_not_called()
    oauth.send.assert_not_called()
    for constructor in oauth.constructors:
        constructor.assert_not_called()


def test_client_secret_sdk_reuse_rotation_and_configuration_invalidation(oauth):
    oauth.env.update(EPP_PROVIDER_AUTH_MODE=" OAuth2 ", EPP_PROVIDER_JWT_ENABLED=" TrUe ")
    secret_constructor, mi_constructor, assertion_constructor = oauth.constructors
    for _ in range(2):
        engine = DispatchEngine(oauth.engine.registry, oauth.secrets, oauth.env, oauth.engine.token_acquirer)
        assert engine.dispatch(oauth.request, "r")[0] == 200
    options = dict(connection_timeout=1.5, read_timeout=1.5, retry_total=0, logging_enable=False)
    secret_constructor.assert_called_once_with(
        tenant_id="tenant-id", client_id="client-id", client_secret="resolved-client-secret",
        authority="https://login.microsoftonline.com", **options,
    )
    assert oauth.credentials[0].get_token.call_args_list == [call("api://provider/.default")] * 2
    assert oauth.secrets.resolve.call_args_list == [call("provider-client-secret")] * 2
    assert not oauth.engine.token_acquirer._lock.locked()
    assert not tokens._acquiring_token.get()
    config = tokens.ProviderTokenConfig.read(read_config(oauth.env), "soprano", 1.5)
    for private in (*oauth.env.values(), "resolved-client-secret", "provider-token"):
        assert private not in repr(config) + repr(oauth.engine.token_acquirer)

    oauth.secrets.resolve.return_value = "rotated-client-secret"
    assert oauth.engine.dispatch(oauth.request, "r")[0] == 200
    oauth.credentials[0].close.assert_called_once()
    assert secret_constructor.call_args.kwargs["client_secret"] == "rotated-client-secret"
    # Every identity/source/endpoint setting and transport timeout participates in the one-entry key.
    for name, value in (
        ("EPP_PROVIDER_ENDPOINT", "https://other-provider.example"),
        ("EPP_PROVIDER_TENANT_ID", "other-tenant"), ("EPP_PROVIDER_CLIENT_ID", "other-client"),
        ("EPP_PROVIDER_SCOPE", "resource/.default"), ("EPP_PROVIDER_CLIENT_SECRET_NAME", "other-secret"),
        ("KEY_VAULT_URL", "https://other-vault.example"), ("AZURE_CLIENT_ID", "other-vault-identity"),
        ("EPP_PROVIDER_TIMEOUT_MS", "99999"),
    ):
        previous = oauth.credentials[-1]
        count = secret_constructor.call_count
        oauth.env[name] = value
        assert oauth.engine.dispatch(oauth.request, "r")[0] == 200
        previous.close.assert_called_once()
        assert secret_constructor.call_count == count + 1
    assert secret_constructor.call_args.kwargs["connection_timeout"] == 2.5
    assert secret_constructor.call_args.kwargs["read_timeout"] == 2.5
    oauth.credentials[-1].get_token.assert_called_once_with("resource/.default")
    mi_constructor.assert_not_called()
    assertion_constructor.assert_not_called()
    assert DispatchEngine(None, None).token_acquirer is DispatchEngine(None, None).token_acquirer


def test_managed_identity_assertion_exchange_uses_two_scopes_and_reuses_pair(oauth):
    oauth.env.pop("EPP_PROVIDER_CLIENT_SECRET_NAME")
    oauth.env.update(EPP_PROVIDER_MI_CLIENT_ID="mi-id", EPP_PROVIDER_TIMEOUT_MS="invalid")
    secret_constructor, mi_constructor, assertion_constructor = oauth.constructors
    for _ in range(2):
        assert oauth.engine.dispatch(oauth.request, "r")[0] == 200
    options = dict(connection_timeout=1.5, read_timeout=1.5, retry_total=0, logging_enable=False)
    mi_constructor.assert_called_once_with(client_id="mi-id", **options)
    assertion_constructor.assert_called_once_with(
        tenant_id="tenant-id", client_id="client-id", func=assertion_constructor.call_args.kwargs["func"],
        authority="https://login.microsoftonline.com", **options,
    )
    identity, assertion = oauth.credentials
    assert identity.get_token.call_args_list == [call("api://AzureADTokenExchange/.default")] * 2
    assert assertion.get_token.call_args_list == [call("api://provider/.default")] * 2
    assert oauth.send.call_args.kwargs["headers"]["Authorization"] == "Bearer provider-token"
    oauth.env["EPP_PROVIDER_MI_CLIENT_ID"] = "replacement-mi"
    assert oauth.engine.dispatch(oauth.request, "r")[0] == 200
    identity.close.assert_called_once()
    assertion.close.assert_called_once()
    assert mi_constructor.call_count == assertion_constructor.call_count == 2
    secret_constructor.assert_not_called()
    oauth.secrets.resolve.assert_not_called()
    oauth.env["EPP_PROVIDER_AUTH_MODE"] = " ApiKey "
    assert oauth.engine.dispatch(oauth.request, "r")[0] == 200
    assert oauth.secrets.resolve.call_args_list == [call("soprano-api-key"), call("soprano-api-id")]
    assert oauth.send.call_args.kwargs["headers"]["Authorization"] == "Bearer provider-token"
    assert oauth.send.call_args.kwargs["headers"]["X-MEMS-API-Key"] == "resolved-client-secret"
    assert mi_constructor.call_count == assertion_constructor.call_count == 2


@pytest.mark.parametrize("auth_mode", ["apiKey", "oauth2"])
def test_token_config_and_sdk_failures_follow_required_or_optional_policy(oauth, caplog, auth_mode):
    oauth.env["EPP_PROVIDER_AUTH_MODE"] = auth_mode
    optional = auth_mode == "apiKey"
    key_calls = [call("soprano-api-key"), call("soprano-api-id")] if optional else []

    def check_failure(expected):
        oauth.send.reset_mock()
        oauth.secrets.resolve.reset_mock()
        status, body = oauth.engine.dispatch(oauth.request, "r")
        assert status == (200 if optional else expected)
        assert "PRIVATE" not in str(body) + caplog.text
        if optional:
            assert oauth.secrets.resolve.call_args_list[:2] == key_calls
            oauth.send.assert_called_once()
            assert oauth.send.call_args.kwargs["headers"] == {
                "Content-Type": "application/json", "Accept": "application/json",
                "X-MEMS-API-ID": "resolved-client-secret", "X-MEMS-API-Key": "resolved-client-secret",
            }
        else:
            oauth.send.assert_not_called()

    # One representative per field/danger class, not a field-by-character cross product.
    invalid = [
        *({name: ""} for name in ("EPP_PROVIDER_TENANT_ID", "EPP_PROVIDER_CLIENT_ID",
                                 "EPP_PROVIDER_SCOPE", "EPP_PROVIDER_CLIENT_SECRET_NAME")),
        *({"EPP_PROVIDER_TENANT_ID": tenant} for tenant in ("COMMON", "Organizations", "consumers", "AdFs", "tenant/common")),
        {"EPP_PROVIDER_CLIENT_ID": " client"}, {"EPP_PROVIDER_SCOPE": "res ource/.default"},
        {"EPP_PROVIDER_CLIENT_SECRET_NAME": "secret\x7f"}, {"AZURE_CLIENT_ID": "vault\u00e9"},
        {"EPP_PROVIDER_MI_CLIENT_ID": "mi\x01", "EPP_PROVIDER_CLIENT_SECRET_NAME": ""},
        {"EPP_PROVIDER_MI_CLIENT_ID": "mi-id"},  # Ambiguous secret + federation sources.
        *({"KEY_VAULT_URL": url} for url in ("", "http://vault.example", "https://", "https://user@vault.example",
                                            "https://vault.example/#fragment", "https://vault.example:0")),
        *({"EPP_PROVIDER_SCOPE": scope} for scope in ("/.default", "api://provider", "api://p/.default\r\n")),
        {"EPP_PROVIDER_CLIENT_SECRET": ""}, {"EPP_PROVIDER_TOKEN_EXCHANGE_AUDIENCE": ""},
    ]
    for changes in invalid:
        oauth.engine.env = {**oauth.env, **changes}
        check_failure(502)
        assert oauth.secrets.resolve.call_args_list == key_calls, changes
    oauth.engine.env = oauth.env
    for constructor in oauth.constructors:
        constructor.assert_not_called()

    sdk_logger = logging.getLogger("azure.identity._internal.get_token_mixin")
    # Simulate an in-flight cached credential: a waiter must neither close it nor release its lock.
    acquirer = oauth.engine.token_acquirer
    acquirer._credential = Mock()
    oauth.env["EPP_PROVIDER_TIMEOUT_MS"] = "1"
    acquirer._lock.acquire()
    try:
        check_failure(504)
        assert acquirer._lock.locked() and not tokens._acquiring_token.get()
        acquirer._credential.close.assert_not_called()
        assert oauth.secrets.resolve.call_args_list == key_calls
        for constructor in oauth.constructors:
            constructor.assert_not_called()
    finally:
        acquirer._lock.release()
        oauth.env.pop("EPP_PROVIDER_TIMEOUT_MS")
    credential = Mock()
    oauth.constructors[0].side_effect = None
    oauth.constructors[0].return_value = credential
    results = (None, *(_token(value) for value in ("", " ", "two tokens", "token\r\n", "token\x01", "token\x7f", "t\u00f6ken")),
               *(_token(expires_on=value) for value in (None, 999, 1060, float("nan"), float("inf"))),
               RuntimeError("PRIVATE-SDK-DETAILS"), ServiceRequestError("PRIVATE-SDK-DETAILS", error=TimeoutError()))
    for result in results:
        def get_token(scope):
            sdk_logger.warning("PRIVATE-SDK-DETAILS")
            if isinstance(result, Exception):
                raise result
            return result

        credential.get_token = Mock(side_effect=get_token)
        check_failure(504 if isinstance(result, ServiceRequestError) else 502)
        credential.get_token.assert_called_once_with("api://provider/.default")
        assert not oauth.engine.token_acquirer._lock.locked() and not tokens._acquiring_token.get()
    oauth.constructors[0].side_effect = RuntimeError("PRIVATE-CONSTRUCTOR-DETAILS")
    oauth.engine.token_acquirer = tokens.ProviderTokenAcquirer()
    check_failure(502)
    for secret in (None, "", " ", RuntimeError("PRIVATE-VAULT-DETAILS")):
        # Resolve required API keys first, then return/raise the client-secret result.
        oauth.secrets.resolve.side_effect = ["resolved-client-secret"] * len(key_calls) + [secret]
        oauth.constructors[0].reset_mock()
        check_failure(502)
        oauth.constructors[0].assert_not_called()
    oauth.constructors[1].assert_not_called()
    oauth.constructors[2].assert_not_called()
    assert "PRIVATE" not in caplog.text
    sdk_logger.warning("outside-acquisition")
    assert "outside-acquisition" in caplog.text


def test_invalid_federation_assertion_stops_before_provider_token_or_delivery(oauth):
    oauth.env.pop("EPP_PROVIDER_CLIENT_SECRET_NAME")
    oauth.env["EPP_PROVIDER_MI_CLIENT_ID"] = "mi-id"
    identity = Mock(get_token=Mock(return_value=_token("exchange-token", expires_on=1000)))
    oauth.constructors[1].side_effect = None
    oauth.constructors[1].return_value = identity
    assert oauth.engine.dispatch(oauth.request, "r")[0] == 502
    identity.get_token.assert_called_once_with(tokens.TOKEN_EXCHANGE_SCOPE)
    oauth.engine.token_acquirer = tokens.ProviderTokenAcquirer()
    oauth.constructors[2].side_effect = RuntimeError("PRIVATE-CONSTRUCTOR-DETAILS")
    assert oauth.engine.dispatch(oauth.request, "r")[0] == 502
    identity.close.assert_called_once()
    oauth.send.assert_not_called()
    oauth.secrets.resolve.assert_not_called()