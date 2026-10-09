# Add multiple provider configurations to your application

You can adapt this sample to use multiple provider accounts behind **one SAS-facing URL:
`/api/SendOtp`**. SAS keeps calling its configured URL. The server maps the validated channel to
exactly one active provider/account context: Telesign for SMS and Soprano for voice in this
walkthrough. Each context has its own configuration and credential cache.

The sample does **not** do this out of the box: it still uses one provider per deployment through
`EPP_PROVIDER_NAME`. This walkthrough shows where to make the changes in your own JavaScript
application. It does not add a router or setup script to the repository.

The snippets are **integration examples, not a drop-in handler**. They fit into
[SendOtp.js](../javascript/src/functions/SendOtp.js) and use its existing variables and helpers.
Anything named `CUSTOMER_*` is a placeholder you must implement; it is not a repository API.

## 1. Bind each channel to one provider at startup

Keep the existing `SendOtp` HTTP-trigger registration and `/api/SendOtp` path. Define this
server-owned map once at startup; do not add another SAS endpoint or a caller-selected provider:

```javascript
// Module scope in your customized SendOtp.js, not supplied by the caller.
const routeByChannel = Object.freeze({
    sms: 'telesign-primary',
    voice: 'soprano-primary',
});
```

Open [entraPayload.js](../javascript/src/functions/entraPayload.js) to see how the handler
validates the channel and exposes `payload.channelName`. Use that validated value with your
approved policy. Reject unsupported or ambiguous routes; do not silently choose a default.

Each supported channel has exactly one active account. Two SMS providers cannot both be
caller-selected in this design. Changing the active SMS provider is an administrative configuration
change, validated and applied through deployment or a controlled restart as described below.
Do not use headers, `providerId`, correlation IDs or body `tenantId` to override the map. There is
no random or round-robin selection, automatic switching, fallback, fan-out or resend. Keep provider
endpoint URLs, vaults, scopes and secret names under server control.

## 2. Define one configuration per provider account

Open [config.js](../javascript/src/functions/config.js). Its `readConfig(env)` function accepts
an explicit settings object, so you can reuse it without changing `process.env` per request.

Give each account a unique context ID. For example, two Telesign accounts would need different
IDs even though both have `EPP_PROVIDER_NAME: "telesign"`.

Use the following as a starting point for **your own configuration format**. Replace the
placeholders with approved values. The sample does not load this JSON automatically.

```json
[
  {
    "id": "telesign-primary",
    "settings": {
      "EPP_PROVIDER_NAME": "telesign",
      "EPP_PROVIDER_CHANNEL": "sms",
      "EPP_PROVIDER_AUTH_MODE": "apiKey",
      "EPP_PROVIDER_ENDPOINT": "https://<approved-telesign-host>/<path>",
      "EPP_PROVIDER_TIMEOUT_MS": "1500",
      "KEY_VAULT_URL": "https://<telesign-vault>.vault.azure.net",
      "AZURE_CLIENT_ID": "<vault-reader-managed-identity-client-id>"
    }
  },
  {
    "id": "soprano-primary",
    "settings": {
      "EPP_PROVIDER_NAME": "soprano",
      "EPP_PROVIDER_CHANNEL": "voice",
      "EPP_PROVIDER_AUTH_MODE": "oauth",
      "EPP_PROVIDER_ENDPOINT": "https://<approved-soprano-host>/<path>",
      "EPP_PROVIDER_TIMEOUT_MS": "1500",
      "EPP_PROVIDER_TENANT_ID": "<provider-tenant-id>",
      "EPP_PROVIDER_SCOPE": "api://<provider-api-resource>/.default",
      "EPP_OUTBOUND_CLIENT_ID": "<outbound-application-client-id>",
      "EPP_OUTBOUND_MI_CLIENT_ID": "<outbound-managed-identity-client-id>"
    }
  }
]
```

