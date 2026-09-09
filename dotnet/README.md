# External Phone Provider Function — C# (.NET isolated worker)

Implements the shared [contract](../docs/CONTRACT.md) with one dispatch engine and one selected
provider per deployment. Target: .NET 8 isolated worker, Azure Functions v4.

## Setup and deployment

1. Follow [customer onboarding](../docs/ONBOARDING.md). Set `EPP_PROVIDER_NAME` to the selected
	adapter's registered manifest id (`<adapter-id>` is only a placeholder).
2. Consult the selected adapter and its manifest in [Src/Providers/](Src/Providers/) for required
	credentials and options. Store credentials in Key Vault under the declared secret names, grant
	the Function's managed identity *Key Vault Secrets User*, and configure the matching endpoint/options.
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
4. Build [dotnet.csproj](dotnet.csproj), run the offline xUnit suites in
	[tests/Epp.Otp.Tests.csproj](tests/Epp.Otp.Tests.csproj), and start the local Functions host from this folder.
	Core Tools has no Easy Auth: bind only to loopback, with no tunnels or public forwarding.
5. Publish this app folder to a compatible .NET isolated Function App. Inspect the package: both
	[.funcignore](.funcignore) and the project protect local settings; private keys must not be included.
	Offline tests cover application behavior, not platform authentication; run the separate
	[deployed security checks](../docs/ONBOARDING.md#4-package-deploy-and-verify).

## Request behavior

`POST /api/SendOtp` uses the same request and trust boundaries as the other runtimes. Incoming
`mode`, `channel`, `ttlSeconds` and `tenantId` are request data, not deployment authentication settings.
Easy Auth authenticates and authorizes the caller before the anonymous handler validates the envelope
and decrypts the JWE. Incoming `Authorization` is not parsed or echoed by the handler. JWE does not
authenticate SAS: anyone with the public key can encrypt a request, and a fixed nonce is not authentication.

Use incoming `mode: 2` or `mode: "evaluation"` as the generic shutter for every provider: platform
authentication on Azure, handler validation and decryption run, but provider lookup, provider Key Vault
reads and provider HTTP do not. No provider configuration or diagnostic environment flag is required.
Live requests forward the rendered message unchanged using the configured provider's API key and
await acceptance before returning the nonce; failures omit it. Acceptance is not handset delivery.
Platform/key prerequisites and HTTP outcomes are defined in the
[contract](../docs/CONTRACT.md#evaluation-generic-shutter).

## Source

| Source | Purpose |
|---|---|
| [Program.cs](Program.cs) | Host and adapter registration |
| [Functions/SendOtp.cs](Functions/SendOtp.cs) | HTTP handler |
| [Src/AppConfig.cs](Src/AppConfig.cs) | Shared deployment settings |
| [Src/DispatchEngine.cs](Src/DispatchEngine.cs) | Envelope/JWE handling and dispatch |
| [Src/ProviderRegistry.cs](Src/ProviderRegistry.cs), [Src/IProviderAdapter.cs](Src/IProviderAdapter.cs) | Adapter lookup and contract |
| [Src/Providers/](Src/Providers/) | Adapter manifests and API-specific implementations |
| [Src/SecretResolver.cs](Src/SecretResolver.cs) | Cached Key Vault access via managed identity |
| [Src/OutcomeMapper.cs](Src/OutcomeMapper.cs), [Src/Models.cs](Src/Models.cs) | Outcomes and shared records |

Implement `IProviderAdapter` and register it in [Program.cs](Program.cs) without adding provider-specific
branches to the shared pipeline. See [production limitations](../docs/CONTRACT.md#production-limitations) before production use.
