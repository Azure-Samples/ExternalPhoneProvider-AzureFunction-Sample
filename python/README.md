# Python implementation

<a id="external-phone-provider-function-python-v2-model"></a>

[Documentation](../docs/README.md) | [Settings](#environment-configuration) | [Request behavior](#request-behavior) | [Source](#source)

Implements the shared [contract](../docs/CONTRACT.md) with one provider per deployment.
Target: Python 3.11, Azure Functions v4, Python v2 programming model.

## Setup and deployment

**Sample deployment:** follow the [five-step guide](../docs/GETTING-STARTED.md), then complete
[provider authentication and validation](../docs/ONBOARDING.md#complete-provider-authentication).

**Custom package development:** follow these steps from `python/`:

1. Create the [local settings below](#environment-configuration). Select a fixed provider ID from
   [providers/](src/providers/), configure it, and complete
   [provider authentication](../docs/ONBOARDING.md#complete-provider-authentication).
2. Use a virtual environment, install [requirements.txt](requirements.txt) and pytest, and run
   [tests/](tests/). Start Core Tools here, **on loopback only, without tunnels**; it has no Easy Auth.
3. For manual deployment, publish to a compatible Linux Python Function with dependencies or
   remote build. Inspect the package for private settings, complete the
   [Easy Auth trust checklist](../docs/ONBOARDING.md#manual-deployment-trust-checklist), and run
   [authorized deployed checks](../docs/ONBOARDING.md#validate-the-deployed-endpoint) to verify
   platform authentication.

**Regional continuity:** use the [Front Door guide](../docs/FRONTDOOR.md) and include
Python-specific package, startup, dependency, and telemetry checks.

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
Store API keys in provider-named Key Vault secrets. Each selected channel requires a valid
endpoint; an invalid or missing endpoint returns an error without using the other channel.

Core Tools loads `Values` into `os.environ`; direct Python and pytest do not. Restart after edits.
Use a local test PEM because Core Tools cannot resolve Key Vault references locally. Keep Azurite
settings local.

In Azure, configure the same app settings and use a Key Vault reference for the private PEM.
Provider secrets use managed identity, not a developer CLI login. Keep local evaluation on loopback.

## Request behavior

`POST /api/SendOtp` follows the [shared request/response contract](../docs/CONTRACT.md#1-http-api).
Easy Auth authenticates the caller. JWE decryption, nonce values, and request fields serve other
parts of the contract. The handler leaves incoming `Authorization` processing to Easy Auth and
does not echo it.

Use [`mode: 2` or `"evaluation"`](../docs/CONTRACT.md#evaluation-no-provider-send) to validate
authentication and decryption without a provider send. Live success confirms acceptance,
**not handset receipt**. Check a timeout before retrying.

For message/voice mapping, see the [Soprano delivery contract](../docs/CONTRACT.md#encrypteddeliverycontext-jwe)
and [Telesign integration](../TECHNICAL.md#telesign-epp).

## Source

Use the provider-neutral
[BYOT request and response guide](../docs/BRING-YOUR-OWN-PROVIDER.md) for the Microsoft Entra ID payload,
caller authentication, and response rules. Customers can connect the outbound phone service
that meets their requirements.

For diagnostics, use [Application Insights](../docs/APPLICATION-INSIGHTS.md) and
[runtime-specific log discovery](../docs/MONITORING.md#runtime-specific-log-discovery).
Verify which Python logging properties the host/export pipeline preserves.

The [cache switches and defaults](../docs/CONTRACT.md#credential-caching-and-refresh) apply here.
Disabling the selected cache removes startup preparation, polling, and cross-request reuse,
not live credential acquisition.

With caching enabled, API keys use Key Vault and `cachetools.TTLCache`; OAuth uses the
managed-identity/Entra SDKs. A daemon polls every 30 seconds. See the
[refresh contract](../docs/CONTRACT.md#credential-caching-and-refresh).

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
See [production-readiness considerations](../docs/CONTRACT.md#production-limitations) when planning a live service.
