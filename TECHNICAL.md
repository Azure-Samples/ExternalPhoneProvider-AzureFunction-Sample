# Technical reference

[Documentation](docs/README.md) | [Deployment guide](docs/GETTING-STARTED.md) | [Send OTP API](docs/CONTRACT.md)

This reference describes the shipped runtimes, packages, settings, and provider adapters.

## Implementations

| Runtime | Azure target | Guide |
| --- | --- | --- |
| JavaScript | Node.js 22, Functions v4 | [JavaScript](javascript/README.md) |
| C# | .NET 10 isolated worker, Functions v4 | [C#](dotnet/README.md) |
| Python | Python 3.11, Functions v4 | [Python](python/README.md) |

Guided setup uses one runtime and one provider per Function App. Each deployment supports SMS and voice.

For advanced deployment scenarios, follow the [multi-region resiliency guide](docs/MULTI-REGION-RESILIENCY.md)
or [multi-provider guide](docs/MULTI-PROVIDER-IMPLEMENTATION.md).

## Single-region architecture

See the [architecture diagram](README.md#architecture).
Microsoft Entra ID sends an authenticated, encrypted request. Easy Auth validates the caller
before the Function validates and decrypts the request.

In **evaluation mode**, the Function returns the nonce without contacting the provider.
In **live mode**, it obtains an OAuth token through managed identity federation and sends the
message to the configured provider. Success confirms provider acceptance, not recipient delivery.

## Guided setup

Follow the [deployment guide](docs/GETTING-STARTED.md). Setup deploys a Linux FC1 or EP1 Function
App with storage, Key Vault, managed identities, Application Insights, and Log Analytics.
It configures Easy Auth, application permissions, provider settings, and a versioned encryption-key
reference. See [setup details](setup/docs/README.md).

## Download a Function ZIP

Guided setup downloads and publishes the package automatically.
For manual deployment, select a stable language release from
[GitHub Releases](https://github.com/Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample/releases):

| Runtime | Release tag | Package contents |
| --- | --- | --- |
| JavaScript | `epp-packages-<run>-<attempt>-javascript` | Application and production dependencies |
| C# | `epp-packages-<run>-<attempt>-dotnet` | Framework-dependent .NET 10 Linux x64 output, Function metadata, and extensions |
| Python | `epp-packages-<run>-<attempt>-python` | Application and Linux x64 dependencies in `.python_packages/lib/site-packages` |

Every language release contains `released-package.zip` and `SHA256SUMS.txt`.
Verify the ZIP against the checksum from that same release, then deploy it with the matching
runtime, [settings](#configure-environment-variables), and
[Easy Auth configuration](docs/ONBOARDING.md#manual-deployment-trust-checklist).

Successful package builds on `main` publish one release per language.
Pull request builds publish workflow artifacts. Each archive contains `host.json` at its root.

## Build ZIPs locally

Run the selected script from the repository root:

| Runtime | Prerequisites | Command | Output |
| --- | --- | --- | --- |
| JavaScript | PowerShell 7+, Node.js 20 or 22, npm | `.\package-javascript.ps1` | `artifacts/javascript/released-package.zip` |
| C# | PowerShell 7+, .NET 10 SDK | `.\package-dotnet.ps1` | `artifacts/dotnet/released-package.zip` |
| Python | Linux x64, PowerShell 7+, Python 3.11, pip | `.\package-python.ps1` | `artifacts/python/released-package.zip` |

The scripts need access to the corresponding package registry.
JavaScript installs production dependencies from its lockfile in a temporary directory.
C# publishes for `linux-x64` with `--self-contained false -p:UseAppHost=false`.
Python bundles binary wheels for `manylinux2014_x86_64`; build it on Linux with Python 3.11.

Existing archives are protected from overwrite. Specify a new output path for another build:

```powershell
.\package-javascript.ps1 -OutputPath .\artifacts\javascript-v2\released-package.zip
```

`-OutputPath` is supported by all three scripts. Inspect custom packages to keep local settings,
private keys, and credentials out of the archive.

## HTTP implementation details

The [Send OTP API](docs/CONTRACT.md) defines the public request and response.

### JWE validation and key handling

The compact JSON Web Encryption (JWE) value uses `RSA-OAEP-256` and `A256GCM`, contains five
nonempty segments, and is limited to 16,384 characters. The original protected header is passed
to the JOSE library, and authentication is checked before plaintext is used.

`EPP_DECRYPTION_KEY_PEM` accepts a private-key PEM or a PEM certificate bundle containing the
private key, as text or base64. In Azure, use a versioned Key Vault secret reference.
`EPP_ENCRYPTION_KEY_ID` is an optional advisory check: a mismatch logs
`encryption_key_id_mismatch`. Decryption uses the configured private key.

### Request validation and runtime differences

The decrypted `nonce`, `phoneNumber`, and `message` must be nonblank strings.
Optional `otp` is a string or `null`; it preserves leading zeros in the provider-neutral delivery
object. Built-in message construction uses `message`.

Optional `riskContext` is an object or `null`. Its `scenario` and `ipAddress` fields are strings
or `null`. Additional fields are preserved in the shared model; each adapter maps only the
fields it uses. Risk data is excluded from logs and responses.

| Behavior | Runtime detail |
| --- | --- |
| JSON parsing | JavaScript and Python parse in the handler. C# binds `EntraSendOtpPayload` before the handler, so binding failures can have a host-generated response. |
| Channel and mode | Use the documented numbers or names. C# also accepts numeric strings. |
| `ttlSeconds` | Use a positive JSON integer. JavaScript normalizes numeric forms such as `60.0`; Python and C# reject them. C# treats `null` as omitted. |
| Trace identifiers | JavaScript preserves request/header correlation values for dispatch. Python and C# sanitize them. Application logs use allowlisted identifiers. |

Request identifiers support tracing. Check uncertain send outcomes before retrying.

### Provider result mapping

Adapters return `Continue`, `Block`, or `Fail`.

| Result | Endpoint status |
| --- | --- |
| Recognized provider acceptance | `200` |
| Explicit provider risk or policy block | `422` |
| Provider throttling (`429`) | `429` |
| Other provider `4xx`, including `401` and `403` | `400` |
| Missing or unregistered provider selection | `400` |
| Invalid provider endpoint, authentication-mode mismatch, unavailable credentials, network failure, or unrecognized response | `502` |
| Provider timeout | `504` |

Provider responses must satisfy the adapter's acceptance rules. A live success response contains
the nonce; failed or blocked responses do not. Inbound caller rejection is handled by Easy Auth.
See [HTTP status codes](docs/CONTRACT.md#http-status-codes).

## Configure environment variables

Guided setup supplies these values. For local or manual deployment, start with
[local.settings.sample.json](docs/local.settings.sample.json). Every `Values` entry is a string.

| Setting | Purpose |
| --- | --- |
| `AzureWebJobsStorage` | Local host storage. The sample value `UseDevelopmentStorage=true` requires Azurite. In Azure, setup configures identity-based storage. |
| `FUNCTIONS_WORKER_RUNTIME` | `node`, `python`, or `dotnet-isolated` for local hosting and EP1. FC1 uses `functionAppConfig.runtime`. |
| `EPP_DECRYPTION_KEY_PEM` | Local test PEM/base64 PEM, or a versioned Key Vault reference in Azure |
| `EPP_ENCRYPTION_KEY_ID` | Optional expected JWE key ID for the advisory check |
| `EPP_PROVIDER_NAME` | `infobip`, `soprano`, or `telesign` |
| `EPP_PROVIDER_AUTH_MODE` | `oauth` |
| `EPP_PROVIDER_SMS_ENDPOINT` | Complete HTTPS SMS URL from the selected provider profile |
| `EPP_PROVIDER_VOICE_ENDPOINT` | Complete HTTPS voice URL from the selected provider profile |
| `EPP_PROVIDER_TENANT_ID` | Provider token-issuing tenant |
| `EPP_PROVIDER_SCOPE` | Provider API scope ending in `/.default` |
| `EPP_OUTBOUND_CLIENT_ID` | Customer application client ID used for token exchange |
| `EPP_OUTBOUND_MI_CLIENT_ID` | Outbound user-assigned managed identity client ID |
| `EPP_PROVIDER_TIMEOUT_MS` | Provider HTTP timeout; default `1500`, maximum `2500` milliseconds |

The selected channel uses its own endpoint. URLs must be absolute HTTPS URLs with a hostname,
valid port, no user information, and no fragment. The transport does not follow redirects.

Setup also records provider metadata such as `EPP_PROVIDER_APP_ID`,
`EPP_PROVIDER_ENDPOINT_REGION`, and `EPP_PROVIDER_RETRY_INTERVAL_MS`.
These values support setup and handoff; the runtime reads the scope, selected channel URL, and
HTTP timeout listed above. In the default flow, each live invocation makes at most one provider
send attempt.

### Provider settings and credential acquisition

All bundled adapters use the same OAuth flow:

1. The outbound managed identity obtains an assertion for `api://AzureADTokenExchange/.default`.
2. The customer application's federated credential permits that identity to act as the application.
3. Azure Identity exchanges the assertion in the provider token tenant for the configured API scope.
4. The adapter sends the resulting bearer token to the provider.

The Azure Identity SDK manages token caching and renewal. The sample requests a usable token for
each live request, with a **5-second credential-acquisition budget** separate from the provider
HTTP timeout. Acquisition failures return `502` and log `credential_unavailable`.

Complete [provider authorization](docs/ONBOARDING.md#complete-provider-authentication) and restart
the worker after changing credential configuration. Evaluation returns before provider work.

### Local settings and Azure settings

Place an untracked `local.settings.json` beside the selected runtime's `host.json`.
Core Tools loads `Values` into environment variables; direct runtime processes and tests do not.
Use a local test key for local evaluation and keep the host accessible only from the local machine.

In Azure, use **Function App** > **Settings** > **Environment variables** > **App settings**.
For the decryption key, use:

```text
@Microsoft.KeyVault(SecretUri=https://<vault>.vault.azure.net/secrets/<certificate-secret>/<version>)
```

Use the exact `certificateSecretId` from the deployment summary. The certificate and secret
version IDs can differ. The Function's system-assigned identity resolves this reference.
See [certificate renewal](setup/docs/README.md#encryption-certificate-lifecycle).

## Built-in providers

All providers use complete channel URLs from their profiles and OAuth through managed identity
federation. Provider authorization is completed separately from Azure deployment.

### Infobip

The [Infobip profile](setup/providers/infobip.json) uses `api.infobip.com` for Global routing and
`api-eu.infobip.com` for EU routing.

SMS maps the message to `content.text`; voice sends `text`, the request locale (default `en`),
and the configured adapter voice `Joanna`. Infobip manages sender and caller-ID selection.
Confirm destination and sender requirements with the provider.

The adapter recognizes `ACCEPTED`, `PENDING`, and `DELIVERED` as accepted outcomes on successful
HTTP responses. See the [SMS API](https://www.infobip.com/docs/api/channels/sms/outbound-sms/send-message/send-sms-messages)
and [voice API](https://www.infobip.com/docs/api/channels/voice/voice-message/voice-message-sending-operations/send-advanced-voice-tts).

### Soprano

The [Soprano profile](setup/providers/soprano.json) supplies the `/messages/omnimsg` endpoint
for both channels.

SMS sends the message text. Voice extracts the first six consecutive digits from `message`
and builds `voice.text2voice` with `beforePasswordText`, `password`, and `afterPasswordText`.
It uses the request locale or `en-US`. A voice message needs a six-digit passcode.

Recognized acceptance statuses are `ENROUTE`, `ACCEPTED`, `SUBMITTED`, `SENT`, `DELIVERED`, and
`QUEUED`. An explicit `BLOCKED` response maps to a provider block.

### Telesign

The [Telesign profile](setup/providers/telesign.json) contains the configured token tenant,
API application ID, scope, and channel URLs.

The adapter sends `recipient.phone_number`, `message.text`, optional `message.language`,
`channels`, and `correlation_id`. Phone numbers must match `^\+[1-9][0-9]{1,14}$`.
SMS preserves the message. Voice separates standalone six-digit passcodes with commas and
repeats the message twice.

When supplied, `riskContext.scenario` maps to `account_lifecycle_event` and `ipAddress` maps to
`originating_ip`. Values are forwarded unchanged; confirm accepted values with Telesign.

The adapter recognizes status codes `200`, `203`, `290`, `291`, `292`, `100`, `101`, `102`, `103`,
and `3001` as accepted on successful HTTP responses. Code `3072` maps to a provider block
and endpoint `422`. Unknown or malformed statuses are failures.

## Production readiness

- Keep Easy Auth enabled with the approved issuer, audience, and caller allowlist.
- Verify evaluation, caller rejection, malformed requests, and tampered encrypted content.
- Confirm controlled live acceptance and recipient delivery for each channel.
- Agree on timeout and retry handling with the caller and provider; investigate uncertain sends
  before retrying.
- Assign owners for provider authorization, certificate renewal, monitoring, costs, and rollback.
- Keep phone numbers, OTPs, nonces, credentials, encrypted bodies, and raw provider responses
  out of logs and support material.

## Security

Easy Auth authenticates the caller before the handler runs. The JWE protects delivery data;
the public encryption key does not identify a caller. OAuth authenticates the separate
outbound provider request.

Use the [Easy Auth checklist](docs/ONBOARDING.md#manual-deployment-trust-checklist) for manual
deployment and repeat [endpoint validation](docs/ONBOARDING.md#validate-the-deployed-endpoint)
after changes.

## Extend the sample

Use the existing provider interfaces and [add a provider](docs/BRING-YOUR-OWN-PROVIDER.md).
For another runtime, implement the [HTTP contract](docs/CONTRACT.md) and
[log schema](docs/LOGGING.md), add matching tests, and integrate with
[CI](.github/workflows/ci.yml).
