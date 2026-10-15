# External Phone Provider Function: JavaScript

[Documentation](../docs/README.md) | [Settings](#environment-configuration) | [Request behavior](#request-behavior) | [Source](#source-and-extension-points)

A Node.js Azure Function implementing the shared [HTTP contract](../docs/CONTRACT.md).
One configured provider owns its credentials, request mapping, and response interpretation.

## Setup

**Deploying the sample?** Use the [five-step guide](../docs/GETTING-STARTED.md).
After guided setup, go to [provider authentication and validation](../docs/ONBOARDING.md#complete-provider-authentication),
not local settings or another deployment. [Guided provider support](../docs/ONBOARDING.md#provider-credential-names)
is narrower than the bundled adapter set.

**Developing a custom package?** Follow these steps from `javascript/`:

1. Create the [local settings below](#environment-configuration). For live integration, choose a
   fixed provider ID from [providers/](src/functions/providers/), configure its endpoints/options,
   and complete [provider authentication](../docs/ONBOARDING.md#complete-provider-authentication).
   No provider is selected by default.
2. Install [package.json](package.json) dependencies, run its offline test script, and start Core Tools
   from this folder. **Bind only to loopback, without tunnels:** Core Tools has no Easy Auth.
3. For manual deployment, [package](../TECHNICAL.md#build-zips-locally) this app only, preserving
   dependencies and [.funcignore](.funcignore). Inspect for secrets before upload. Complete the
   [Easy Auth trust checklist](../docs/ONBOARDING.md#manual-deployment-trust-checklist) before public access:
   it is the only caller-authentication gate; never disable it or exempt SendOtp.
   Then run [authorized deployed checks](../docs/ONBOARDING.md#validate-the-deployed-endpoint);
   offline tests do not verify platform authentication.

**Regional continuity:** [Front Door](../docs/FRONTDOOR.md) uses multiple regional origins behind
one URL. Its JavaScript trials and readiness contract provide the starting point for implementing
and validating your regional package and provisioning process.

## Environment configuration

Run Core Tools from `javascript/`. Create an untracked `local.settings.json` **beside
[host.json](host.json), not inside `src/`**. Start from the
[shared sample](../docs/local.settings.sample.json); for local evaluation, start Azurite and replace
the test-key placeholder in this minimal setup:

```json
{
   "IsEncrypted": false,
   "Values": {
      "AzureWebJobsStorage": "UseDevelopmentStorage=true",
      "FUNCTIONS_WORKER_RUNTIME": "node",
      "EPP_DECRYPTION_KEY_PEM": "<base64 of your local test private PEM>"
   }
}
```

For live delivery, use the [shared settings table](../TECHNICAL.md#configure-environment-variables)
for `EPP_PROVIDER_NAME`, both channel endpoints, authentication, and adapter-specific options.
Keep `Values` as strings, including `EPP_PROVIDER_TIMEOUT_MS`, for example `"1500"`.
Replace placeholders; API keys belong in Key Vault, not this file.
A missing/invalid selected channel endpoint fails closed without fallback.

Core Tools copies `Values` into the process environment; direct Node processes and offline tests do
not load this file. [AppConfig](src/functions/config.js) reads `process.env` when `readConfig()` runs.
Restart after edits. Core Tools cannot resolve Key Vault references locally, so use only a local
test PEM or base64 PEM. Never copy Azurite settings into Azure.

In Azure, configure the same app settings and use a Key Vault reference for the private PEM.
Provider secrets use managed identity, not a developer CLI login. Keep local evaluation on loopback.

## Request behavior

`POST /api/SendOtp` follows the [shared request/response contract](../docs/CONTRACT.md#1-http-api).
Easy Auth authenticates; JWE decryption, nonce values, and request fields do not.
The handler never parses or echoes incoming `Authorization`.

Use [`mode: 2` or `"evaluation"`](../docs/CONTRACT.md#evaluation-no-provider-send) for no-send validation:
authentication and decryption still run, but request-path provider lookup, credentials, and HTTP do not.
Live success waits for acceptance, **not handset receipt**; failures omit the nonce.
Never blindly retry a timeout.

For message/voice mapping and credential rules, see the
[Soprano delivery contract](../docs/CONTRACT.md#encrypteddeliverycontext-jwe) and
[Telesign integration](../TECHNICAL.md#telesign-epp).

## Source and extension points

Start with the provider-neutral
[BYOT request and response guide](../docs/BRING-YOUR-OWN-PROVIDER.md) for the Microsoft Entra ID payload,
caller authentication, and response rules. Your team owns the outbound service integration.

For deployed diagnostics, use [Application Insights](../docs/APPLICATION-INSIGHTS.md) and the
[JavaScript service-event queries](../docs/MONITORING.md#4-javascript-service-event-queries).
Logs are JSON `service` events ending in `request_completed`, not a `logType: "request"` summary.

The [cache switches and defaults](../docs/CONTRACT.md#credential-caching-and-refresh) apply here.
Disabling the selected cache removes startup preparation, polling, and cross-request reuse,
not live credential acquisition.

With caching enabled, startup selects only the provider's API-key or OAuth cache. API keys use
Key Vault and `lru-cache`; OAuth uses the managed-identity/Entra SDKs. A shared 30-second refresh
loop and one in-flight acquisition keep warm reads nonblocking; failures never extend expiry.
See the [refresh contract](../docs/CONTRACT.md#credential-caching-and-refresh). Leave the provider
unset for local evaluation without credential acquisition; prewarming never sends an OTP.

| Source | Purpose |
|---|---|
| [src/functions/SendOtp.js](src/functions/SendOtp.js) | Explicit HTTP orchestration and startup/termination hooks |
| [src/functions/config.js](src/functions/config.js) | Shared deployment settings |
| [src/functions/entraPayload.js](src/functions/entraPayload.js) | Validated Entra envelope and exact contract reasons |
| [src/functions/delivery.js](src/functions/delivery.js) | Validated decrypted context and immutable provider-neutral delivery |
| [src/functions/jwe.js](src/functions/jwe.js) | Flat JWE validation/decryption with pinned algorithms and PEM key cache |
| [src/functions/providerTransport.js](src/functions/providerTransport.js) | HTTPS validation, bounded fetch, body read, JSON parse and manual redirects |
| [src/functions/providerResult.js](src/functions/providerResult.js) | Provider result and endpoint outcome model |
| [src/functions/logging.js](src/functions/logging.js) | Immutable request context and fixed privacy-safe structured events |
| [src/functions/credentials.js](src/functions/credentials.js) | `CredentialTokenService`, `ApiKeyCache`, `AccessTokenCache` and refresh lifecycle |
| [src/functions/providers/](src/functions/providers/) | Fixed lookup and provider-owned credential/request/response rules |
| [test/](test/) | Representative offline checks |

To add a provider, implement its fixed `name`, `authenticationMode`, `credentialSpec`,
`createRequest` and `interpretResponse` in the provider folder, then add it to the switch in
[providers/index.js](src/functions/providers/index.js). `interpretResponse` returns a
`ProviderResult` containing the provider-owned outcome, endpoint HTTP status and one safe fixed
failure classification. Raw API JSON stays inside the provider. See
[production limitations](../docs/CONTRACT.md#production-limitations) before production use.
