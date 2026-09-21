# External Phone Provider Function: Language-Agnostic Contract

This defines the shared contract for [JavaScript](../javascript/), [Python](../python/) and
[.NET](../dotnet/). See [production limitations](#production-limitations) before production use.

> **Naming.** EPP means **External Phone Provider**. App settings use the `EPP_` prefix; the
> request and delivery models are `Envelope`, `DeliveryContext` and `DispatchRequest`.
> Documentation names do not change the external JSON fields or `microsoft.mfa.otpDeliver.v1` version.

The design is **one dispatch engine + registered provider adapters**, with one selected provider per
deployment. API-specific paths, headers, payloads and status rules belong in adapters, not this guide.

---

## 1. HTTP API

**Endpoint:** `POST /api/SendOtp` (Functions HTTP trigger, `authLevel: anonymous`). **Easy Auth is the
only caller-authentication boundary and runs before the handler**; the application has no token
validator or function-key gate. This is the interface **SAS (StrongAuthenticationService)** calls.
SAS sends an Entra bearer JWT as part of its protocol; Easy Auth validates it, not the handler.
PII (phone number + the rendered message, which contains the passcode) is **encrypted** inside a JWE;
the cleartext envelope carries routing/scheduling only.

### Request headers

| Header | Notes |
|--------|-------|
| `Authorization` | consumed by platform authentication, not parsed or echoed by handler |
| `User-Agent` | caller-supplied identifier; not interpreted or logged |
| `x-ms-correlation-id` | tracing only; fallback for envelope `correlationId`, not authentication |
| `x-ms-client-request-id` | per-attempt tracing id (used as `messageId`), not authentication |

Forwarded headers, including `x-ms-client-principal`, do not establish trust by themselves and cannot
replace the required Easy Auth gate. The handler does not use them to authenticate callers or forward
the incoming `Authorization` header to the provider. Configure Easy Auth as described in section 5.

### EPP request body: `Envelope` (cleartext envelope)

| Field | Required | Notes |
|-------|----------|-------|
| `type` | yes | exactly `microsoft.mfa.otpDeliver.v1`; unknown versions are rejected |
| `tenantId` | no | opaque request routing metadata; never selects the trusted issuer, signing keys or provider |
| `correlationId` | no | sign-in tracing metadata |
| `channel` | yes | request delivery channel: `1`/`sms` or `2`/`voice`; not deployment configuration |
| `mode` | yes | request delivery mode: `1`/`live` or `2`/`evaluation`; evaluation does not deliver |
| `ttlSeconds` | no | positive JSON integer, at most `2147483647`; null, booleans, strings, fractions and nonpositive values are rejected. Use canonical integer notation (`60`, not `60.0` or `6e1`) across runtimes |
| `encryptedDeliveryContext` | yes | JWE compact serialization (see below) |

Canonical integer notation is a caller requirement, not a portable raw-JSON-token check: JavaScript's
JSON parser normalizes `60.0` and `6e1` to `60`, while Python/.NET reject those representations here.
Always send `60` to obtain the same result across runtimes; no custom JSON tokenizer is used.

Unknown `type`, invalid `ttlSeconds`, unsupported `channel` or `mode`, or missing/empty `encryptedDeliveryContext` → `400`. Arrays, objects and booleans are not channel/mode values.

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

All three HTTP-handler suites use [shared policy cases](../tests/fixtures/contract.json): the allowed
pair succeeds, while `RSA-OAEP`, `A128GCM` and `A256CBC-HS512` alternatives return `400 decryption_failed`
without provider I/O. Decryption uses the same policy before live/evaluation branching, so the matrix
runs once per language. Tag tampering and original-header-byte tests remain.

| Field | Required | Notes |
|-------|----------|-------|
| `nonce` | yes | value the endpoint MUST echo to prove decryption |
| `phoneNumber` | yes | caller supplies an E.164 string; full E.164 validation is an implementation gap |
| `message` | yes | fully rendered, localized text containing the passcode; text-message adapters forward it unchanged, Soprano voice extracts the first six consecutive digits, and Telesign voice paces standalone six-digit numeric runs and repeats the full message twice |
| `extension` | no | office-voice contract field; not currently forwarded by the shared dispatch model |
| `locale` | no | voice selection input where supported by the selected adapter |
| `riskContext` | no | contextual request data; no risk-policy evaluation is implemented here |
| `textToVoice` | no | legacy structured speech input; current Soprano adapters ignore it |

Decryption failure → `400`. Missing `nonce` / `phoneNumber` / `message` → `400`.

For Soprano live voice, the adapter finds the first six consecutive digits in `message`, preserving
leading zeros, and splits the rendered text into `beforePasswordText`, `password`, and
`afterPasswordText`. It uses a nonblank SAS `locale` as `language`, falling back to `en-US`, and sends
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
`EPP_OUTBOUND_MI_CLIENT_ID`. `EPP_PROVIDER_AUTH_MODE=oauth` matches the Soprano adapter.
`EPP_PROVIDER_ENDPOINT` is the complete selected send URL and is not modified by the adapter.
The calling app registration and outbound user-assigned identity must share a home tenant; the
calling app must be multitenant and provisioned/authorized in the provider tenant. The app's
federated credential trusts the identity's principal ID, home-tenant v2 issuer, and
`api://AzureADTokenExchange` audience. Key Vault identity selection remains independent.

Only the final application token is sent as `Authorization: Bearer ...`. No Soprano API ID/key,
managed-identity assertion, or incoming SAS token is forwarded. Missing settings, token-acquisition
failure, blank tokens, or tokens with 30 seconds or less remaining lifetime fail before provider HTTP;
there is no API-key fallback. Evaluation skips acquisition. A provider rejection is not retried.
Tokens are treated as opaque: the Function checks SDK expiry metadata, not custom JWT claims.
Soprano remains responsible for signature, issuer, audience, expiry, permissions, and account validation.

Credential instances are reused for the configured tenant/application/identity; each acquisition
uses the selected scope. JavaScript and .NET pass one 2.5-second cancellation signal/token through
both exchange stages. Python uses 2.5-second connect/read inactivity timeouts, not a total deadline.
Configured SDK transport retries are disabled. Managed-identity discovery may involve additional
SDK operations; this is not an end-to-end delivery deadline. JavaScript suppresses SDK logs only
in the acquisition's asynchronous context. Python filters Azure Identity/Core/MSAL records on
configured handlers in that context; configure logging sinks before handling requests. .NET disables
credential diagnostics. Keep platform body tracing off and never log credential objects or tokens.

When migrating from the earlier optional-JWT branch, replace `EPP_PROVIDER_APPLICATION_ID` with
`EPP_OUTBOUND_CLIENT_ID` and `EPP_PROVIDER_MI_CLIENT_ID` with `EPP_OUTBOUND_MI_CLIENT_ID`.
Remove `EPP_PROVIDER_JWT_ENABLED`; it no longer controls authentication. Reuse the exact provider
scope selected by setup and replace old base URLs with complete send URLs. These source changes
do not update deployed settings or establish provider authorization. Earlier QA4 tests of API keys
plus JWT do not validate the current Bearer-only configuration or production endpoints.

See [Microsoft's managed-identity federation guidance](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation-config-app-trust-managed-identity).

Use a SAS locale supported by the selected Soprano endpoint and account. On QA4, an API-key
voice request using `en` returned HTTP `400` with error code `400101`; the same request structure
using `en-US` returned HTTP `201` with `ENROUTE` on September 15, 2026. This confirms acceptance,
not handset receipt or audio quality. When SAS omits the locale, the adapters use `en-US`.

The supplied Soprano Connect Voice PDF describes a different API: `POST /voice/voice_orderApiCreate.do`
with form-encoded fields, `subAction=20`, and numeric language IDs (`1` is default English).
Its password fields are `beforePassword`, `passwordText`, and `afterPassword`. This adapter follows
the reference integration's JSON `/messages/omnimsg` contract instead; do not mix the form API's
language IDs, field names, or `ApiResponse.StatusCode` response format with this JSON interface.

JWE provides payload confidentiality and integrity, **not SAS caller authentication**. Anyone with the
public key can encrypt a request. The nonce acknowledges decryption; it is not an authentication
credential or replay protection, and a fixed nonce cannot substitute for Easy Auth.

### EPP response (JSON)

```json
{ "nonce": "<echo of request nonce>", "correlationId": "<echo>", "providerStatus": "accepted" }
```

`accepted`/`pending` are **not** failures (provider queued it; acceptance ≠ delivery to the handset).
The endpoint returns **`200`** on acceptance (any `2xx` counts as transport acceptance). On `2xx` **with a
matching nonce**, SAS treats the send as handled. **Nonce mismatch / non-2xx / timeout → SAS falls back
to native CAPP delivery.** `Evaluation` mode returns `200` + nonce echo without delivering.

Live handlers await provider acceptance; they do not launch background delivery after replying.
Handler failures omit the nonce and accepted status and return a sanitized error with a request ID
and, after envelope processing, a correlation ID. Platform rejections happen before the handler and
do not use this application response contract.

Validation failures return `error: "bad_request"` and a fixed `reason` in every language. Envelope
checks run in this order: object shape, version, encrypted-context presence, channel, mode, TTL.
Reasons are `invalid JSON body`, `invalid envelope`, `unsupported envelope type`,
`encryptedDeliveryContext is required`, `unsupported channel`, `unsupported mode`, `invalid ttlSeconds`
or `ttlSeconds expired`. A decrypted context missing a required nonblank string returns
`incomplete delivery context`. Reasons never include supplied values or exception text. JWE failures
return `error: "decryption_failed"` without a cryptographic reason or nonce.

### Evaluation (generic shutter)

The only shared non-delivery control is the existing incoming `mode: 2` or `mode: "evaluation"`,
for every provider and language. On Azure, Easy Auth still authenticates the caller before the
handler validates the envelope and decrypts the JWE with integrity checks. Provider lookup, provider
Key Vault reads and outbound provider HTTP are skipped. No provider name, endpoint or credentials
are needed. Platform authentication and resolution of the decryption-key reference may still require
network access. Core Tools has no Easy Auth; local evaluation must remain loopback-only, without tunnels.

There is no diagnostic environment flag. A live request is not an evaluation request. Adapter-specific
wire fields, where required by an API, remain internal and cannot enable a separate non-delivery mode.

---

## 2. Outcome → HTTP status mapping

The provider's parsed status is mapped via the adapter's `responseMapping` to an **outcome**, then to
an HTTP status. **Fail-closed:** an unknown/unmapped status is treated as `Fail`.
An unsuccessful provider HTTP response cannot become `Continue` because its body contains a
success-looking status. Explicit `Block`/`StepUp` outcomes remain non-success responses.

| Outcome | HTTP | When |
|---------|------|------|
| `Continue` | `200` | recognized success status |
| `Block` | `403` | provider says blocked |
| `StepUp` | `409` | provider signals step-up / fraud escalation |
| `Fail` | `429` | provider returned 429 |
| `Fail` | `401` | provider returned 401/403 (auth) |
| `Fail` | `400` | other provider 4xx |
| `Fail` | `502` | other provider error, or missing credential/endpoint |
| N/A | `504` | request to the provider timed out |
| N/A | `502` | network error to the provider (non-timeout) |

---

## 3. Provider adapter contract

Each provider is one unit exposing three things:

- **`manifest`**: protocol facts only:
  - `id`: provider id selected by `EPP_PROVIDER_NAME`; its complete request URL is `EPP_PROVIDER_ENDPOINT`
  - `auth`: either `{ mode: 'apiKey', keyVaultSecretName, identityKeyVaultSecretName? }` or
    `{ mode: 'oauth' }`; unsupported modes fail closed
  - `responseMapping`: map of provider status → `Continue` | `Fail` | `Block` | `StepUp` (+ `default`)
- **`buildRequest({ channel, endpoint, dispatch, credential, env })`** → `{ url, method, headers, body }`
- **`parseResponse({ httpStatus, ok, json })`** → `ParsedResponse`, containing `success`,
  `providerHttpStatus`, optional `providerMessageId`, `providerStatusName`, `providerStatusCode`
  and `providerStatusDescription` (snake_case attributes in Python, PascalCase in .NET).

The adapter reads its API-specific JSON and constructs a normalized `ParsedResponse` object:
[JavaScript](../javascript/src/functions/models.js), [Python](../python/src/models.py),
[.NET](../dotnet/Src/Models.cs). The engine reads named properties/attributes rather than provider JSON
or string-key response dictionaries. Optional values default to null/None; a status name takes precedence
over a code during outcome mapping, as before. Custom Python adapters must return `ParsedResponse`,
not the former dictionary.

This model is internal: do not serialize it into the endpoint response or logs. The
[request logger](#application-logs) selects only the provider HTTP status, a status found in the
adapter's mapping, the mapped outcome and a bounded raw provider message ID; descriptions and raw
metadata remain private. Public HTTP responses still expose only the existing
nonce/correlation/status or sanitized error contract.
Provider requests are serialized only when building the outbound HTTP body; incoming provider JSON
is parsed once and normalized inside its adapter. No serialization framework or provider-specific
class hierarchy is required.

Adapters require registration in the chosen runtime. Consult the selected adapter and its manifest
for required credentials and options: the manifest declares authentication and protocol mappings;
the implementation reads adapter-specific options from app settings. Individual API contracts remain
in the adapters; the [onboarding credential naming table](ONBOARDING.md#provider-credential-names)
lists the exact manifest secret names for provisioning and authorized local tests. Keep that table
aligned with the manifests; never include secret values in documentation or the settings sample.

### Telesign EPP integration

SMS and Voice use the complete provider-approved URLs selected from the provider profile. The adapter
supplies `recipient.phone_number`, the unchanged `message.text`, optional `message.language`, one
selected `channels[].channel`, and `correlation_id`. Keep the leading `+` in the E.164 phone number.

Phase 1 supports Basic and Digest; this sample implements Basic only. Per
[Telesign's authentication instructions](https://developer.telesign.com/enterprise/docs/authentication#basic-authentication),
the header is `Authorization: Basic <base64(UTF8(customer-id:api-key))>`, using the raw Customer ID
and API Key strings from Key Vault. Do not decode the API key first, send the API key alone, or
substitute a key identifier. The guide's `Basic YOUR_API_KEY` is abbreviated, not the literal encoding.
Provider-token authentication is described as Phase 2 and is not implemented for Telesign here.

The optional `account_lifecycle_event` and `originating_ip` fields are reserved for future intelligence
capabilities. They are omitted; do not infer an originating address from the Function or synthesize
account events to fill them.

Telesign's `X-Shutter-Mode: true` suppresses delivery at the provider while still calling its endpoint.
It is appropriate for an explicitly authorized, direct provider diagnostic, not normal OTP delivery.
The production adapter does not add or forward this header. Function evaluation mode remains separate:
it validates/decrypts and skips all provider HTTP. A successful provider shutter probe is not evidence
that an SMS was delivered or a Voice call was placed. Enabling the API globally also does not prove
that a particular Customer ID/API Key pair is authorized for this integration.

---

## 4. Configuration (app settings / env)

Set by provisioning. **Identical names across all languages.**

| Key | Purpose |
|-----|---------|
| `EPP_PROVIDER_NAME` | registered id of the selected provider; `<adapter-id>` is a placeholder, not a bundled default |
| `EPP_PROVIDER_ENDPOINT` | complete absolute HTTPS request URL for the selected channel/region, with a hostname, port 1–65535, and no userinfo or fragment; redirects are not followed |
| `EPP_PROVIDER_CHANNEL` | optional configured `sms` or `voice` route; when set, other live-request channels fail closed |
| `EPP_PROVIDER_ENDPOINT_REGION` | selected `global` or `eu` route label; informational at runtime |
| `EPP_PROVIDER_AUTH_MODE` | must match the selected adapter (`apiKey` for Telesign, `oauth` for Soprano) |
| `EPP_PROVIDER_TENANT_ID` | selected provider tenant; added to the Step 1 app's allowed-tenants preview and used as the OAuth authority for Soprano |
| `EPP_PROVIDER_SCOPE` | Soprano OAuth scope |
| `EPP_OUTBOUND_CLIENT_ID`, `EPP_OUTBOUND_MI_CLIENT_ID` | client application and user-assigned identity used for Soprano client-assertion exchange |
| `EPP_PROVIDER_ACCOUNT_NAME` | sender/source only when required by the selected adapter |
| `EPP_PROVIDER_TIMEOUT_MS` | trimmed ASCII decimal milliseconds; default 1500 for missing/invalid/nonpositive values; capped at 2500. Not a whole-invocation deadline |
| `EPP_DECRYPTION_KEY_PEM` | single RSA private key for JWE decryption, PEM or base64-encoded PEM; use a Key Vault secret reference in Azure, not a plaintext private key in shared settings |
| `EPP_ENCRYPTION_KEY_ID` | optional expected JWE `kid`; after successful decryption, a mismatch emits only `encryption_key_id_mismatch`. Advisory, not a key selector or authentication check |
| `KEY_VAULT_URL` | Key Vault URI for API-key providers |
| `AZURE_CLIENT_ID` | set for a user-assigned managed identity |

Telesign credentials live in **Key Vault**, under the names in its manifest, and are fetched via
managed identity. Soprano exchanges an outbound managed-identity assertion for a token in the
configured provider tenant/scope. Do not put provider secrets in code or app settings.

Caller trust is configured in **Easy Auth**, not application environment variables: pin the trusted
tenant issuer, the endpoint-app audience and the authorized SAS caller application ID. Incoming
`tenantId` is routing metadata and cannot select any of these. There is no application host-detection
guard or backup token validation. See [platform onboarding](ONBOARDING.md#2-provision-encryption-and-deployment-trust).

### Default provider and configuration readers

Provision `EPP_PROVIDER_NAME` with the customer's selected provider, plus the complete selected
channel/region `EPP_PROVIDER_ENDPOINT` and matching authentication settings. A missing or unknown
provider fails closed; there is no implicit default or automatic failover. Request-body provider
fields are not used.

The shared configuration readers are [JavaScript `readConfig`](../javascript/src/functions/config.js),
[Python `read_config`](../python/src/config.py), and [.NET `AppConfig.Read`](../dotnet/Src/AppConfig.cs).
They return named configuration objects for encryption and the selected provider, not caller-authentication
settings. Key Vault settings are read by JavaScript's configuration object and by the Python/.NET secret resolvers.
Provider-specific options remain ordinary app settings passed to the selected adapter.

JSON parsing and type checks stay at the request boundary. Downstream code uses `Envelope`,
`DeliveryContext` and `DispatchRequest` models (documented object shapes in JavaScript, dataclasses
in Python, and classes/records in .NET). Named .NET response records preserve the existing wire names
and optional-field omission. Object construction does not replace validation or coerce invalid input.

All customers call the same `POST /api/SendOtp` handler in their chosen language. Its registry selects
the configured adapter, which builds the provider's SMS or voice API call. Purchasing an unsupported
provider does not install an adapter: add and register that provider's adapter first. Purchase,
subscription activation and changing tenant policy belong to provisioning, not this Function.

---

## 5. Required behaviors

- **Fail-closed**: only `Continue` → `200 accepted`; unknown status → `Fail`.
- **Managed identity**: Key Vault access via managed identity only (user-assigned if `AZURE_CLIENT_ID`
  set, else system-assigned). No static credentials.
- **Privacy**: never log phone numbers, passcodes, nonce values, bearer tokens, API keys, JWE headers/payloads,
  raw exceptions, provider descriptions/responses or endpoint query strings. There is no plaintext diagnostic
  override. Each handler emits separate service events and one [request summary](#application-logs),
  with generated Function IDs distinguished from raw Microsoft/provider support IDs. Original wire IDs
  and the required nonce echo remain unchanged. Support IDs can correlate customer activity; restrict
  log access and retention. Endpoint logs contain only scheme, host/port and API path, never userinfo,
  query strings or fragments. A configured encryption-key-ID mismatch adds a correlated fixed warning,
  never either key ID or the JWE header. Disable SDK, platform and proxy body tracing separately.
- **Platform authentication only**: enable Easy Auth with `requireAuthentication=true`,
  `unauthenticatedClientAction=Return401` and `requireHttps=true`. Configure the trusted tenant issuer
  and `allowedAudiences` for the endpoint app, plus a **nonempty `allowedApplications`** list pinned to
  the authorized SAS caller application ID. No excluded path may bypass authentication for SendOtp.
  The trigger remains `authLevel: anonymous`; there is no application token validation or function-key
  fallback. The platform rejects unauthenticated requests with `401` and denies callers outside the
  allowlist before the handler. **Never expose the endpoint to the public internet with Easy Auth off
  or bypassed.** Core Tools supplies no Easy Auth: local execution must bind only to loopback, with
  no tunnels or public forwarding. Neither request data, JWE decryption, a fixed nonce nor forwarded
  principal headers authenticate the SAS caller.
- **Timeout boundaries**: platform authentication and Key Vault retrieval happen outside the outbound HTTP
  timer. Python uses connect/read inactivity timeouts, not a hard elapsed-time deadline. The cap
  therefore does not guarantee a 3.2-second end-to-end response, especially on cold starts.
  A timed-out POST may already have been accepted; avoid blind retries that duplicate messages.

### Application logs

All three implementations emit JSON records with the same field names. .NET also supplies these
fields as structured `ILogger` state. Service events have `logType: "service"` and an individual
`eventName`: they are emitted as the work happens, **not buffered or combined into a multi-step log**.
Each handler invocation ends with exactly one `logType: "request"`, `eventName: "request_completed"`
summary, including validation failures, evaluation and provider failures.

A successful live request emits these separate service events, followed by the request summary:

| Service event | Safe information recorded |
|---|---|
| `request_received` | Function invocation and available raw Microsoft trace IDs under their `x-ms-*` names; no raw body or arbitrary headers. |
| `envelope_validated` | Allowlisted body metadata: validated `envelopeType`, normalized `channel`, `evaluation`, optional `ttlSeconds`, and `encryptedDeliveryContextPresent: true`. |
| `delivery_context_decrypted` | Decryption completed; no plaintext fields, JWE or key ID. |
| `provider_selected` | Registered provider and its authentication mode. |
| `provider_credential_resolution_started` | OAuth client-assertion or Key Vault credential source, with explicitly named raw OAuth application/identity/tenant IDs. |
| `provider_credential_resolved` | Credential resolution and usability checks completed, with elapsed time; no secret, token, assertion or claims. |
| `provider_request_build_started` | The adapter is preparing the outbound request. |
| `provider_request_built` | Allowlisted HTTP method, final endpoint scheme/host/port/API path, HTTPS and disabled redirects; no query string, authorization headers or body. |
| `provider_request_started` | The outbound send is beginning, with method, sanitized endpoint and timeout. |
| `provider_response_received` | Actual upstream HTTP status; emitted before response-body reading completes. |
| `provider_response_processed` | Mapped provider status/outcome, raw provider message/reference ID, duration and resulting Function HTTP status. |
| `response_prepared` | Response status and booleans indicating nonce/correlation inclusion, not their values or the response body. |

Body metadata is built from validated fields, **not** from a body dump with a few sensitive
properties removed. Unknown request properties, `tenantId`, locale/risk data and all decrypted
fields remain excluded. An invalid envelope never contributes unvalidated type or TTL values.

`providerCredentialSource` is `managed_identity_client_assertion` for the app-token path and
`key_vault` for API-key providers. Resolution may use cached credentials: these events do not claim
a Key Vault network fetch or a fresh identity/token exchange occurred. `providerCredentialElapsedMs`
covers resolution plus the existing credential checks, not a separately enforced deadline. SDK
diagnostics remain suppressed as before; logging adds no token acquisition, secret reads or retries.

`provider_request_built` describes the adapter request, not creation of a new physical HTTP connection
or a new HTTP client in every runtime. `providerEndpoint` uses the **final** adapter URL, which can
differ from the configured base URL, but records only scheme + host/port + API path. For example,
`https://provider.example/epp/voice?key=secret` is logged as `https://provider.example/epp/voice`.
Userinfo, the entire query string and fragments are excluded. Use provider-approved paths that do
not embed secrets or personal data; path segments are not redacted. This does not alter the outbound
URL or its required query parameters. Standard HTTP verbs are logged in uppercase; custom or invalid
values are represented as `other` without changing the request sent.

`response_prepared` is emitted on success **and failure** immediately before returning the handler
response. It does not claim the host has serialized/transmitted that response or Microsoft received
it; consult platform request telemetry for transport completion. Evaluation emits
`evaluation_completed` instead of provider events, then `response_prepared` and the summary,
without resolving provider configuration, credentials or HTTP. Failures emit their own stage event,
such as `decryption_failed`, `provider_credentials_failed` or `provider_transport_failed`.
A parsed provider rejection uses `provider_response_processed` with its non-success outcome and
fixed failure reason.

Every service event carries the Function request/invocation IDs, the Microsoft trace IDs available
at that point, and the known channel, evaluation flag and selected provider. The initial event can
only know header trace IDs; a valid envelope can subsequently supply the selected correlation.
The generated Function request ID joins these events even when Microsoft IDs are absent or change
from header to envelope. The identifiers are intentionally not named simply `requestId` or
`correlationId` in logs:

| Log field | Source and meaning |
|---|---|
| `functionName` | Runtime function name: `SendOtp` in JavaScript/.NET, `send_otp` in Python. The HTTP route remains `/api/SendOtp` in every runtime. |
| `functionRequestId` | Generated by this handler. Matches `requestId` in failure responses; it is not Microsoft's request ID. |
| `functionInvocationId` | Azure Functions host invocation ID. Null for direct handler calls without a host context. |
| `x-ms-client-request-id` | Raw Microsoft per-attempt ID from the header of the same name, not the generated fallback used by dispatch. |
| `x-ms-correlation-id` | Raw selected Microsoft correlation: envelope `correlationId` first, then the header of the same name. The existing precedence is unchanged, and this never contains a generated Function ID. |
| `msCorrelationIdSource` | `envelope`, `header` or `none`; disambiguates the selected value when the envelope and header differ. |
| `providerMessageId` | Raw adapter-normalized message/reference ID returned by the provider, including Telesign `reference_id`, for support lookup. Not filled from dispatch or Function IDs, although a provider may echo an ID it received. |
| `providerTenantId` | Raw configured `EPP_PROVIDER_TENANT_ID` for OAuth, not incoming envelope `tenantId`. |
| `functionOutboundClientId` | Raw application's `EPP_OUTBOUND_CLIENT_ID` used for provider access, not the endpoint application's inbound audience or a Microsoft request ID. |
| `functionOutboundManagedIdentityClientId` | Raw configured `EPP_OUTBOUND_MI_CLIENT_ID` used to obtain the app assertion, not the Key Vault identity or the identity's principal/Object ID. |
| `providerEndpoint` | Validated final outbound URL without userinfo, query string or fragment; scheme, host/port and API path remain visible. |

The six external/configuration ID fields preserve their raw values and case for cross-system support
lookup; they are not hashed or truncated. To avoid dumping arbitrary text, only nonblank strings
of 1-128 ASCII characters are recorded: the first character must be a letter or digit, followed by
letters, digits, `.`, `_`, `:`, or `-`. This includes GUIDs, hex IDs and ordinary opaque references.
Missing/blank values are null; other invalid values are null and their field names appear in
`omittedIdFields`, never the rejected values. These guards affect logs only, not wire IDs or outcomes.
Application/client/tenant IDs are identifiers, not client secrets or bearer tokens.
These are tracing fields, not authentication assertions. In particular, an incoming `tenantId`
does not become a trusted tenant identity in logs. The existing wire correlation precedence,
provider request IDs and public responses are unchanged.

The request summary contains:

| Fields | Purpose |
|---|---|
| `httpStatus`, `result`, `elapsedMs` | Final Function response, `accepted` / `evaluated` / `failed`, and total handler time in milliseconds. Acceptance is not handset delivery. |
| `envelopeType`, `channel`, `evaluation`, `ttlSeconds` | Allowlisted request-body metadata; null until envelope validation succeeds. Omitted TTL remains null; logging does not introduce expiry enforcement. |
| `providerName`, `providerAuthMode`, `providerAttempted` | Registered adapter ID, its `apiKey` / `oauth` mode, and whether provider HTTP was attempted. Unknown configured names and credentials are never echoed. |
| `providerCredentialSource`, `providerCredentialElapsedMs` | Credential resolution path and duration, including failed resolution; null if it never started. |
| `providerTenantId`, `functionOutboundClientId`, `functionOutboundManagedIdentityClientId` | Raw configured OAuth identity IDs; null when OAuth resolution was not attempted. |
| `providerHttpMethod`, `providerEndpoint` | Final adapter request method and scheme/host/port/API path, set only after request construction and URL validation. No query string. |
| `providerHttpStatus`, `providerStatus`, `providerOutcome` | Actual upstream HTTP status and normalized response mapping. Status is logged only if it is an explicit adapter mapping key (not `default`); otherwise it is `unmapped`. |
| `providerMessageId` | Raw provider lookup/reference ID for support escalation. |
| `providerElapsedMs`, `providerTimeoutMs` | Outbound request duration including response-body reading, and the configured/clamped HTTP timeout. Neither is an end-to-end deadline. |
| `failureStage`, `failureReason` | Stage and fixed diagnostic reason, such as `provider_credentials` / `credential_unavailable`, `provider_transport` / `provider_timeout`, or `provider_response` / `provider_rejected`. No exception messages. |
| `encryptionKeyIdMismatch` | Whether the advisory warning was emitted; never the configured or received key ID. |
| `responseContainsNonce`, `responseContainsCorrelationId` | Whether those fields are in the prepared response, without recording their values. Null if no response was prepared. |
| `omittedIdFields` | Names of support ID fields whose current values failed the logging format/length guard; empty for ordinary valid IDs. |

Provider fields remain null when their stage was not reached. `providerHttpStatus` is captured as
soon as headers arrive, so a response-body timeout can legitimately show upstream `200` alongside
Function `httpStatus: 504`, without a mapped provider status or success acknowledgement. Unknown
provider status text and malformed JSON are never logged; malformed JSON emits only
`provider_response_invalid_json` before the existing adapter outcome rules run.

Normal events and request summaries use Information; invalid requests, non-success 4xx outcomes and
advisory warnings use Warning; 5xx failures and timeouts use Error. Keep application Information logs
enabled when investigating. This contract describes **emission**, not guaranteed collection:
host/telemetry filters and sampling can drop trace records. Application summaries are logs, not
the host's Request telemetry type, so excluding `Request` from sampling does not by itself retain
every summary. Configure collection and retention deliberately without enabling SDK/body tracing.
Easy Auth rejections occur before the handler and appear in platform telemetry, not these events.

---

## 6. Lightweight tests

Each language keeps lightweight offline tests covering representative application checks for:

- Bundled adapter request formats and static provider credentials.
- Fail-closed outcomes, missing credentials, HTTPS guards and timeouts.
- Envelope validation and real JWE decryption/tamper rejection.
- Evaluation without provider I/O.
- Awaited delivery, nonce acknowledgement and privacy-safe logging, including the shared
  service-event order and summary field set in [contract.json](../tests/fixtures/contract.json),
  identifier provenance, error paths, provider-body timeouts and concurrent request isolation.

The sample deliberately omits exhaustive input permutations and SDK internals. These tests use
local keys and mocked external services; they do not send SMS and **do not test Easy Auth or platform
authorization**. Separate deployed security tests are required for missing/invalid credentials,
wrong issuer or audience, unauthorized caller, HTTPS enforcement and SendOtp route protection.
An authorized evaluation must succeed without provider I/O. These checks do not replace provider
integration or handset-delivery checks. See [deployment verification](ONBOARDING.md#4-package-deploy-and-verify).

## Production limitations

This is a sample, not production certification. Successful provider acceptance and nonce checks do
not prove handset delivery or support for every provider feature.

- The Function imports one private PEM through a Key Vault secret reference and decrypts in-process;
  vault-resident cryptographic operations and overlapping key rotation are not implemented.
- The Preview 1 setup guide requires asynchronous delivery after acceptance. This sample still waits
  for the provider and has no durable queue or automatic retry implementation; it does not satisfy that
  timing architecture merely because the setup script deploys it.
- The outbound timeout is not an end-to-end deadline. Cold starts, platform authentication and Key
  Vault access can exceed the caller's budget; Python uses connect/read inactivity timeouts.
- Voice text is forwarded unchanged. Digit-by-digit rendering required by the setup guide must be
  verified for the chosen voice integration; unspaced numeric text is not guaranteed to be spoken correctly.
- Full body-size/content-type and E.164 validation, subscription provisioning, certification,
  least-cost routing and voice-callback workflows are outside this sample. Native fallback belongs
  to the caller, not this Function.

See [setup compatibility](ONBOARDING.md#setup-script-compatibility) for credential provisioning,
endpoint format and unsupported setup options.
