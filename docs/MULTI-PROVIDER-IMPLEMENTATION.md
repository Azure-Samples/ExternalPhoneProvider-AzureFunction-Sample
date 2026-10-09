# Add conservative primary-to-secondary provider fallback

You can adapt this application to try a secondary provider **only when the primary is known
not to have accepted the message**. Keep one SAS-facing URL, `/api/SendOtp`, and use Telesign
as the SMS primary and Infobip as the SMS secondary. Both serve the same channel; the caller
does not select an account or supply a provider header.

The sample still ships with one provider per deployment and **no provider fallback**. This guide
describes customer code you must implement and review. A timeout, lost response or generic
provider error is not proof of nonacceptance: in those cases, do not automatically send again.

## 1. Set a fixed provider order and a deny-by-default policy

Keep the existing HTTP registration in [SendOtp.js](../javascript/src/functions/SendOtp.js).
Define the provider order in server-owned startup configuration:

```javascript
const providerOrder = Object.freeze({
    channel: 'sms',
    primary: 'telesign-primary',
    secondary: 'infobip-secondary',
});
```

Reject unsupported channels and invalid configuration. Do not accept provider IDs, endpoints,
vaults or scopes from request headers or bodies. There is no round-robin selection, fan-out,
recursive fallback or primary retry. The secondary can be attempted at most once.

Keep **routing order** separate from **fallback eligibility**. Use this policy:

| Primary result | Action |
| --- | --- |
| Accepted, successful, or `PENDING` | Stop. Do not contact the secondary. Acceptance is not handset delivery. |
| Block/fraud denial, bad recipient or payload, invalid inbound authentication | Stop. Never use another provider to bypass the denial or validation. |
| Unknown status, malformed/lost response, timeout, connection/read error, or cancellation after dispatch | Record a terminal or uncertain outcome. Do not automatically contact the secondary. |
| Generic 4xx/5xx, `Fail`, or `provider_rejected` | No fallback based on that classification alone. |
| Primary-only credential acquisition fails before transport is entered | Eligible only if this pre-dispatch fact is recorded, the account policy explicitly permits it, the durable operation guard allows the transition, and the request budget is sufficient. |
| Provider-specific, documented proof that the primary did not accept the operation | Eligible only through a reviewed nonacceptance classifier, explicit account policy, the durable guard and sufficient budget. |

**Default to no fallback.** No real Telesign or Infobip response is designated safe to fall back
from by this guide. Obtain and review provider-specific semantics before enabling that path.
An expired/rejected inbound token never reaches it. A provider credential failure must not bypass
account suspension, consent requirements, entitlement restrictions or a provider block.

## 2. Configure and prevalidate both accounts

[config.js](../javascript/src/functions/config.js) accepts `readConfig(settings)`, so each
account can use its own immutable settings without changing `process.env` per request.
The following is a **customer-owned configuration format**, not a file the sample loads:

```json
[
  {
    "id": "telesign-primary",
    "settings": {
      "EPP_PROVIDER_NAME": "telesign",
      "EPP_PROVIDER_CHANNEL": "sms",
      "EPP_PROVIDER_AUTH_MODE": "apiKey",
      "EPP_PROVIDER_ENDPOINT": "https://<approved-telesign-host>/<path>",
      "KEY_VAULT_URL": "https://<telesign-vault>.vault.azure.net",
      "AZURE_CLIENT_ID": "<telesign-vault-reader-client-id>"
    }
  },
  {
    "id": "infobip-secondary",
    "settings": {
      "EPP_PROVIDER_NAME": "infobip",
      "EPP_PROVIDER_CHANNEL": "sms",
      "EPP_PROVIDER_AUTH_MODE": "apiKey",
      "EPP_PROVIDER_ENDPOINT": "https://<approved-infobip-base-host>",
      "EPP_PROVIDER_ACCOUNT_NAME": "<approved-sender>",
      "KEY_VAULT_URL": "https://<infobip-vault>.vault.azure.net",
      "AZURE_CLIENT_ID": "<infobip-vault-reader-client-id>"
    }
  }
]
```

Your startup loader must reject duplicate/missing IDs, mismatched channels/authentication modes,
unapproved endpoints, missing credential references and invalid deadline policy. Validate both
contexts before enabling the endpoint, not only after the primary fails.

The [Telesign adapter](../javascript/src/functions/providers/telesign.js) requests
`telesign-api-key` and `telesign-customer-id`. The
[Infobip adapter](../javascript/src/functions/providers/infobip.js) requests `infobip-api-key`
and appends `/sms/3/messages` to its configured **base URL**. Reject an operation suffix, query
or fragment in that base URL; reject or normalize a trailing slash before freezing settings.
The suffix must appear once. Set an account/destination-approved sender; the adapter's `Verify`
default is not proof that this sender is valid for your account.

