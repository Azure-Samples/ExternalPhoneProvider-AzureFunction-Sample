# C# implementation

<a id="external-phone-provider-function-c-net-isolated-worker"></a>

[Documentation](../docs/README.md) | [Settings](#environment-configuration) | [Request behavior](#request-behavior) | [Source](#source)

Implements the shared [contract](../docs/CONTRACT.md) with one provider per deployment.
Target: .NET 10 isolated worker, Azure Functions v4.

## Setup and deployment

**Sample deployment:** follow the [five-step guide](../docs/GETTING-STARTED.md), then complete
[provider authentication and validation](../docs/ONBOARDING.md#complete-provider-authentication).

**Custom package development:** follow these steps from `dotnet/`:

Install the .NET 10 SDK and current Azure Functions Core Tools v4.
On Linux, use Flex Consumption or Premium hosting; .NET 10 is not supported on the legacy
Linux Consumption plan.

1. Create the [local settings below](#environment-configuration). Select an adapter's fixed `Name`
   from [Providers/](Src/Providers/), configure it, and complete
   [provider authentication](../docs/ONBOARDING.md#complete-provider-authentication).
2. Build [dotnet.csproj](dotnet.csproj), run [xUnit tests](tests/Epp.Otp.Tests.csproj), and start
   Core Tools here, **on loopback only, without tunnels**. It has no Easy Auth.
3. For manual deployment, publish to a compatible .NET isolated Function App. Inspect the output
   for private settings and complete the
   [Easy Auth trust checklist](../docs/ONBOARDING.md#manual-deployment-trust-checklist), then run
   [authorized deployed checks](../docs/ONBOARDING.md#validate-the-deployed-endpoint) to verify
   platform authentication.

**Regional continuity:** use the [Front Door guide](../docs/FRONTDOOR.md) and include
.NET-specific package, startup, dependency, and telemetry checks.

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
Keep `Values` as strings, including `EPP_PROVIDER_TIMEOUT_MS`, for example `"1500"`.
Replace the placeholders. API-key adapters store credentials in Key Vault. Each selected channel
requires a valid endpoint; a missing or invalid endpoint never uses the other channel.

Core Tools loads `Values` into environment variables. Direct worker execution and tests do not.
Restart after edits. Use a local test PEM because Core Tools cannot resolve Key Vault references.
The [project](dotnet.csproj) excludes local settings from publish output.

In Azure, configure the same app settings and use a Key Vault reference for the private PEM.
Provider credentials use managed identity, not a developer CLI login. Keep local evaluation on loopback.

## Request behavior

`POST /api/SendOtp` follows the [shared request/response contract](../docs/CONTRACT.md#1-http-api).
Easy Auth authenticates the caller. The handler then validates and decrypts the payload. It never
forwards or returns the incoming `Authorization` header.

**.NET binding runs first:** `[FromBody]` creates `EntraSendOtpPayload`. Malformed JSON, invalid
enum tokens, or other deserialization errors can fail before `SendOtp`, its `ILogger` events,
or its custom error response. Successfully bound requests retain application validation,
privacy-safe logging, and response behavior. See
[binding differences](../TECHNICAL.md#request-validation-and-runtime-differences).

Use [`mode: 2` or `"evaluation"`](../docs/CONTRACT.md#evaluation-no-provider-send) to validate
authentication and decryption without a provider send. Live success confirms acceptance,
**not handset receipt**. Check a timeout before retrying.

For built-in message and voice mapping, see
[Infobip, Soprano, and Telesign](../TECHNICAL.md#built-in-providers).

## Source

To add Twilio, follow the [Twilio integration guide](../docs/BRING-YOUR-OWN-PROVIDER.md).
Keep caller authentication and public responses in the shared handler.

For deployed diagnostics, use [Application Insights](../docs/APPLICATION-INSIGHTS.md) and
[runtime-specific log discovery](../docs/MONITORING.md#runtime-specific-log-discovery).
The host's OpenTelemetry setting does not by itself initialize a direct worker exporter.
Verify actual `ILogger` collection before depending on event-based alerts.

`SendOtp` validates and decrypts, selects `EPP_PROVIDER_NAME`, resolves credentials, and calls the
provider. `PhoneProviderBase.SendJsonAsync<TResponse>` owns bounded HTTP transport and typed response
mapping. Each provider maps its statuses to `ProviderResult`. Request-aware routing or multiple
accounts require a separate trust, configuration, credential, and test design.

`CredentialTokenService` invokes the selected provider's credential retrieval for each live
request with a 5-second cancellation budget. API-key secrets are read from Key Vault each time.
The OAuth providers share `OAuthCredentialSource` and reuse Azure Identity SDK credential instances,
leaving token caching and renewal to the SDK. There is no custom credential cache, hosted warmup service, polling, or
retry cooldown. Evaluation does no provider credential work. See
[credential acquisition](../TECHNICAL.md#provider-settings-and-credential-acquisition).

| Source | Purpose |
| --- | --- |
| [Program.cs](Program.cs) | Host, provider, credential service and HTTP client registration |
| [Functions/SendOtp.cs](Functions/SendOtp.cs) | HTTP handler, provider selection, credential resolution and delivery orchestration |
| [Src/AppConfig.cs](Src/AppConfig.cs) | Shared deployment settings |
| [Src/EntraSendOtpPayload.cs](Src/EntraSendOtpPayload.cs) | Bound request model, strict channel/mode converters and semantic validation |
| [Src/JweDeliveryContext.cs](Src/JweDeliveryContext.cs) | Pinned JWE decryption and decrypted delivery context |
| [Src/CredentialTokenService.cs](Src/CredentialTokenService.cs) | Bounded provider-supplied credential retrieval for each live request |
| [Src/OAuthCredentialSource.cs](Src/OAuthCredentialSource.cs) | Shared managed-identity assertion exchange and reusable SDK clients for Infobip, Soprano, and Telesign OAuth |
| [Src/OtpLog.cs](Src/OtpLog.cs) | Source-generated, strongly typed [structured logging events](../docs/LOGGING.md#event-sequence) |
| [Src/PhoneProviderBase.cs](Src/PhoneProviderBase.cs) | Provider extension contract and shared typed JSON/HTTP transport |
| [Src/Providers/](Src/Providers/) | Provider identity, credential delegation and API-specific request/response protocols |
| [Src/SecretResolver.cs](Src/SecretResolver.cs) | Key Vault transport. `ISecretResolver.ResolveAsync` accepts cancellation. |
| [Src/Models.cs](Src/Models.cs) | Outcomes and shared records |

Derive from `PhoneProviderBase`, register the provider in [Program.cs](Program.cs), and give it the configured
name used by the simple `SelectProvider` policy in `SendOtp`. Providers own authentication declaration,
credential resolution, request construction and private typed response DTOs. Their public `SendOtpAsync`
method delegates to the base `SendJsonAsync<TResponse>` transport and maps the typed response into
`ProviderResult`. Provider mapping code never handles `HttpResponseMessage` or raw JSON DOM types.
Each provider keeps its own response rules. Common async HTTP transport lives in
`PhoneProviderBase`. See
[production readiness](../TECHNICAL.md#production-readiness) when planning a live service.
