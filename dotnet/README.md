# External Phone Provider Function: C# (.NET isolated worker)

Implements the shared [contract](../docs/CONTRACT.md) with one `SendOtp` request pipeline and one
selected provider per deployment. Target: .NET 8 isolated worker, Azure Functions v4.

## Setup and deployment

1. Follow [customer onboarding](../docs/ONBOARDING.md). Set `EPP_PROVIDER_NAME` to the selected
	adapter's `Name` (`<adapter-id>` is only a placeholder).
2. Consult the selected adapter in [Src/Providers/](Src/Providers/) for required credentials and
	options. Telesign/Soprano require provider OAuth authorization and outbound managed-identity
	federation. For API-key adapters, store credentials in Key Vault under the provider's secret names
	and grant *Key Vault Secrets User*. Configure the matching endpoint/options.
3. Base private local settings on [../docs/local.settings.sample.json](../docs/local.settings.sample.json),
	replacing placeholders and selecting `FUNCTIONS_WORKER_RUNTIME=dotnet-isolated`. Put settings
	at the app root beside [host.json](host.json). Configure decryption from the
	[shared catalog](../docs/CONTRACT.md#4-configuration-app-settings--env) and caller trust through
	[Easy Auth](../docs/ONBOARDING.md#2-provision-encryption-and-deployment-trust), the only authentication
	gate before the anonymous Function. Enable `requireAuthentication=true`,
	`unauthenticatedClientAction=Return401` and `requireHttps=true`; pin the trusted tenant issuer,
	endpoint-app `allowedAudiences` and a nonempty `allowedApplications` list for the authorized SAS
	caller. Do not exclude SendOtp. There is no backup application token validation; never expose the
	endpoint to the public internet with Easy Auth disabled or bypassed.

	`SendOtp` uses Azure Functions `[FromBody]` binding to create `EntraSendOtpPayload`. Malformed JSON,
	invalid enum tokens and other deserialization failures are rejected by the Functions binding/runtime
	before `SendOtp` runs. Those failures therefore do not produce application `ILogger` events or the
	handler's custom error response body; platform diagnostics and responses apply instead.
4. Build [dotnet.csproj](dotnet.csproj), run the offline xUnit suites in
	[tests/Epp.Otp.Tests.csproj](tests/Epp.Otp.Tests.csproj), and start the local Functions host from this folder.
	Core Tools has no Easy Auth: bind only to loopback, with no tunnels or public forwarding.
5. Publish this app folder to a compatible .NET isolated Function App. Inspect the package: both
	[.funcignore](.funcignore) and the project protect local settings; private keys must not be included.
	Offline tests cover application behavior, not platform authentication; run the separate
	[deployed security checks](../docs/ONBOARDING.md#4-package-deploy-and-verify).

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

For live delivery, add `EPP_PROVIDER_NAME`, the complete selected `EPP_PROVIDER_ENDPOINT`, and the
matching provider authentication settings to `Values`.
Add `EPP_PROVIDER_ACCOUNT_NAME` and adapter-specific options only when required. Optional
`EPP_PROVIDER_TIMEOUT_MS` is a string such as `"1500"`. Replace placeholders; store provider credentials
under the adapter's Key Vault secret names, not in local settings. See the
[complete variable table](../TECHNICAL.md#configure-environment-variables).

Core Tools loads `Values` into environment variables. [AppConfig.Read](Src/AppConfig.cs) reads them
through `IEnv`; direct worker execution and unit tests do not automatically load local settings.
Restart the host after edits. Configure local host storage other than Azurite separately; do not copy
the emulator connection into Azure. Core Tools does not resolve Key Vault references locally; supply
the local test PEM or base64 PEM directly. The [project](dotnet.csproj) excludes private local settings
from publish output.

For Azure, configure the same application variables on the serving app/slot's **Environment variables
→ App settings** page and resolve the private PEM through a Key Vault reference. Key Vault provider
credentials use managed identity, not the developer's CLI login. Use loopback-only local evaluation
or the offline tests' injected environment and secret resolver for local development.

## Request behavior

`POST /api/SendOtp` uses the same request and trust boundaries as the other runtimes. Incoming
`mode`, `channel`, `ttlSeconds` and `tenantId` are request data, not deployment authentication settings.
Easy Auth authenticates and authorizes the caller before the anonymous handler validates the payload
and decrypts the JWE. Incoming `Authorization` is not parsed or echoed by the handler. JWE does not
authenticate SAS: anyone with the public key can encrypt a request, and a fixed nonce is not authentication.
Requests that bind successfully retain the application validation, PII-safe logging and response lifecycle.

Use incoming `mode: 2` or `mode: "evaluation"` as the generic shutter for every provider: platform
authentication on Azure, handler validation and decryption run, but provider lookup, provider Key Vault
reads and provider HTTP do not. No provider configuration or diagnostic environment flag is required.
Live requests forward the rendered message unchanged using the configured provider's API key or OAuth token and
await acceptance before returning the nonce; failures omit it. Acceptance is not handset delivery.
Platform/key prerequisites and HTTP outcomes are defined in the
[contract](../docs/CONTRACT.md#evaluation-generic-shutter).

For Soprano voice, the adapter extracts the first six-digit passcode from the rendered message. It
uses a nonblank SAS request locale as the language, falling back to `en-US`, and sends fixed gender
`1` and loop `2`. These values require no additional environment settings. Soprano SMS continues to
forward the rendered message unchanged.

Telesign SMS also forwards the rendered message unchanged. Telesign voice comma-separates each
six-digit numeric run that is not part of a longer number and repeats the complete paced message twice.
Telesign and Soprano share `OAuthPhoneProviderBase` for managed-identity client-assertion exchange.
Telesign no longer uses API-key/customer-ID secrets or Basic authentication; see the
[migration guidance](../docs/ONBOARDING.md#telesign-oauth-migration).

## Source

`SendOtp` validates and decrypts the request, selects the configured provider in its private
`SelectProvider` method, resolves that provider's credentials, builds and sends the common bounded HTTP
request, asks the provider to deserialize its typed response DTO and return the final outcome, then maps that
outcome to the endpoint HTTP status. Providers
return standard `HttpRequestMessage` instances with typed `JsonContent`; the shared transport sends those
messages directly with redirects disabled, `ResponseHeadersRead`, and the bounded timeout. Each provider maps
its own normalized response status to the final outcome and reports whether that status was recognized. The
default method selects by `EPP_PROVIDER_NAME`; replace only its body if deployment policy later needs country,
tenant or other request-aware selection. No router or routing configuration abstraction is required.

`CredentialTokenService` is the hosted startup warmer and runtime credential cache.
It asks the selected provider for credentials at startup and on cache misses.
Each provider owns credential acquisition and its secret names. The service stores
the result in .NET `MemoryCache` until the credential's absolute expiry; the next request fetches a
replacement. There is no polling timer or separate cache implementation. Each shared acquisition owns
its cancellation budget, so a waiter cannot cancel another request's retrieval. Evaluation remains
independent.

| Source | Purpose |
|---|---|
| [Program.cs](Program.cs) | Host, provider, credential cache and HTTP client registration |
| [Functions/SendOtp.cs](Functions/SendOtp.cs) | HTTP handler, provider selection, delivery orchestration and common HTTP transport |
| [Src/AppConfig.cs](Src/AppConfig.cs) | Shared deployment settings |
| [Src/EntraSendOtpPayload.cs](Src/EntraSendOtpPayload.cs) | Bound request model, strict channel/mode converters and semantic validation |
| [Src/JweDeliveryContext.cs](Src/JweDeliveryContext.cs) | Pinned JWE decryption and decrypted delivery context |
| [Src/CredentialTokenService.cs](Src/CredentialTokenService.cs) | Provider-supplied retrieval, one expiring `MemoryCache` value and startup warmup |
| [Src/OtpLog.cs](Src/OtpLog.cs) | Source-generated, strongly typed [structured logging events](../docs/CONTRACT.md#application-logs) |
| [Src/PhoneProviderBase.cs](Src/PhoneProviderBase.cs) | Provider extension contract and shared typed JSON/HTTP transport |
| [Src/OAuthPhoneProviderBase.cs](Src/OAuthPhoneProviderBase.cs) | Shared managed-identity OAuth acquisition for Telesign and Soprano |
| [Src/Providers/](Src/Providers/) | Provider identity, credential delegation and API-specific request/response protocols |
| [Src/SecretResolver.cs](Src/SecretResolver.cs) | Key Vault transport; `ISecretResolver.ResolveAsync` accepts cancellation |
| [Src/Models.cs](Src/Models.cs) | Outcomes and shared records |

Derive from `PhoneProviderBase`, register the provider in [Program.cs](Program.cs), and give it the configured
name used by the simple `SelectProvider` policy in `SendOtp`. Providers own authentication declaration,
credential resolution, request construction and private typed response DTOs. Their public `SendOtpAsync`
method delegates to the base `SendJsonAsync<TResponse>` transport and maps the typed response into
`ProviderResult`; provider mapping code never handles `HttpResponseMessage` or raw JSON DOM types.
Provider-specific response semantics stay in each provider; no shared response-mapping
registry is used. Common async HTTP transport remains in `SendOtp`. See
[production limitations](../docs/CONTRACT.md#production-limitations) before production use.
