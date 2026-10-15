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

Microsoft Entra ID sends an authenticated, encrypted request. Easy Auth checks the caller, the
Function decrypts the request, and the selected adapter submits a live message. Success means
provider acceptance, not confirmed delivery.

East US is illustrative. API-key integrations use provider secrets; OAuth integrations use
managed-identity token exchange. See [credential caching](docs/CONTRACT.md#credential-caching-and-refresh)
and [runtime logs](docs/MONITORING.md#runtime-specific-log-discovery).

An authorized **evaluation request (`mode: 2`)** returns the nonce without sending a message.
Authentication failures return **401 or 403**.

## Resiliency and business continuity

The [Azure Front Door design](docs/FRONTDOOR.md) adds regional origins behind one public URL.
It covers capacity, shared keys, dependencies, readiness, failover drills, and rollback.

## Implementations

| Language | Status | Folder |
|----------|--------|--------|
| JavaScript (Node.js) | Available | [javascript/](javascript/) |
| C# (.NET isolated worker) | Available | [dotnet/](dotnet/) |
| Python (v2 model) | Available | [python/](python/) |

Choose **one language and one provider per Function App**. All implementations share the
[HTTP, configuration, and trust contract](docs/CONTRACT.md); runtime behavior can differ.

For local work, use the selected runtime guide. For a custom integration, start with
[Bring your own provider](docs/BRING-YOUR-OWN-PROVIDER.md).

## Guided EPP setup

Follow the [five-step guide](docs/GETTING-STARTED.md). `Setup-Epp.ps1` retrieves its support files
from one commit and deploys after plan approval. See the [setup reference](setup/docs/README.md#step-2---download-and-run-one-script).

Review [application permissions](setup/docs/README.md#step-1---manually-create-the-application)
and [certificate selection](setup/docs/README.md#encryption-certificate-selection). Setup pins one
PEM secret version and downloads only the public certificate.

One deployment accepts SMS and voice; each request's `channel` selects its configured provider URL.

## Download a Function ZIP

Guided setup already publishes the package. Use this section for manual deployment.

Download the latest successful CI ZIP for your chosen language:

| Language | Download | Contents |
|---|---|---|
| JavaScript | [epp-javascript.zip](https://github.com/Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample/releases/latest/download/epp-javascript.zip) | Application and production dependencies |
| .NET | [epp-dotnet-source.zip](https://github.com/Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample/releases/latest/download/epp-dotnet-source.zip) | C# Function source and project file; build/publish before deployment |
| Python | [epp-python-source.zip](https://github.com/Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample/releases/latest/download/epp-python-source.zip) | Source for Azure remote build on Linux |

Verify `SHA256SUMS.txt`, configure the runtime, settings, Key Vault, and **Easy Auth**, then build
.NET or use Python remote build. Source ZIPs are not run-from-package artifacts.

Successful `main` builds publish a versioned [release](https://github.com/Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample/releases/latest).
PR builds publish workflow artifacts only. Packaging does not deploy or verify delivery.

## Build ZIPs Locally

Run one packaging script from the repository root. It creates a local ZIP without changing Azure.

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

Choose one command. Each ZIP has `host.json` at its root and excludes local settings, credentials,
and tests.

JavaScript installs production dependencies from the lockfile in a temporary folder. Review
packaging for native dependencies or required lifecycle scripts. It does not modify `node_modules`.

**The .NET download contains source.** Run
`dotnet publish dotnet.csproj --configuration Release --output ../publish` with .NET 8, then deploy
the publish output with `host.json` at its root. The archive includes `dotnet.csproj`,
`Program.cs`, `Functions/`, and `Src/`, and excludes `bin/` and `obj/`.

**The Python download contains source.** Deploy it to Linux with remote build so Azure installs
`requirements.txt`.

Existing archives are never overwritten. For another build, specify a new path:

```powershell
pwsh -File ./package-javascript.ps1 -OutputPath ./artifacts/epp-javascript-v2.zip
```

`-OutputPath` works for all three scripts. Configure the destination and follow
[deployment and validation](docs/ONBOARDING.md#4-package-deploy-and-verify). Never include secrets.

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

For guided deployment, inspect the [values and ownership table](docs/ONBOARDING.md#values-and-ownership).
The following settings are for local or manual deployment.

Start from [sample settings](docs/local.settings.sample.json). Every `Values` entry is a string.

Change `node` to `python` or `dotnet-isolated` as needed. Replace placeholders. The sample storage
value requires **Azurite** and must not be copied to Azure.

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
`message` unchanged as `message.text`, including whitespace. For Voice, each standalone six-digit
number is rendered with comma-separated digits. The complete paced message is sent twice with one
separating space. Telesign performs text-to-speech for Voice; no
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

Responses normalize `reference_id` and `status.code`/`status.description` internally. Provider
metadata is not exposed in the public nonce response. [Application logs](docs/LOGGING.md#safe-fields-and-identifiers)
include the provider HTTP status and mapped status/outcome. They also include a length-limited
provider reference ID as `providerMessageId` for support lookup. They exclude the raw response
and description.
Existing numeric success codes remain unchanged (SMS: 200, 203, 290-292; Voice: 100-103).
EPP code `3001` ("Message in progress"),
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
