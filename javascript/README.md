# External Phone Provider Function — JavaScript

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
4. Configure the existing authentication and decryption settings from the
   [shared catalog](../docs/CONTRACT.md#4-configuration-app-settings--env). Enable Easy Auth and
   in-process JWT validation on Azure. An incoming body tenant or forwarded principal header is not
   deployment trust; the explicit issuer pin is optional, but trusted issuer-tenant configuration is not.
5. Install dependencies from [package.json](package.json), run its offline test script and start the
   local Functions host from this folder. Publish this app folder only, preserving dependencies and
   observing [.funcignore](.funcignore); inspect the package before upload.

## Request behavior

`POST /api/SendOtp` authenticates the caller and decrypts the JWE. Request `mode`, `channel`,
`ttlSeconds` and `tenantId` are request data, not environment settings or sources of identity trust.
The caller-rendered message is forwarded unchanged; the endpoint does not guess a passcode.

For non-delivery validation, use incoming `mode: 2` or `mode: "evaluation"`. This generic shutter
works for every provider without provider configuration, provider Key Vault reads or provider HTTP;
authentication and decryption still run. No diagnostic environment flag is needed. See the
[evaluation contract](../docs/CONTRACT.md#evaluation-generic-shutter) for authentication/key prerequisites.

Live requests await provider acceptance before returning the nonce. Acceptance is not handset
delivery; failures omit the nonce, and timeouts must not trigger blind retries. The shared contract
defines validation, HTTP outcomes and privacy-safe logging.

## Source and extension points

| Source | Purpose |
|---|---|
| [src/functions/SendOtp.js](src/functions/SendOtp.js) | HTTP handler |
| [src/functions/config.js](src/functions/config.js) | Shared deployment settings |
| [src/functions/security.js](src/functions/security.js) | Inbound JWT validation |
| [src/functions/dispatch.js](src/functions/dispatch.js) | Envelope/JWE handling, registry and dispatch |
| [src/functions/providers/](src/functions/providers/) | Adapter manifests and API-specific implementations |
| [test/](test/) | Representative offline checks |

To add an adapter, implement `manifest`, `buildRequest` and `parseResponse` in the adapter folder and
register it in [src/functions/dispatch.js](src/functions/dispatch.js). Keep credentials, options and
status mapping with that adapter; the shared pipeline needs no provider-specific branches. See
[production limitations](../docs/CONTRACT.md#production-limitations) before production use.
