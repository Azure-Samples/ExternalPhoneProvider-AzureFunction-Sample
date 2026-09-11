# External Phone Provider — Azure Function Sample

A provider-agnostic **OTP-delivery Azure Function** sample, implemented across multiple languages.
Each language folder is a self-contained implementation of the **same design and the same
[contract](docs/CONTRACT.md)** — one engine, drop-in provider adapters, env-provisioned config, and
secrets in Key Vault.

## Implementations

| Language | Status | Folder |
|----------|--------|--------|
| JavaScript (Node.js) | Available | [javascript/](javascript/) |
| C# (.NET isolated worker) | Available | [dotnet/](dotnet/) |
| Python (v2 model) | Available | [python/](python/) |

All implementations conform to the **language-agnostic contract** in
[docs/CONTRACT.md](docs/CONTRACT.md) — identical HTTP API, provider-adapter shape, config/env var
names, Key Vault secret names, and behaviors (fail-closed, managed identity, privacy). Pick any folder
and follow its README.

Choose one language and configure the adapter for your provider. No provider is preferred or selected
by default. Deploy each language separately, not all three to the same Function App. See the
[shared configuration](docs/CONTRACT.md#default-provider-and-configuration-readers).

**Using one provider?** Only that provider needs settings and credentials. Keeping the other adapter
files is harmless. To omit them from a deployment, follow the [single-provider setup](docs/ONBOARDING.md#single-provider-deployments).

New here? Start with **[docs/ONBOARDING.md](docs/ONBOARDING.md)** — setup, config, running, securing,
and deploying, step by step.

## The design in one line

SAS → Easy Auth → anonymous HTTP handler (`POST /api/SendOtp`, validate envelope + decrypt JWE) →
configured provider (API key by default; opt-in OAuth for a supporting adapter) → HTTP result with nonce on success.
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
is running**; local HTTP-only execution can omit that storage setting. Do not copy
`UseDevelopmentStorage=true` into Azure. The sample shows safe auth-gate defaults; other optional
settings stay in the table below rather than appearing as required placeholders. Keep explanatory comments outside
`Values`, otherwise the host loads them as environment variables too.

The local settings file is an environment-variable input for the Functions host, **not a serialized
`AppConfig` or request model**. For example, `EPP_PROVIDER_NAME` becomes `config.providerName` in
JavaScript, `config.provider_name` in Python, and `config.ProviderName` in .NET. The refactor changed
how code accesses configuration, not the environment-variable names.

| Variable | When needed | Value |
|---|---|---|
| `AzureWebJobsStorage` | Functions host storage | Local sample: `UseDevelopmentStorage=true` with Azurite running. Configure Azure host storage separately for the selected plan. |
| `FUNCTIONS_WORKER_RUNTIME` | Functions host | `node`, `python`, or `dotnet-isolated`—exactly one value matching the chosen implementation. |
| `EPP_DECRYPTION_KEY_PEM` | Every request | Local test PEM or base64 PEM. In Azure, use a Key Vault reference resolving to the private-key secret. |
| `EPP_ENCRYPTION_KEY_ID` | Optional | Expected encryption key ID; mismatch only produces an advisory warning. |
| `EPP_PROVIDER_NAME` | Live delivery | Selected adapter's manifest ID. No default provider. |
| `EPP_PROVIDER_ENDPOINT` | Live delivery | HTTPS **base URL**, in the same environment as the provider credentials; the adapter adds its route. |
| `EPP_PROVIDER_AUTH_MODE` | Optional | Defaults to `apiKey`; `oauth2` requires a provider JWT. See the [auth gate table](docs/CONTRACT.md#provider-authentication-gates). |
| `EPP_PROVIDER_JWT_ENABLED` | Optional | Defaults to `false`: no provider-token lookup. `true` enables optional JWT alongside API keys or required JWT in `oauth2` mode, only for supporting adapters. |
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

Evaluation requests do not need provider variables or provider secrets. They still need the decryption
key. The default credential resolvers use `ManagedIdentityCredential`, **not** the developer's CLI
login; ordinary local machines have no managed-identity endpoint. Use offline tests or loopback-only
evaluation locally, or an explicitly injected test resolver for integration work. Never commit local
settings, keys or test credentials.

Core Tools does not resolve Azure Key Vault reference expressions locally. Supply the local test PEM
or base64 PEM directly; use a reference such as `@Microsoft.KeyVault(SecretUri=https://<vault>.vault.azure.net/secrets/<private-key-secret>/)`
for `EPP_DECRYPTION_KEY_PEM` in Azure app settings, where the platform resolves it.

Configure inbound issuer/audience/caller trust in **Easy Auth**, not these application variables.
Incoming `tenantId`, `channel`, `mode` and `ttlSeconds` are request data. Outbound OAuth settings are
separate from that inbound trust; see the [configuration catalog](docs/CONTRACT.md#4-configuration-app-settings--env)
and [onboarding](docs/ONBOARDING.md#provider-jwt-setup) for token setup and structured voice input.

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
keys or OAuth client secrets are read from **Key Vault** via **managed identity**. A supported OAuth
adapter may instead exchange a managed-identity assertion for a provider token. These credentials
authenticate the outbound provider call, not the inbound request; the caller's token is never forwarded.

Core Tools does not provide Easy Auth. Local execution is unauthenticated: bind only to loopback,
with no tunnels or public forwarding. Offline tests cover application behavior, not platform
authentication; [separate deployed security checks](docs/ONBOARDING.md#4-package-deploy-and-verify) are required.

## Docs

- **[docs/ONBOARDING.md](docs/ONBOARDING.md)** — customer setup / run / secure / deploy guide.
- **[docs/CONTRACT.md](docs/CONTRACT.md)** — the language-agnostic contract every implementation follows.

## Contributing a language or provider

- **New provider** (in any language): add one adapter file exposing `manifest` + `buildRequest` +
  `parseResponse` — no engine changes. See the language folder's README.
- **New language**: mirror the folder structure, implement the contract, add the same test scenarios,
  and wire it into [.github/workflows/ci.yml](.github/workflows/ci.yml).

### Future pull requests

Start a short-lived branch from up-to-date `main`. After review and passing checks, select **Squash
and merge** to place one commit on `main`, then delete that PR's feature branch. Squashing is a merge
choice, not automatic just because commits are on a feature branch. Do not merge old feature histories
into a new branch or delete other branches containing unmerged work. This workflow does not rewrite
existing `main` history.