Store no credential values in the configuration. Attach each referenced user-assigned managed
identity to the Function App and grant the vault-reading identity scoped secret-read access,
such as Key Vault Secrets User under RBAC or the approved access-policy equivalent. If using
the system-assigned identity, grant that identity instead. Client-ID settings do not attach
identities or grant access. Complete provider account, recipient, sender and consent prerequisites;
see [provider onboarding](ONBOARDING.md#complete-provider-authentication).

## 3. Give each context its own credential service and lifecycle

Open [credentials.js](../javascript/src/functions/credentials.js). Its singleton caches the
first selected configuration; passing another account to it does not switch its cache.
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

Remove the singleton import only after replacing its request/lifecycle uses. Each service begins
periodic refresh when first used. An evaluation request must not start credential acquisition;
already-running refresh is independent. Rebuild contexts on controlled restart when configuration
changes; never repurpose a live service for another account.

## 4. Add durable operation state before enabling fallback

The repository has **no durable attempt store or idempotency contract**. Implement these before
adding a second possible submission. Agree on a stable, authorized logical-operation key with
the caller/test contract. Do not assume a generated invocation ID, correlation GUID or nonce is
an idempotency key. Bind the key to the authorized caller, operation and immutable request/policy
identity so another request cannot reuse it to obtain a different delivery.

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
Real SAS/native fallback outside this endpoint can still produce duplicates; coordinate that
behavior with the owner rather than promising the local guard prevents it.

## 5. Integrate one guarded fallback into the handler

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
return errors. Your attempt helper must report the stage to the orchestrator instead of hiding
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
connection errors; do not guess they happened before send. A primary credential failure can
be pre-dispatch only when control flow and operation state prove transport was never entered,
the failure is isolated to that primary, and account policy still permits the secondary.

Keep endpoint allowlists, HTTPS checks, manual redirects and per-provider response mapping.
Never forward inbound authorization. Preserve the endpoint success nonce/correlation response
only for evaluation or an accepted delivery result; terminal/uncertain outcomes get no success
nonce. Continue using [safe logging](../javascript/src/functions/logging.js), with an explicit
per-attempt provider ID/classification and one final request outcome.

## 6. Enforce one aggregate deadline

Define an end-to-end budget with the service/caller owner; this guide provides no SLA or magic
timeout value. Include validation, durable-store waits, primary credential acquisition/transport,
secondary credential acquisition/transport and final response work. An operation must not receive
a fresh budget when a duplicate invocation arrives.

The current credential service has its own acquisition bound and the transport its own timeout.
`parseProviderTimeout` normalizes a single provider timeout, **not** an aggregate deadline.
Add explicit remaining-budget checks and cancellation propagation in your customer integration.
Do not use `Promise.race` to return while a send continues in the background. If ownership,
deadline or cancellation changes after dispatch, record uncertainty and never fall back.
Reserve enough time for the whole secondary attempt and finalization, rechecking before intent;
insufficient budget means no secondary even when nonacceptance is otherwise eligible.

## 7. Validate offline, then deploy only after separate approval

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

An offline policy-model experiment can check those branches, but a fake classifier does not
prove any real provider's nonacceptance semantics, and a fake store does not prove distributed
durability. Earlier routing/isolation tests are **not fallback tests**. No production
nonacceptance classifier is supplied here; keep response-based fallback disabled until reviewed.

Use one Function App/package and the existing `/api/SendOtp` entry point. Deploy new code for the
orchestrator, classifier, durable-store integration or code-owned policy changes. Validate
startup-loaded configuration changes and perform a controlled restart. For secret rotation,
verify cache refresh; update pinned references explicitly. Repeating an unchanged approved test
or editing Markdown needs no redeployment.

Preserve inbound authentication and origin/network restrictions, including any Front Door
forwarding. Regional failover is separate from provider fallback. Before live use, review
account permissions/consent, sender/recipient entitlement, durable-store guarantees and caller
retry/native-fallback behavior. Resolve exposed-credential rotation first. Any real SAS or
provider test needs separate authorization, an approved recipient, explicit attempt limits and
stop conditions for uncertainty. HTTP 200/`PENDING` is not handset receipt. Nothing here authorizes
a send or proves real SAS integration, capacity, regional resilience or live delivery.

## .NET and Python integration pointers

**.NET:** Start with [SendOtp.cs](../dotnet/Functions/SendOtp.cs),
[AppConfig.Read(IEnv)](../dotnet/Src/AppConfig.cs) and
[PhoneProviderBase](../dotnet/Src/PhoneProviderBase.cs).
[CredentialTokenService](../dotnet/Src/CredentialTokenService.cs) caches by provider name, while
[SopranoProvider](../dotnet/Src/Providers/SopranoProvider.cs) retains initialized OAuth state and
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
