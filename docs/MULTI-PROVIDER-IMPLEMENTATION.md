# Provider fallback

<a id="add-conservative-primary-to-secondary-provider-fallback"></a>

[Documentation](README.md) | [Normal deployment](GETTING-STARTED.md) | [Provider interface](BRING-YOUR-OWN-PROVIDER.md)

Add controlled primary-to-secondary fallback around `/api/SendOtp`. Keep one server-owned SMS
provider order with durable state and provider-specific approval.

Use the secondary **only after proof that the primary did not accept the request**. Timeouts,
lost responses, and generic errors are uncertain and must not trigger an automatic resend.

Follow [policy](#1-set-a-fixed-provider-order-and-a-deny-by-default-policy),
[account configuration](#2-configure-and-prevalidate-both-accounts),
[credential isolation](#3-give-each-context-its-own-credential-service-and-lifecycle),
[durable state](#4-add-durable-operation-state-before-enabling-fallback),
[fallback flow](#5-integrate-one-guarded-fallback-into-the-handler),
[end-to-end deadline](#6-enforce-one-aggregate-deadline), and [validation](#7-validate-offline-then-deploy-only-after-separate-approval).
[.NET/Python pointers](#net-and-python-integration-pointers) are not implemented fallback.

<a id="1-set-a-fixed-provider-order-and-a-deny-by-default-policy"></a>
## 1. Provider order

Keep [SendOtp.js](../javascript/src/functions/SendOtp.js) and define the order at startup:

```javascript
const providerOrder = Object.freeze({
    channel: 'sms',
    primary: 'primary-account',
    secondary: 'secondary-account',
});
```

Reject unsupported channels and request-supplied provider configuration. Do not use round-robin,
fan-out, recursive fallback, or primary retries. Attempt the secondary at most once.

Keep **routing order** separate from **fallback eligibility**. Use this policy:

| Primary result | Action |
| --- | --- |
| Accepted, successful, or `PENDING` | Stop. Do not contact the secondary. Acceptance is not handset delivery. |
| Block/fraud denial, bad recipient or payload, invalid inbound authentication | Stop. Never use another provider to bypass the denial or validation. |
| Unknown status, malformed/lost response, timeout, connection/read error, or cancellation after dispatch | Record a terminal or uncertain outcome. Do not automatically contact the secondary. |
| Generic 4xx/5xx, `Fail`, or `provider_rejected` | No fallback based on that classification alone. |
| Primary-only credential acquisition fails before transport is entered | Eligible only if this pre-dispatch fact is recorded, the account policy explicitly permits it, the durable operation guard allows the transition, and the request budget is sufficient. |
| Provider-specific, documented proof that the primary did not accept the operation | Eligible only through a reviewed nonacceptance classifier, explicit account policy, the durable guard and sufficient budget. |

**Enable fallback only after the provider confirms a safe nonacceptance signal.** Caller
authentication and provider account controls still apply.

## 2. Configure and prevalidate both accounts

[config.js](../javascript/src/functions/config.js) accepts `readConfig(settings)`, so each
account can use its own immutable settings without changing `process.env` per request.
The following **customer-owned format** is not loaded by the sample. Replace each
`<supported-adapter-name>` with a registered adapter and match its credential requirements.

```json
[
  {
    "id": "primary-account",
    "settings": {
      "EPP_PROVIDER_NAME": "<supported-adapter-name>",
      "EPP_PROVIDER_AUTH_MODE": "apiKey",
      "EPP_PROVIDER_SMS_ENDPOINT": "<approved-primary-sms-endpoint-or-base-url>",
      "KEY_VAULT_URL": "https://<primary-vault>.vault.azure.net",
      "AZURE_CLIENT_ID": "<primary-vault-reader-client-id>"
    }
  },
  {
    "id": "secondary-account",
    "settings": {
      "EPP_PROVIDER_NAME": "<supported-adapter-name>",
      "EPP_PROVIDER_AUTH_MODE": "apiKey",
      "EPP_PROVIDER_SMS_ENDPOINT": "<approved-secondary-sms-endpoint-or-base-url>",
      "EPP_PROVIDER_ACCOUNT_NAME": "<approved-sender>",
      "KEY_VAULT_URL": "https://<secondary-vault>.vault.azure.net",
      "AZURE_CLIENT_ID": "<secondary-vault-reader-client-id>"
    }
  }
]
```

This SMS-only policy requires `EPP_PROVIDER_SMS_ENDPOINT` for each account. A voice policy requires
`EPP_PROVIDER_VOICE_ENDPOINT` instead. The validated request channel selects the matching endpoint;
there is no shared or other-channel endpoint fallback.

At startup, validate both account configurations before enabling the endpoint. Check for unique
IDs, the required channel endpoint, matching authentication mode, approved URLs, credential
references, and a valid deadline policy.

For each selected [adapter](../javascript/src/functions/providers), inspect `credentialSpec`
for the required secret names and any account identifier, and `createRequest` for endpoint and
sender requirements. Some adapters accept a complete operation URL; others append an operation
path to a **base URL**. Use the approved HTTPS form expected by that adapter. For base URLs,
reject an already-appended operation suffix, query or fragment, and reject or normalize a trailing
slash before freezing settings so the operation path appears exactly once.
Set an account/destination-approved sender where required; an adapter's default sender is not
proof of approval. These requirements apply equally to primary and secondary roles.

Store no credential values in the configuration. Attach each referenced user-assigned managed
identity to the Function App. Grant the vault-reading identity scoped secret-read access, such
as Key Vault Secrets User under RBAC or the approved access-policy equivalent. If using
the system-assigned identity, grant that identity instead. Client-ID settings do not attach
identities or grant access. Complete provider account, recipient, sender and consent prerequisites;
see [provider onboarding](ONBOARDING.md#complete-provider-authentication).

<a id="3-give-each-context-its-own-credential-service-and-lifecycle"></a>
## 3. Credential isolation

Open [credentials.js](../javascript/src/functions/credentials.js). When caching is enabled, its
singleton retains the first selected configuration; passing another account does not switch that cache.
Create a long-lived service for each account instead, with an immutable configuration:

```javascript
// Consolidate with existing imports in your customized SendOtp.js; do not duplicate consts.
const { readConfig } = require('./config');
const { selectProvider } = require('./providers');
const { CredentialTokenService } = require('./credentials');

// CUSTOMER_* helpers are your implementation, not repository APIs.
const entries = CUSTOMER_LOAD_AND_VALIDATE_ACCOUNTS_AND_POLICY();
const contexts = new Map();
for (const entry of entries) {
    const settings = Object.freeze({ ...entry.settings });
    const config = Object.freeze(readConfig(settings));
    const provider = selectProvider(config.providerName);
    contexts.set(entry.id, Object.freeze({
        config, provider, credentials: new CredentialTokenService(),
    }));
}
```

The loader must finish all checks in step 2 before this loop runs. Do not share caches between
accounts, even if they use the same adapter. Keep expiry, acquisition bounds, refresh coalescing
and sanitized failure reporting. Logical isolation within a worker is not a tenant security boundary.

For this walkthrough, acquire credentials lazily. In `SendOtp.js`, remove the singleton's
`startProviderCredentialRefresh` function and its `app.hook.appStart(...)` registration. Replace
the termination function, retain its registration once, and update the **bottom export** together:

```javascript
function stopProviderCredentialRefresh() {
    for (const { credentials } of contexts.values()) credentials.close();
}

// Keep this registration once, replacing the original lifecycle wiring.
app.hook.appTerminate(stopProviderCredentialRefresh);
// At the bottom of the module; do not leave the removed startup function here.
module.exports = { stopProviderCredentialRefresh };
```

Remove the singleton import only after replacing its request/lifecycle uses. With its selected
cache enabled, each service begins periodic refresh when first used. With caching disabled,
each live attempt acquires credentials without a poller or cross-request reuse. Preserve
the [cache switches](BRING-YOUR-OWN-PROVIDER.md#credential-caching) in each account's configuration.
Setup sets them to `false` for FC1 and `true` for EP1. Omitted values default to `true`.
An evaluation request must not start credential acquisition. Already-running refresh is independent.
Rebuild contexts on controlled restart when configuration changes. Never repurpose a live service
for another account.

<a id="4-add-durable-operation-state-before-enabling-fallback"></a>
## 4. Operation state

Add a **durable attempt store and idempotency contract** before allowing a second submission.
Agree on a stable, authorized operation key with the caller and test owner. Generated invocation
IDs, correlation GUIDs, and nonces serve other purposes. Bind the operation key to the authorized
caller, request, and fixed policy so another request cannot reuse it for a different delivery.

Use transactional/conditional writes in a durable shared store, not an in-memory map or lock.
Atomically claim an operation across concurrent invocations and worker restarts. Persist intent
**before** entering each provider transport call. For example, your state machine can use:

```text
NEW -> CLAIMED -> PRIMARY_INTENT -> ACCEPTED | TERMINAL | UNCERTAIN
                |                         -> VERIFIED_NONACCEPTANCE
                -> PRIMARY_PRE_DISPATCH_FAILURE

PRIMARY_PRE_DISPATCH_FAILURE or VERIFIED_NONACCEPTANCE
  -> SECONDARY_RESERVED (atomic, policy-approved, once)
  -> SECONDARY_INTENT -> ACCEPTED | TERMINAL | UNCERTAIN
```

All transitions require the expected state/version and valid ownership. A duplicate invocation
must not send; handle its response using the agreed operation contract. Never reset an intent
or uncertain dispatched attempt after a timeout, lease expiry or restart. An abandoned intent
may mean a message was sent even if no result was saved. Fail closed when the store is unavailable.
Do not let stale owners send after a claim is revoked or let a new owner reclaim a reserved attempt.

Record operation state, safe provider context ID and per-attempt classifications separately from
request logs. Do not store/log bodies, OTPs or credentials as attempt evidence. Retention and key
reuse rules must cover the caller's replay window. A store guard cannot atomically commit an
external provider send: it is **not provider-side idempotency or true exactly-once delivery**.
Entra ID retries or native fallback outside this endpoint can still produce duplicates; confirm that
behavior with the owner rather than promising the local guard prevents it.

<a id="5-integrate-one-guarded-fallback-into-the-handler"></a>
<a id="5-fallback-orchestration"></a>
## 5. Fallback flow

In [SendOtp.js](../javascript/src/functions/SendOtp.js), preserve authentication at the platform
boundary, [envelope validation](../javascript/src/functions/entraPayload.js),
[decryption](../javascript/src/functions/jwe.js), completeness checks and the existing evaluation
early return. Keep inbound `config.decryptionKeyPem` and `config.expectedKeyId` unchanged.
Only live validated requests proceed to the operation claim and provider attempts.

Replace the flow from `const provider = selectProvider(config.providerName)` through the
single-provider result handling with your guarded orchestration. Extract the existing credential,
request-build, transport and response blocks into an attempt helper that takes one context and
returns a structured category. Use `providerConfig` for outbound settings and that context's
`credentials.getCredentials(provider.credentialSpec, providerConfig)`. Keep
[OtpDelivery](../javascript/src/functions/delivery.js) construction and content handling intact.

The existing credential catch immediately returns 502, and transport/result failures immediately
return errors. The attempt helper reports the stage to the main flow instead of hiding
it in a catch that calls the secondary. Preserve their final HTTP classifications when fallback
is denied. This is **policy pseudocode**, not executable glue or a complete handler:

```javascript
// Runs after existing validation/decryption/evaluation handling.
const operation = await CUSTOMER_ATOMIC_CLAIM_AUTHORIZED_OPERATION();
if (!operation.owned) return CUSTOMER_DUPLICATE_RESPONSE_WITHOUT_SENDING();

const primary = await CUSTOMER_ATTEMPT_ONCE(
    operation, contexts.get(providerOrder.primary), aggregateDeadline);
if (primary.category === 'accepted') return CUSTOMER_EXISTING_SUCCESS_RESPONSE();
if (!['primary_pre_dispatch_failure', 'verified_nonacceptance']
    .includes(primary.category)) return CUSTOMER_TERMINAL_OR_UNCERTAIN_RESPONSE(primary);

const approval = CUSTOMER_CHECK_ACCOUNT_POLICY_AND_EVIDENCE(primary);
if (!approval.allowed || !CUSTOMER_HAS_SECONDARY_BUDGET(aggregateDeadline))
    return CUSTOMER_TERMINAL_OR_UNCERTAIN_RESPONSE(primary);
if (!await CUSTOMER_ATOMIC_RESERVE_SECONDARY(operation, approval))
    return CUSTOMER_DUPLICATE_RESPONSE_WITHOUT_SENDING();

const secondary = await CUSTOMER_ATTEMPT_ONCE(
    operation, contexts.get(providerOrder.secondary), aggregateDeadline);
return CUSTOMER_FINAL_RESPONSE_WITHOUT_ANOTHER_ATTEMPT(secondary);
```

Every `CUSTOMER_*` helper, result category, classifier, store and deadline here is new customer
code. `CUSTOMER_ATTEMPT_ONCE` must reserve/persist transport intent and recheck ownership and
remaining budget immediately before sending. Only the primary's approved pre-dispatch or proven
nonacceptance outcome can reserve a secondary; secondary failure is final.
Persist each outcome, including policy/budget denial, before the final response. If saving a
result fails after intent, leave that attempt non-reclaimable; do not send through the secondary.

**Do not use `result.httpStatus >= 400` or `catch -> sendSecondary`.**
[providerResult.js](../javascript/src/functions/providerResult.js) exposes `Continue`, `Fail`
and `Block`, not a safe-to-fallback receipt. Preserve Block as terminal and recognized
accepted/`PENDING` as accepted. A customer classifier must require provider-specific,
documented nonacceptance for this exact attempt and account policy approval. It must not
reinterpret generic `Fail` or a broad status range as proof.

[providerTransport.js](../javascript/src/functions/providerTransport.js) collapses fetch and
response-body failures into `provider_timeout`/`provider_network_error`. Those errors do **not**
expose whether the request was transmitted. Treat them as uncertain after intent, including
connection errors; do not guess they happened before send. Treat a primary credential failure
as pre-dispatch only when the flow and operation state prove transport was never entered.
The failure must also be isolated to the primary, and account policy must still allow the secondary.

Keep endpoint allowlists, HTTPS checks, manual redirects and per-provider response mapping.
Never forward inbound authorization. Preserve the endpoint success nonce/correlation response
only for evaluation or an accepted delivery result; terminal/uncertain outcomes get no success
nonce. Continue using [safe logging](../javascript/src/functions/logging.js), with an explicit
per-attempt provider ID/classification and one final request outcome.

<a id="6-enforce-one-aggregate-deadline"></a>
## 6. Use one end-to-end deadline

Define one end-to-end time budget with the service and caller owners. Include validation,
durable-store waits, both providers' credential and transport work, and the final response.
A duplicate invocation continues to use the original operation budget.

The current credential service has its own acquisition bound and the transport its own timeout.
`parseProviderTimeout` normalizes a single provider timeout, **not** an aggregate deadline.
Add explicit remaining-budget checks and cancellation propagation in your customer integration.
Do not use `Promise.race` to return while a send continues in the background. If ownership,
deadline or cancellation changes after dispatch, record uncertainty and never fall back.
Reserve enough time for the complete secondary attempt and final response, and check the remaining
time again before sending. Skip the secondary when the remaining time cannot cover that work,
even when the primary result would otherwise allow fallback.

<a id="7-validate-offline-then-deploy-only-after-separate-approval"></a>
## 7. Validation and deployment

Before editing, run the existing JavaScript tests from the repository root. Restore missing
dependencies from the existing lockfile only when needed:

```powershell
# Only if dependencies are missing.
npm ci --prefix .\javascript --ignore-scripts --no-audit --no-fund
node --test .\javascript\test\provider-flow.test.js `
    .\javascript\test\credential-cache.test.js `
    .\javascript\test\sendotp.test.js
```

After customization, adapt the original singleton/lifecycle fixtures and extend the
[adapter](../javascript/test/provider-flow.test.js),
[credential](../javascript/test/credential-cache.test.js) and
[handler](../javascript/test/sendotp.test.js) tests. Use fake credentials, transport, clocks and
store faults; block external network. Verify:

- Primary acceptance means zero secondary calls. Approved credential-before-transport failure
  or explicitly modeled nonacceptance allows at most one secondary, only with guard and budget.
- Blocks, invalid input, generic provider errors, unknown/malformed responses and all uncertain
  dispatches mean zero secondary calls. Secondary failure never restarts the sequence.
- Concurrent/retried logical operations and process restarts cannot reclaim intent/reservations.
  Store failure, deadline exhaustion and cancellation fail closed.
- Evaluation returns before operation claims/provider calls; incomplete/decryption failures remain
  errors. Credentials, endpoints and wire responses stay isolated between accounts.

Fake classifiers/stores cannot prove provider nonacceptance or distributed durability.
Routing/isolation tests alone are **not fallback tests**. No production classifier is supplied;
keep response-based fallback disabled until reviewed.

Deploy one app/package at `/api/SendOtp` for code-owned policy, orchestrator, classifier, or store changes.
Validate startup configuration on controlled restart. Verify cache refresh for rotation and update
pinned references explicitly. Unchanged approved tests or Markdown edits need no redeployment.

Preserve inbound authentication and origin/network restrictions, including any Front Door
forwarding. Regional failover is separate from provider fallback. Before live use, review
account permissions/consent, sender/recipient entitlement, durable-store guarantees and caller
retry/native-fallback behavior. Rotate any exposed credentials before testing. Any Entra ID sign-in or
provider test needs separate authorization, an approved recipient, explicit attempt limits and
stop conditions for uncertainty. HTTP 200/`PENDING` is not handset receipt. Nothing here authorizes
a send or proves Entra ID integration, capacity, regional resilience or live delivery.

## .NET and Python integration pointers

**.NET:** Start with [SendOtp.cs](../dotnet/Functions/SendOtp.cs),
[AppConfig.Read(IEnv)](../dotnet/Src/AppConfig.cs) and
[PhoneProviderBase](../dotnet/Src/PhoneProviderBase.cs).
[CredentialTokenService](../dotnet/Src/CredentialTokenService.cs) caches by provider name, while
the [OAuth adapter implementation](../dotnet/Src/Providers) retains initialized OAuth state and
[SecretResolver](../dotnet/Src/SecretResolver.cs) retains its vault client. Isolate the full
account object graph and update [Program.cs](../dotnet/Program.cs) lifecycle registrations.
Review cancellation, concurrent acquisition and failure classification rather than assuming
the JavaScript behavior transfers unchanged.

**Python:** Start with [function_app.py](../python/function_app.py),
[read_config(env)](../python/src/config.py) and [PhoneProviderBase](../python/src/provider.py).
Pass explicit account contexts instead of rereading process settings. Use a separate
[CredentialTokenService](../python/src/credentials.py) and
[SecretResolver(env)](../python/src/secrets.py) per account; update warmup/shutdown.
Both runtimes still need customer-owned durable operation state, deadline enforcement and
reviewed fallback classification. These pointers are not evidence that fallback is implemented
or validated in either runtime.
