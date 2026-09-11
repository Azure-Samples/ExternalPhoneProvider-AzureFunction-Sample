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

## The design in one line

SAS → Easy Auth → anonymous HTTP handler (`POST /api/SendOtp`, validate envelope + decrypt JWE) →
configured provider (API key) → HTTP result with nonce on success.
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
is running**; do not copy `UseDevelopmentStorage=true` into Azure. Optional settings stay in the table
below rather than appearing as required placeholders in the sample. Keep explanatory comments outside
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
| `EPP_PROVIDER_ACCOUNT_NAME` | Adapter-dependent | Sender/account metadata, not an API key or credential identity. |
| `KEY_VAULT_URL` | Provider credential lookup | URI of the vault containing the manifest-named provider secrets. Separate from the encryption-key reference. |
| `AZURE_CLIENT_ID` | Optional | User-assigned managed identity's client ID for Key Vault. Leave unset for system-assigned identity. |

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
Incoming `tenantId`, `channel`, `mode` and `ttlSeconds` are request data. No outbound OAuth settings
are supported by this main-based implementation.

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
are retained (SMS: 200, 203, 290-292; Voice: 100-103); the supplied EPP integration overview does not provide
a replacement status-code catalog. Missing, malformed, or unknown codes fail closed, as do
unsuccessful HTTP responses. Confirm these codes and account access with Telesign before production.

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
