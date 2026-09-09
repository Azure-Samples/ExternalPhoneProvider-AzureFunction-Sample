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
	at the app root beside [host.json](host.json). Use the shared authentication/encryption catalog;
	Azure requires Easy Auth and in-process JWT validation. No host-detection setting is customer-provisioned.
4. Build [dotnet.csproj](dotnet.csproj), run the offline xUnit suites in
	[tests/Epp.Otp.Tests.csproj](tests/Epp.Otp.Tests.csproj), and start the local Functions host from this folder.
5. Publish this app folder to a compatible .NET isolated Function App. Inspect the package: both
	[.funcignore](.funcignore) and the project protect local settings; private keys must not be included.

## Request behavior

`POST /api/SendOtp` uses the same request and trust boundaries as the other runtimes. Incoming
`mode`, `channel`, `ttlSeconds` and `tenantId` are request data, not deployment authentication settings.

Use incoming `mode: 2` or `mode: "evaluation"` as the generic shutter for every provider: authentication,
validation and decryption run, but provider lookup, provider Key Vault reads and provider HTTP do not.
No provider configuration or diagnostic environment flag is required. Authentication/key prerequisites
and live acceptance semantics are defined in the [contract](../docs/CONTRACT.md#evaluation-generic-shutter).

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
| [Src/TokenValidator.cs](Src/TokenValidator.cs) | Inbound JWT validation |

Implement `IProviderAdapter` and register it in [Program.cs](Program.cs) without adding provider-specific
branches to the shared pipeline. See [production limitations](../docs/CONTRACT.md#production-limitations) before production use.