Store **references and identifiers, not secret values**. The
[Telesign adapter](../javascript/src/functions/providers/telesign.js) requests the secret names
`telesign-api-key` and `telesign-customer-id`. Separate vaults let two accounts use those same
names. Different names in one vault require your own per-context credential specification;
do not mutate the shared adapter's `credentialSpec`.

The [Soprano adapter](../javascript/src/functions/providers/soprano.js) uses OAuth. Keep its
provider tenant, resource scope, outbound application and managed identity together as one
configuration. These settings do not grant consent or provider entitlement.

Keep inbound authentication and decryption configuration separate. Selecting an outbound provider
must not change the key used to decrypt the incoming request.

## 3. Create isolated, long-lived credential contexts

Open [credentials.js](../javascript/src/functions/credentials.js). The exported
`credentialTokenService` singleton keeps **one selected cache**. Passing it a different account
or authentication mode does not switch that cache.

Use a new `CredentialTokenService` for each context instead. Build the contexts once per worker,
not once per request. Consolidate the imports below with the existing imports in your customized
`SendOtp.js`: `readConfig` and `selectProvider` are already imported, so do not paste duplicate
`const` declarations. Add `CredentialTokenService` to the existing credentials import and retain
required logging helpers such as `reportRefreshFailure`. Remove the `credentialTokenService`
singleton import only after replacing all its request and lifecycle uses.

```javascript
const { readConfig } = require('./config');
const { selectProvider } = require('./providers');
const { CredentialTokenService, reportRefreshFailure } = require('./credentials');

// CUSTOMER_LOAD_AND_VALIDATE_CONFIG is your startup-only configuration loader.
// It must validate the complete list before any context is used.
const entries = CUSTOMER_LOAD_AND_VALIDATE_CONFIG();
const contexts = new Map();

for (const entry of entries) {
    if (!entry.id || contexts.has(entry.id)) {
        throw new Error('Missing or duplicate provider context ID');
    }
    const settings = Object.freeze({ ...entry.settings });
    const config = Object.freeze(readConfig(settings));
    const provider = selectProvider(config.providerName);
    if (!provider || config.providerAuthMode !== provider.authenticationMode) {
        throw new Error('Invalid provider context');
    }
    contexts.set(entry.id, Object.freeze({
        config,
        provider,
        credentials: new CredentialTokenService(),
    }));
}
```

Your loader must also validate required credential settings, allowed channels, approved endpoint
allowlists, timeout values, a bounded context count, and that every routing rule identifies exactly
one matching context. The checks above are not a complete configuration validator.
[providers/index.js](../javascript/src/functions/providers/index.js) supplies the fixed adapter
lookup; unknown names return `null`.

Freeze both the settings and config objects: `readConfig` retains the settings object as `env`.
Never reuse a context's service for a different vault, account, OAuth scope or identity. A provider
name alone is not enough to identify cached credentials.

## 4. Select the context only after evaluation returns

In [SendOtp.js](../javascript/src/functions/SendOtp.js), find `if (evaluation)`. Leave that branch,
the preceding envelope checks, [JWE decryption](../javascript/src/functions/jwe.js), and the
complete-delivery-context check in place. Keep Easy Auth enabled at the application boundary.

The order must remain:

```text
Authenticate -> validate envelope -> decrypt -> check delivery context
  -> evaluation? Return the existing nonce response
  -> otherwise select one provider context
```

Immediately after the existing evaluation early return, replace the block beginning
`const provider = selectProvider(config.providerName)` through the end of `if (!provider)` with
the following. Keep the `logContext = providerContext(...)` and `provider_selected` lines that
follow it. This fragment uses the handler's existing response helpers and request variables:

```javascript
const contextId = routeByChannel[payload.channelName];
const selectedContext = contexts.get(contextId);
if (!selectedContext) {
    fail('provider_selection', 'unknown_provider', 400);
    return respond(400, {
        error: 'provider_delivery_failed', correlationId, requestId,
    });
}
const { provider, config: providerConfig, credentials } = selectedContext;
```

The existing channel check below this block will reject a mismatched channel in step 5.
Use only the startup-owned `routeByChannel` map for selection. Evaluation must not depend on
that selection or acquire provider credentials. An invalid encrypted evaluation still fails the
existing checks; do not add a shortcut that returns a nonce before decryption.

