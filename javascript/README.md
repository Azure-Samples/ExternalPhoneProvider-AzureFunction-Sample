# JavaScript implementation

<a id="external-phone-provider-function-javascript"></a>

[Documentation](../docs/README.md) | [Settings](#environment-configuration) | [Request behavior](#request-behavior) | [Source](#source-and-extension-points)

A Node.js Azure Function implementing the shared [HTTP contract](../docs/CONTRACT.md) with one
provider per deployment.

## Setup

**Sample deployment:** follow the [five-step guide](../docs/GETTING-STARTED.md), then complete
[provider authentication and validation](../docs/ONBOARDING.md#complete-provider-authentication).

**Custom package development:** follow these steps from `javascript/`:

1. Create the [local settings below](#environment-configuration). Select a fixed provider ID from
   [providers/](src/functions/providers/), configure it, and complete
   [provider authentication](../docs/ONBOARDING.md#complete-provider-authentication).
2. Install [package.json](package.json) dependencies, run its offline test script, and start Core Tools
   from this folder. **Bind only to loopback, without tunnels:** Core Tools has no Easy Auth.
3. For manual deployment, [package](../TECHNICAL.md#build-zips-locally) this app, inspect it for
   secrets, and complete the [Easy Auth trust checklist](../docs/ONBOARDING.md#manual-deployment-trust-checklist).
   Keep Easy Auth enabled for SendOtp, then run
   [authorized deployed checks](../docs/ONBOARDING.md#validate-the-deployed-endpoint) to verify
   platform authentication.

**Regional continuity:** use the [Front Door guide](../docs/FRONTDOOR.md).

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
Replace placeholders; Store API keys in Key Vault. Each selected channel requires a valid endpoint; an invalid or
missing endpoint returns an error without using the other channel.

Core Tools copies `Values` into the process environment; direct Node processes and offline tests
do not load the file. Restart after edits. Use a local test PEM because Core Tools cannot resolve
Key Vault references locally. Keep Azurite settings local.

In Azure, configure the same app settings and use a Key Vault reference for the private PEM.
Provider secrets use managed identity, not a developer CLI login. Keep local evaluation on loopback.

## Request behavior

`POST /api/SendOtp` follows the [shared request/response contract](../docs/CONTRACT.md#1-http-api).
Easy Auth authenticates the caller. JWE decryption, nonce values, and request fields serve other
parts of the contract. The handler leaves incoming `Authorization` processing to Easy Auth and
does not echo it.

Use [`mode: 2` or `"evaluation"`](../docs/CONTRACT.md#evaluation-no-provider-send) to validate
authentication and decryption without a provider send. Live success confirms acceptance,
**not handset receipt**. Check a timeout before retrying.

For message/voice mapping and credential rules, see the
[Soprano integration](../docs/BRING-YOUR-OWN-PROVIDER.md#soprano-integration) and
[Telesign integration](../docs/BRING-YOUR-OWN-PROVIDER.md#telesign-integration).

## Source and extension points

Use the provider-neutral
[BYOT request and response guide](../docs/BRING-YOUR-OWN-PROVIDER.md) for the Microsoft Entra ID payload,
caller authentication, and response rules. Customers can connect the outbound phone service
that meets their requirements.

For diagnostics, use [Application Insights](../docs/APPLICATION-INSIGHTS.md) and the
[JavaScript event queries](../docs/MONITORING.md#4-javascript-service-event-queries).

The [cache switches and defaults](../docs/BRING-YOUR-OWN-PROVIDER.md#credential-caching) apply here.
Disabling the selected cache removes startup preparation, polling, and cross-request reuse,
not live credential acquisition.

With caching enabled, API keys use Key Vault and `lru-cache`; OAuth uses the managed-identity/Entra
SDKs. A 30-second refresh loop and one in-flight acquisition support warm reads. See the
[credential caching guide](../docs/BRING-YOUR-OWN-PROVIDER.md#credential-caching).

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
`createRequest`, and `interpretResponse` in the provider folder. Then add it to the switch in
[providers/index.js](src/functions/providers/index.js). `interpretResponse` returns a
`ProviderResult` containing the provider-owned outcome, endpoint HTTP status and one safe fixed
failure classification. Raw API JSON stays inside the provider. See
[production readiness](../docs/BRING-YOUR-OWN-PROVIDER.md#production-readiness) when planning a live service.
