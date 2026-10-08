# Implementing multiple provider configurations

**A customer customization is feasible, but it is not a built-in feature.** An offline JavaScript
prototype exercised the existing adapters with independently configured Telesign API-key and
Soprano OAuth contexts, including concurrent requests. The critical requirement is to isolate
configuration and credentials per context, not merely change the selected provider name.

This guide describes changes **you would implement in your own application**. It does not ship a
router, setup script, configuration validator, or new deployment behavior. The unmodified sample
still uses **one provider per deployment**, selected by `EPP_PROVIDER_NAME`. Separate deployments
remain the simpler option when accounts require strong isolation.

## What was demonstrated offline

A session-only experiment against the JavaScript implementation at commit
`0d5db07f00a8b83295d83344a877f3bfd1ef009a`, using Node.js 22.17.1, passed six focused tests:

- Forty concurrent synthetic SMS dispatches used four named contexts: two Telesign accounts and
  two Soprano accounts. Each had its own frozen configuration and `CredentialTokenService`.
  Assertions checked the exact endpoint, account/token, request content, correlation ID and
  response mapping for every dispatch. Concurrent credential acquisition coalesced within each
  context, not across accounts.
- A negative control deliberately reused one credential service with another account and then
  another authentication mode. It returned the first cached API-key bundle. **Changing the
  arguments passed to the existing singleton does not switch its configuration.**
- A locally encrypted evaluation request was parsed and decrypted, then returned its nonce
  before route lookup, credential acquisition or transport, even with an unknown route ID.
  An incomplete decrypted context still failed before routing.
- Unknown/duplicate route IDs, an unknown adapter and a channel mismatch were rejected before
  credential or transport calls.
- A synthetic provider HTTP failure was terminal for that request while an independent
  concurrent route succeeded; no retry or alternate-provider dispatch occurred.
- After simulated secret-cache expiry, a failing account could not borrow another context's
  credentials or cause fallback. An independent OAuth route still succeeded.

The prototype used the **real** configuration reader, payload parser, local JWE decryption,
credential service/cache classes, Telesign/Soprano request builders, shared transport logic and
response mappers. Only the Azure SDK boundary and `fetch` were replaced with deterministic fakes;
socket, HTTP and DNS access were guarded to fail. Periodic refresh scheduling was simulated and
every service was closed. No process environment was changed per request. Existing JavaScript
adapter, credential-cache and handler tests also passed.

**This was not an end-to-end provider or SAS test.** The prototype used a customer-style dispatch
seam, test-owned route IDs, fake credentials, fake responses and a locally generated encryption key.
It did not run a deployed Function, validate Easy Auth, establish a trusted routing identity,
perform a real OAuth exchange, read Key Vault, or send SMS/voice messages. Its new multi-context
dispatch tests covered SMS, not a multi-provider voice rollout. Real refresh scheduling, distributed
workers, production load and configuration reload were not demonstrated. The prototype is not
included as a supported repository command; the evidence does not certify a production router.

## Start at these existing code seams

### JavaScript: experimentally exercised

- [SendOtp.js](../javascript/src/functions/SendOtp.js): the registered handler validates/decrypts,
  returns evaluation before selection, checks channel/authentication/endpoint, resolves credentials,
  builds one request, calls transport and maps the endpoint response. Its
  `startProviderCredentialRefresh`/`stopProviderCredentialRefresh` hooks currently manage one
  selected credential service.
- [config.js](../javascript/src/functions/config.js): `readConfig(env)` / `AppConfig` already accept
  an explicit settings object; use that seam rather than mutating `process.env`.
- [providers/index.js](../javascript/src/functions/providers/index.js): `selectProvider(name)`
  resolves a fixed adapter with no default. [Telesign](../javascript/src/functions/providers/telesign.js)
  and [Soprano](../javascript/src/functions/providers/soprano.js) expose `credentialSpec`,
  `createRequest` and `interpretResponse`.
- [credentials.js](../javascript/src/functions/credentials.js): `CredentialTokenService`,
  `ApiKeyCache` and `AccessTokenCache` own acquisition, cache expiry, in-flight refresh and shutdown.
  The exported singleton owns **one** selected cache; it is not keyed by provider or configuration.
- [providerTransport.js](../javascript/src/functions/providerTransport.js): `sendProviderRequest`
  enforces request URL checks, timeout and manual redirects.
  [providerResult.js](../javascript/src/functions/providerResult.js) maps adapter outcomes to
  endpoint statuses; preserve those mappings rather than treating all HTTP responses as success.
- [entraPayload.js](../javascript/src/functions/entraPayload.js),
  [jwe.js](../javascript/src/functions/jwe.js) and
  [logging.js](../javascript/src/functions/logging.js): retain payload/decryption checks and
  selected-metadata logging. Parsing a `tenantId` field does not establish its routing authority.

### .NET: inspected, not multi-context-tested here

Follow [Functions/SendOtp.cs](../dotnet/Functions/SendOtp.cs) for evaluation, `SelectProvider` and
dispatch; [AppConfig.Read(IEnv)](../dotnet/Src/AppConfig.cs) and
[IEnv](../dotnet/Src/Models.cs) provide explicit configuration seams.
[PhoneProviderBase](../dotnet/Src/PhoneProviderBase.cs) defines credential acquisition,
`SendOtpAsync`, shared HTTP handling and response-status mapping.