## 5. Use the selected context for one dispatch

Continue in [SendOtp.js](../javascript/src/functions/SendOtp.js). Keep its channel, authentication
mode and endpoint checks, but read their outbound settings from `providerConfig`. Keep using the
original `const config = readConfig()` for `config.decryptionKeyPem` and `config.expectedKeyId`.
Do not redeclare `config` in the handler or replace its inbound settings with the selected context.
After the evaluation return, change the existing checks' `config.providerChannel`,
`config.providerAuthMode` and `config.providerEndpoint` references to the corresponding
`providerConfig` properties; leave their failure branches intact.

Inside the existing credential-resolution `try` block, replace the singleton call with:

```javascript
credential = await credentials.getCredentials(
    provider.credentialSpec,
    providerConfig,
);
```

Keep the existing completeness checks for API-key identity/secret and OAuth access token, and
the `credential_unavailable` error path. For OAuth logging, pass `providerConfig` to
`credentialContext` too.

Keep the handler's [OtpDelivery](../javascript/src/functions/delivery.js) construction so phone,
message, locale and correlation handling stay unchanged. In the existing **request-build**
`try` block, replace only the `provider.createRequest` call:

```javascript
providerRequest = provider.createRequest({
    channel,
    endpoint: providerConfig.providerEndpoint,
    delivery,
    credential,
    env: providerConfig.env,
});
```

In the separate **transport** `try` block, replace only the `sendProviderRequest` call.
Keep both blocks' existing catches so build failures and transport failures retain their
different error classifications:

```javascript
transportResponse = await sendProviderRequest(
    providerRequest,
    parseProviderTimeout(providerConfig.providerTimeoutMs),
    logContext,
);
```

The imports and error handling for `sendProviderRequest` and `parseProviderTimeout` already exist
in `SendOtp.js`. See [providerTransport.js](../javascript/src/functions/providerTransport.js)
for URL checks, manual redirects and timeout behavior. Preserve those controls and your approved
endpoint allowlist. Do not forward the inbound authorization header.

Keep `provider.interpretResponse(transportResponse)` and the existing
[response mapping](../javascript/src/functions/providerResult.js). Preserve success/block/failure
statuses, the success nonce and correlation ID, and the handler's error responses. A provider
timeout, rejection or unknown response must not trigger another account or provider.
**One request gets one dispatch: no fan-out, automatic fallback or resend.**

Retain the [logging helpers](../javascript/src/functions/logging.js) and their fixed failure
classifications. If you add a context ID to telemetry, use an approved non-secret identifier.
Never log OTP/phone data, request bodies, credentials, raw provider descriptions or exceptions.

## 6. Update startup, refresh and shutdown together

Find `startProviderCredentialRefresh` and `stopProviderCredentialRefresh` in
[SendOtp.js](../javascript/src/functions/SendOtp.js). They currently use the singleton. Replace
that lifecycle wiring as part of your customization; leaving it behind could warm the wrong account.

Decide explicitly whether to prewarm approved contexts at startup or acquire credentials on the
first live request. A service starts its own periodic refresh when first used. Prewarming performs
credential I/O, so do not do it in an offline test without fake SDK boundaries. Report acquisition
failures through the existing safe reporting mechanism; never borrow another context's credentials.

If you choose startup prewarming, replace **both existing function bodies** with the following
pattern. This assumes every context has passed your startup validation and is approved for
credential acquisition. Keep the existing `reportRefreshFailure` import; remove the singleton
import once no handler or lifecycle code references it.

```javascript
async function startProviderCredentialRefresh() {
    for (const { provider, config: providerConfig, credentials } of contexts.values()) {
        try {
            await credentials.getCredentials(provider.credentialSpec, providerConfig);
        } catch {
            // Refresh failures are reported by the service; report initialization failures here.
            if (!credentials.current) reportRefreshFailure('configuration');
        }
    }
}

function stopProviderCredentialRefresh() {
    for (const { credentials } of contexts.values()) {
        credentials.close();
    }
}
```

