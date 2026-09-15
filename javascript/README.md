# External Phone Provider Function: JavaScript

A Node.js Azure Function implementing the shared [contract](../docs/CONTRACT.md): one dispatch
engine and one selected provider per deployment. API-specific behavior stays in registered adapters.

## Setup

1. Follow [customer onboarding](../docs/ONBOARDING.md). Choose a registered adapter and set
   `EPP_PROVIDER_NAME` to its manifest id; `<adapter-id>` is a placeholder, not a default.
2. Consult the selected adapter and its manifest in [src/functions/providers/](src/functions/providers/)
   for required credentials and options. Store credential values under the manifest's Key Vault
   secret names, grant the Function's managed identity *Key Vault Secrets User*, and configure the
   matching endpoint and required options. This guide does not duplicate individual API contracts.
3. Use [../docs/local.settings.sample.json](../docs/local.settings.sample.json) as a starting point,
   replacing placeholders with the selected adapter's settings. Keep local settings private at
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

For live delivery, add `EPP_PROVIDER_NAME`, `EPP_PROVIDER_ENDPOINT` and `KEY_VAULT_URL` to `Values`.
Add `EPP_PROVIDER_ACCOUNT_NAME` and any adapter-specific options only when required. Optional
`EPP_PROVIDER_TIMEOUT_MS` is a string such as `"1500"`. Replace placeholders; do not put API keys in
this file. See the [complete variable table](../README.md#configure-environment-variables).

Optional Soprano JWT acquisition uses `ManagedIdentityCredential` and `ClientAssertionCredential`, not an application secret.
Set `EPP_PROVIDER_SCOPE` to the provider API's Application ID or URI plus `/.default`, and enable
`EPP_PROVIDER_JWT_ENABLED` only after provider authorization. Configure `EPP_PROVIDER_TENANT_ID`,
`EPP_PROVIDER_APPLICATION_ID`, and `EPP_PROVIDER_MI_CLIENT_ID` for the federated exchange.
`AZURE_CLIENT_ID` remains independent for Key Vault. See [JWT setup](../README.md#soprano-jwt-setup)
for tenant requirements. Local tests mock the identity SDK; CLI login is not a token fallback.

Core Tools copies `Values` into the process environment; direct Node processes and the offline tests
do **not** automatically load this file. [AppConfig](src/functions/config.js) reads `process.env`
once per call to `readConfig()`. Restart the host after changing settings. Configure any local host
storage other than Azurite separately; do not copy a local emulator connection into Azure. Core Tools
does not resolve Key Vault references locally; supply the local test PEM or base64 PEM directly.

Older private settings may contain `DEFAULT_PROVIDER`, `ENDPOINT_TIMEOUT_MS`, `REQUIRE_AUTH`,
`EXPECTED_AUDIENCE`, `ISSUER_TENANT_ID`, `EUDB`, or per-provider `*_ENDPOINT` entries. Those do not
configure the current shared engine. Use `EPP_PROVIDER_NAME`, `EPP_PROVIDER_ENDPOINT` and
`EPP_PROVIDER_TIMEOUT_MS` instead; configure caller authentication in Easy Auth. Keep adapter options
that are actually read, such as a service-plan ID or voice selection. Private integration helpers may
load settings from another location or use test credential variables, but the Function itself does not.

For the omnimsg adapter, the configured base ends in `/cgpapi`; the adapter appends `/messages/omnimsg`
for SMS and voice. QA4 is the test environment; select the provider-approved production base separately.
The base URL is not hard-coded and changing local settings does not change an already deployed app.

For Azure, set these application variables on the Function App/slot's **Environment variables → App
settings** page and use a Key Vault reference for the private PEM. The provider-secret resolver uses
managed identity; signing into the CLI locally does not supply that identity. Local evaluation avoids
provider lookup, while tests inject mocked credentials and HTTP. Keep the local endpoint on loopback.

## Request behavior

Easy Auth authenticates and authorizes the caller before `POST /api/SendOtp`; the anonymous handler
validates the envelope and decrypts the JWE, without parsing or echoing incoming `Authorization`.
JWE does not authenticate SAS: anyone with the public key can encrypt a request, and a fixed nonce
is not authentication. Request `mode`, `channel`, `ttlSeconds` and `tenantId` are request data, not
environment settings or sources of identity trust. The caller-rendered message is forwarded unchanged;
the endpoint does not guess a passcode.

For non-delivery validation, use incoming `mode: 2` or `mode: "evaluation"`. This generic shutter
works for every provider without provider configuration, provider Key Vault reads or provider HTTP;
platform authentication on Azure and handler decryption still run. No diagnostic environment flag is needed. See the
[evaluation contract](../docs/CONTRACT.md#evaluation-generic-shutter) for authentication/key prerequisites.

Live requests use the configured provider's API key and await acceptance before returning the nonce.
Acceptance is not handset delivery; failures omit the nonce, and timeouts must not trigger blind
retries. The shared contract defines validation, HTTP outcomes and privacy-safe logging.

## Source and extension points

| Source | Purpose |
|---|---|
| [src/functions/SendOtp.js](src/functions/SendOtp.js) | HTTP handler |
| [src/functions/config.js](src/functions/config.js) | Shared deployment settings |
| [src/functions/models.js](src/functions/models.js) | Delivery context, normalized `ParsedResponse`, and documented request objects |
| [src/functions/dispatch.js](src/functions/dispatch.js) | Envelope/JWE handling, registry and dispatch |
| [src/functions/providers/](src/functions/providers/) | Adapter manifests and API-specific implementations |
| [test/](test/) | Representative offline checks |

To add an adapter, implement `manifest`, `buildRequest` and `parseResponse` in the adapter folder and
register it in [src/functions/dispatch.js](src/functions/dispatch.js). Return a `ParsedResponse` from
`parseResponse`; raw API-specific JSON stays inside that adapter. Keep credentials, options and
status mapping with that adapter; the shared pipeline needs no provider-specific branches. See
[production limitations](../docs/CONTRACT.md#production-limitations) before production use.
