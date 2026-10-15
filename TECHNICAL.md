# Technical reference

<a id="external-phone-provider-technical-reference"></a>

[Documentation](docs/README.md) | [First deployment](docs/GETTING-STARTED.md) | [HTTP contract](docs/CONTRACT.md)

This reference covers implementation details, app settings, and packages.
Sections: [implementations](#implementations), [guided setup](#guided-epp-setup),
[download](#download-a-function-zip), [build](#build-zips-locally),
[settings](#configure-environment-variables), [provider details](#provider-specific-integration-details),
or [security](#security). For regional continuity, see
[resiliency and business continuity](#resiliency-and-business-continuity).

## Single-region architecture

See the [single-region diagram in the sample overview](README.md#architecture).

Microsoft Entra ID sends an authenticated, encrypted request. Easy Auth checks the caller,
then the Function decrypts the request using its Key Vault-backed key. For a live request, the
selected adapter submits the message and returns success after provider acceptance, not after
confirmed recipient delivery. Application Insights collects the available request and log telemetry.

The diagram is an overview, not a portal screenshot. East US is illustrative; select a region
with capacity and quota for your hosting plan. The provider-secret path applies to API-key
integrations; OAuth integrations use managed-identity token exchange instead. Credential caching
depends on the [selected cache settings](docs/CONTRACT.md#credential-caching-and-refresh), and
[log formats vary by runtime](docs/MONITORING.md#runtime-specific-log-discovery).

An authorized, valid encrypted **evaluation request (`mode: 2`)** returns the matching nonce
without submitting a message to the provider. When caching is enabled, credential preparation
can run independently; it never sends an OTP. Authentication failures can return **401 or 403**,
neither of which is a successful evaluation.

## Resiliency and business continuity

Start with a validated single-region deployment. When regional continuity is required, the
[Azure Front Door design](docs/FRONTDOOR.md) describes one public URL across independently
provisioned regional origins while preserving the SendOtp contract.

The guide covers survivor capacity, shared encryption-key coordination, regional dependencies,
safe failover drills, and rollback. It also defines a dedicated non-delivering readiness endpoint
to implement and validate with each regional package. Build regional provisioning and readiness
into your approved BCDR process, then activate only after both directions pass the documented checks.

## Implementations

| Language | Status | Folder |
|----------|--------|--------|
| JavaScript (Node.js) | Available | [javascript/](javascript/) |
| C# (.NET isolated worker) | Available | [dotnet/](dotnet/) |
| Python (v2 model) | Available | [python/](python/) |

Choose **one language and one provider per Function App**; no provider is preferred or selected
by default. All implementations share the [HTTP, configuration, and trust contract](docs/CONTRACT.md),
but provider APIs, binding errors, credential caching, and telemetry can differ by runtime.

For [local development or manual deployment](docs/ONBOARDING.md#optional-local-development-and-manual-deployment),
follow the selected runtime guide. For a custom service integration, start with the
[provider-neutral BYOT interface](docs/BRING-YOUR-OWN-PROVIDER.md), then implement and validate
the outbound adapter through the selected runtime.

## Guided EPP setup

Follow the [five-step guide](docs/GETTING-STARTED.md), including its access and approval gates.
Download only `Setup-Epp.ps1`; it retrieves its support files from one commit and deploys after
you approve the complete plan. The [setup reference](setup/docs/README.md#step-2---download-and-run-one-script)
explains provider, route, runtime, hosting, and resource choices.

Review [application permissions and caller trust](setup/docs/README.md#step-1---manually-create-the-application),
including tenant-wide Graph `Application.Read.All`, and the
[certificate selection rules](setup/docs/README.md#encryption-certificate-selection).
Setup pins one PEM secret version and verifies Function access before changing registered encryption
credentials. Only the public certificate is downloaded. Replacement requires coordinated maintenance,
not zero-downtime rotation; certificate synchronization and policy activation remain manual.

One deployment accepts SMS and voice; each request's `channel` selects its configured provider URL.

## Download a Function ZIP

**Optional developer/manual deployment path:** guided setup already selects, verifies, builds as
needed, and publishes the package. Customers using it should continue with
[provider authentication and validation](docs/ONBOARDING.md#complete-provider-authentication);
the deployed package is ready for that handoff.

Download the latest successful CI ZIP for your chosen language:

| Language | Download | Contents |
|---|---|---|
| JavaScript | [epp-javascript.zip](https://github.com/Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample/releases/latest/download/epp-javascript.zip) | Application and production dependencies |
| .NET | [epp-dotnet-source.zip](https://github.com/Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample/releases/latest/download/epp-dotnet-source.zip) | C# Function source and project file; build/publish before deployment |
| Python | [epp-python-source.zip](https://github.com/Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample/releases/latest/download/epp-python-source.zip) | Source for Azure remote build on Linux |

Downloads need no PowerShell or build tools. Verify the release's `SHA256SUMS.txt`, then configure
the target runtime, app settings, Key Vault access, and **Easy Auth before deployment**.
Build/publish .NET source; use Azure remote build for Python dependencies. Neither source ZIP is
directly runnable as a run-from-package artifact. **Code > Download ZIP** is the repository, not
a deployment package.

Each successful `main` build tests all three runtimes and inspects the ZIPs before publishing a
versioned [latest release](https://github.com/Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample/releases/latest).
These links and guided setup track that release; older assets remain available and are not overwritten.
PR builds publish workflow artifacts only, which may require GitHub sign-in. Public releases do not.
Packaging neither deploys nor verifies provider delivery.

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
JavaScript dependencies. When adding native dependencies or packages that require install scripts,
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
extend it deliberately when adding runtime assets, and never put secrets in application source.

## The design in one line

Microsoft Entra ID → Easy Auth → anonymous HTTP handler (`POST /api/SendOtp`, validate envelope + decrypt JWE) →
configured provider (API key or OAuth) → HTTP result with nonce on success.
Only provider acceptance returns the nonce for live requests. Incoming `mode: 2` (evaluation) is the
non-delivery path: after platform authentication, validate and decrypt, then echo the nonce without
calling a provider.

Request `tenantId`, `channel`, `mode` and `ttlSeconds` are request data, not extra environment settings.
The trusted tenant issuer, endpoint-app audience and authorized Microsoft caller are configured in Easy Auth,
not in application environment settings or incoming request data.

## Configure environment variables

For guided deployment, use the [customer values and ownership table](docs/ONBOARDING.md#values-and-ownership)
to inspect what setup already configured. The following sample/local instructions are for
developers and manual deployments; they are not an extra guided-setup step.

Use the [sample settings](docs/local.settings.sample.json) as the starting point for the chosen
runtime. All entries in its `Values` object are **strings**. The application reads environment
variables; Azure Functions Core Tools loads that `Values` object for local runs.

The sample uses `node`; change it to `python` or `dotnet-isolated` for those runtimes. Replace the
provider, endpoint, vault and test-key placeholders before use. Its storage value assumes **Azurite
is running**; do not copy `UseDevelopmentStorage=true` into Azure. Optional settings stay in the table
below rather than appearing as required placeholders in the sample. Keep explanatory comments outside
`Values`, otherwise the host loads them as environment variables too.

Local settings supply environment variables, **not a serialized `AppConfig` or request model**.
For example, `EPP_PROVIDER_NAME` becomes `config.providerName` in JavaScript,
`config.provider_name` in Python, and `config.ProviderName` in .NET.

| Variable | When needed | Value |
|---|---|---|
| `AzureWebJobsStorage` | Functions host storage | Local sample: `UseDevelopmentStorage=true` with Azurite running. Configure Azure host storage separately for the selected plan. |
| `FUNCTIONS_WORKER_RUNTIME` | Local host / EP1 | `node`, `python`, or `dotnet-isolated`. FC1 uses `functionAppConfig.runtime` instead; do not add this EP1 setting to FC1. |
| `EPP_DECRYPTION_KEY_PEM` | Every request | Local test PEM or base64 PEM. In Azure, use a Key Vault reference resolving to the private-key secret. Guided setup pins the PEM backing secret of its Key Vault certificate. |
| `EPP_ENCRYPTION_KEY_ID` | Optional | Expected encryption key ID; mismatch only produces an advisory warning. |
| `EPP_PROVIDER_NAME` | Live delivery | Selected adapter's manifest ID. No default provider. |
| `EPP_PROVIDER_SMS_ENDPOINT` | Required for SMS delivery | Provider-approved HTTPS SMS endpoint. Guided setup writes the complete send URL from the selected regional profile. |
| `EPP_PROVIDER_VOICE_ENDPOINT` | Required for voice delivery | Provider-approved HTTPS voice endpoint, which can differ from the SMS endpoint. Guided setup writes the complete send URL. |
| `EPP_PROVIDER_ENDPOINT_REGION` | Guided deployment metadata | Selected `global` or `eu` route label. |
| `EPP_PROVIDER_AUTH_MODE` | Live delivery | Must match the adapter: `apiKey` for Infobip, Sinch, or Telesign; `oauth` for Soprano. Bundled adapters do not all have guided setup profiles. |
| `EPP_PROVIDER_TENANT_ID`, `EPP_PROVIDER_SCOPE` | Soprano OAuth | Provider tenant and selected API scope. |
| `EPP_OUTBOUND_CLIENT_ID`, `EPP_OUTBOUND_MI_CLIENT_ID` | Soprano OAuth | Existing multitenant application and outbound user-assigned managed identity used for client-assertion exchange. |
| `EPP_PROVIDER_TIMEOUT_MS` | Optional | Decimal milliseconds. Defaults to `1500`, capped at `2500`; not an end-to-end deadline. |
| `EPP_KEY_VAULT_CACHE_ENABLED` | Optional | `true` enables provider API-key bundle caching; `false` reads the bundle for each live request. Unset defaults to `true`. |
| `EPP_ACCESS_TOKEN_CACHE_ENABLED` | Optional | `true` enables OAuth credential caching; `false` uses request-scoped MI/client-assertion credentials. Unset defaults to `true`. |
| `EPP_PROVIDER_ACCOUNT_NAME` | Adapter-dependent | Sender/account metadata, not an API key or credential identity. |
| `KEY_VAULT_URL` | Provider credential lookup | URI of the vault containing the manifest-named provider secrets. Separate from the encryption-key reference. |
| `AZURE_CLIENT_ID` | Optional | User-assigned managed identity's client ID for Key Vault. Leave unset for system-assigned identity. |

The request's channel-specific endpoint is required. A missing, empty, or invalid endpoint fails
closed; there is no shared or other-channel endpoint fallback. Telesign and Soprano
use complete URLs unchanged. Infobip and Sinch retain their adapter-specific base-URL behavior;
see [endpoint selection](docs/CONTRACT.md#default-provider-and-configuration-readers).

1. **Locally:** create private local settings beside the chosen runtime's host file, following its
  [JavaScript](javascript/README.md#environment-configuration), [Python](python/README.md#environment-configuration)
  or [.NET](dotnet/README.md#environment-configuration) instructions. Restart the host after edits.
2. **In Azure:** set the same application variables on the selected Function App (or serving slot)
  under **Settings → Environment variables → App settings**, then apply the changes. Local settings
  are not published automatically. Configure host storage separately for the selected hosting plan.
3. For Telesign, store provider API credentials in Key Vault using the exact manifest names. For
  Soprano, configure provider consent plus the profile's tenant/scope and outbound managed-identity
  federation; the Function stores no Soprano client secret.

Evaluation requests do not need provider variables or provider secrets. They still need the decryption
key. The default credential resolvers use `ManagedIdentityCredential`, **not** the developer's CLI
login; ordinary local machines have no managed-identity endpoint. Use offline tests or loopback-only
evaluation locally, or an explicitly injected test resolver for integration work. Never commit local
settings, keys or test credentials.

For cache values, failure behavior, and runtime differences, use the
[credential caching contract](docs/CONTRACT.md#credential-caching-and-refresh).
JavaScript/Python poll; .NET refreshes on cache misses. Setup writes both switches as `false` for FC1
or `true` for EP1; deploy a supporting package and restart after changes.
Evaluation skips provider work, but cached workers can independently acquire credentials without
sending an OTP. Leave `EPP_PROVIDER_NAME` unset or disable its cache for local evaluation without
credential acquisition. Provider caching is separate from platform-managed identity caching and
decryption-key references.

Core Tools does not resolve Azure Key Vault reference expressions locally. Supply the local test PEM
or base64 PEM directly; use a reference such as `@Microsoft.KeyVault(SecretUri=https://<vault>.vault.azure.net/secrets/<private-key-secret>/)`
for `EPP_DECRYPTION_KEY_PEM` in Azure app settings, where the platform resolves it.
Guided setup uses the **versioned** backing-secret URL recorded as `certificateSecretId` in the
deployment summary. Initial creation uses `phone-provider-encryption`; replacement uses a suffixed
name, and reuse preserves the selected certificate's name and vault. The secret contains the
certificate and its exportable RSA private key in PEM format. Do not reconstruct its URL from the
certificate name or version. A new Key Vault certificate version does not automatically switch
the Function or update Entra. See [certificate lifecycle](setup/docs/README.md#encryption-certificate-lifecycle).

Configure inbound issuer/audience/caller trust in **Easy Auth**, not these application variables.
Incoming `tenantId`, `channel`, `mode` and `ttlSeconds` are request data and never override the
configured provider or authentication. `channel` selects the configured SMS or voice endpoint;
there is no deployment-level channel restriction. The legacy `EPP_PROVIDER_CHANNEL` setting is ignored.

## Provider-specific integration details

Use the [credential and deployment-support table](docs/ONBOARDING.md#provider-credential-names)
for your selected adapter. The [Soprano OAuth and voice contract](docs/CONTRACT.md#soprano-provider-jwt)
and [Telesign EPP contract](docs/CONTRACT.md#telesign-epp-integration) describe different API requirements,
not a provider ranking. The wire example below illustrates Telesign's format only.

### Telesign EPP

The `telesign` adapter sends its JSON contract to the complete SMS or voice URL selected by the
request channel from the configured endpoints. It does not append or infer a route.

Basic authentication uses `base64(customer-id:api-key)`, with the existing Key Vault secrets
`telesign-customer-id` and `telesign-api-key`. Digest and provider-token authentication are not
implemented. The incoming caller's Authorization header is never forwarded.

For an SMS request, the adapter builds the following JSON from the decrypted delivery context and envelope:

```json
{
  "recipient": { "phone_number": "+1234567890" },
  "message": { "text": "Your verification code is 4821", "language": "en" },
  "channels": [{ "channel": "sms" }],
  "correlation_id": "unique-string-123"
}
```

`phoneNumber` must match `^\+[1-9][0-9]{1,14}$`; the leading `+` is preserved. SMS passes the complete
`message` unchanged as `message.text`, including whitespace. For Voice, each six-digit numeric run
that is not part of a longer number is rendered with comma-separated digits, and the complete paced
message is sent twice with one separating space. Telesign performs text-to-speech for Voice; no
separate speech object is needed.
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
metadata is not exposed in the public nonce response. [Application logs](docs/LOGGING.md#safe-fields-and-identifiers)
include only the provider HTTP status, mapped status/outcome and the bounded raw provider reference
ID as `providerMessageId` for support lookup, never the raw response or description. Existing numeric success codes
are retained (SMS: 200, 203, 290-292; Voice: 100-103). EPP code `3001` ("Message in progress"),
observed for both channels, is also accepted on successful HTTP responses. This acknowledges
provider acceptance, not handset receipt or completed audio playback. The sample's recognized
codes are not a complete provider status-code catalog. Missing, malformed, or
unknown codes fail closed, as do unsuccessful HTTP responses. Confirm the status-code catalog and
account access with Telesign before production.

## Security

**Easy Auth is the only caller-authentication gate before the anonymous Function.**
Follow the [exact trust checklist](docs/ONBOARDING.md#manual-deployment-trust-checklist) for HTTPS,
issuer, audience, caller allowlist, and unauthenticated rejection. Never disable it or exempt SendOtp;
there is no handler token validator or function-key fallback.

JWE and its nonce prove no caller identity: anyone with the public key can encrypt.
Provider credentials authenticate outbound calls, not incoming requests; vault access uses managed identity.
Core Tools has no Easy Auth: bind locally to loopback without tunnels.
[Deployed checks](docs/ONBOARDING.md#validate-the-deployed-endpoint) remain required after offline tests.

## Docs

Use the [documentation index](docs/README.md) for setup, troubleshooting, operations, and advanced designs.
For code work, keep the [HTTP contract](docs/CONTRACT.md) and [log schema](docs/LOGGING.md) together.

## Contributing a language or provider

- **New provider**: follow the selected language's provider base/interface and registration steps.
  Internal method names differ by runtime. A bundled adapter is not automatically a guided setup
  profile or an approved provider offer.
- **New language**: mirror the folder structure, implement the contract, add the same test scenarios,
  and wire it into [.github/workflows/ci.yml](.github/workflows/ci.yml).

### Future pull requests

Start a short-lived branch from up-to-date `main`. After review and passing checks, select **Squash
and merge** to place one commit on `main`, then delete that PR's feature branch. Squashing is a merge
choice, not automatic just because commits are on a feature branch. Do not merge old feature histories
into a new branch or delete other branches containing unmerged work. This workflow does not rewrite
existing `main` history.