[CredentialTokenService](../dotnet/Src/CredentialTokenService.cs) caches by `provider.Name`, which
does not distinguish two accounts of the same adapter.
[SopranoProvider](../dotnet/Src/Providers/SopranoProvider.cs) also retains the first initialized
OAuth identity/credential/scope. [SecretResolver](../dotnet/Src/SecretResolver.cs) retains a vault
client built from its `IEnv`. Merely changing the outer cache key is therefore insufficient.
Build a context-owned service/provider/resolver/configuration object graph, or redesign every
relevant cache key and initialization boundary. Review cold-acquisition concurrency explicitly;
do not assume its cache has the same single-flight behavior as JavaScript.
[Program.cs](../dotnet/Program.cs) currently registers singleton providers/services and a
non-redirecting HTTP client; customer DI/lifecycle changes must preserve transport safety.

### Python: inspected, not multi-context-tested here

In [function_app.py](../python/function_app.py), `_select_provider`, `_send_to_provider` and the
evaluation branch are the dispatch seams. `_send_to_provider` currently rereads process settings.
Pass the selected context explicitly instead. [read_config(env)](../python/src/config.py) already
accepts a mapping. [CredentialTokenService](../python/src/credentials.py) owns one selected cache;
construct one per context, with a context-specific [SecretResolver(env)](../python/src/secrets.py).
Do not share the module-level `_credentials` across configurations. Update the warmup thread and
shutdown lifecycle deliberately.
[PhoneProviderBase](../python/src/provider.py) provides `build_request`, `map_response`,
`send_otp`, transport handling and endpoint-status mapping.

The runtime adapters include Infobip, Sinch, Soprano and Telesign, but this experiment exercised
only Telesign and Soprano. The [setup catalog](../setup/providers/catalog.json) provisions only
Telesign/Soprano profiles. Adapter availability, setup coverage and a provider's approved account
capabilities are different things; none establishes a new multi-provider deployment contract.

## Design your customization

### Define named contexts and a trusted, deterministic selection rule

A context ID identifies a complete configuration, not just an adapter name. For example,
`telesign-primary` and `telesign-secondary` must remain distinct even though both use Telesign.
Create a finite, reviewed context list at startup. Reject duplicate IDs, unknown adapters,
ambiguous rules, missing credentials configuration, disallowed endpoints and mismatched
authentication/channel settings before enabling live use.

The following is **illustrative customer-owned configuration, not a supported new file format**.
Values in angle brackets must be supplied and reviewed; never place secret values in it:

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

For one endpoint, an explicit server-owned `sms -> telesign-primary`,
`voice -> soprano-primary` rule is one possible deterministic policy. Validate the incoming channel
using the existing contract and authorize it against that policy. This is a design example; the
experiment used test-supplied route IDs for SMS across all four contexts.

If different customers/accounts need the same channel, first define and verify the **trusted
endpoint/customer binding** from which routing can be authorized. Do not assume the SAS caller
identity distinguishes every customer. Do not use an arbitrary request header, a newly invented
`providerId`, correlation ID, or unverified body `tenantId` as authority. The existing wire contract
does not supply a new trusted provider-selector field. Never allow a caller to supply an endpoint,
vault, scope or secret name. Unknown or ambiguous routing must fail closed without a default.

### Keep state and credentials isolated

Build each context from a copied, immutable settings object. In JavaScript, `readConfig` retains
the supplied `env` reference, so freeze that object as well as the returned config. Separate
inbound authentication/decryption settings from outbound provider settings; do not switch the
inbound key because a provider route changed.

Create **one long-lived credential service per context**, not per request. Bind it permanently to
that context's adapter credential specification, vault/secret names, vault-reading identity,
OAuth tenant/resource scope, outbound application and outbound managed identity. A provider name
alone is not a safe cache key. Share nothing that can retain another account's token or secret.
For Telesign, the existing adapter uses `telesign-api-key` and `telesign-customer-id`; distinct vaults
can isolate accounts with those same names. Using different names in one vault requires an explicit
per-context credential-spec customization, not mutation of the shared adapter object.

Keep expiry, acquisition bounds, failure reporting and refresh coalescing. A failed/expired
context must fail its own request, never borrow credentials. Bound the context count, close every
service at shutdown, and define how background refresh is started. A request's evaluation branch
must not resolve credentials; independently running warmup/refresh is a separate lifecycle concern.
For configuration changes, prefer a controlled worker restart or a versioned replacement of the
whole context with safe draining/disposal, rather than modifying a live cache's inputs.

These are logical isolation boundaries, not tenant security boundaries: one compromised worker
may access all identities assigned to it. Review least-privilege identity/vault access and provider
onboarding separately; retain separate deployments where stronger isolation is required.

### Insert selection after evaluation, then dispatch once

The sketch below uses existing JavaScript interfaces but is **pseudocode, not a complete handler**.
The uppercase helpers are customer responsibilities; authorization, error handling, lifecycle and
response/logging behavior must be integrated with the existing handler rather than bypassed.

