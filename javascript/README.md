# External Phone Provider Function: JavaScript

A Node.js Azure Function implementing the shared [contract](../docs/CONTRACT.md). The Function owns
an explicit parse → decrypt → evaluation short-circuit or provider selection → credential resolution
→ provider request/transport/result → response flow. One provider is selected per deployment, and
each provider owns its credentials, wire request, response interpretation, outcome and failure class.

## Setup

**Customer deployment:** start with the [root guide](../README.md). Guided setup publishes this
runtime and its Azure settings; continue with [provider authentication and validation](../docs/ONBOARDING.md#complete-provider-authentication).
Do not create local settings or republish after a successful guided deployment.

**The steps below are optional developer/manual deployment work**, not additional onboarding
requirements. Guided providers are Telesign and Soprano; other adapters require separate integration.

For multiple regional origins behind one URL, see [manual Front Door onboarding](../docs/FRONTDOOR.md).
The JavaScript evaluation trials used a separate readiness handler; it is not included in this
sample's release package. No Front Door deployment script is supplied.

1. Follow [customer onboarding](../docs/ONBOARDING.md). Choose a bundled provider and set
   `EPP_PROVIDER_NAME` to its fixed id; `<provider-id>` is a placeholder, not a default.
2. Consult the selected implementation in [src/functions/providers/](src/functions/providers/)
   for required credentials and options. Store credential values under the provider's Key Vault
   secret names, grant the Function's managed identity *Key Vault Secrets User*, and configure the
   matching endpoint and required options. This guide does not duplicate individual API contracts.
3. Use [../docs/local.settings.sample.json](../docs/local.settings.sample.json) as a starting point,
   replacing placeholders with the selected provider's settings. Keep local settings private at
   the app root beside [host.json](host.json), with `FUNCTIONS_WORKER_RUNTIME=node`.
4. Configure decryption from the [shared catalog](../docs/CONTRACT.md#4-configuration-app-settings--env).
   Follow [platform trust setup](../docs/ONBOARDING.md#2-provision-encryption-and-deployment-trust): Easy
   Auth is the only caller-authentication gate before the anonymous Function. Enable
   `requireAuthentication=true`, `unauthenticatedClientAction=Return401` and `requireHttps=true`; pin the
   trusted tenant issuer, endpoint-app `allowedAudiences` and a nonempty `allowedApplications` list for
   the authorized SAS caller. Do not exclude SendOtp. There is no backup application token validation;
   never expose the endpoint to the public internet with Easy Auth disabled or bypassed.
5. Install dependencies from [package.json](package.json), run its offline test script and start the
   local Functions host from this folder. Core Tools has no Easy Auth: bind only to loopback, with no
   tunnels or public forwarding. Publish this app folder only, preserving dependencies and observing
   [.funcignore](.funcignore); inspect the package before upload. Offline tests cover application
   behavior, not platform authentication; run the separate
   [deployed security checks](../docs/ONBOARDING.md#4-package-deploy-and-verify).

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

For live delivery, add `EPP_PROVIDER_NAME`, the complete selected `EPP_PROVIDER_ENDPOINT`, and the
matching provider authentication settings to `Values`.
Add `EPP_PROVIDER_ACCOUNT_NAME` and any provider-specific options only when required. Optional
`EPP_PROVIDER_TIMEOUT_MS` is a string such as `"1500"`. Replace placeholders; do not put API keys in
this file. See the [complete variable table](../TECHNICAL.md#configure-environment-variables).

Core Tools copies `Values` into the process environment; direct Node processes and the offline tests
do **not** automatically load this file. [AppConfig](src/functions/config.js) reads `process.env`
once per call to `readConfig()`. Restart the host after changing settings. Configure any local host
storage other than Azurite separately; do not copy a local emulator connection into Azure. Core Tools
does not resolve Key Vault references locally; supply the local test PEM or base64 PEM directly.

Older private settings may contain `DEFAULT_PROVIDER`, `ENDPOINT_TIMEOUT_MS`, `REQUIRE_AUTH`,
`EXPECTED_AUDIENCE`, `ISSUER_TENANT_ID`, `EUDB`, or per-provider `*_ENDPOINT` entries. Those do not
configure the current shared engine. Use `EPP_PROVIDER_NAME`, `EPP_PROVIDER_ENDPOINT` and
`EPP_PROVIDER_TIMEOUT_MS` instead; configure caller authentication in Easy Auth. Keep provider options
that are actually read, such as a service-plan ID or voice selection. Private integration helpers may
load settings from another location or use test credential variables, but the Function itself does not.

The Soprano provider uses the configured complete endpoint and an OAuth bearer token. For voice, it
extracts the first six-digit passcode from the rendered message and sends fixed synthesis values:
gender `1` and loop `2`. It uses a nonblank SAS request locale as the language, falling back to
`en-US` when the locale is absent or invalid. These values require no additional environment
settings. Soprano SMS continues to forward the rendered message unchanged. The Telesign provider
uses the configured complete endpoint and API-key credentials from Key Vault. Telesign SMS forwards
the rendered message unchanged; Telesign voice comma-separates each six-digit numeric run that is
not part of a longer number and repeats the complete paced message twice.

For Azure, set these application variables on the Function App/slot's **Environment variables → App
settings** page and use a Key Vault reference for the private PEM. The provider-secret resolver uses
managed identity; signing into the CLI locally does not supply that identity. Local evaluation avoids
provider lookup, while tests inject mocked credentials and HTTP. Keep the local endpoint on loopback.

## Request behavior

Easy Auth authenticates and authorizes the caller before `POST /api/SendOtp`; the anonymous handler
validates the envelope and decrypts the JWE, without parsing or echoing incoming `Authorization`.
JWE does not authenticate SAS: anyone with the public key can encrypt a request, and a fixed nonce
is not authentication. Request `mode`, `channel`, `ttlSeconds` and `tenantId` are request data, not
environment settings or sources of identity trust. SMS forwards the caller-rendered message;
voice uses the provider-specific extraction/pacing described above.

For non-delivery validation, use incoming `mode: 2` or `mode: "evaluation"`. This generic shutter
works for every provider without provider configuration, provider Key Vault reads or provider HTTP;
platform authentication on Azure and handler decryption still run. No diagnostic environment flag is needed. See the
[evaluation contract](../docs/CONTRACT.md#evaluation-generic-shutter) for authentication/key prerequisites.

Live requests use the configured provider's API key or OAuth token and await acceptance before returning the nonce.
Acceptance is not handset delivery; failures omit the nonce, and timeouts must not trigger blind
retries. The shared contract defines validation, HTTP outcomes and privacy-safe logging.

## Source and extension points

For deployed diagnostics, use [Application Insights](../docs/APPLICATION-INSIGHTS.md) and the
[JavaScript service-event queries](../docs/MONITORING.md#4-javascript-service-event-queries).
Logs are JSON `service` events ending in `request_completed`, not a `logType: "request"` summary.

The app-start hook selects `ApiKeyCache` or `AccessTokenCache` from the provider credential spec.
Only that cache starts: API keys use Key Vault and `lru-cache`; access tokens use the MI/Entra SDKs,
without Key Vault. One shared 30-second refresh loop and one in-flight acquisition keep warm reads
nonblocking. Configuration changes require restart; failures never extend expiry. A small HTTP-client
wrapper propagates cancellation to the installed identity SDK. Shutdown prevents late publication. See the
[refresh contract](../docs/CONTRACT.md#credential-caching-and-refresh). Leave the provider unset for
local evaluation-only use without credential acquisition; prewarming never sends an OTP.

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
