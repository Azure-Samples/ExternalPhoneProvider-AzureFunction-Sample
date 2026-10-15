# External Phone Provider Function: Python (v2 model)

[Documentation](../docs/README.md) | [Settings](#environment-configuration) | [Request behavior](#request-behavior) | [Source](#source)

Implements the shared [contract](../docs/CONTRACT.md) with a direct Azure Function flow and one
selected provider per deployment. Target: Python 3.11, Azure Functions v4, Python v2 programming model.

## Setup and deployment

**Deploying the sample?** Use the [five-step guide](../docs/GETTING-STARTED.md).
Guided setup builds remotely and publishes; no local Python installation or second deployment.
Continue with [provider authentication and validation](../docs/ONBOARDING.md#complete-provider-authentication).
[Guided provider support](../docs/ONBOARDING.md#provider-credential-names) is narrower than the adapter set.

**Developing a custom package?** Follow these steps from `python/`:

1. Create the [local settings below](#environment-configuration). For live integration, choose a
   fixed provider ID from [providers/](src/providers/), configure its endpoints/options, and
   complete [provider authentication](../docs/ONBOARDING.md#complete-provider-authentication).
   No provider is selected by default.
2. Use a virtual environment, install [requirements.txt](requirements.txt) and pytest, and run
   [tests/](tests/). Start Core Tools here, **on loopback only, without tunnels**; it has no Easy Auth.
3. For manual deployment, publish this app to a compatible Linux Python Function with dependencies
   or a supported remote build. Inspect [.funcignore](.funcignore) and the package for private
   settings/keys. Complete the [Easy Auth trust checklist](../docs/ONBOARDING.md#manual-deployment-trust-checklist)
   before public access: it is the only caller-authentication gate; never disable it or exempt SendOtp.
   Run [authorized deployed checks](../docs/ONBOARDING.md#validate-the-deployed-endpoint);
   offline tests do not verify platform authentication.

**Optional:** [Front Door](../docs/FRONTDOOR.md) has no supplied deployment script/readiness handler.
Trials used JavaScript; independently implement and validate Python readiness and regional deployment.

## Environment configuration

Run Core Tools from `python/`. Create an untracked `local.settings.json` beside
[host.json](host.json), starting from the [shared sample](../docs/local.settings.sample.json).
For local evaluation, start Azurite and replace the test-key placeholder in this minimal setup:

```json
{
	"IsEncrypted": false,
	"Values": {
		"AzureWebJobsStorage": "UseDevelopmentStorage=true",
		"FUNCTIONS_WORKER_RUNTIME": "python",
		"EPP_DECRYPTION_KEY_PEM": "<base64 of your local test private PEM>"
	}
}
```

For live delivery, use the [shared settings table](../TECHNICAL.md#configure-environment-variables)
for `EPP_PROVIDER_NAME`, both channel endpoints, authentication, and adapter-specific options.
Keep values as strings, including `EPP_PROVIDER_TIMEOUT_MS: "1500"`. Replace placeholders;
API keys belong in provider-named Key Vault secrets, not this file.
A missing/invalid selected channel endpoint fails closed without fallback.

Core Tools loads `Values` into `os.environ`; direct Python execution and pytest do not.
[read_config](src/config.py) returns an `AppConfig`, and the handler reads its attributes.
Restart after edits. Core Tools cannot resolve Key Vault references locally, so use only a local
test PEM or base64 PEM. Never copy Azurite settings into Azure.

In Azure, configure the same app settings and use a Key Vault reference for the private PEM.
Provider secrets use managed identity, not a developer CLI login. Keep local evaluation on loopback.

## Request behavior

`POST /api/SendOtp` follows the [shared request/response contract](../docs/CONTRACT.md#1-http-api).
Easy Auth authenticates; JWE decryption, nonce values, and request fields do not.
The handler never parses or echoes incoming `Authorization`.

Use [`mode: 2` or `"evaluation"`](../docs/CONTRACT.md#evaluation-no-provider-send) for no-send validation:
authentication and decryption still run, but request-path provider lookup, credentials, and HTTP do not.
Live success waits for acceptance, **not handset receipt**; failures omit the nonce.
Never blindly retry a timeout.

For message/voice mapping, see the [Soprano delivery contract](../docs/CONTRACT.md#encrypteddeliverycontext-jwe)
and [Telesign integration](../TECHNICAL.md#telesign-epp).

## Source

Start with the provider-neutral
[BYOT request and response guide](../docs/BRING-YOUR-OWN-PROVIDER.md) for the Microsoft Entra ID payload,
caller authentication, and response rules. Your team owns the outbound service integration.

For deployed diagnostics, use [Application Insights](../docs/APPLICATION-INSIGHTS.md) and
[runtime-specific log discovery](../docs/MONITORING.md#runtime-specific-log-discovery).
Python emits fixed messages with `event_name` and other logging extras, not a universal JSON
request summary. Verify which properties the host/export pipeline preserves.

The [cache switches and defaults](../docs/CONTRACT.md#credential-caching-and-refresh) apply here.
Disabling the selected cache removes startup preparation, polling, and cross-request reuse,
not live credential acquisition.

With caching enabled, startup selects only the provider's API-key or OAuth cache. API keys use
Key Vault and `cachetools.TTLCache`; OAuth uses the managed-identity/Entra SDKs. A daemon polls
every 30 seconds; synchronous SDK calls use connect/read timeouts rather than one total deadline.
See the [refresh contract](../docs/CONTRACT.md#credential-caching-and-refresh). Leave the provider
unset for local evaluation without background credential acquisition.

| Source | Purpose |
|---|---|
| [function_app.py](function_app.py) | Typed request orchestration and direct provider selection |
| [src/config.py](src/config.py) | Shared deployment settings |
| [src/models.py](src/models.py) | Typed Entra payload, delivery context, provider request and result dataclasses |
| [src/jwe.py](src/jwe.py) | Pinned JWE decryption and typed delivery-context conversion |
| [src/provider.py](src/provider.py) | Shared HTTPS transport, timeout handling and endpoint status mapping |
| [src/credentials.py](src/credentials.py) | `CredentialTokenService`, `ApiKeyCache` and `AccessTokenCache` |
| [src/otp_log.py](src/otp_log.py) | Fixed standard-logging event definitions and immutable request context |
| [src/providers/](src/providers/) | Provider-owned credentials, requests and response mapping |
| [src/secrets.py](src/secrets.py) | Key Vault transport; bundle caching belongs to `ApiKeyCache` |

Add a provider by subclassing `PhoneProviderBase`, declaring its credential specification, and
implementing `build_request` and `map_response`. Return `ProviderResult` with the coarse endpoint
outcome and a fixed safe failure classification. Raw provider JSON remains local to the provider.
See [production limitations](../docs/CONTRACT.md#production-limitations) before production use.