Keep the existing `app.hook.appStart(startProviderCredentialRefresh)` and
`app.hook.appTerminate(stopProviderCredentialRefresh)` registrations once each; do not add duplicate
hooks. Build and validate `contexts` before startup runs. With prewarming, retain both functions
in the existing bottom export:

```javascript
module.exports = { startProviderCredentialRefresh, stopProviderCredentialRefresh };
```

For **lazy acquisition**, remove the app-start registration and the
`startProviderCredentialRefresh` function together. Retain the context-closing termination
function and its hook, and replace the bottom export with:

```javascript
module.exports = { stopProviderCredentialRefresh };
```

Leaving the removed startup function in `module.exports` causes a `ReferenceError` when the module
loads, before any request can run. In either variant, no lifecycle code should continue to resolve
credentials from the original process-wide provider selection.

Keep cache expiry, refresh coalescing and acquisition bounds. Use a controlled worker restart when
changing startup-loaded configuration, rebuilding each context and its cache. Do not
modify a live service's inputs. Evaluation requests must not start credential acquisition, but
already-running background refresh is independent of a request's evaluation branch.

Separate contexts provide logical isolation, not a tenant security boundary. A compromised worker
may reach every identity assigned to it. Review least privilege before approving this design.

## 7. Test your changes offline first

Start from the existing
[adapter tests](../javascript/test/provider-flow.test.js),
[credential-cache tests](../javascript/test/credential-cache.test.js) and
[handler tests](../javascript/test/sendotp.test.js).
They show how to fake credential acquisition and provider transport. Use synthetic delivery data
and a locally generated encryption key; make unexpected network calls fail.

**Before editing the handler**, run the existing tests as a baseline. Use Node.js 22 and restore
missing JavaScript dependencies from the existing lockfile first. From the repository root in
PowerShell:

```powershell
# Only if dependencies are not installed.
npm ci --prefix .\javascript --ignore-scripts --no-audit --no-fund
```

Then run:

```powershell
node --test .\javascript\test\provider-flow.test.js `
    .\javascript\test\credential-cache.test.js `
    .\javascript\test\sendotp.test.js
```

**After customization**, update the test fixtures and singleton/lifecycle mocks to use your
context services before rerunning and extending these tests. The original single-provider fixtures
are not automatically valid for your customized handler.

They are a starting point, not coverage for your new router. Add tests for concurrent requests to
different channel bindings, including separate SMS/voice test accounts of the same adapter.
Do not introduce two active SMS choices to run these tests. Check the exact endpoint,
credential, message and correlation ID for each request. Test unknown/duplicate/ambiguous routes,
channel mismatch, expired or failing credentials, provider errors, timeouts, malformed responses,
shutdown and configuration replacement. Failures must cause no second dispatch.

Check that valid evaluation returns before routing/credentials/transport and invalid evaluation
still fails. Cover voice and every adapter you intend to enable. The shared
[contract fixtures](../tests/fixtures/contract.json) help preserve endpoint response behavior.

## 8. Review and approve live rollout separately

Before deployment, review identity/vault permissions, OAuth consent, provider entitlement,
sender/channel approval, rate limits, secret rotation and operational ownership. Rotate any exposed
credentials first. Offline checks do not establish any of these prerequisites.

Use a separately approved nonproduction deployment. Verify authentication, encryption and policy
readback before authorized evaluation. A real SAS trigger can involve surrounding fallback
behavior, so do not assume it is harmless because this Function's evaluation branch skips delivery.

Only attempt live delivery with explicit authorization, an approved recipient, coordinated policy
and attempt limits, and a **one-attempt safety gate**. Provider acceptance is not proof of handset
delivery. Plan an explicit rollout and rollback; do not hide failures behind automatic fallback.
Nothing in this walkthrough authorizes a SAS trigger or provider send.

### What needs deployment, configuration, or restart?

