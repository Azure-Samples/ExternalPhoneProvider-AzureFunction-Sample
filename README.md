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

New here? Start with **[docs/ONBOARDING.md](docs/ONBOARDING.md)** — setup, config, running, securing,
and deploying, step by step.

## Guided EPP setup

Use **[setup](setup/docs/README.md)** for **Step 2: endpoint deployment**. Download only
`Setup-Epp.ps1`; it downloads its supporting tools, Bicep, and provider JSON from GitHub. Supply
missing customer settings, select **JavaScript, .NET, or Python**, choose Telesign or Soprano,
**SMS or voice**, **Global or EU**, enter a resource prefix, and approve one complete resource plan.
Generated names add `epp` after the customer prefix. Missing required Azure resource providers
are registered automatically after approval. Package links and published checksums are
selected automatically. Setup publishes .NET for Linux and requests Azure remote build for Python;
customers do not build or deploy the source ZIPs manually. The .NET choice requires the .NET 8 SDK.
Application registration (Step 1) and policy activation (Step 3) remain manual. Missing provider
details are explicitly labelled test values and written to the real Function App settings; replace
them and complete Telesign API-key or Soprano OAuth onboarding before live delivery.

## Download a Function ZIP

Download the preview ZIP for your chosen language:

| Language | Download | Contents |
|---|---|---|
| JavaScript | [epp-javascript.zip](https://github.com/siyixian/ExternalPhoneProvider-AzureFunction-Sample/releases/download/epp-provider-auth-preview-20260915/epp-javascript.zip) | Application and production dependencies |
| .NET | [epp-dotnet-source.zip](https://github.com/siyixian/ExternalPhoneProvider-AzureFunction-Sample/releases/download/epp-provider-auth-preview-20260915/epp-dotnet-source.zip) | C# Function source and project file; build/publish before deployment |
| Python | [epp-python-source.zip](https://github.com/siyixian/ExternalPhoneProvider-AzureFunction-Sample/releases/download/epp-provider-auth-preview-20260915/epp-python-source.zip) | Source for Azure remote build on Linux |

Customers do not need PowerShell or a local build toolchain to download these files. Verify downloads
against the corresponding release's `SHA256SUMS.txt`. Configure the target Function App's runtime, app settings,
Key Vault access, and Easy Auth before deploying. .NET requires building/publishing the extracted
project; Python requires remote build to install dependencies. Neither source ZIP can run directly
as a run-from-package artifact. GitHub's **Code > Download ZIP**
is the whole source repository, not a Function deployment package.

The private test links above match `test/epp-single-script`. After the packaging workflow is merged
upstream, each successful `main` build tests all three implementations,
builds and inspects the ZIPs, and publishes a new versioned release. Get those builds from
[Latest release](https://github.com/Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample/releases/latest).
Older releases remain available; existing assets are not overwritten. Pull requests build downloadable
workflow artifacts only and cannot publish releases. GitHub sign-in may be required for workflow
artifacts, but public release downloads do not require a local build. Packaging does not deploy or
verify live provider delivery.

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
configured provider (Telesign API key or Soprano OAuth) → HTTP result with nonce on success.
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
| `FUNCTIONS_WORKER_RUNTIME` | Functions host | `node`, `python`, or `dotnet-isolated`—exactly one value matching the chosen implementation. |
| `EPP_DECRYPTION_KEY_PEM` | Every request | Local test PEM or base64 PEM. In Azure, use a Key Vault reference resolving to the private-key secret. |
| `EPP_ENCRYPTION_KEY_ID` | Optional | Expected encryption key ID; mismatch only produces an advisory warning. |
| `EPP_PROVIDER_NAME` | Live delivery | Selected adapter's manifest ID. No default provider. |
| `EPP_PROVIDER_ENDPOINT` | Live delivery | Complete provider-approved HTTPS request URL for the selected channel and endpoint region. |
| `EPP_PROVIDER_CHANNEL` | Guided deployment | Selected `sms` or `voice` route; live requests for the other channel fail closed. |
| `EPP_PROVIDER_ENDPOINT_REGION` | Guided deployment metadata | Selected `global` or `eu` route label. |
| `EPP_PROVIDER_AUTH_MODE` | Live delivery | Must match the adapter: `apiKey` for Telesign or `oauth` for Soprano. |
| `EPP_PROVIDER_TENANT_ID`, `EPP_PROVIDER_SCOPE` | Soprano OAuth | Provider tenant and selected API scope. |
| `EPP_OUTBOUND_CLIENT_ID`, `EPP_OUTBOUND_MI_CLIENT_ID` | Soprano OAuth | Existing multitenant application client ID and outbound user-assigned managed identity client ID used for client-assertion exchange. |
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
3. For Telesign, store provider API credentials in Key Vault using the **exact names in the adapter
  manifest** and grant the Function identity *Key Vault Secrets User*. For Soprano, configure the
  provider tenant/scope and outbound managed-identity federation; no provider secret is stored.

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
