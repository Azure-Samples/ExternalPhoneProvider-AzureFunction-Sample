# Technical reference

<a id="external-phone-provider-technical-reference"></a>

[Documentation](docs/README.md) | [First deployment](docs/GETTING-STARTED.md) | [HTTP contract](docs/CONTRACT.md)

This reference covers implementation details, app settings, packages, and built-in providers.

| Task | Section |
| --- | --- |
| Choose a runtime | [Implementations](#implementations) |
| Understand guided setup | [Guided EPP setup](#guided-epp-setup) |
| Download or build a package | [Download](#download-a-function-zip) or [build](#build-zips-locally) |
| Review request processing | [HTTP implementation details](#http-implementation-details) |
| Configure settings | [Environment variables](#configure-environment-variables) |
| Configure Infobip, Soprano, or Telesign | [Built-in providers](#built-in-providers) |
| Prepare for live use | [Production readiness](#production-readiness) |
| Review trust boundaries | [Security](#security) |
| Design regional continuity | [Resiliency and business continuity](#resiliency-and-business-continuity) |

## Single-region architecture

See the [single-region diagram in the sample overview](README.md#architecture).

Microsoft Entra ID sends an authenticated, encrypted request. Easy Auth checks the caller, the
Function decrypts the request, and the selected adapter submits a live message. Success means
provider acceptance, not confirmed delivery.

East US is illustrative. API-key integrations use provider secrets. OAuth integrations use
managed-identity token exchange. See [provider settings and credential acquisition](#provider-settings-and-credential-acquisition)
and [runtime logs](docs/MONITORING.md#runtime-specific-log-discovery).

An authorized **evaluation request (`mode: 2`)** returns the nonce without sending a message.
Authentication failures return **401 or 403**.

## Resiliency and business continuity

The [Azure Front Door design](docs/FRONTDOOR.md) adds regional origins behind one public URL.
It covers capacity, shared keys, dependencies, readiness, regional recovery drills, and rollback.

## Implementations

| Language | Status | Folder |
| --- | --- | --- |
| JavaScript (Node.js) | Available | [javascript/](javascript/) |
| C# (.NET isolated worker) | Available | [dotnet/](dotnet/) |
| Python (v2 model) | Available | [python/](python/) |

Choose **one language and one provider per Function App**. All implementations share the
[HTTP, configuration, and trust contract](docs/CONTRACT.md). Runtime behavior can differ.

For local work, use the selected runtime guide. To add Twilio, use
[Add Twilio](docs/BRING-YOUR-OWN-PROVIDER.md).

## Guided EPP setup

Follow the [five-step guide](docs/GETTING-STARTED.md). `Setup-Epp.ps1` retrieves its support files
from one commit and deploys after plan approval. See the [setup reference](setup/docs/README.md#step-2---download-and-run-one-script).

Review [application permissions](setup/docs/README.md#step-1---manually-create-the-application)
and [certificate selection](setup/docs/README.md#encryption-certificate-selection). Setup pins one
PEM secret version and downloads only the public certificate.

One deployment accepts SMS and voice. Each request's `channel` selects its configured provider URL.

## Download a Function ZIP

Guided setup selects and publishes the language ZIP automatically. Use this section for manual deployment.

Open the [package releases](https://github.com/Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample/releases)
and choose the newest stable tag ending in your language ID. Each language release contains
`released-package.zip` and its own `SHA256SUMS.txt`:

| Language | Release tag | Contents |
| --- | --- | --- |
| JavaScript | `epp-packages-<run>-<attempt>-javascript` | Node.js 22 application and production dependencies |
| .NET | `epp-packages-<run>-<attempt>-dotnet` | Framework-dependent .NET 8 Linux x64 publish output, including Azure Functions metadata and extensions |
| Python | `epp-packages-<run>-<attempt>-python` | Python 3.11 application with Linux x64 dependencies in `.python_packages/lib/site-packages` |

Deploy the ZIP to an Azure Functions v4 app on Linux x64 with the matching language runtime.
Verify the ZIP against `SHA256SUMS.txt` from the same language release and configure the matching
runtime, settings, Key Vault, and **Easy Auth**.

Successful `main` builds publish one versioned release per language.
PR builds publish workflow artifacts only, with each ZIP and checksum under its language folder.
These folders separate identical asset names locally; the ZIP itself contains the Function payload,
not a wrapper folder. Packaging does not deploy or verify delivery.
The `released-package.zip` filename meets the
[Flex Consumption ARM filename requirement](https://learn.microsoft.com/azure/azure-functions/functions-infrastructure-as-code#deployment-package).
Use trusted immutable release assets: setup verifies the local download, but ARM fetches the URL
again and does not enforce that locally verified SHA-256.

## Build ZIPs locally

Run one packaging script from the repository root. It creates a local ZIP without changing Azure.

| Language | Root-level script | Prerequisites | ZIP in `artifacts/` |
| --- | --- | --- | --- |
| JavaScript | [package-javascript.ps1](package-javascript.ps1) | PowerShell 7+, Node.js 20 or 22 with npm, npm registry access | `javascript/released-package.zip` |
| .NET | [package-dotnet.ps1](package-dotnet.ps1) | PowerShell 7+, .NET 8 SDK, and NuGet feed access to build the ZIP | `dotnet/released-package.zip` |
| Python | [package-python.ps1](package-python.ps1) | Linux x64, PowerShell 7+, Python 3.11 with pip, and PyPI access to build the ZIP | `python/released-package.zip` |

```powershell
pwsh -File ./package-javascript.ps1
pwsh -File ./package-dotnet.ps1
pwsh -File ./package-python.ps1
```

Choose one command. Each ZIP has `host.json` at its root and excludes local settings, credentials,
and tests.

JavaScript installs production dependencies from the lockfile in a temporary folder. Review
packaging for native dependencies or required lifecycle scripts. It does not modify `node_modules`.

**The .NET script publishes for `linux-x64`** with `--self-contained false -p:UseAppHost=false`.
The archive contains `dotnet.dll`, runtime configuration, Function metadata, and `.azurefunctions`
extensions with `host.json` at its root. Azure supplies the .NET runtime.

**Build Python packages on Linux with Python 3.11.** The script installs production binary wheels
for `manylinux2014_x86_64` into `.python_packages/lib/site-packages`. CI checks the archive and
imports the application using only the bundled dependencies.

Existing archives are never overwritten. For another build, specify a new path:

```powershell
pwsh -File ./package-javascript.ps1 -OutputPath ./artifacts/javascript-v2/released-package.zip
```

`-OutputPath` works for all three scripts. Configure the destination and follow
[deployment and validation](docs/ONBOARDING.md#4-package-deploy-and-verify). Never include secrets.

<a id="the-design-in-one-line"></a>
## Request flow

Microsoft Entra ID → Easy Auth → Function handler (`POST /api/SendOtp`, validate envelope + decrypt JWE) →
configured provider (API key or OAuth) → HTTP result with nonce on success.
Only provider acceptance returns the nonce for live requests. Incoming `mode: 2` (evaluation) is the
non-delivery path: after platform authentication, validate and decrypt, then echo the nonce without
calling a provider.

Request `tenantId`, `channel`, `mode` and `ttlSeconds` are request data, not extra environment settings.
The trusted tenant issuer, endpoint-app audience and authorized Microsoft caller are configured in Easy Auth,
not in application environment settings or incoming request data.

## HTTP implementation details

Use [Send OTP](docs/CONTRACT.md) for the public request and response. This section covers runtime
implementation details.

### JWE validation and key handling

The compact JWE must use `RSA-OAEP-256` and `A256GCM`, contain five nonempty segments, and stay
within 16,384 characters. The authentication tag is validated before plaintext is used.
`RSA-OAEP`, `A128GCM`, and `A256CBC-HS512` are rejected.

Pass the original compact JWE to the JOSE library. Do not rebuild its protected header.

`EPP_DECRYPTION_KEY_PEM` accepts a private-key PEM or a PEM certificate bundle containing the
private key, as text or base64. In Azure, use a versioned Key Vault secret reference.
`EPP_ENCRYPTION_KEY_ID` checks `kid` after decryption and logs
`encryption_key_id_mismatch` on mismatch. It does not select a key.

### Request validation and runtime differences

Required decrypted fields are nonblank `nonce`, `phoneNumber`, and `message` strings.
The optional `otp` must be a string or `null`. All runtimes carry it unchanged into the
provider-neutral delivery object (`OtpDelivery.otp` in JavaScript/Python, `OtpDelivery.Otp` in C#).
It is not converted to a number or extracted from `message`, and is not logged or returned in
the HTTP response. Existing built-in provider message and voice mappings remain unchanged.

The optional `riskContext` must be a JSON object or `null`. All runtimes parse it into the
shared `RiskContext` model with optional `scenario` and `ipAddress` strings and additional
properties for unknown signals. Values are preserved without normalization. Invalid common-field
types return `400` before provider work, including evaluation.
Adapters access common fields directly and extensions through `additionalProperties` (JavaScript),
`AdditionalProperties` (C#), or `additional_properties` (Python). Python uses `ip_address` for
the common IP field. Providers explicitly map supported fields; never forward or log the whole context.

Current runtimes do not read an incoming `textToVoice` property. The Soprano adapters build their
provider `text2voice` object from `message` and `locale`.

Validation reasons include:

- `invalid JSON body`
- `invalid envelope` or `invalid payload`
- `unsupported envelope type` or `unsupported payload type`
- `encryptedDeliveryContext is required`
- `unsupported channel`
- `unsupported mode`
- `invalid ttlSeconds`
- `ttlSeconds expired`
- `incomplete delivery context`
- `decryption_failed`

Runtime differences:

- JavaScript and Python parse JSON inside the handler. .NET binds to `EntraSendOtpPayload` first.
- .NET accepts numeric strings for channel or mode. JavaScript and Python reject them.
- JavaScript normalizes `60.0` and `6e1` to `60`. Python and .NET reject those TTL forms.
- .NET treats a null TTL as omitted.
- JavaScript uses raw correlation and request-ID headers. Python and .NET sanitize them.
- Request and correlation IDs support tracing. They do not provide deduplication.

### Provider result mapping

The shared outcomes are `Continue`, `Block`, and `Fail`.

| Result | HTTP status |
| --- | --- |
| Recognized acceptance | `200` |
| Recognized provider risk/policy block | `422` |
| Provider `429` | `429` |
| Provider `401` or `403` | `400` |
| Other provider `4xx` | `400` |
| Missing or unregistered provider selection | `400` |
| Missing or invalid endpoint, authentication-mode mismatch, credential or network failure, or unknown response | `502` |
| Provider timeout | `504` |

Unknown or incomplete provider responses fail closed. Check a timed-out live request before
retrying because the provider might already have accepted it.

HTTP `401` and `403` are reserved for inbound SAS-to-Function authentication, authorization, or
platform access failures. HTTP `422` carries `error: "provider_blocked"` without a nonce.
Existing SAS classifies completed `400` and `422` responses as endpoint client errors, without
HTTP retry or endpoint failure/slowdown-breaker accounting. This does not suppress permitted native
fallback or add a distinct provider-blocked SAS log category.
See [existing SAS behavior and limitations](docs/CONTRACT.md#provider-blocks-and-existing-sas-behavior).

Provider adapters use these safe failure labels: `provider_http_error`, `provider_blocked`, `provider_rejected`,
`unrecognized_provider_status`, `missing_provider_message_id`, and `invalid_provider_json`.

## Configure environment variables

For guided deployment, inspect the [values and ownership table](docs/ONBOARDING.md#values-and-ownership).
The following settings are for local or manual deployment.

Start from [sample settings](docs/local.settings.sample.json). Every `Values` entry is a string.

Set the runtime to `node`, `python`, or `dotnet-isolated`, then replace the placeholders. The
sample storage value requires **Azurite** and is for local use only.

Local settings supply environment variables, **not a serialized `AppConfig` or request model**.
For example, `EPP_PROVIDER_NAME` becomes `config.providerName` in JavaScript,
`config.provider_name` in Python, and `config.ProviderName` in .NET.

| Variable | When needed | Value |
| --- | --- | --- |
| `AzureWebJobsStorage` | Functions host storage | Local sample: `UseDevelopmentStorage=true` with Azurite running. Configure Azure host storage separately for the selected plan. |
| `FUNCTIONS_WORKER_RUNTIME` | Local host / EP1 | `node`, `python`, or `dotnet-isolated`. FC1 uses `functionAppConfig.runtime` instead. Do not add this EP1 setting to FC1. |
| `EPP_DECRYPTION_KEY_PEM` | Every request | Local test PEM or base64 PEM. In Azure, use a Key Vault reference resolving to the private-key secret. Guided setup pins the PEM backing secret of its Key Vault certificate. |
| `EPP_ENCRYPTION_KEY_ID` | Optional | Expected encryption key ID. A mismatch only produces an advisory warning. |

<a id="provider-settings-and-credential-caching"></a>
### Provider settings and credential acquisition

- **Provider:** `EPP_PROVIDER_NAME`, `EPP_PROVIDER_AUTH_MODE`, and
  `EPP_PROVIDER_ENDPOINT_REGION`.
- **Endpoints:** `EPP_PROVIDER_SMS_ENDPOINT` and `EPP_PROVIDER_VOICE_ENDPOINT`.
- **Timeout and account:** `EPP_PROVIDER_TIMEOUT_MS` and `EPP_PROVIDER_ACCOUNT_NAME`.
- **Key Vault:** `KEY_VAULT_URL` and optional `AZURE_CLIENT_ID`.
- **OAuth:** `EPP_PROVIDER_TENANT_ID`, `EPP_PROVIDER_SCOPE`, `EPP_OUTBOUND_CLIENT_ID`, and
  `EPP_OUTBOUND_MI_CLIENT_ID`.

For OAuth, setup maps profile `deployment.AccessTokenScopeTenant` to `EPP_PROVIDER_TENANT_ID`.
The adjacent `deployment.tenantId` remains the provider's Security Store tenant and identifies
the provider during application discovery. If an older profile omits `AccessTokenScopeTenant`,
setup uses `tenantId`; explicit empty, invalid, or placeholder values fail validation.
Both provider tenants are included in the reviewed app allowlist, preserving existing entries.
This does not change inbound Easy Auth or use request `tenantId` as a source of trust.

All runtimes use `ManagedIdentityCredential` for Key Vault and outbound token access. They do not
fall back to a developer's Azure CLI identity.

The provider timeout defaults to `1500` and is capped at `2500` milliseconds.

Each live request uses the endpoint for its selected channel. Endpoints must be absolute HTTPS
URLs with a hostname, valid port, no user information, and no fragment. Redirects are not followed.
Each channel uses only its configured endpoint. A secondary provider requires the
[advanced secondary-provider design](docs/MULTI-PROVIDER-IMPLEMENTATION.md).

All runtimes acquire provider credentials on demand for each live request:

- **API keys:** read the required secret values from Key Vault each time. A failed read does not
  reuse a previous secret bundle.
- **OAuth:** reuse Azure Identity SDK credential instances and call their token API for each
  request. The SDK owns token caching and renewal; a usable cached token does not require
  another token exchange. Managed-identity assertions are obtained only when the SDK needs them.

There are no application-owned provider credential caches, startup warmup, background refresh
loops, or failure cooldowns. Evaluation skips provider credential work. Acquisition retains its
2.5-second budget. A failure returns `502` with a request-correlated `credential_unavailable`
log; the next live request can attempt acquisition again.

`EPP_KEY_VAULT_CACHE_ENABLED` and `EPP_ACCESS_TOKEN_CACHE_ENABLED` are obsolete and ignored by
current packages. Setup no longer writes them for either hosting plan. Deploy the updated package
to remove the old behavior; changing settings alone does not update an older package.
Restart the worker after credential configuration changes so its SDK clients use the new settings.
This does not change the platform's decryption-key reference or in-process PEM key handling.

1. **Locally:** create private local settings beside the chosen runtime's host file, following its
  [JavaScript](javascript/README.md#environment-configuration), [Python](python/README.md#environment-configuration)
  or [.NET](dotnet/README.md#environment-configuration) instructions. Restart the host after edits.
2. **In Azure:** set the same application variables on the selected Function App (or serving slot)
  under **Settings → Environment variables → App settings**, then apply the changes. Local settings
  are not published automatically. Configure host storage separately for the selected hosting plan.
Evaluation needs the decryption key but not provider settings. Use offline tests or loopback-only
evaluation locally. Never commit local settings, keys, or test credentials.

Core Tools does not resolve Azure Key Vault reference expressions locally. Supply the local test PEM
or base64 PEM directly. Use a reference such as `@Microsoft.KeyVault(SecretUri=https://<vault>.vault.azure.net/secrets/<private-key-secret>/)`
for `EPP_DECRYPTION_KEY_PEM` in Azure app settings, where the platform resolves it.
Guided setup uses the **versioned** backing-secret URL recorded as `certificateSecretId` in the
deployment summary. Initial creation uses `phone-provider-encryption`. Replacement uses a suffixed
name, and reuse preserves the selected certificate's name and vault. The secret contains the
certificate and its exportable RSA private key in PEM format. Do not reconstruct its URL from the
certificate name or version. A new Key Vault certificate version does not automatically switch
the Function or update Microsoft Entra ID. See
[certificate lifecycle](setup/docs/README.md#encryption-certificate-lifecycle).

Configure inbound issuer/audience/caller trust in **Easy Auth**, not these application variables.
Incoming `tenantId`, `channel`, `mode` and `ttlSeconds` are request data and never override the
configured provider or authentication. `channel` selects the configured SMS or voice endpoint.
Every deployment can serve both configured channels. The legacy `EPP_PROVIDER_CHANNEL` setting is ignored.

<a id="provider-specific-integration-details"></a>
## Built-in providers

<a id="telesign-epp"></a>
<a id="soprano-integration"></a>
<a id="telesign-integration"></a>

Guided setup supports the sample's built-in **Infobip**, **Soprano**, and **Telesign** integrations.
Use the [credential and deployment-support table](docs/ONBOARDING.md#provider-credential-names)
for onboarding.

### Infobip

Infobip uses OAuth only, with the same managed-identity client-assertion exchange and settings as
[Soprano](#soprano). No `infobip-api-key` secret is read. The
[guided profile](setup/providers/infobip.json) supplies the Security Store manifest's provider
tenant and API application ID; its OAuth scope is that application ID followed by `/.default`.
Provider-side authorization of the customer application is still required.

Both channel settings are **base URLs**, without a message path or trailing slash:

| Provider route | `EPP_PROVIDER_SMS_ENDPOINT` and `EPP_PROVIDER_VOICE_ENDPOINT` |
| --- | --- |
| Global | `https://api.infobip.com` |
| EU | `https://api-eu.infobip.com` |

The adapters preserve the API-key-tested request and response contracts: append `/sms/3/messages`
for SMS or `/tts/3/advanced` for voice, and send the existing `messages` payload with OAuth
`Authorization: Bearer <access-token>` instead of `App <api-key>`. Voice does **not** switch to
the manifest's `/tts/3/single` contract, and neither channel uses plain HTTP.
Message text, destinations, correlation IDs, locale, and voice options are unchanged.
Recognized success groups remain `ACCEPTED`, `PENDING`, and `DELIVERED` on successful HTTP responses;
unknown statuses fail closed.

Set `EPP_PROVIDER_ACCOUNT_NAME` to an Infobip-approved sender/caller ID and confirm it works for
both intended channels. The adapter's existing `Verify` fallback is not proof of sender approval.

For an older API-key deployment, deploy a package containing this OAuth update and rerun setup
with `-Provider infobip` to configure federation and the provider tenant/scope. Review
`EPP_PROVIDER_AUTH_MODE=oauth` and the regional base URLs. Updating settings alone does not upgrade
an older adapter; this version has no API-key fallback. Complete
[provider authorization](docs/ONBOARDING.md#complete-provider-authentication) before live use.

### Soprano

Soprano uses OAuth client-assertion exchange with:

- `EPP_PROVIDER_TENANT_ID`
- `EPP_PROVIDER_SCOPE`
- `EPP_OUTBOUND_CLIENT_ID`
- `EPP_OUTBOUND_MI_CLIENT_ID`

The outbound managed identity first requests `api://AzureADTokenExchange/.default`. The configured
provider scope is used for the final token sent to `/messages/omnimsg`. The Function stores no
Soprano client secret and does not forward the incoming Microsoft Entra ID token.
Missing settings, blank tokens, and tokens with 30 seconds or less remaining fail before provider
HTTP. Soprano uses OAuth only, and the adapter does not retry provider sends.

For voice, the adapter extracts the first six consecutive digits from `message`, uses the request
locale or `en-US`, and sends `beforePasswordText`, `password`, and `afterPasswordText` in
`voice.text2voice`. A message without six consecutive digits fails before provider HTTP.

### Telesign

Telesign uses OAuth only, with the same managed-identity client-assertion exchange and settings as
[Soprano](#soprano). Complete the
[Telesign profile](docs/ONBOARDING.md#telesign-oauth-configuration-and-handoff) before deployment.

The adapter sends `recipient.phone_number`, `message.text`, optional `message.language`, one
`channels[].channel`, and `correlation_id`. SMS forwards the message unchanged. Voice separates
standalone six-digit runs with commas and repeats the message twice.
`phoneNumber` must match `^\+[1-9][0-9]{1,14}$`.

When present in the decrypted `riskContext`, `scenario` maps to `account_lifecycle_event` and
`ipAddress` maps to `originating_ip`. String values are forwarded unchanged, including casing;
missing or `null` values are omitted. The shared `RiskContext` model rejects non-string common
fields during parsing before provider work. Other risk fields are not forwarded, and no risk
fields are logged. Telesign documents lifecycle values
`create`, `sign-in`, `transact`, `update`, and `delete`; the adapter does not normalize values such
as `signIn` or `signin`, so the provider may reject them.

Recognized success codes:

- SMS: `200`, `203`, `290`, `291`, `292`
- Voice: `100`, `101`, `102`, `103`
- Either channel: `3001` on a successful HTTP response

On a successful HTTP response, Intelligence status `3072` maps to a blocked outcome and endpoint
HTTP `422` with `error: "provider_blocked"`, not an authentication failure or provider outage.
Non-successful provider HTTP responses still override status
mapping. Unknown or malformed statuses fail closed. Acceptance does not confirm handset receipt
or completed audio. Evaluation remains provider-independent and does not call Telesign shutter mode.

## Production readiness

Before live use:

- Keep Easy Auth enabled for every public `/api/SendOtp` route.
- Use managed identity for Key Vault access.
- Keep phone numbers, messages, passcodes, nonces, tokens, keys, JWE contents, raw exceptions,
  and provider responses out of logs.
- Validate evaluation, live acceptance, recipient delivery, caller rejection, invalid payloads,
  and tampered JWE independently.
- Define end-to-end timing, duplicate-send protection, retry handling, certificate renewal,
  rollback, monitoring, and delivery confirmation.
- Check a timeout with the provider before retrying.

## Security

**Easy Auth is the caller-authentication gate before the Function runs.**
Follow the [exact trust checklist](docs/ONBOARDING.md#manual-deployment-trust-checklist) for HTTPS,
issuer, audience, caller allowlist, and unauthenticated rejection. Never disable it or exempt SendOtp.
The handler does not validate bearer tokens itself and does not accept a function key as an
alternative.

JWE encryption and the nonce do not identify the caller. Anyone with the public key can encrypt.
Provider credentials authenticate outbound calls, not incoming requests. Vault access uses managed identity.
Because Core Tools does not provide Easy Auth, bind local hosts to loopback without tunnels.
[Deployed checks](docs/ONBOARDING.md#validate-the-deployed-endpoint) remain required after offline tests.

## Docs

Use the [documentation index](docs/README.md) for setup, troubleshooting, operations, and advanced designs.
For code changes, review both the [HTTP contract](docs/CONTRACT.md) and
[log schema](docs/LOGGING.md).

## Contributing a language or provider

- **New provider**: follow the selected language's provider base/interface and registration steps.
  Internal method names differ by runtime. A bundled adapter is not automatically a guided setup
  profile or an approved provider offer.
- **New language**: mirror the folder structure, implement the contract, add the same test scenarios,
  and wire it into [.github/workflows/ci.yml](.github/workflows/ci.yml).