Deploy your customized application code once, after its offline tests pass. Adding provider
settings to an unchanged checkout does not implement this guide: the shipped handler still
selects one provider per deployment. This customization hosts the SMS and voice account contexts
in **one Function App and one code package**, behind the existing `SendOtp` HTTP-triggered function.
It is not one deployment per provider, and it does not change the SAS-facing URL.

| Change | Required action |
| --- | --- |
| Change the handler, channel map, an adapter, or a code-owned endpoint allowlist | Build, test and deploy a new application package. |
| Change account references, scopes or identities in the startup configuration loader | Validate the complete configuration, apply it, and perform a controlled worker restart. If configuration is embedded in code, deploy a new package instead. |
| Rotate a referenced secret | Update the approved secret and verify credential-cache refresh. Updating the vault alone is not proof that running workers use the new version; use a controlled restart when needed. Update pinned secret-version references explicitly. |
| Repeat an authorized test with unchanged code and configuration | No redeployment is needed. Verify the deployed package identifier, routing, authentication and credential readiness first. |
| Update only this documentation | No runtime deployment is needed. |

The existing deployment automation does not create your custom account contexts, channel map or
configuration loader. Adapt your deployment process to provision only the required identities,
vault permissions and provider consent, then deploy the same reviewed package and validated
configuration to each intended instance. Preserve inbound authentication and decryption settings.
Treat code and configuration as one rollout, and retain their previous versions for rollback.

### Replace the active SMS provider with Infobip

This is an optional administrative replacement of Telesign for SMS, not an additional caller
choice. `/api/SendOtp` and the Soprano voice binding remain unchanged.

1. Replace the `telesign-primary` entry in your custom loader's active configuration with the
   following `infobip-primary` entry. Keep the Soprano entry. Supply approved account values,
   never secret values:

```json
{
  "id": "infobip-primary",
  "settings": {
    "EPP_PROVIDER_NAME": "infobip",
    "EPP_PROVIDER_CHANNEL": "sms",
    "EPP_PROVIDER_AUTH_MODE": "apiKey",
    "EPP_PROVIDER_ENDPOINT": "https://<approved-infobip-base-host>",
    "EPP_PROVIDER_ACCOUNT_NAME": "<approved-sender>",
    "EPP_PROVIDER_TIMEOUT_MS": "1500",
    "KEY_VAULT_URL": "https://<infobip-vault>.vault.azure.net",
    "AZURE_CLIENT_ID": "<vault-reader-managed-identity-client-id>"
  }
}
```

The [Infobip adapter](../javascript/src/functions/providers/infobip.js) reads `infobip-api-key`
and appends `/sms/3/messages` to the configured **base URL**. Do not put that operation suffix
in `EPP_PROVIDER_ENDPOINT`: it must be appended exactly once. In your startup loader, validate
the approved HTTPS base host with no operation path, query or fragment, and either reject a
trailing slash or remove it before freezing the settings; otherwise the adapter creates a double
separator. The adapter defaults to `Verify` if the sender setting is absent; that is not a
universally valid sender. Set the sender approved for your Infobip account and destination.

2. Complete the account, sender, destination and vault-access prerequisites before activating
   the replacement. Create a new long-lived credential service/cache for the Infobip context;
   never reuse the Telesign cache with different inputs.

