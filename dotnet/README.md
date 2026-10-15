# External Phone Provider Function: C# (.NET isolated worker)

[Documentation](../docs/README.md) | [Settings](#environment-configuration) | [Request behavior](#request-behavior) | [Source](#source)

Implements the shared [contract](../docs/CONTRACT.md) with one `SendOtp` request pipeline and one
selected provider per deployment. Target: .NET 8 isolated worker, Azure Functions v4.

## Setup and deployment

**Deploying the sample?** Use the [five-step guide](../docs/GETTING-STARTED.md).
Guided setup builds with the .NET 8 SDK and publishes. Continue with
[provider authentication and validation](../docs/ONBOARDING.md#complete-provider-authentication),
not a local host or second deployment.
[Guided provider support](../docs/ONBOARDING.md#provider-credential-names) is narrower than the adapter set.

**Developing a custom package?** Follow these steps from `dotnet/`:

1. Create the [local settings below](#environment-configuration). For live integration, choose an
   adapter's fixed `Name` from [Providers/](Src/Providers/), configure its endpoints/options, and
   complete [provider authentication](../docs/ONBOARDING.md#complete-provider-authentication).
   No provider is selected by default.
2. Build [dotnet.csproj](dotnet.csproj), run [xUnit tests](tests/Epp.Otp.Tests.csproj), and start
   Core Tools here, **on loopback only, without tunnels**; it has no Easy Auth.
3. For manual deployment, publish this app to a compatible .NET isolated Function App.
   Inspect the output and [.funcignore](.funcignore); the project excludes local settings, and
   private keys must not be packaged. Complete the
   [Easy Auth trust checklist](../docs/ONBOARDING.md#manual-deployment-trust-checklist) before public
   access: it is the only caller-authentication gate; never disable it or exempt SendOtp.
   Run [authorized deployed checks](../docs/ONBOARDING.md#validate-the-deployed-endpoint);
   offline tests do not verify platform authentication.

**Regional continuity:** use the [Front Door guide](../docs/FRONTDOOR.md) to implement and validate
the readiness route and regional deployment for .NET. The recorded trials used JavaScript, so
include .NET-specific package, startup, dependency, and telemetry checks.

## Environment configuration

Run Core Tools from `dotnet/`. Create an untracked `local.settings.json` beside
[host.json](host.json), starting from the [shared sample](../docs/local.settings.sample.json).
For local evaluation, start Azurite and replace the test-key placeholder in this minimal setup:

```json
{
	"IsEncrypted": false,
	"Values": {
		"AzureWebJobsStorage": "UseDevelopmentStorage=true",
		"FUNCTIONS_WORKER_RUNTIME": "dotnet-isolated",
		"EPP_DECRYPTION_KEY_PEM": "<base64 of your local test private PEM>"
	}
}
```

For live delivery, use the [shared settings table](../TECHNICAL.md#configure-environment-variables)
for `EPP_PROVIDER_NAME`, both channel endpoints, authentication, and adapter-specific options.
Keep values as strings, including `EPP_PROVIDER_TIMEOUT_MS`, for example `"1500"`.
Replace placeholders; credentials belong in the adapter's Key Vault secrets, not this file.
A missing/invalid selected channel endpoint fails closed without fallback.

Core Tools loads `Values` into environment variables; direct worker execution and unit tests do not
load local settings. [AppConfig.Read](Src/AppConfig.cs) reads them through `IEnv`. Restart after
edits. Core Tools cannot resolve Key Vault references locally, so use only a local test PEM or
base64 PEM. The [project](dotnet.csproj) excludes local settings from publish output.

In Azure, configure the same app settings and use a Key Vault reference for the private PEM.
Provider credentials use managed identity, not a developer CLI login. Keep local evaluation on loopback.

## Request behavior

`POST /api/SendOtp` follows the [shared request/response contract](../docs/CONTRACT.md#1-http-api).
Easy Auth authenticates; JWE decryption, nonce values, and request fields do not.
The handler never parses or echoes incoming `Authorization`.

**.NET binding runs first:** `[FromBody]` creates `EntraSendOtpPayload`. Malformed JSON, invalid
enum tokens, or other deserialization errors can fail before `SendOtp`, its `ILogger` events,
or its custom error response. Successfully bound requests retain application validation,
privacy-safe logging, and response behavior. See [binding differences](../docs/CONTRACT.md#runtime-binding-differences).

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
The host's OpenTelemetry setting does not by itself initialize a direct worker exporter;
verify actual `ILogger` collection before depending on event-based alerts.

`SendOtp` validates and decrypts, selects `EPP_PROVIDER_NAME`, resolves credentials, and calls the
provider. `PhoneProviderBase.SendJsonAsync<TResponse>` owns bounded HTTP transport and typed response
mapping; each provider maps its statuses to `ProviderResult`. Request-aware routing or multiple
accounts require a separate trust, configuration, credential, and test design.

`CredentialTokenService` warms and caches the selected provider credential. The shared cache
switches default to `true`; disabling the selected switch skips warmup and fetches on every live
request. Enabled credentials remain in `MemoryCache` until absolute expiry. There is no polling
timer, and concurrent misses can fetch more than once. The fetch has a 2.5-second cancellation
budget. See the [shared cache contract](../docs/CONTRACT.md#credential-caching-and-refresh).

| Source | Purpose |
|---|---|
| [Program.cs](Program.cs) | Host, provider, credential cache and HTTP client registration |
| [Functions/SendOtp.cs](Functions/SendOtp.cs) | HTTP handler, provider selection, credential resolution and delivery orchestration |
| [Src/AppConfig.cs](Src/AppConfig.cs) | Shared deployment settings |
| [Src/EntraSendOtpPayload.cs](Src/EntraSendOtpPayload.cs) | Bound request model, strict channel/mode converters and semantic validation |
| [Src/JweDeliveryContext.cs](Src/JweDeliveryContext.cs) | Pinned JWE decryption and decrypted delivery context |
| [Src/CredentialTokenService.cs](Src/CredentialTokenService.cs) | Provider-supplied retrieval, one expiring `MemoryCache` value and startup warmup |
| [Src/OtpLog.cs](Src/OtpLog.cs) | Source-generated, strongly typed [structured logging events](../docs/LOGGING.md#event-sequence) |
| [Src/PhoneProviderBase.cs](Src/PhoneProviderBase.cs) | Provider extension contract and shared typed JSON/HTTP transport |
| [Src/Providers/](Src/Providers/) | Provider identity, credential delegation and API-specific request/response protocols |
| [Src/SecretResolver.cs](Src/SecretResolver.cs) | Key Vault transport; `ISecretResolver.ResolveAsync` accepts cancellation |
| [Src/Models.cs](Src/Models.cs) | Outcomes and shared records |

Derive from `PhoneProviderBase`, register the provider in [Program.cs](Program.cs), and give it the configured
name used by the simple `SelectProvider` policy in `SendOtp`. Providers own authentication declaration,
credential resolution, request construction and private typed response DTOs. Their public `SendOtpAsync`
method delegates to the base `SendJsonAsync<TResponse>` transport and maps the typed response into
`ProviderResult`; provider mapping code never handles `HttpResponseMessage` or raw JSON DOM types.
Provider-specific response semantics stay in each provider; no shared response-mapping
registry is used. Common async HTTP transport lives in `PhoneProviderBase`. See
[production limitations](../docs/CONTRACT.md#production-limitations) before production use.
