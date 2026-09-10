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

### Setup script compatibility

The Preview 1 setup script creates the encryption-key secret, not the selected provider's API
credentials. Before live delivery, complete these steps:

1. Set `KEY_VAULT_URL` to the vault containing the provider credentials. When it is the vault created
	by setup, use that vault's `vaultUri`; otherwise explicitly select the credential vault and grant
	the Function identity read access there. An encryption-key reference does not configure this client.
2. Store the API key under the selected manifest's `keyVaultSecretName` (`key_vault_secret_name` in
	Python). If the manifest also declares `identityKeyVaultSecretName`
	(`identity_key_vault_secret_name`), store the matching API/customer ID as a separate secret.
	`EPP_PROVIDER_ACCOUNT_NAME` is a sender/account option, **not** that credential ID or the API key.
	Keep secret values out of parameters, console transcripts and checked-in settings.
3. Give `EPP_PROVIDER_ENDPOINT` the **base URL expected by the adapter**. Bundled adapters append the
	channel-specific API path. Do not pass an already complete send URL unless an adapter explicitly
	expects it. Use the same account/environment for the endpoint and its credential pair.
4. Supply any additional options read by the selected adapter. Registering a provider does not make
	every account option or channel automatically available.

The script already writes the correct `EPP_` names; no variable-prefix translation is required.

| Setup value | Current application behavior |
|---|---|
| `EPP_PROVIDER_NAME` | Selects one registered adapter; no implicit default. |
| `EPP_PROVIDER_ENDPOINT` | Base URL, with the final send path built by the adapter. |
| `EPP_PROVIDER_TIMEOUT_MS` | Default 1500 ms; positive decimal values are capped at 2500 ms. Zero/invalid values use the default, not an infinite timeout. |
| `EPP_PROVIDER_RETRY_INTERVAL_MS` | Not consumed. Calls are not automatically retried; writing this setting does not enable retries. |
| `EPP_PROVIDER_ACCOUNT_NAME` | Adapter-specific sender/account option, separate from credential secrets. |
| `EPP_DECRYPTION_KEY_PEM` | PEM or base64 PEM, usually resolved from a Key Vault secret reference. |
| `EPP_ENCRYPTION_KEY_ID` | Advisory mismatch warning only; not overlapping-key selection. |
| `EPP_EXPECTED_AUDIENCE`, `EPP_EXPECTED_ISSUER`, `EPP_EXPECTED_CLIENT_ID`, `EPP_TENANT_ID` | The script may write these, but this platform-authenticated application does not read them. The script's separate Easy Auth configuration enforces caller trust. |

**Do not use the script's `-NoEasyAuth` option with this application.** There is no application token
validator to take over. For the script's v1 registration, configure Easy Auth with the identifier URI
as audience, `https://sts.windows.net/{tenantId}/` as issuer, and the authorized SAS application in
`allowedApplications`. Use the v2 audience/issuer only when the registration actually issues v2 tokens.
No Entra application role check is performed. Azure RBAC grants to the Function's managed identity
for storage/Key Vault are separate from granting application permissions to the SAS caller.

The script alone does not make this implementation conform to every Preview 1 requirement:

- The guide requires accepting before provider delivery. This implementation still waits for provider
  acceptance. A durable handoff, expiry and duplicate-handling design is needed before changing that
  acknowledgement boundary; starting an unawaited task is not a reliable replacement.
- The guide requires selecting retained private keys by `kid`. This implementation has one configured
  key. A versionless secret reference alone does not retain both keys during rotation.
- The guide requires voice digits to be spoken separately. This implementation preserves the supplied
  message; verify the selected voice API's behavior rather than assuming unspaced digits are intelligible.

The pasted script also needs its advertised 100-byte UTF-8 endpoint-URL check before deployment.
A public-only certificate cannot supply the private key it later exports. Treat failed infrastructure
role assignments as failures unless the exact assignment is verified as already present. Verify these
script prerequisites separately; the application tests do not validate provisioning.

## 2. Provision encryption and deployment trust

