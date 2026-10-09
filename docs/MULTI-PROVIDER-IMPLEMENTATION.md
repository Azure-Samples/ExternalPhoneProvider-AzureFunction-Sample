# Add multiple provider configurations to your application

You can adapt this sample to choose between multiple provider accounts in one application.
The key is to give each account its own configuration and credential cache, then select exactly
one account for each request.

The sample does **not** do this out of the box: it still uses one provider per deployment through
`EPP_PROVIDER_NAME`. This walkthrough shows where to make the changes in your own JavaScript
application. It does not add a router or setup script to the repository. If accounts need a strong
security boundary, keep them in separate deployments instead.

The snippets are **integration examples, not a drop-in handler**. They fit into
[SendOtp.js](../javascript/src/functions/SendOtp.js) and use its existing variables and helpers.
Anything named `CUSTOMER_*` is a placeholder you must implement; it is not a repository API.

## 1. Choose a routing rule you control

Start with a simple, server-owned rule. The steps below use an **illustrative channel policy**:
one account for SMS and another for voice. This is different from the
[two-SMS fixed-URL test](#testing-two-sms-providers-in-one-deployment) later in this guide.

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

If you need two accounts for the same channel, first decide how your application will verify
the customer or endpoint identity that owns the request. The existing contract has no trusted
provider-selector field. An arbitrary header, `providerId`, correlation ID or unverified body
`tenantId` is **not** authority to select an account. The SAS caller identity may not distinguish
your customers either. Keep endpoint URLs, vaults, scopes and secret names under server control.

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
For customer/account-based routing, this is where your **verified, authorized** customer binding
must select the context instead of `routeByChannel`. Evaluation must not depend on that selection
or acquire provider credentials. An invalid encrypted evaluation still fails the existing checks;
do not add a shortcut that returns a nonce before decryption.

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
changing configuration, or implement safe draining and replacement of whole contexts. Do not
modify a live service's inputs. Evaluation requests must not start credential acquisition, but
already-running background refresh is independent of a request's evaluation branch.

Separate contexts provide logical isolation, not a tenant security boundary. A compromised worker
may reach every identity assigned to it. Review least privilege and use separate deployments when
that risk is unacceptable.

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
different providers **and two accounts of the same provider**. Check the exact endpoint,
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
selects one provider per deployment. A customer implementation can host multiple account
contexts in **one Function App and one code package**, with multiple HTTP-triggered functions
sharing handler code. This is not one deployment per provider. Separate deployments are needed
only when your security or operational isolation requirements call for them.

| Change | Required action |
| --- | --- |
| Add or change the router, an adapter, a Function entry point, or a code-owned endpoint allowlist | Build, test and deploy a new application package. |
| Change account references, scopes, identities, or routing in an already implemented startup configuration loader | Validate the complete configuration, apply it, and perform a controlled worker restart. If configuration is embedded in code, deploy a new package instead. |
| Rotate a referenced secret | Update the approved secret and verify credential-cache refresh. Updating the vault alone is not proof that running workers use the new version; use a controlled restart when needed. Update pinned secret-version references explicitly. |
| Repeat an authorized test with unchanged code and configuration | No redeployment is needed. Verify the deployed package identifier, routing, authentication and credential readiness first. |
| Update only this documentation | No runtime deployment is needed. |

The existing deployment automation does not create your custom account registry, routes or
configuration loader. Adapt your deployment process to provision only the required identities,
vault permissions and provider consent, then deploy the same reviewed package and validated
configuration to each intended instance. Preserve inbound authentication and decryption settings.
Treat code and configuration as one rollout, and retain their previous versions for rollback.

### Testing two SMS providers in one deployment

The channel example earlier distinguishes SMS/Telesign from voice/Soprano. It cannot choose
between two SMS providers. For the reported customer test design, use these fixed bindings in
**one Function App and one package**:

```text
POST /api/SendOtp        -> telesign-primary -> Telesign -> channel=sms
POST /api/SendOtpInfobip -> infobip-primary  -> Infobip  -> channel=sms
```

The caller chooses the URL; server code binds that URL to its approved provider context.
No provider-selection header is needed. Authorize the caller for the account behind each entry
point: the URL's existence alone is not account authorization.

If these URLs are behind a proxy or Front Door, configure and verify forwarding for both intended
paths while retaining authentication and origin restrictions. Adding a Function route does not
automatically update upstream routing configuration.

In your customization of [SendOtp.js](../javascript/src/functions/SendOtp.js), extract the common
callback into a handler factory that captures a fixed context ID. Register two HTTP-triggered
functions using the existing `app.http` pattern, with explicit `route: 'SendOtp'` and
`route: 'SendOtpInfobip'` (assuming the standard `/api` route prefix). Register each name/route
once; replace the original registration rather than adding a duplicate. The shared handler keeps
the same validation, decryption, evaluation early return and error/response mapping. Only after
evaluation returns does it look up its captured ID, instead of using `routeByChannel`. Both
contexts must require `sms`. A handler factory is **code you implement**, not a shipped
`createHandler` API. Neither payload fields nor headers may override the captured binding.

Keep the Telesign configuration from step 2 and add this entry through your custom loader:

```json
{
  "id": "infobip-primary",
  "settings": {
    "EPP_PROVIDER_NAME": "infobip",
    "EPP_PROVIDER_CHANNEL": "sms",
    "EPP_PROVIDER_AUTH_MODE": "apiKey",
    "EPP_PROVIDER_ENDPOINT": "https://<approved-infobip-base-host>",
    "EPP_PROVIDER_ACCOUNT_NAME": "Verify",
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
separator. `Verify` was the sender setting for this test design, not a universally valid sender.
Use the sender approved for your Infobip account and destination; do not rely on the adapter's
`Verify` default as evidence of approval.

Create a separate long-lived credential service/cache for each account, with the required vault
permissions and managed identity access. Complete each provider's account, route, sender and
recipient prerequisites. Keep shared inbound authentication/decryption separate from these
outbound credentials. The existing setup catalog does not provision this Infobip customization.

This is **provider selection, not automatic provider failover**. The test caller chooses a fixed
entry point; its server-owned binding chooses the account. Both requests still use the validated
`sms` channel, and no provider-selection header is needed. A failed or timed-out request must not
silently switch accounts, retry or send through both. **SAS calling one configured URL keeps
using that URL**; adding another function does not make SAS select it. Single-URL provider
selection or automatic fallback requires a separately designed trusted policy and handling for
delivery uncertainty and duplicates. [Front Door regional failover](FRONTDOOR.md) is separate
from provider selection.

Only under a separately approved test plan, after authorized encrypted evaluation and rejection
checks pass on both entry points, a bounded comparison can use **five paired rounds**:
one Telesign message and one Infobip message per round, **ten planned message attempts if all
five pairs finish**. Agree on that limit and an approved recipient before running. These labels
describe planned attempts, not verified sends or delivery:

```text
EPP multi-provider test: Telesign - attempt 1/5.
EPP multi-provider test: Infobip - attempt 1/5.
...
EPP multi-provider test: Telesign - attempt 5/5.
EPP multi-provider test: Infobip - attempt 5/5.
```

Alternate providers while keeping the deployed package and account configuration unchanged.
Assign a unique correlation ID to every request. Atomically persist a durable guard recording
intent before dispatch, keyed by test run, provider and attempt number; refuse an already-recorded
attempt, including after a runner restart. This guard is **not provider idempotency or proof of
exactly-once delivery**: a crash or timeout can leave the outcome uncertain.
Do not retry an uncertain send automatically. Stop on unexpected failures, report actual attempted
counts and partial results, and obtain separate approval for any replacement attempt. Do not
automatically top up an aborted run to ten or turn errors into fallback sends.

For each planned request, record its provider, round, package identifier, endpoint response,
nonce validation, latency and correlated provider-dispatch evidence. Verify exactly one dispatch
to the intended provider and no cross-account fallback. Record provider acceptance and handset
receipt separately; `PENDING` or HTTP 200 is not a delivery receipt. Keep phone numbers, message
contents, tokens and credentials out of telemetry.

A sequential comparison does not prove concurrency, capacity, automatic provider failover,
Front Door regional resilience or real SAS integration. Preserve the existing inbound authentication
and origin/network restrictions for both functions; use only the approved test access path. If that
path is unavailable, stop and arrange authorized access rather than opening ingress or bypassing
restrictions. This section documents a custom test design, not authorization to execute it or a
claim that all planned messages were accepted or delivered.

Keep the evidence separate: the earlier offline registered-handler checks exercised channel-based
Telesign SMS/Soprano voice routing, not this Telesign/Infobip pair of fixed HTTP routes. Their
concurrency results do not validate the new deployment or extend the user's reported sequential
URL-based test into a concurrency test.

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
or authenticated end-to-end test. Real OAuth/Key Vault, trusted customer routing, production
refresh/scale-out and handset delivery still need your validation. .NET/Python pointers are
based on code inspection, not equivalent multi-context tests.

Runtime adapters also include Infobip and Sinch; the [setup catalog](../setup/providers/catalog.json)
contains only Telesign and Soprano. Adapter availability does not imply setup coverage or account
entitlement. The original offline feasibility check performed no Azure, Graph, Key Vault, SAS or
provider operations. Report any subsequent live test of a customer customization separately,
including its deployed revision, authorized workload, provider responses and delivery limitations.
Such a test does not make the custom router part of the shipped sample.
