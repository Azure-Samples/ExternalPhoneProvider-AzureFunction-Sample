# Technical reference

<a id="external-phone-provider-technical-reference"></a>

[Documentation](docs/README.md) | [First deployment](docs/GETTING-STARTED.md) | [HTTP contract](docs/CONTRACT.md)

This reference covers implementation details, app settings, and packages.
Sections: [implementations](#implementations), [guided setup](#guided-epp-setup),
[download](#download-a-function-zip), [build](#build-zips-locally),
[HTTP details](#http-implementation-details), [settings](#configure-environment-variables),
[built-in providers](#built-in-providers), [production readiness](#production-readiness),
or [security](#security). For regional continuity, see
[resiliency and business continuity](#resiliency-and-business-continuity).

## Single-region architecture

See the [single-region diagram in the sample overview](README.md#architecture).

Microsoft Entra ID sends an authenticated, encrypted request. Easy Auth checks the caller, the
Function decrypts the request, and the selected adapter submits a live message. Success means
provider acceptance, not confirmed delivery.

East US is illustrative. API-key integrations use provider secrets. OAuth integrations use
managed-identity token exchange. See [provider settings and caching](#provider-settings-and-credential-caching)
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

Guided setup already publishes the package. Use this section for manual deployment.

Download the latest successful CI ZIP for your chosen language:

| Language | Download | Contents |
|---|---|---|
| JavaScript | [epp-javascript.zip](https://github.com/Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample/releases/latest/download/epp-javascript.zip) | Application and production dependencies |
| .NET | [epp-dotnet-source.zip](https://github.com/Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample/releases/latest/download/epp-dotnet-source.zip) | C# Function source and project file. Build and publish before deployment. |
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
| .NET | [package-dotnet.ps1](package-dotnet.ps1) | PowerShell 7+ to package. .NET 8 SDK and NuGet feed access when customers build. | `epp-dotnet-source.zip` |
| Python | [package-python.ps1](package-python.ps1) | PowerShell 7+. Azure remote build required when deploying. | `epp-python-source.zip` |

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

<a id="the-design-in-one-line"></a>
## Request flow

Microsoft Entra ID → Easy Auth → anonymous HTTP handler (`POST /api/SendOtp`, validate envelope + decrypt JWE) →
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
| Recognized block | `403` |
| Provider `429` | `429` |
| Provider `401` or `403` | `401` |
| Other provider `4xx` | `400` |
| Missing configuration, network failure, or unknown response | `502` |
| Provider timeout | `504` |

Unknown or incomplete provider responses fail closed. Check a timed-out live request before
retrying because the provider might already have accepted it.

Provider adapters use these safe failure labels: `provider_http_error`, `provider_rejected`,
`unrecognized_provider_status`, `missing_provider_message_id`, and `invalid_provider_json`.

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
| `FUNCTIONS_WORKER_RUNTIME` | Local host / EP1 | `node`, `python`, or `dotnet-isolated`. FC1 uses `functionAppConfig.runtime` instead. Do not add this EP1 setting to FC1. |
| `EPP_DECRYPTION_KEY_PEM` | Every request | Local test PEM or base64 PEM. In Azure, use a Key Vault reference resolving to the private-key secret. Guided setup pins the PEM backing secret of its Key Vault certificate. |
| `EPP_ENCRYPTION_KEY_ID` | Optional | Expected encryption key ID. A mismatch only produces an advisory warning. |

### Provider settings and credential caching

- **Provider:** `EPP_PROVIDER_NAME`, `EPP_PROVIDER_AUTH_MODE`, and
  `EPP_PROVIDER_ENDPOINT_REGION`.
- **Endpoints:** `EPP_PROVIDER_SMS_ENDPOINT` and `EPP_PROVIDER_VOICE_ENDPOINT`.
- **Timeout and account:** `EPP_PROVIDER_TIMEOUT_MS` and `EPP_PROVIDER_ACCOUNT_NAME`.
- **Key Vault:** `KEY_VAULT_URL` and optional `AZURE_CLIENT_ID`.
- **OAuth:** `EPP_PROVIDER_TENANT_ID`, `EPP_PROVIDER_SCOPE`, `EPP_OUTBOUND_CLIENT_ID`, and
  `EPP_OUTBOUND_MI_CLIENT_ID`.
- **Caching:** `EPP_KEY_VAULT_CACHE_ENABLED` and `EPP_ACCESS_TOKEN_CACHE_ENABLED`.

All runtimes use `ManagedIdentityCredential` for Key Vault and outbound token access. They do not
fall back to a developer's Azure CLI identity.

The provider timeout defaults to `1500` and is capped at `2500` milliseconds.

Each live request uses the endpoint for its selected channel. Endpoints must be absolute HTTPS
URLs with a hostname, valid port, no user information, and no fragment. Redirects are not followed.
There is no shared endpoint fallback or automatic provider failover.

Cache switches accept `true` or `false` and default to `true`. JavaScript and Python warm at startup
and poll every 30 seconds. .NET warms once and refreshes on a cache miss. Disabling the selected
cache obtains credentials for each live request. Other values fail live credential acquisition.
Evaluation skips provider credential work. Credential acquisition has a 2.5-second budget.

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
the Function or update Entra. See [certificate lifecycle](setup/docs/README.md#encryption-certificate-lifecycle).

Configure inbound issuer/audience/caller trust in **Easy Auth**, not these application variables.
Incoming `tenantId`, `channel`, `mode` and `ttlSeconds` are request data and never override the
configured provider or authentication. `channel` selects the configured SMS or voice endpoint.
there is no deployment-level channel restriction. The legacy `EPP_PROVIDER_CHANNEL` setting is ignored.

<a id="provider-specific-integration-details"></a>
## Built-in providers

<a id="telesign-epp"></a>
<a id="soprano-integration"></a>
<a id="telesign-integration"></a>

Guided setup supports the sample's built-in **Soprano** and **Telesign** integrations.
Use the [credential and deployment-support table](docs/ONBOARDING.md#provider-credential-names)
for onboarding.

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
HTTP. There is no API-key fallback or provider retry.

For voice, the adapter extracts the first six consecutive digits from `message`, uses the request
locale or `en-US`, and sends `beforePasswordText`, `password`, and `afterPasswordText` in
`voice.text2voice`. A message without six consecutive digits fails before provider HTTP.

### Telesign

Telesign uses `telesign-customer-id` and `telesign-api-key` from Key Vault. Basic authentication is:

```text
base64(UTF8(customer-id:api-key))
```

The adapter sends `recipient.phone_number`, `message.text`, optional `message.language`, one
`channels[].channel`, and `correlation_id`. SMS forwards the message unchanged. Voice separates
standalone six-digit runs with commas and repeats the message twice.
`phoneNumber` must match `^\+[1-9][0-9]{1,14}$`.

Recognized success codes:

- SMS: `200`, `203`, `290`, `291`, `292`
- Voice: `100`, `101`, `102`, `103`
- Either channel: `3001` on a successful HTTP response

Unknown or malformed statuses fail closed. Acceptance does not confirm handset receipt or
completed audio.

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

**Easy Auth is the only caller-authentication gate before the anonymous Function.**
Follow the [exact trust checklist](docs/ONBOARDING.md#manual-deployment-trust-checklist) for HTTPS,
issuer, audience, caller allowlist, and unauthenticated rejection. Never disable it or exempt SendOtp.
There is no handler token validator or function-key fallback.

JWE and its nonce prove no caller identity: anyone with the public key can encrypt.
Provider credentials authenticate outbound calls, not incoming requests. Vault access uses managed identity.
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
