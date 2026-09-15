# External Phone Provider: Azure Function Sample

A provider-agnostic **OTP-delivery Azure Function** sample, implemented across multiple languages.
Each language folder is a self-contained implementation of the **same design and the same
[contract](docs/CONTRACT.md)**: one engine, drop-in provider adapters, env-provisioned config, and
secrets in Key Vault.

## Implementations

| Language | Status | Folder |
|----------|--------|--------|
| JavaScript (Node.js) | Available | [javascript/](javascript/) |
| C# (.NET isolated worker) | Available | [dotnet/](dotnet/) |
| Python (v2 model) | Available | [python/](python/) |

All implementations conform to the **language-agnostic contract** in
[docs/CONTRACT.md](docs/CONTRACT.md): identical HTTP API, provider-adapter shape, config/env var
names, Key Vault secret names, and behaviors (fail-closed, managed identity, privacy). Pick any folder
and follow its README.

Choose one language and configure the adapter for your provider. No provider is preferred or selected
by default. Deploy each language separately, not all three to the same Function App. See the
[shared configuration](docs/CONTRACT.md#default-provider-and-configuration-readers).

New here? Start with **[docs/ONBOARDING.md](docs/ONBOARDING.md)** for setup, config, running, securing,
and deploying, step by step.

## Download a Function ZIP

Download the preview ZIP for your chosen language:

| Language | Download | Contents |
|---|---|---|
| JavaScript | [epp-javascript.zip](https://github.com/Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample/releases/download/epp-packages-preview-20260914/epp-javascript.zip) | Application and production dependencies |
| .NET | [epp-dotnet-source.zip](https://github.com/Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample/releases/download/epp-dotnet-source-preview-20260915/epp-dotnet-source.zip) | C# Function source and project file; build/publish before deployment |
| Python | [epp-python-source.zip](https://github.com/Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample/releases/download/epp-packages-preview-20260914/epp-python-source.zip) | Source for Azure remote build on Linux |

Customers do not need PowerShell or a local build toolchain to download these files. Verify downloads
against the corresponding release's `SHA256SUMS.txt`. Configure the target Function App's runtime, app settings,
Key Vault access, and Easy Auth before deploying. .NET requires building/publishing the extracted
project; Python requires remote build to install dependencies. Neither source ZIP can run directly
as a run-from-package artifact. GitHub's **Code > Download ZIP**
is the whole source repository, not a Function deployment package.

After the packaging workflow is merged, each successful `main` build tests all three implementations,
builds and inspects the ZIPs, and publishes a new versioned release. Get those builds from
[Latest release](https://github.com/Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample/releases/latest).
Older releases remain available; existing assets are not overwritten. Pull requests build downloadable
workflow artifacts only and cannot publish releases. GitHub sign-in may be required for workflow
artifacts, but public release downloads do not require a local build. Packaging does not deploy or
verify live provider delivery. The current preview is built from the packaging branch, not a merged
release of the separate provider feature branches.

## Build ZIPs Locally

For custom builds, run the script for your chosen language from the repository root. These standalone scripts create
ZIPs locally; they do not sign in to Azure, upload code, or change app settings.

| Language | Root-level script | Prerequisites | ZIP in `artifacts/` |
|---|---|---|---|
| JavaScript | [package-javascript.ps1](package-javascript.ps1) | PowerShell 7+, Node.js 20 or 22 with npm, npm registry access | `epp-javascript.zip` |
| .NET | [package-dotnet.ps1](package-dotnet.ps1) | PowerShell 7+ to package; .NET 8 SDK and NuGet feed access when customers build | `epp-dotnet-source.zip` |
| Python | [package-python.ps1](package-python.ps1) | PowerShell 7+; Azure remote build required when deploying | `epp-python-source.zip` |

```powershell
pwsh -File ./package-javascript.ps1
pwsh -File ./package-dotnet.ps1
pwsh -File ./package-python.ps1
```

Choose one command; each packages only its language. The scripts locate source relative to their
own location, so invoking an absolute script path also works from another directory. Each ZIP has
`host.json` at its root, with no enclosing language folder. Local settings, credential files, and
first-party tests are excluded. Generated ZIPs are ignored by Git.

JavaScript installs production dependencies from the lockfile in a temporary folder; your working
`node_modules` is not copied or modified. Dependency lifecycle scripts are disabled for this sample's
JavaScript dependencies. If you add native dependencies or packages requiring install scripts,
review packaging and build them for the target Azure OS.

**.NET is a source ZIP, not compiled output.** It contains `dotnet.csproj`, `host.json`, `Program.cs`,
and the C# files under `Functions/` and `Src/`. Packaging does not run restore, build, or publish,
and needs no .NET SDK. It excludes `bin/`, `obj/`, tests, local settings, and compiled dependencies.
Customers extract it and run `dotnet publish dotnet.csproj --configuration Release --output ../publish`
with the .NET 8 SDK, or use a deployment pipeline that builds the project. Deploy the resulting
publish output with `host.json` at its root, not the source ZIP directly. CI tests this customer
build from an extracted copy; that temporary publish output is not included in the download.

**Python is a source ZIP, not a ready-to-run package.** Deploy to a Linux Function App with remote
build enabled in the deployment tool for your hosting plan, so Azure installs `requirements.txt`.
Do not use this source ZIP directly with run-from-package or copy Windows-installed Python dependencies
to Azure. The script deliberately does not invoke pip or include a local virtual environment.

Existing archives are never overwritten. For another build, specify a new path:

```powershell
pwsh -File ./package-javascript.ps1 -OutputPath ./artifacts/epp-javascript-v2.zip
```

The same `-OutputPath` option works for all three scripts. Configure the destination app's runtime,
app settings, Key Vault access, and Easy Auth separately before deployment. See
[deployment and validation](docs/ONBOARDING.md#4-package-deploy-and-verify). Packaging success does
not verify cloud configuration or provider delivery. File selection is tailored to this sample;
extend it deliberately if you add runtime assets, and never put secrets in application source.

## The design in one line

SAS → Easy Auth → anonymous HTTP handler (`POST /api/SendOtp`, validate envelope + decrypt JWE) →
configured provider (API key) → HTTP result with nonce on success.
For Soprano with the JWT flag enabled, the Function exchanges a managed-identity assertion for an
application token in the provider tenant, without an application secret, and adds it to the
API-ID/key-authenticated send. SAS supplies the encrypted delivery
payload, not that provider JWT. See [Soprano JWT setup](#soprano-jwt-setup).
Only provider acceptance returns the nonce for live requests. Incoming `mode: 2` (evaluation) is the
generic shutter: after platform authentication, validate and decrypt, then echo the nonce without
calling a provider.

See [docs/CONTRACT.md](docs/CONTRACT.md) for the full specification every implementation follows.

Request `tenantId`, `channel`, `mode` and `ttlSeconds` are request data, not extra environment settings.
The trusted tenant issuer, endpoint-app audience and authorized SAS caller are configured in Easy Auth,
not in application environment settings or incoming request data.

## Configure environment variables

Use the [sample settings](docs/local.settings.sample.json) as the starting point for the chosen
runtime. All entries in its `Values` object are **strings**. The application reads environment
variables; Azure Functions Core Tools loads that `Values` object for local runs.

The sample uses `node`; change it to `python` or `dotnet-isolated` for those runtimes. Replace the
provider, endpoint, vault and test-key placeholders before use. Its storage value assumes **Azurite
is running**; do not copy `UseDevelopmentStorage=true` into Azure. The optional Soprano JWT settings
are included with the feature disabled; leave them unused for other providers. Other optional settings
are listed below. Keep explanatory comments outside
`Values`, otherwise the host loads them as environment variables too.

The local settings file is an environment-variable input for the Functions host, **not a serialized
`AppConfig` or request model**. For example, `EPP_PROVIDER_NAME` becomes `config.providerName` in
JavaScript, `config.provider_name` in Python, and `config.ProviderName` in .NET. The refactor changed
how code accesses configuration, not the environment-variable names.

| Variable | When needed | Value |
|---|---|---|
| `AzureWebJobsStorage` | Functions host storage | Local sample: `UseDevelopmentStorage=true` with Azurite running. Configure Azure host storage separately for the selected plan. |
| `FUNCTIONS_WORKER_RUNTIME` | Functions host | `node`, `python`, or `dotnet-isolated`. Choose the value matching your implementation. |
| `EPP_DECRYPTION_KEY_PEM` | Every request | Local test PEM or base64 PEM. In Azure, use a Key Vault reference resolving to the private-key secret. |
| `EPP_ENCRYPTION_KEY_ID` | Optional | Expected encryption key ID; mismatch only produces an advisory warning. |
| `EPP_PROVIDER_NAME` | Live delivery | Selected adapter's manifest ID. No default provider. |
| `EPP_PROVIDER_ENDPOINT` | Live delivery | HTTPS **base URL**, in the same environment as the provider credentials; the adapter adds its route. |
| `EPP_PROVIDER_TIMEOUT_MS` | Optional | Decimal milliseconds. Defaults to `1500`, capped at `2500`; not an end-to-end deadline. |
| `EPP_PROVIDER_JWT_ENABLED` | Optional, Soprano only | Default off. `true` exchanges a managed-identity assertion for an application token in the provider tenant. API-ID/key headers remain mandatory; unavailable token means API-key-only. |
| `EPP_PROVIDER_TENANT_ID` | Soprano JWT acquisition | Provider/resource tenant where the final application token is requested. |
| `EPP_PROVIDER_APPLICATION_ID` | Soprano JWT acquisition | Application (client) ID of the calling app registration trusted by Soprano, not the provider API's Application ID. |
| `EPP_PROVIDER_MI_CLIENT_ID` | Soprano JWT acquisition | Client ID of an attached user-assigned managed identity trusted by that app registration's federated credential. Not its Object (principal) ID. |
| `EPP_PROVIDER_SCOPE` | Soprano JWT acquisition | Provider API Application ID or Application ID URI plus `/.default`, exactly as agreed with the provider. Required when enabling JWT; no default. |
| `EPP_PROVIDER_ACCOUNT_NAME` | Adapter-dependent | Sender/account metadata, not an API key or credential identity. |
| `KEY_VAULT_URL` | Provider credential lookup | URI of the vault containing the manifest-named provider secrets. Separate from the encryption-key reference. |
| `AZURE_CLIENT_ID` | Optional, Key Vault only | Client ID of a user-assigned managed identity for Key Vault access. Leave empty/unset for the system-assigned identity. Independent of the provider federation identity. |

1. **Locally:** create private local settings beside the chosen runtime's host file, following its
  [JavaScript](javascript/README.md#environment-configuration), [Python](python/README.md#environment-configuration)
  or [.NET](dotnet/README.md#environment-configuration) instructions. Restart the host after edits.
2. **In Azure:** set the same application variables on the selected Function App (or serving slot)
  under **Settings → Environment variables → App settings**, then apply the changes. Local settings
  are not published automatically. Configure host storage separately for the selected hosting plan.
3. Store provider API keys and any required identity secrets in Key Vault using the **exact names in
  the adapter manifest**. Grant that app/slot's managed identity *Key Vault Secrets User* on those
  secrets. An API key in a local environment variable is not a supported replacement for the resolver.
  See the [provider credential naming table](docs/ONBOARDING.md#provider-credential-names) and
  [local use of existing cloud secrets](docs/ONBOARDING.md#local-settings-and-cloud-secrets).

Evaluation requests do not need provider variables or provider secrets. They still need the decryption
key. The default credential resolvers use `ManagedIdentityCredential`, **not** the developer's CLI
login; ordinary local machines have no managed-identity endpoint. Use offline tests or loopback-only
evaluation locally, or an explicitly injected test resolver for integration work. Never commit local
settings, keys or test credentials.

Core Tools does not resolve Azure Key Vault reference expressions locally. Supply the local test PEM
or base64 PEM directly; use a reference such as `@Microsoft.KeyVault(SecretUri=https://<vault>.vault.azure.net/secrets/<private-key-secret>/)`
for `EPP_DECRYPTION_KEY_PEM` in Azure app settings, where the platform resolves it.

Configure inbound issuer/audience/caller trust in **Easy Auth**, not these application variables.
Incoming `tenantId`, `channel`, `mode` and `ttlSeconds` are request data and cannot select the
managed identity or provider scope. The Function ignores any incoming `providerJwt` or provider-token header.

## Soprano JWT Setup

**No application client secret is needed.** Azure manages the Function's identity credentials;
Entra issues and signs the token. Keep the existing `soprano-api-id` and `soprano-api-key` secrets
in Key Vault. The JWE decryption key is also unchanged.

1. Attach an existing **user-assigned managed identity** to the Function. Set `EPP_PROVIDER_MI_CLIENT_ID`
  to its Client ID. Keep the existing system-assigned identity or `AZURE_CLIENT_ID` for Key Vault.
2. Configure or reuse a federated identity credential on the **calling app registration**, which must
  share the managed identity's home tenant. Its issuer is `https://login.microsoftonline.com/<home-tenant-id>/v2.0`,
  subject is the identity's **Object (principal) ID**, and audience is `api://AzureADTokenExchange`
  (without `/.default`). For another provider tenant, the calling app must be multitenant, provisioned
  there, and authorized for the provider API. This is not a credential on the provider API registration.
3. Configure the exchange and enable JWT after confirming Soprano accepts the calling application:

  ```json
  {
    "EPP_PROVIDER_JWT_ENABLED": "true",
    "EPP_PROVIDER_TENANT_ID": "<provider-tenant-id>",
    "EPP_PROVIDER_APPLICATION_ID": "<calling-application-id>",
    "EPP_PROVIDER_MI_CLIENT_ID": "<user-assigned-managed-identity-client-id>",
    "EPP_PROVIDER_SCOPE": "<provider-api-application-id>/.default"
  }
  ```

  Use the exact resource identifier agreed with the provider, which may instead be
  `api://<provider-api-application-id>/.default`. The QA4 example is
  `32dfc82a-86dd-4515-a0a2-f20ef2f5c7fe/.default`; it is not a built-in default.

4. Verify SMS and Voice with the flag off and on. Off means no token request. Missing settings,
  unavailable managed identity, or exchange errors use API keys alone. Check the `SopranoAuth=api-key+jwt` log
  for the request to prove a token was actually attached. A provider rejection never triggers a resend.

The flow is **SAS JWE -> Function decrypts -> user-assigned identity gets an exchange assertion ->
ClientAssertionCredential requests an application token from the provider tenant -> Soprano receives
API-ID/key plus the final Bearer JWT**. The first token is for `api://AzureADTokenExchange/.default`;
it is never sent to Soprano. SAS's HTTP Authorization is validated separately by Easy Auth and is
never forwarded. Neither the OTP nor the JWE is included in either token request.

All three implementations reuse Azure Identity `ManagedIdentityCredential` and `ClientAssertionCredential`
so the SDKs handle assertion/application-token caching and refresh:
[JavaScript `acquireToken`](javascript/src/functions/providers/soprano.js),
[Python `acquire_token`](python/src/providers/soprano.py), or
[.NET `AcquireTokenAsync`](dotnet/Src/Providers/SopranoProvider.cs).
The Function checks token presence and expiry metadata, not JWT structure or signatures.
**Soprano validates the provider JWT; Easy Auth validates the inbound caller JWT; the Function
validates and decrypts the JWE.** See the [contract](docs/CONTRACT.md#optional-soprano-provider-jwt)
for timeouts and fallback implications.

For local tests, mock the managed-identity credential as the test suites do. Ordinary development
machines do not have the Azure managed-identity endpoint; CLI login is not a fallback. A local
API-key send with an injected secret resolver does not verify managed-identity JWT acquisition.

When migrating from the earlier secret-based implementation, replace `EPP_PROVIDER_CLIENT_ID` with
`EPP_PROVIDER_APPLICATION_ID`, keep the intended provider tenant, and remove `EPP_PROVIDER_CLIENT_SECRET_NAME`.
Attach/configure the trusted user-assigned identity instead. Revoke only obsolete credentials dedicated to that flow
after confirming no other workload uses them. Do not delete provider API keys or JWE keys.

See [Microsoft's managed-identity federation setup](https://learn.microsoft.com/entra/workload-id/workload-identity-federation-config-app-trust-managed-identity)
for the same-tenant trust requirement and multitenant resource access.

### QA4 Live Verification

On September 15, 2026, a three-round matrix exercised the **public deployed HTTP endpoint**
for each language, using real JWE payloads, Key Vault reads, and provider HTTP. The authorized test
application obtained its ingress tokens through the existing MSI federation, without creating passwords.

| Runtime | API-key SMS | API-key Voice | Federated-JWT SMS | Federated-JWT Voice |
|---|---|---|---|---|
| JavaScript | 3/3 accepted | 3/3 accepted | 3/3 accepted | 3/3 accepted |
| Python | 3/3 accepted | 3/3 accepted | 3/3 accepted | 3/3 accepted |
| .NET | 3/3 accepted | 3/3 accepted | 3/3 accepted | 3/3 accepted |

All 36 requests returned HTTP `200` with matching nonce and correlation ID. Per-request authentication
logs confirmed `api-key` for all 18 API-key cases and `api-key+jwt` for all 18 JWT cases; no JWT pass
was an API-key fallback. No live request was retried. Readiness delays were handled with non-delivery
evaluation requests. Afterward, original settings (federated JWT enabled) and SAS-only caller allowlists
were restored, test caller denial was verified on all three apps, and temporary ingress tokens were
cleared. Existing identities, federated trust, and application passwords were unchanged. This verifies
the deployed application flow with a dedicated test caller, not execution by the actual SAS service
or handset receipt. Voice used `en-US`. It does not establish which credential Soprano prioritizes
when both JWT and API-key headers are present. Earlier secret-based and direct-MSI experiments remain
in historical reports and are not evidence for this federated flow. Subsequent source-review fixes
to SDK log privacy have offline regression coverage, but are not included
in this live result until redeployed and verified.

## Telesign EPP

The `telesign` adapter uses `POST https://verify.telesign.com/integration/msft/cyot`
for both SMS and Voice. Set `EPP_PROVIDER_NAME=telesign` and
`EPP_PROVIDER_ENDPOINT=https://verify.telesign.com` (the base URL, without the route).
This replaces the legacy `/v1/messaging` and `/v1/voice` integrations in all three languages.

Basic authentication uses `base64(customer-id:api-key)`, with the existing Key Vault secrets
`telesign-customer-id` and `telesign-api-key`. Digest and Phase 2 token authentication are not
implemented. The incoming caller's Authorization header is never forwarded.

The adapter builds the following JSON from the decrypted delivery context and envelope:

```json
{
  "recipient": { "phone_number": "+1234567890" },
  "message": { "text": "Your verification code is 4821", "language": "en" },
  "channels": [{ "channel": "voice" }],
  "correlation_id": "unique-string-123"
}
```

`phoneNumber` must match `^\+[1-9][0-9]{1,14}$`; the leading `+` is preserved. The complete
`message` is passed unchanged as `message.text`, including whitespace and OTP digit spacing.
Telesign performs text-to-speech for Voice; no separate speech object or OTP extraction is needed.
A nonblank string `locale` becomes `message.language`; otherwise language is omitted. The envelope
channel selects the single `sms` or `voice` entry. `correlation_id` uses a nonempty string request
correlation ID, falling back to the message ID for absent, empty, or non-string values. Reserved
`account_lifecycle_event` and `originating_ip` fields are
not sent; no client-IP inference or account-event default is applied. `TELESIGN_VOICE` and the
legacy sender/form fields no longer affect this adapter.

Telesign's API supports `X-Shutter-Mode: true` for direct provider tests. The Function deliberately
omits that header on live sends and does not forward it from incoming requests. Use the existing
`mode: 2` evaluation path for Function tests without delivery: it skips provider HTTP and credential
lookup entirely, rather than invoking Telesign shutter mode.

Responses normalize `reference_id` and `status.code`/`status.description` internally; provider
metadata is not logged or exposed in the public nonce response. Existing numeric success codes
are retained (SMS: 200, 203, 290-292; Voice: 100-103). CYOT code `3001` ("Message in progress"),
observed for both channels, is also accepted on successful HTTP responses. This acknowledges
provider acceptance, not handset receipt or completed audio playback. The supplied EPP integration
overview does not provide a complete replacement status-code catalog. Missing, malformed, or
unknown codes fail closed, as do unsuccessful HTTP responses. Confirm the status-code catalog and
account access with Telesign before production.

## Security

**Easy Auth (App Service Authentication) is the only caller-authentication gate, before the anonymous
Function.** Enable it with `requireAuthentication=true`, `unauthenticatedClientAction=Return401` and
`requireHttps=true`. Configure the trusted tenant issuer and `allowedAudiences` for the endpoint app,
and a **nonempty `allowedApplications`** list pinned to the authorized SAS caller application ID.
Do not exclude the SendOtp path. The handler does not parse or validate bearer tokens, and there is
no backup application validation or function-key gate. **Never expose this endpoint to the public
internet with Easy Auth disabled or bypassed.** See [platform setup](docs/ONBOARDING.md#2-provision-encryption-and-deployment-trust).

JWE decryption protects the payload but **does not authenticate SAS**: anyone with the public key can
encrypt a request. A nonce echo, including a fixed nonce, is not caller authentication. Provider API
keys are read from **Key Vault** via **managed identity**; they authenticate the outbound provider call,
not the inbound request.

Core Tools does not provide Easy Auth. Local execution is unauthenticated: bind only to loopback,
with no tunnels or public forwarding. Offline tests cover application behavior, not platform
authentication; [separate deployed security checks](docs/ONBOARDING.md#4-package-deploy-and-verify) are required.

## Docs

- **[docs/ONBOARDING.md](docs/ONBOARDING.md)**: customer setup, security, deployment, and validation.
- **[docs/CONTRACT.md](docs/CONTRACT.md)**: the language-agnostic contract every implementation follows.

## Contributing a language or provider

- **New provider** (in any language): add one adapter file exposing `manifest` + `buildRequest` +
  `parseResponse`; no engine changes. See the language folder's README.
- **New language**: mirror the folder structure, implement the contract, add the same test scenarios,
  and wire it into [.github/workflows/ci.yml](.github/workflows/ci.yml).

### Future pull requests

Start a short-lived branch from up-to-date `main`. After review and passing checks, select **Squash
and merge** to place one commit on `main`, then delete that PR's feature branch. Squashing is a merge
choice, not automatic just because commits are on a feature branch. Do not merge old feature histories
into a new branch or delete other branches containing unmerged work. This workflow does not rewrite
existing `main` history.
