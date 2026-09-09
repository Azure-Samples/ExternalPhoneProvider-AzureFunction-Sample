# Customer Onboarding

A shared setup guide for the External Phone Provider OTP Function. Use one implementation:
[JavaScript](../javascript/README.md), [Python](../python/README.md) or [.NET](../dotnet/README.md).
[CONTRACT.md](CONTRACT.md) defines shared settings and behavior; the selected adapter and its manifest
define required credentials and options. No provider is preferred or selected by default.

## 1. Select and configure an adapter

Choose a registered adapter for the selected provider and an account supporting the required channels.
Set `EPP_PROVIDER_NAME` to its actual manifest id (`<adapter-id>` is only a placeholder), and configure
its matching `EPP_PROVIDER_ENDPOINT` and required options. One provider is active per deployment;
request fields cannot change it. Purchasing or activating a subscription does not install an adapter.

Store credentials under the Key Vault secret names declared by the selected adapter's manifest, not
in code or app settings. Grant the Function's managed identity *Key Vault Secrets User* access at the
appropriate secret or vault scope. Confirm that the endpoint and credentials belong to the same
account and environment. Individual API contracts stay in the adapters.

## 2. Provision encryption and deployment trust

Use [local.settings.sample.json](local.settings.sample.json) as a starting point, replacing its
placeholders with the selected adapter's configuration. Keep local settings private and set the
same shared values in the Function App environment for deployment; the
[configuration catalog](CONTRACT.md#4-configuration-app-settings--env) is authoritative.

- Configure `EPP_DECRYPTION_KEY_PEM` through a Key Vault secret reference in Azure and give the caller
	the matching public key. `EPP_ENCRYPTION_KEY_ID` is an optional advisory comparison after decryption,
	not strict key pinning or multi-key lookup.
- Set `EPP_REQUIRE_AUTH=true`, the trusted issuer tenant and `EPP_EXPECTED_CLIENT_ID`. For v2 tokens,
	`EPP_EXPECTED_AUDIENCE` is the endpoint app client-ID GUID. `EPP_EXPECTED_ISSUER` is optional; an
	explicit issuer does not replace the required trusted tenant configuration. The Application ID URI
	used for provisioning is not automatically the v2 token audience.
- Enable Easy Auth: `unauthenticatedClientAction=Return401` and `allowedApplications` pinned to the
	admitted caller. In-process JWT validation remains mandatory on Azure; forwarded principal headers
	do not authenticate a request on their own.

Incoming `mode`, `channel`, `ttlSeconds` and `tenantId` are request data, not customer deployment
settings or sources of identity trust. Host detection uses existing Azure metadata internally;
customers do not configure an `OnAzure` variable or replace that guard with a request header.

## 3. Validate without delivery

Use `POST /api/SendOtp` with an admitted caller's token and a valid encrypted envelope containing
`mode: 2` or `mode: "evaluation"`. This is the generic shutter for every provider: it authenticates,
validates and decrypts, then echoes the nonce without provider lookup, provider Key Vault reads or
provider HTTP. No provider configuration or diagnostic environment flag is required. Authentication
metadata and the decryption key remain prerequisites; see the [evaluation contract](CONTRACT.md#evaluation-generic-shutter).

Evaluation success proves the validation/decryption path, not live credentials or handset delivery.
A live `200` with the matching nonce means provider acceptance, not handset receipt; confirm delivery
through the selected provider's reports. Forward the rendered message unchanged, including voice
digit spacing, without guessing a passcode. A timed-out send may already be accepted; avoid blind retries.

## 4. Package and deploy

Build and publish only the chosen language folder, retaining runtime dependencies or using a supported
remote build. Verify managed identity access, encryption and authentication settings on the deployed
app. Inspect the final package; do not publish the repository root or reuse stale build output.

The repository-root [.gitignore](../.gitignore) covers all runtimes and nested helper scripts.
Publishing has separate exclusions in [JavaScript](../javascript/.funcignore),
[Python](../python/.funcignore) and [.NET](../dotnet/.funcignore); local settings, private keys and tests
must stay out of the package. The [.NET project](../dotnet/dotnet.csproj) also excludes local settings
from publish output. Application logs are privacy-limited; disable platform/SDK body tracing separately.

## 5. Add an adapter

Implement `manifest`, `buildRequest` and `parseResponse`, register the adapter in the chosen runtime,
then provision its credentials and options. Keep API-specific logic in the adapter, with fail-closed
response mapping; the shared delivery pipeline does not need provider-specific branches.