Use [local.settings.sample.json](local.settings.sample.json) as a starting point, replacing its
placeholders with the selected adapter's configuration and choosing the matching worker runtime.
The sample's `UseDevelopmentStorage=true` is local-only and requires Azurite. Keep local settings
private; set application values in the Function App environment for deployment, configure its host
storage separately, and use a Key Vault reference instead of a local private-key value. The
[configuration catalog](CONTRACT.md#4-configuration-app-settings--env) is authoritative.

- Configure `EPP_DECRYPTION_KEY_PEM` through a Key Vault secret reference in Azure and give the caller
	the matching public key. `EPP_ENCRYPTION_KEY_ID` is an optional advisory comparison after decryption,
	not strict key pinning or multi-key lookup.

**Do not enable Entra access-token encryption for the Easy Auth resource app.** Leave its app
registration's `tokenEncryptionKeyId` as `null`; if previously configured, clear that property without
deleting its certificates or changing signing keys. This integration expects a signed bearer JWT,
not an encrypted access token that requires a separate private-key decryption step before validation.
After changing the registration, request a fresh token rather than reusing a cached encrypted token.
The resource is the endpoint app configured in Easy Auth's `clientId`/audience, not necessarily the
application requesting the token. The application code does not configure `tokenEncryptionKeyId`.

This is separate from the **required JWE encryption of `encryptedDeliveryContext`** in the request
body. Keep `EPP_DECRYPTION_KEY_PEM`; `EPP_ENCRYPTION_KEY_ID` only produces an advisory warning after
successful payload decryption and cannot cause a platform `401`.

Configure caller trust in the Function App's **App Service Authentication (Easy Auth)** platform
settings, not application environment variables:

- Enable the authentication platform and Microsoft Entra identity provider. Set
	`globalValidation.requireAuthentication=true`,
	`globalValidation.unauthenticatedClientAction=Return401` and `httpSettings.requireHttps=true`.
- Under `identityProviders.azureActiveDirectory.registration`, configure the endpoint app's client ID
	and a tenant-specific `openIdIssuer` for the trusted SAS issuer tenant and token version. Do not use
	`common` or `organizations`, or derive the issuer from request `tenantId` or unverified claims.
- Under `identityProviders.azureActiveDirectory.validation.allowedAudiences`, configure the exact
	endpoint-app audience agreed during SAS onboarding. For v2 tokens this is the endpoint app client-ID
	GUID; a v1 configuration may use its Application ID URI. The provisioning URI is not automatically
	the v2 audience. This is the endpoint app, not the provider or caller application.
- Set `identityProviders.azureActiveDirectory.validation.defaultAuthorizationPolicy.allowedApplications`
	to a **nonempty** allowlist containing the authorized SAS caller application ID supplied during
	onboarding. Do not substitute the endpoint app ID, allow every tenant application, or leave this list empty.
- Do not exempt `/api/SendOtp` through `globalValidation.excludedPaths` or any alternate ingress route.
	Verify these requirements on every serving app and slot, including after configuration changes or swaps.

Easy Auth is the **only** caller-authentication gate before the `authLevel: anonymous` HTTP Function.
The handler does not validate bearer tokens or authenticate forwarded principal headers; there is no
backup application validation or function-key gate. **Do not expose the endpoint to the public internet
with Easy Auth disabled or bypassed.** JWE decryption does not authenticate SAS: anyone with the public
key can encrypt a request. A nonce echo, including a fixed nonce, is not authentication or replay protection.

Incoming `mode`, `channel`, `ttlSeconds` and `tenantId` are request data, not customer deployment
settings or sources of identity trust. There is no application host-detection authentication guard.

**Migration:** Older application authentication settings are no longer consumed. Deployments running
older code require a separate rollout; source edits do not update them. Configure and verify the
platform gate before publishing this code, then repeat the deployed security checks below.

## 3. Validate without delivery

Use `POST /api/SendOtp` with an admitted caller's token and a valid encrypted envelope containing
`mode: 2` or `mode: "evaluation"`. On Azure, Easy Auth authenticates and authorizes the caller first.
The handler then validates and decrypts, and echoes the nonce without provider lookup, provider Key
Vault reads or provider HTTP. No provider configuration or diagnostic environment flag is required.
Platform trust configuration and the decryption key remain prerequisites; see the
[evaluation contract](CONTRACT.md#evaluation-generic-shutter).

Core Tools does **not** provide Easy Auth. Local evaluation exercises the unauthenticated application
path only: bind the host exclusively to loopback, with no tunnels, public forwarding or shared-network
exposure. Use local test keys and synthetic request data. Sending an authorization header locally
does not enable authentication, and local success does not verify platform security.

Evaluation success proves the validation/decryption path, not live credentials or handset delivery.
A live `200` with the matching nonce means provider acceptance, not handset receipt; confirm delivery
through the selected provider's reports. Forward the rendered message unchanged, including voice
digit spacing, without guessing a passcode. A timed-out send may already be accepted; avoid blind retries.

## 4. Package, deploy and verify

Build and publish only the chosen language folder, retaining runtime dependencies or using a supported
remote build. Configure and verify Easy Auth before publishing; keep public ingress disabled until
the required platform gate is in place. Verify managed identity access, encryption and platform
authentication settings on the deployed app. Inspect the final package; do not publish the repository
root or reuse stale build output.

The repository-root [.gitignore](../.gitignore) covers all runtimes and nested helper scripts.
Publishing has separate exclusions in [JavaScript](../javascript/.funcignore),
[Python](../python/.funcignore) and [.NET](../dotnet/.funcignore); local settings, private keys and tests
must stay out of the package. The [.NET project](../dotnet/dotnet.csproj) also excludes local settings
from publish output. Application logs are privacy-limited; disable platform/SDK body tracing separately.

### Required deployed security checks

Offline suites cover local application behavior, **not Easy Auth**. Separately test the deployed
endpoint with non-delivering evaluation requests and synthetic data:

- Missing, malformed, expired or invalidly signed credentials receive `401` before handler execution.
- Wrong tenant issuer or endpoint audience is rejected; a valid token for an application outside the
	SAS caller allowlist is denied before handler execution. Check the actual non-success status rather
	than relying on the handler's response schema for platform errors.
- An authorized SAS caller with a valid encrypted evaluation request receives `200` and the matching
	nonce, without provider lookup, provider Key Vault reads or provider HTTP.
- HTTPS is enforced, and no excluded path, alternate hostname, route or serving slot bypasses the
	authentication gate for SendOtp. Verify the nonempty caller allowlist in the deployed configuration.

Do not disable Easy Auth on a public endpoint to test failure behavior. Never record raw phone
numbers, messages, nonce values, bearer tokens, API keys, encrypted request bodies or provider response
bodies in test reports. Repeat these checks after deployment and any authentication or slot changes;
passing offline tests is not deployment security certification.

## 5. Add an adapter

Implement `manifest`, `buildRequest` and `parseResponse`, register the adapter in the chosen runtime,
then provision its credentials and options. Keep API-specific logic in the adapter, with fail-closed
response mapping; the shared delivery pipeline does not need provider-specific branches.
