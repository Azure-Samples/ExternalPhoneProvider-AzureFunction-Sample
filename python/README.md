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
   [tests/](tests/). Start Core Tools here, **on loopback only, without tunnels**. It has no Easy Auth.
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
Keep values as strings, including `EPP_PROVIDER_TIMEOUT_MS: "1500"`. Replace the placeholders.
Store API keys in provider-named Key Vault secrets. Each selected channel requires a valid
endpoint. An invalid or missing endpoint returns an error without using the other channel.

Core Tools loads `Values` into `os.environ`. Direct Python and pytest do not. Restart after edits.
Use a local test PEM because Core Tools cannot resolve Key Vault references locally. Keep Azurite
settings local.

In Azure, configure the same app settings and use a Key Vault reference for the private PEM.
Provider secrets use managed identity, not a developer CLI login. Keep local evaluation on loopback.

## Request behavior

`POST /api/SendOtp` follows the [shared request/response contract](../docs/CONTRACT.md#1-http-api).
Easy Auth authenticates the caller. The handler then validates and decrypts the payload. It never
forwards or returns the incoming `Authorization` header.

Use [`mode: 2` or `"evaluation"`](../docs/CONTRACT.md#evaluation-no-provider-send) to validate
authentication and decryption without a provider send. Live success confirms acceptance,
**not handset receipt**. Check a timeout before retrying.

For built-in message and voice mapping, see
[Infobip, Soprano, and Telesign](../TECHNICAL.md#built-in-providers).

## Source

To add Twilio, follow the [Twilio integration guide](../docs/BRING-YOUR-OWN-PROVIDER.md).
Keep caller authentication and public responses in the shared handler.

For diagnostics, use [Application Insights](../docs/APPLICATION-INSIGHTS.md) and
[runtime-specific log discovery](../docs/MONITORING.md#runtime-specific-log-discovery).
Verify which Python logging properties the host/export pipeline preserves.

Each live request reads API-key secrets from Key Vault or calls the reusable Azure Identity
credential's token API. Only the SDK caches tokens and renews them as needed; there is no custom
credential cache, startup warmup, polling, or retry cooldown. Evaluation does no provider credential
work. Request-scoped daemon threads bound the caller's acquisition wait to 2.5 seconds without
blocking process shutdown. Timed-out results are discarded; SDK network timeouts bound the
underlying calls. See [credential acquisition](../TECHNICAL.md#provider-settings-and-credential-acquisition).

| Source | Purpose |
|---|---|
| [function_app.py](function_app.py) | Typed request orchestration and direct provider selection |
| [src/config.py](src/config.py) | Shared deployment settings |
| [src/models.py](src/models.py) | Typed Microsoft Entra ID payload, delivery context, provider request and result dataclasses |
| [src/jwe.py](src/jwe.py) | Pinned JWE decryption and typed delivery-context conversion |
| [src/provider.py](src/provider.py) | Shared HTTPS transport, timeout handling and endpoint status mapping |
| [src/credentials.py](src/credentials.py) | Bounded request-time acquisition and reusable SDK clients |
| [src/otp_log.py](src/otp_log.py) | Fixed standard-logging event definitions and immutable request context |
| [src/providers/](src/providers/) | Provider-owned credentials, requests and response mapping |
| [src/secrets.py](src/secrets.py) | Reusable Key Vault client; secret values are read on every live request |

Add a provider by subclassing `PhoneProviderBase`, declaring its credential specification, and
implementing `build_request` and `map_response`. Return `ProviderResult` with the coarse endpoint
outcome and a fixed safe failure classification. Raw provider JSON remains local to the provider.
See [production readiness](../TECHNICAL.md#production-readiness) when planning a live service.