```javascript
// Startup: customer validates unique IDs, rules, endpoints, identities and required settings.
const contexts = new Map();
for (const entry of VALIDATED_CUSTOMER_CONTEXTS) {
    const settings = Object.freeze({ ...entry.settings });
    const config = Object.freeze(readConfig(settings));
    const provider = selectProvider(config.providerName);
    REQUIRE_VALID_CONTEXT(entry.id, provider, config, contexts);
    contexts.set(entry.id, Object.freeze({
        config, provider, credentials: new CredentialTokenService()
    }));
}

// Request: retain Easy Auth, envelope validation and JWE checks from SendOtp.
const { payload, deliveryContext } = VALIDATE_AND_DECRYPT_WITH_EXISTING_HANDLER(request);
if (payload.isEvaluation) {
    return EXISTING_EVALUATION_RESPONSE(deliveryContext.nonce);
}
const id = AUTHORIZE_AND_SELECT_ONE_CONTEXT(serverOwnedPolicy, payload.channelName);
const context = contexts.get(id);
REQUIRE_KNOWN_CONTEXT_AND_MATCHING_CHANNEL(context, payload.channelName);
const { config, provider, credentials } = context;
const credential = await credentials.getCredentials(provider.credentialSpec, config);
REQUIRE_COMPLETE_CREDENTIAL_FOR_ADAPTER(credential, provider);
const delivery = BUILD_EXISTING_OTP_DELIVERY(deliveryContext, payload);
const outbound = provider.createRequest({
    channel: payload.channelName, endpoint: config.providerEndpoint,
    delivery, credential, env: config.env
});
const response = await sendProviderRequest(
    outbound, parseProviderTimeout(config.providerTimeoutMs), safeLogContext);
const result = provider.interpretResponse(response);
return EXISTING_ENDPOINT_RESPONSE_MAPPING(result, deliveryContext.nonce);
// Shutdown: close each context.credentials; never fall through to another context on failure.
```

Keep approved endpoint allowlists in addition to generic HTTPS checks, preserve redirect/timeout
controls, and never forward inbound authorization to a provider. Retain the existing success,
block, failure and nonce rules. Do not turn an unknown provider response into success.
Log an approved non-secret context identifier and fixed failure classification, not request bodies,
OTP/phone data, credentials, tokens, raw provider descriptions or exception contents.
This design chooses **one** context per request: no fan-out, automatic fallback or resend.

## Validate your implementation and roll out separately

1. Start with offline fixtures. Adapt the real interfaces in
   [provider-flow.test.js](../javascript/test/provider-flow.test.js),
   [credential-cache.test.js](../javascript/test/credential-cache.test.js) and
   [sendotp.test.js](../javascript/test/sendotp.test.js).
   Replace SDK acquisition and transport with fakes, guard network access, and use only synthetic
   delivery data. Test both authentication modes and multiple accounts of the same adapter under
   concurrency; assert endpoint, credentials and correlation isolation, not just success counts.
2. Add unknown/duplicate/ambiguous routes, invalid settings, channel mismatch, cross-account
   attempts, failed/expired credential acquisition, provider rejection, timeout, malformed response,
   shutdown and configuration replacement tests. Prove failures cause no second provider attempt.
   Verify valid evaluation returns before routing/credentials and malformed evaluation still fails.
   Extend voice and every additional adapter before claiming support.
3. Run your runtime's existing contracts as well. .NET examples are
   [SendOtpTests](../dotnet/tests/SendOtpTests.cs),
   [CredentialTokenServiceTests](../dotnet/tests/CredentialTokenServiceTests.cs) and
   [ContractTests](../dotnet/tests/ContractTests.cs). Python examples are
   [test_engine.py](../python/tests/test_engine.py),
   [test_credential_cache.py](../python/tests/test_credential_cache.py),
   [test_function_app.py](../python/tests/test_function_app.py) and
   [test_contract.py](../python/tests/test_contract.py). The shared
   [contract fixtures](../tests/fixtures/contract.json) help preserve response behavior.
4. Review identity permissions, provider entitlement/consent, route and sender approval, secret
   lifecycle, authorization boundaries, rate limits, observability and operational ownership.
   Resolve exposed-credential rotation before any live validation. Passing a local configuration
   or mocked test establishes none of these.
5. Deploy only after separate approval to a dedicated nonproduction environment. Verify deployed
   authentication, encryption, policy readback and authorized evaluation independently. A real SAS
   trigger can have surrounding fallback behavior: do not assume evaluation is harmless merely
   because this Function returns before its provider call.
6. Perform live provider/delivery validation only with explicit authorization, approved recipient,
   coordinated policy/attempt limits and a one-attempt safety gate. Provider acceptance is not
   proof of handset delivery. Use an explicit rollout/rollback decision; do not add automatic
   fallback to conceal a failing integration.

No Azure resources, Graph roles/policy, Key Vault credentials, SAS triggers or provider sends were
used or changed to produce this guide. The feasibility result concerns reusable code seams and
offline context isolation, not production readiness or a delivered multi-provider feature.
