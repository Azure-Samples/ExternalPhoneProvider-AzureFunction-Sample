# HTTP contract

<a id="external-phone-provider-function-language-agnostic-contract"></a>

[Documentation](README.md) | [Implementation walkthrough](BRING-YOUR-OWN-PROVIDER.md) | [Settings and packages](../TECHNICAL.md)

This page defines the shared contract for [JavaScript](../javascript/), [Python](../python/) and
[.NET](../dotnet/). Use the [production-readiness considerations](#production-limitations) when
planning a live service.

Go to [request/response](#1-http-api), [HTTP outcomes](#2-outcome--http-status-mapping),
[provider contract](#3-provider-contract), [settings](#4-configuration-app-settings--env),
[caching](#credential-caching-and-refresh), [required behaviors](#5-required-behaviors),
[logs](#application-logs), or [tests](#6-lightweight-tests).

> **Naming.** EPP means **External Phone Provider**. App settings use the `EPP_` prefix; the
> request and delivery models are `Envelope`, `DeliveryContext` and provider-neutral OTP delivery.
> Documentation names do not change the external JSON fields or `microsoft.mfa.otpDeliver.v1` version.

Each deployment selects one provider. The HTTP Function owns the request lifecycle, while
API-specific credentials, paths, headers, payloads, response rules, outcomes and safe failure
classifications remain inside each provider implementation.

For regional continuity, the [Front Door design](FRONTDOOR.md) routes this same API to regional
origins while preserving caller authentication, JWE validation, nonce semantics, and provider
selection. Its readiness endpoint is separate from this contract and never delivers OTPs.
Provider fallback and delivery deduplication remain separate designs.

---

## 1. HTTP API

**Endpoint:** `POST /api/SendOtp` (Functions HTTP trigger, `authLevel: anonymous`). **Easy Auth is the
only caller-authentication boundary and runs before the handler**; the application has no token
validator or function-key gate. This is the interface **Microsoft Entra ID** calls.
Entra ID sends a signed bearer JWT; Easy Auth validates it, not the handler.
PII (phone number + the rendered message, which contains the passcode) is **encrypted** inside a JWE;
the cleartext envelope carries routing/scheduling only.

### Request headers

| Header | Notes |
|--------|-------|
| `Authorization` | consumed by platform authentication, not parsed or echoed by handler |
| `User-Agent` | caller-supplied identifier; not interpreted or logged |
| `x-ms-correlation-id` | tracing only; fallback for envelope `correlationId`, not authentication |
| `x-ms-client-request-id` | per-attempt tracing id (used as `messageId`), not authentication |

Easy Auth provides caller trust. Forwarded headers such as `x-ms-client-principal` provide context,
not authentication. The handler does not use them to authenticate callers or forward the incoming
`Authorization` header to the provider. Configure Easy Auth as described in section 5.

<a id="epp-request-body-envelope-cleartext-envelope"></a>
### EPP request body

| Field | Required | Notes |
|-------|----------|-------|
| `type` | yes | exactly `microsoft.mfa.otpDeliver.v1`; unknown versions are rejected |
| `tenantId` | no | opaque request routing metadata; never selects the trusted issuer, signing keys or provider |
| `correlationId` | no | sign-in tracing metadata |
| `channel` | yes | request delivery channel: `1`/`sms` or `2`/`voice`; not deployment configuration |
| `mode` | yes | request delivery mode: `1`/`live` or `2`/`evaluation`; evaluation does not deliver |
| `ttlSeconds` | no | positive JSON integer, at most `2147483647`; omit when absent. Null is not portable; booleans, strings, fractions and nonpositive values are invalid. Use canonical integer notation (`60`, not `60.0` or `6e1`) across runtimes |
| `encryptedDeliveryContext` | yes | JWE compact serialization (see below) |

Canonical integer notation is a caller requirement, not a portable raw-JSON-token check: JavaScript's
JSON parser normalizes `60.0` and `6e1` to `60`, while Python/.NET reject those representations here.
Always send `60` to obtain the same result across runtimes; no custom JSON tokenizer is used.

Handler validation failures for unknown `type`, invalid `ttlSeconds`, unsupported `channel` or
`mode`, or missing/empty `encryptedDeliveryContext` return `400`. Arrays, objects and booleans
are not channel/mode values. Some invalid inputs fail .NET host binding before the handler;
see [runtime binding differences](#runtime-binding-differences).

These are request data, not settings to provision. The TTL check validates the supplied value; it
does not verify passcode expiry or implement a delivery deadline. Deployment trust comes only from
the required platform authentication and caller allowlist, not the body or tracing headers.

### `encryptedDeliveryContext` (JWE)

Alg: **RSA-OAEP-256** (CEK wrap) + **A256GCM** (content). The JOSE protected header carries `kid`;
this sample uses the single configured RSA private key (`EPP_DECRYPTION_KEY_PEM`, a Key Vault
reference in Azure), not a multi-key lookup. The compact JWE must have **exactly five non-empty
segments** and at most **16,384 characters**; `alg`/`enc` are pinned (only `RSA-OAEP-256` + `A256GCM` accepted) and the AES-GCM auth tag is
verified before any plaintext is used. Decrypted plaintext = `DeliveryContext`:

The original compact JWE is passed unchanged to the JOSE library. Parsing header fields for the
advisory key-ID check must not replace the original protected-header bytes used for authentication.

`EPP_DECRYPTION_KEY_PEM` accepts a private-key PEM alone or a PEM certificate bundle containing the
private key, in plain text or base64 form. Guided setup issues a certificate inside Key Vault or
reuses a selected certificate version. It pins the PEM backing-secret reference and keeps exactly
one approved encryption credential on the application. Certificate synchronization
is manual; Key Vault renewal does not automatically update Entra or select another decryption key. See the
[certificate lifecycle](../setup/docs/README.md#encryption-certificate-lifecycle).

All three HTTP-handler suites use [shared policy cases](../tests/fixtures/contract.json): the allowed
pair succeeds, while `RSA-OAEP`, `A128GCM` and `A256CBC-HS512` alternatives return `400 decryption_failed`
without provider I/O. Decryption uses the same policy before live/evaluation branching, so the matrix
runs once per language. Tag tampering and original-header-byte tests remain.

| Field | Required | Notes |
|-------|----------|-------|
| `nonce` | yes | value the endpoint MUST echo to prove decryption |
| `phoneNumber` | yes | caller supplies an E.164 string; full E.164 validation is an implementation gap |
| `message` | yes | fully rendered, localized text containing the passcode; text-message providers forward it unchanged, Soprano voice extracts the first six consecutive digits, and Telesign voice paces standalone six-digit numeric runs and repeats the full message twice |
| `extension` | no | office-voice contract field; not currently forwarded by the shared dispatch model |
| `locale` | no | voice selection input where supported by the selected provider |
| `riskContext` | no | contextual request data; no risk-policy evaluation is implemented here |
| `textToVoice` | no | legacy structured speech input; current Soprano implementations ignore it |

Decryption failure → `400`. Missing `nonce` / `phoneNumber` / `message` → `400`.

For Soprano live voice, the provider finds the first six consecutive digits in `message`, preserving
leading zeros, and splits the rendered text into `beforePasswordText`, `password`, and
`afterPasswordText`. It uses the request's nonblank `locale` as `language`, falling back to `en-US`, and sends
fixed `gender: 1` and `loop: 2`. The resulting object is sent as `voice.text2voice` without a top-level
`text` field. A message without a six-digit sequence fails closed before provider HTTP. No additional
environment settings are required. Soprano SMS continues to forward `message` unchanged, and
evaluation continues to skip provider-specific validation and I/O.
Soprano uses OAuth client-assertion exchange. The outbound user-assigned managed identity obtains an
`api://AzureADTokenExchange/.default` assertion for the existing multitenant application, which then
requests the configured provider scope. Existing platform caller authentication is unchanged.

### Soprano provider JWT

The Function obtains one provider token through the shared OAuth credential resolver using the
setup-generated `EPP_PROVIDER_TENANT_ID`, `EPP_PROVIDER_SCOPE`, `EPP_OUTBOUND_CLIENT_ID`, and
`EPP_OUTBOUND_MI_CLIENT_ID`. `EPP_PROVIDER_AUTH_MODE=oauth` matches the Soprano provider.
The request channel selects the required `EPP_PROVIDER_SMS_ENDPOINT` or `EPP_PROVIDER_VOICE_ENDPOINT`.
The selected complete send URL is not modified by the provider.
The calling app registration and outbound user-assigned identity must share a home tenant; the
calling app must be multitenant and provisioned/authorized in the provider tenant. The app's
federated credential trusts the identity's principal ID, home-tenant v2 issuer, and
`api://AzureADTokenExchange` audience. Key Vault identity selection remains independent.

Only the final application token is sent as `Authorization: Bearer ...`. No Soprano API ID/key,
managed-identity assertion, or incoming Entra ID token is forwarded. Missing settings, token-acquisition
failure, blank tokens, or tokens with 30 seconds or less remaining lifetime fail before provider HTTP;
there is no API-key fallback. Evaluation skips acquisition. A provider rejection is not retried.
Tokens are treated as opaque: the Function checks SDK expiry metadata, not custom JWT claims.
Soprano remains responsible for signature, issuer, audience, expiry, permissions, and account validation.

With `EPP_ACCESS_TOKEN_CACHE_ENABLED=true` (the default), credential instances and their SDK caches
are reused for the configured tenant/application/identity.
JavaScript/Python use a [worker-local refresh loop](#credential-caching-and-refresh) for both
exchange stages. .NET warms at startup and fetches a replacement on a cache miss; it has no poller.
JavaScript bounds shared acquisition to 2.5 seconds independently of individual waiters;
.NET bounds each fetch to 2.5 seconds with cancellation linked to that caller. JavaScript links
cancellation through an SDK HTTP-client wrapper because `getToken` options alone are insufficient
in the installed SDK. Python bounds caller waits and SDK connect/read inactivity to 2.5 seconds;
shared synchronous retrieval may finish after a waiter leaves. It uses `get_token_info` for refresh
hints when supported, otherwise `get_token`; a failed acquisition never falls back to another API.

Credential SDK transport retries are disabled. With caching enabled, JavaScript/Python failed refreshes use the polling
cadence below; .NET retries credential acquisition on a later cache miss. These are not end-to-end
delivery deadlines. JavaScript suppresses SDK logs in the
acquisition's asynchronous context. Python filters Azure Identity/Core/MSAL records on configured
handlers in that context; configure logging sinks before handling requests. .NET disables credential
diagnostics. Keep platform body tracing off and never log credential objects or tokens.

Use the exact provider scope and complete send URLs selected by setup. Source changes do not
update deployed settings or establish provider authorization. Validate the current OAuth
configuration with your provider before activation.

See [Microsoft's managed-identity federation guidance](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation-config-app-trust-managed-identity).

Confirm that the request's locale is supported by your Soprano endpoint and account. The Soprano
adapter uses `en-US` when the locale is absent or blank; a nonblank value is forwarded without
checking provider support. Test recipient audio separately from API acceptance.
This adapter uses the JSON `/messages/omnimsg` interface configured by the provider profile,
not a form-encoded voice API. Use the field names and response mapping in the selected adapter.

JWE provides payload confidentiality and integrity, **not caller authentication**. Anyone with the
public key can encrypt a request. The nonce acknowledges decryption; it is not an authentication
credential or replay protection, and a fixed nonce cannot substitute for Easy Auth.

### EPP response (JSON)

```json
{ "nonce": "<echo of request nonce>", "correlationId": "<echo>", "providerStatus": "accepted" }
```

The endpoint returns **`200`** only after the adapter recognizes acceptance on a successful
provider HTTP response. A queued or pending status counts only when that adapter explicitly
recognizes it; a provider `2xx` alone is insufficient. Acceptance is not handset delivery.
`Evaluation` mode returns `200` + nonce echo without a provider send.

The sample's integration contract expects the caller to treat `2xx` with a matching nonce as
handled; a nonce mismatch, non-`2xx` response, or timeout can lead to native fallback.
This repository does not implement or verify the Entra ID caller's current fallback, retry,
or timing behavior. Confirm it through the
[approved EPP procedure](ONBOARDING.md#validate-the-deployed-endpoint);
do not rely on fallback as a guaranteed recovery mechanism.

Live handlers await provider acceptance; they do not launch background delivery after replying.
Handler failures omit the nonce and accepted status and return a sanitized error with a request ID
and, after envelope processing, a correlation ID. Platform rejections happen before the handler and
do not use this application response contract.

Handler validation failures return `error: "bad_request"` and a fixed `reason`. JavaScript/Python
envelope checks run in this order: object shape, version, encrypted-context presence, channel, mode, TTL.
Their reasons are `invalid JSON body`, `invalid envelope`, `unsupported envelope type`,
`encryptedDeliveryContext is required`, `unsupported channel`, `unsupported mode`, `invalid ttlSeconds`
or `ttlSeconds expired`. A decrypted context missing a required nonblank string returns
`incomplete delivery context`. Reasons never include supplied values or exception text. JWE failures
return `error: "decryption_failed"` without a cryptographic reason or nonce.

### Runtime binding differences

Use the request forms above across runtimes, but expect differences in parsing and errors.
JavaScript/Python parse JSON inside the handler. The .NET Functions host first binds the JSON
to a typed `EntraSendOtpPayload`, then calls the handler.

- .NET treats null `ttlSeconds` as omitted, and its enum converter accepts numeric
  strings such as `"1"`. JavaScript/Python reject those forms. Send an integer TTL or omit it,
  and use integer channel/mode codes or named strings for portability.
- Malformed JSON and incompatible property types can fail .NET host binding before the
  handler's sanitized error response. For payloads reaching its validation, .NET uses
  `unsupported payload type` rather than `unsupported envelope type`; a null bound payload
  produces `invalid payload`. Do not assume a host-binding error has handler JSON fields.
- Required decrypted fields must be nonblank strings. .NET deserializes them as strings, so
  incompatible types can produce `decryption_failed` before the completeness check.
  JavaScript/Python instead check their raw values for completeness. Optional fields are not
  uniformly modeled: only `locale` accompanies the required fields in .NET's delivery context;
  JavaScript/Python also retain `extension` and `riskContext`, but shared dispatch omits both.
- For normal nonempty string IDs, the response uses body `correlationId` first, then
  `x-ms-correlation-id`, then a generated `requestId`. JavaScript uses the raw header;
  Python/.NET sanitize it. .NET preserves an empty body string; JavaScript/Python fall back.
  Early validation errors omit correlation; later handled errors include it.
  Python's unexpected-error path can return null correlation when a parsed payload lacks it.
- `x-ms-client-request-id` supplies the internal `messageId`, with a generated fallback.
  JavaScript uses the raw header; Python/.NET sanitize it. Neither request ID nor correlation
  ID provides deduplication.

See the handlers for exact binding and response paths:
[JavaScript](../javascript/src/functions/SendOtp.js),
[Python](../python/function_app.py), and [.NET](../dotnet/Functions/SendOtp.cs).

### Evaluation (no provider send)

The only shared non-delivery control is the existing incoming `mode: 2` or `mode: "evaluation"`,
for every provider and language. On Azure, Easy Auth still authenticates the caller before the
handler validates the envelope and decrypts the JWE with integrity checks. Provider lookup, provider
Key Vault reads and outbound provider HTTP are skipped. No provider name, endpoint or credentials
are needed. Platform authentication and resolution of the decryption-key reference may still require
network access. Core Tools has no Easy Auth; local evaluation must remain loopback-only, without tunnels.

This describes the evaluation **request path**. Independently, workers with a configured provider
and its cache enabled prepare credentials at startup; JavaScript/Python also poll for refresh,
even if their current traffic is evaluation-only.
No background task dispatches an OTP. A worker without `EPP_PROVIDER_NAME` performs no credential
prewarming. Disabling the selected cache also suppresses this preparation; evaluation never requires it to succeed.

There is no diagnostic environment flag. A live request is not an evaluation request. Adapter-specific
wire fields, where required by an API, remain internal and cannot enable a separate non-delivery mode.

---

## 2. Outcome → HTTP status mapping

The provider interprets its parsed status as an **outcome** and endpoint HTTP status.
**Fail-closed:** an unknown/unmapped or incomplete response is treated as `Fail`.
An unsuccessful provider HTTP response cannot become `Continue` because its body contains a
success-looking status. Explicit `Block` outcomes remain non-success responses.
The current runtime outcome enums contain only `Continue`, `Block`, and `Fail`; there is no
implemented `StepUp`/`409` mapping.

| Outcome | HTTP | When |
|---------|------|------|
| `Continue` | `200` | recognized success status |
| `Block` | `403` | provider says blocked |
| `Fail` | `429` | provider returned 429 |
| `Fail` | `401` | provider returned 401/403 (auth) |
| `Fail` | `400` | other provider 4xx |
| `Fail` | `502` | other provider error, or missing credential/endpoint |
| N/A | `400` | configured provider name is missing or not registered |
| N/A | `504` | request to the provider timed out |
| N/A | `502` | network error to the provider (non-timeout) |

---

## 3. Provider contract

Each provider owns:

- its fixed name, authentication mode and credential acquisition specification;
- request construction, including provider-specific paths, headers and JSON;
- response shape interpretation, recognized statuses, outcome and endpoint HTTP status;
- safe failure classification: `provider_http_error`, `provider_rejected`,
  `unrecognized_provider_status`, `missing_provider_message_id` or `invalid_provider_json`.

The shared transport owns final HTTPS validation, timeout handling, disabled redirects, and
response-body reading and decoding. JavaScript/.NET propagate cancellation through body reading;
Python uses connect/read inactivity timeouts. The provider receives
the transport result and returns a normalized provider result. Raw API-specific JSON is not inspected
by the Function and never enters public responses or logs.

This model is internal: do not serialize it into the endpoint response or logs. The
[request logger](LOGGING.md) selects only the provider HTTP status, a recognized normalized
status, the mapped outcome and a bounded raw provider message ID; descriptions and raw
metadata remain private. Public HTTP responses still expose only the existing
nonce/correlation/status or sanitized error contract.
Provider requests are serialized when building the outbound HTTP body. JavaScript/Python map
parsed response objects; .NET deserializes provider-specific response types through
`PhoneProviderBase.SendJsonAsync<TResponse>`. The handler uses only the normalized result.

Consult the selected provider implementation for required credentials and options. The
[onboarding credential naming table](ONBOARDING.md#provider-credential-names) lists exact secret
names for provisioning and authorized local tests. Keep that table aligned with provider credential
specifications; never include secret values in documentation or the settings sample.

### Telesign EPP integration

SMS and Voice use the complete provider-approved URLs selected from the provider profile. The provider
supplies `recipient.phone_number`, `message.text` (unchanged for SMS, paced/repeated for voice), optional `message.language`, one
selected `channels[].channel`, and `correlation_id`. Keep the leading `+` in the E.164 phone number.

This sample implements Basic authentication only. Per
[Telesign's authentication instructions](https://developer.telesign.com/enterprise/docs/authentication#basic-authentication),
the header is `Authorization: Basic <base64(UTF8(customer-id:api-key))>`, using the raw Customer ID
and API Key strings from Key Vault. Do not decode the API key first, send the API key alone, or
substitute a key identifier. The guide's `Basic YOUR_API_KEY` is abbreviated, not the literal encoding.
Digest and provider-token authentication are not implemented for Telesign here.

The optional `account_lifecycle_event` and `originating_ip` fields are reserved for future intelligence
capabilities. They are omitted; do not infer an originating address from the Function or synthesize
account events to fill them.

Telesign's `X-Shutter-Mode: true` suppresses delivery at the provider while still calling its endpoint.
It is appropriate for an explicitly authorized, direct provider diagnostic, not normal OTP delivery.
The production provider does not add or forward this header. Function evaluation mode remains separate:
it validates/decrypts and skips all provider HTTP. A successful provider shutter probe is not evidence
that an SMS was delivered or a Voice call was placed. Enabling the API globally also does not prove
that a particular Customer ID/API Key pair is authorized for this integration.

---

## 4. Configuration (app settings / env)

Set by provisioning. **Identical names across all languages.**

| Key | Purpose |
|-----|---------|
| `EPP_PROVIDER_NAME` | fixed id of the selected provider; `<provider-id>` is a placeholder, not a bundled default |
| `EPP_PROVIDER_SMS_ENDPOINT` | required SMS endpoint for the selected provider/region; complete send URL for Telesign/Soprano, base URL for Infobip/Sinch |
| `EPP_PROVIDER_VOICE_ENDPOINT` | required voice endpoint for the selected provider/region; complete send URL for Telesign/Soprano, base URL for Infobip/Sinch; may differ from SMS |
| `EPP_PROVIDER_ENDPOINT_REGION` | selected `global` or `eu` route label; informational at runtime |
| `EPP_PROVIDER_AUTH_MODE` | must match the selected adapter (`apiKey` for Infobip, Sinch, or Telesign; `oauth` for Soprano); see [guided versus adapter-only support](ONBOARDING.md#provider-credential-names) |
| `EPP_PROVIDER_TENANT_ID` | selected provider tenant; added to the Step 1 app's allowed-tenants preview and used as the OAuth authority for Soprano |
| `EPP_PROVIDER_SCOPE` | Soprano OAuth scope |
| `EPP_OUTBOUND_CLIENT_ID`, `EPP_OUTBOUND_MI_CLIENT_ID` | client application and user-assigned identity used for Soprano client-assertion exchange |
| `EPP_PROVIDER_ACCOUNT_NAME` | sender/source only when required by the selected provider |
| `EPP_PROVIDER_TIMEOUT_MS` | trimmed ASCII decimal milliseconds; default 1500 for missing/invalid/nonpositive values; capped at 2500. Not a whole-invocation deadline |
| `EPP_KEY_VAULT_CACHE_ENABLED` | `true`/`false`: API-key bundle caching and startup/refresh; unset defaults to `true` |
| `EPP_ACCESS_TOKEN_CACHE_ENABLED` | `true`/`false`: OAuth credential caching and startup/refresh; unset defaults to `true` |
| `EPP_DECRYPTION_KEY_PEM` | single RSA private key for JWE decryption, PEM or base64-encoded PEM; use a Key Vault secret reference in Azure, not a plaintext private key in shared settings |
| `EPP_ENCRYPTION_KEY_ID` | optional expected JWE `kid`; after successful decryption, a mismatch emits only `encryption_key_id_mismatch`. Advisory, not a key selector or authentication check |
| `KEY_VAULT_URL` | Key Vault URI for API-key providers |
| `AZURE_CLIENT_ID` | set for a user-assigned managed identity |

Telesign credentials live in **Key Vault**, under the names in its credential specification, and are fetched via
managed identity. Soprano exchanges an outbound managed-identity assertion for a token in the
configured provider tenant/scope. Do not put provider secrets in code or app settings.

Caller trust is configured in **Easy Auth**, not application environment variables: pin the trusted
tenant issuer, the endpoint-app audience and the authorized Microsoft caller application ID. Incoming
`tenantId` is routing metadata and cannot select any of these. There is no application host-detection
guard or backup token validation. See [platform onboarding](ONBOARDING.md#2-provision-encryption-and-deployment-trust).

### Default provider and configuration readers

Provision `EPP_PROVIDER_NAME` with the customer's selected provider, plus
`EPP_PROVIDER_SMS_ENDPOINT`, `EPP_PROVIDER_VOICE_ENDPOINT`, and matching authentication settings.
The endpoint settings can use different URLs for the same provider. A missing or unknown
provider fails closed; there is no implicit default or automatic failover. Request-body provider
fields are not used.

For each live request, the matching channel-specific endpoint is required. A missing, empty, or
invalid selected endpoint fails with `502`; there is no shared endpoint fallback, and one channel
never borrows the other channel's URL. The unselected channel's endpoint does not affect the request.
Endpoints must be absolute HTTPS URLs with a hostname, port 1-65535, and no userinfo or fragment; redirects are
not followed. Evaluation does not require provider endpoints.

Telesign and Soprano send to the selected URL unchanged. Infobip and Sinch use the selected
channel-specific base URL and append their API paths. Neither adapter substitutes a default base URL.

Each valid request's `channel` selects SMS or voice, without a deployment-level channel restriction.
The legacy `EPP_PROVIDER_CHANNEL` setting is not read. Unsupported request channels still fail
validation; provider account access for each intended channel remains an onboarding requirement.

The shared configuration readers are [JavaScript `readConfig`](../javascript/src/functions/config.js),
[Python `read_config`](../python/src/config.py), and [.NET `AppConfig.Read`](../dotnet/Src/AppConfig.cs).
They return named configuration objects for encryption and the selected provider, not caller-authentication
settings. Key Vault settings are read by JavaScript's configuration object and by the Python/.NET secret resolvers.
Provider-specific options remain ordinary app settings passed to the selected provider.

JSON parsing and type checks stay at the request boundary. Downstream code uses `Envelope`,
`DeliveryContext` and provider-neutral delivery models (immutable JavaScript objects, dataclasses
in Python, and classes/records in .NET). Named .NET response records preserve the existing wire names
and optional-field omission. Object construction does not replace validation or coerce invalid input.

All customers call the same `POST /api/SendOtp` handler in their chosen language. A fixed lookup selects
the configured provider, which builds the SMS or voice API call. Purchasing an unsupported
provider does not install an implementation: add that provider first. Purchase,
subscription activation and changing tenant policy belong to provisioning, not this Function.

### Credential caching and refresh

Provider credentials are process-local, distinct from the platform-resolved decryption-key
reference. Credential acquisition never sends an OTP or changes caller authentication.
All runtimes use `EPP_KEY_VAULT_CACHE_ENABLED` for the selected `apiKey` provider or
`EPP_ACCESS_TOKEN_CACHE_ENABLED` for the selected `oauth` provider. The switches are independent;
runtime selection does not depend on the hosting plan. Unset defaults to enabled. Values accept
trimmed, case-insensitive `true` or `false`; blank or other explicit selected values fail live
credential acquisition closed with a sanitized warning, without blocking evaluation.
Restart workers after configuration changes. Setup writes both as `false` for FC1 or `true` for EP1;
deploy a supporting package, since older releases do not read these settings.

With caching **disabled**, each live request retrieves a complete Key Vault bundle or uses fresh
managed-identity/client-assertion SDK credentials for OAuth. There is no startup preparation,
periodic polling, cross-request credential sharing, or failure cooldown. Request-scoped state is
discarded after acquisition; Python closes its SDK clients when synchronous acquisition finishes.
The same expiry checks and acquisition budgets below still apply. Azure's managed-identity service
and platform Key Vault-reference caching remain outside these switches.

With caching **enabled**, each runtime retains its existing policy:

| Runtime | Startup and replacement behavior | Operator consequence |
|---|---|---|
| [JavaScript](../javascript/src/functions/credentials.js) | Selects `ApiKeyCache` (`lru-cache`) or `AccessTokenCache`; warms at startup and polls every 30 seconds. API-key bundles target refresh at four minutes and expire at five. OAuth reuses SDK credentials/caches and the latest usable token. | Warm reads do not wait for refresh. Concurrent cold callers share acquisition; failures are retried at the polling cadence, not by sending another OTP. |
| [Python](../python/src/credentials.py) | Equivalent selected-cache/polling policy using `cachetools.TTLCache` and a daemon initialization/refresh thread. | Callers can stop waiting while synchronous acquisition remains shared. Connect/read inactivity timeouts are not a hard total I/O deadline. |
| [.NET](../dotnet/Src/CredentialTokenService.cs) | Hosted service warms the selected provider once. `MemoryCache` holds provider-supplied credentials until absolute expiry; the next miss fetches again. No periodic refresh loop. API-key credentials expire after five minutes; Soprano entries expire 30 seconds before SDK token expiry. | The first request after expiry can pay acquisition latency. `GetOrCreateAsync` does not guarantee single-flight retrieval for concurrent misses. A quiet app need not emit periodic credential events. |

JavaScript/Python retry failed refresh on a later poll without extending cached credential
lifetime; requests with expired credentials join acquisition or fail closed. SDK token expiry
is preserved, and tokens with 30 seconds or less remaining are unusable. These implementations
stop polling/prevent late publication at shutdown. .NET has no poller to stop: failed cache
fills are not retained and later misses attempt retrieval. It does not proactively refresh a
still-valid entry.

JavaScript limits shared acquisition to 2.5 seconds and passes cancellation through the SDK
transport. Python limits waits and SDK connect/read inactivity to 2.5 seconds. Synchronous I/O
may continue until the underlying call returns. .NET uses a 2.5-second fetch budget linked to
the caller's cancellation token. None is a whole-invocation deadline.

All runtimes fetch a complete API-key/customer-ID bundle before use and use managed identity
for vault access. With caching enabled, Soprano reuses managed-identity and client-assertion SDK credentials
without Key Vault or a client-secret fallback. Evaluation skips credential resolution on the
request path even when independent startup/refresh work runs.

**Prewarming is not traffic readiness or a latency guarantee.** Test cold, warm, expired, rotated,
and concurrent cases for the deployed runtime. The `credential_refresh_failed` event name is also
used by .NET for startup/cache-fill failures; it does not imply a periodic job. Field casing and
collection differ by runtime; use [runtime-specific discovery](MONITORING.md#runtime-specific-log-discovery).
Do not log SDK exception details or tokens. No cache retries/deduplicates provider sends.

---

## 5. Required behaviors

- **Safe outcome mapping (fail-closed)**: only `Continue` → `200 accepted`; unknown status → `Fail`.
- **Managed identity**: Key Vault access via managed identity only (user-assigned if `AZURE_CLIENT_ID`
  set, else system-assigned). No static credentials.
- **Privacy**: never log phone numbers, passcodes, nonce values, bearer tokens, API keys, JWE headers/payloads,
  raw exceptions, provider descriptions/responses or endpoint query strings. There is no plaintext diagnostic
  override. Each handler emits separate service events. JavaScript and .NET use fixed completion
  events rather than a mutable comprehensive summary; Python uses the same fixed-event approach
  through the standard `logging` pipeline.
  Generated Function IDs remain distinguished from raw Microsoft/provider support IDs. Original wire IDs
  and the required nonce echo remain unchanged. Support IDs can correlate customer activity; restrict
  log access and retention. Endpoint logs contain only scheme, host/port and API path, never userinfo,
  query strings or fragments. A configured encryption-key-ID mismatch adds a correlated fixed warning,
  never either key ID or the JWE header. Disable SDK, platform and proxy body tracing separately.
- **Platform authentication only**: enable Easy Auth with `requireAuthentication=true`,
  `unauthenticatedClientAction=Return401` and `requireHttps=true`. Configure the trusted tenant issuer
  and `allowedAudiences` for the endpoint app, plus a **nonempty `allowedApplications`** list pinned to
  the authorized Microsoft caller application ID. No excluded path may bypass authentication for SendOtp.
  The trigger remains `authLevel: anonymous`; there is no application token validation or function-key
  fallback. The platform rejects unauthenticated requests with `401` and denies callers outside the
  allowlist before the handler. **Keep Easy Auth enabled for every public SendOtp route.**
  Core Tools supplies no Easy Auth, so local execution stays on loopback without tunnels or public
  forwarding. Request data, JWE decryption, a fixed nonce, and forwarded principal headers serve
  other parts of the contract; Easy Auth authenticates the Entra ID caller.
- **Timeout boundaries**: platform authentication and Key Vault retrieval happen outside the outbound HTTP
  timer. Python uses connect/read inactivity timeouts, not a hard elapsed-time deadline. The cap
  does not guarantee a 3.2-second end-to-end response, especially on cold starts.
  A timed-out POST may already have been accepted; avoid blind retries that duplicate messages.

### Application logs

See the [application log reference](LOGGING.md) for event order, allowlisted fields, identifier
provenance, levels, and runtime formats. Each invocation emits fixed events ending in
`request_completed`, not a mutable request summary. Evaluation emits no provider events.
Keep bodies, nonces, credentials, and raw exceptions out of every pipeline.

Emission is not guaranteed collection. Use [runtime-specific queries](MONITORING.md#runtime-specific-log-discovery)
and [collection diagnostics](APPLICATION-INSIGHTS.md) before relying on alerts.

---

## 6. Lightweight tests

Each language keeps lightweight offline tests covering representative application checks for:

- Bundled provider request formats and static provider credentials.
- Fail-closed outcomes, missing credentials, HTTPS guards and timeouts.
- Envelope validation and real JWE decryption/tamper rejection.
- Evaluation handling without provider I/O; configured-provider startup refresh is tested separately.
- Awaited delivery, nonce acknowledgement and privacy-safe logging, including the shared
  service-event order and safe field cases in [contract.json](../tests/fixtures/contract.json),
  identifier provenance, error paths, provider-body timeouts and concurrent request isolation.
- Runtime-specific credential caching using fake dependencies: JavaScript/Python cover selected-cache
  startup, shared retrieval, polling, expiry, and shutdown; .NET covers its startup/cache-miss model.
  JavaScript tests also exercise cancellation through the actual SDK pipeline.

The sample deliberately omits exhaustive input permutations and SDK internals. These tests use
local keys and mocked external services; they do not send SMS and **do not test Easy Auth or platform
authorization**. Separate deployed security tests are required for missing/invalid credentials,
wrong issuer or audience, unauthorized caller, HTTPS enforcement and SendOtp route protection.
An authorized evaluation must succeed without provider I/O. These checks do not replace provider
integration or handset-delivery checks. See [deployment verification](ONBOARDING.md#4-package-deploy-and-verify).

<a id="production-limitations"></a>
<a id="production-readiness-considerations"></a>
## Production readiness

Use this checklist to plan capabilities required beyond the sample.
Provider acceptance and nonce checks confirm important stages of the request, while handset
delivery and provider-specific features need their own validation.

- **Encryption and rotation:** the Function imports one private PEM through a Key Vault secret
  reference and decrypts in-process. A production design can add vault-resident cryptographic
  operations and overlapping key rotation when required.
- **Delivery workflow:** the sample waits for provider acceptance before replying. Add a durable
  queue, early acknowledgement/background handoff, or automated retry strategy only when the
  approved product design defines their timing and duplicate-send behavior.
- **End-to-end timing:** size the caller budget for cold starts, platform authentication, Key Vault
  access, and the provider request. The outbound timeout covers the provider call rather than the
  full invocation; Python uses connect/read inactivity timeouts.
- **Credential readiness:** caches are process-local and proactive preparation is best-effort.
  Provider delivery still waits for acceptance; background credential refresh is separate from
  OTP delivery, queuing, and duplicate-send protection.
- **Voice experience:** Soprano extracts the first six consecutive digits; Telesign paces
  standalone six-digit numeric runs and repeats the full message. Validate supported locales,
  passcode formats, and actual audio for the intended experience.
- **Additional production capabilities:** add the body-size/content-type and E.164 validation,
  subscription setup, certification, least-cost routing, or voice-callback workflows required
  by the design. Native caller fallback remains with the caller rather than this Function.

See [setup compatibility](ONBOARDING.md#setup-script-compatibility) for credential provisioning,
endpoint format and unsupported setup options.