Attach each referenced user-assigned managed identity to the Function App and grant the
vault-reading identity scoped secret-read access to its intended
vault, such as **Key Vault Secrets User** under RBAC or the approved access-policy equivalent.
If using the Function App's system-assigned identity, grant that identity instead. Context IDs and
managed-identity client-ID settings do not attach identities or grant permissions. See the
[provider credential onboarding guidance](ONBOARDING.md#complete-provider-authentication).
Keep shared inbound authentication/decryption separate from these outbound credentials.
The existing setup catalog does not provision this Infobip customization.

3. Change only the `sms` value in `routeByChannel` from `telesign-primary` to `infobip-primary`.
   Validate that each supported channel resolves to one configured context with the matching
   channel/authentication mode and an approved provider endpoint. Reject missing or duplicate
   configuration, and rerun the offline handler tests with the replacement binding.
4. The map in section 1 is code-owned, so build and deploy the reviewed package with the new map
   and active configuration. For later changes to values already read by the startup loader,
   validate and apply the complete configuration with a controlled worker restart. Close old
   contexts and initialize fresh caches; do not switch an in-flight request or retry its delivery.
   Verify the deployed package/configuration version before any separately authorized live check.

SAS still sends to `/api/SendOtp`; it does not select the replacement provider. An SMS failure
must not return to Telesign, retry or send through both providers. [Front Door regional
failover](FRONTDOOR.md) remains separate: retain forwarding for `/api/SendOtp` and preserve
inbound authentication and origin/network restrictions.

For an authorized live check, record unique correlations and durable intent-before-send attempt
guards. Stop on unexpected failures and do not retry uncertain sends automatically. A guard is
not provider idempotency or proof of exactly-once delivery. Record actual attempts, provider
acceptance and handset receipt separately: HTTP 200 or `PENDING` alone is not handset proof.
A sequential check does not establish concurrency, capacity, automatic failover, regional
resilience or real SAS integration. This replacement procedure authorizes no live operation.

## Using .NET or Python instead

**.NET:** Start with [SendOtp.cs](../dotnet/Functions/SendOtp.cs) and
[AppConfig.Read(IEnv)](../dotnet/Src/AppConfig.cs). Isolate the entire configuration, provider,
credential service and secret resolver per account.
[CredentialTokenService](../dotnet/Src/CredentialTokenService.cs) caches by `provider.Name`;
[SopranoProvider](../dotnet/Src/Providers/SopranoProvider.cs) retains its initial OAuth
identity/scope, and [SecretResolver](../dotnet/Src/SecretResolver.cs) retains its initial vault
client. Changing only the outer cache key is not enough. Update the singleton registrations and
lifecycle in [Program.cs](../dotnet/Program.cs), preserve
[PhoneProviderBase](../dotnet/Src/PhoneProviderBase.cs) transport/response behavior, and test
concurrent cold acquisition rather than assuming JavaScript's coalescing behavior.
Extend [SendOtpTests](../dotnet/tests/SendOtpTests.cs) and
[CredentialTokenServiceTests](../dotnet/tests/CredentialTokenServiceTests.cs).

**Python:** Start with `_send_to_provider` and the evaluation branch in
[function_app.py](../python/function_app.py). Pass a selected context explicitly instead of
rereading process settings. Use [read_config(env)](../python/src/config.py), a separate
[CredentialTokenService](../python/src/credentials.py) and
[SecretResolver(env)](../python/src/secrets.py) per account; the module-level credential service
owns one selected cache. Update warmup/shutdown and preserve
[PhoneProviderBase](../python/src/provider.py) transport/response behavior. Extend
[test_engine.py](../python/tests/test_engine.py),
[test_credential_cache.py](../python/tests/test_credential_cache.py) and
[test_function_app.py](../python/tests/test_function_app.py).

## Scope of this guidance

An offline, in-memory adaptation of the registered JavaScript `SendOtp` handler checked this
SMS/Telesign and voice/Soprano design, same-provider account isolation, failures and evaluation
ordering. Its registered startup/shutdown callbacks and simulated refresh were also exercised.
Functions host registration, Azure SDK calls and provider HTTP were faked: this was not a deployed
or authenticated end-to-end test. Real OAuth/Key Vault, deployed authentication, production
refresh/scale-out and handset delivery still need your validation. .NET/Python pointers are
based on code inspection, not equivalent multi-context tests.

Runtime adapters also include Infobip and Sinch; the [setup catalog](../setup/providers/catalog.json)
contains only Telesign and Soprano. Adapter availability does not imply setup coverage or account
entitlement. The original offline feasibility check performed no Azure, Graph, Key Vault, SAS or
provider operations. Report any subsequent live test of a customer customization separately,
including its deployed revision, authorized workload, provider responses and delivery limitations.
Such a test does not make the custom router part of the shipped sample.
