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
| `message` | yes | fully rendered, localized text containing the passcode; forward unchanged when the adapter uses message text. Do not extract, infer or guess a passcode |
| `extension` | no | office-voice contract field; not currently forwarded by the shared dispatch model |
| `locale` | no | voice selection input where supported by the selected adapter |
| `riskContext` | no | contextual request data; no risk-policy evaluation is implemented here |
| `textToVoice` | for Soprano live voice | structured speech object supplied inside the encrypted context; see below |

Decryption failure → `400`. Missing `nonce` / `phoneNumber` / `message` → `400`.

For Soprano live voice, include `textToVoice` alongside the required delivery fields:

```json
"textToVoice": {
  "beforePasswordText": "Your verification code is",
  "password": "001234",
  "language": "en-US"
}
```

`beforePasswordText` must be a string (empty is allowed); `password` and `language` must be
nonblank strings. Supply the password explicitly to preserve leading zeros; it is never extracted
from `message`. These values are forwarded unchanged as `voice.text2voice`, without a top-level
`text` field. Missing or invalid speech returns `400` before credential lookup or provider HTTP.
SMS continues to use `message`, and evaluation continues to skip provider-specific validation and I/O.
Soprano always requires `X-MEMS-API-ID` and `X-MEMS-API-Key`, resolved from `soprano-api-id` and
`soprano-api-key` in Key Vault. The optional provider JWT described below supplements these headers;
it never replaces them. Existing platform caller authentication is unchanged.

Use a speech language supported by the selected Soprano endpoint and account. On QA4, an API-key
voice request using `en` returned HTTP `400` with error code `400101`; the same request structure
using `en-US` returned HTTP `201` with `ENROUTE` on September 15, 2026. This confirms acceptance,
not handset receipt or audio quality. The adapter preserves the supplied language and does not
guess a region for a language-only value.

The supplied Soprano Connect Voice PDF describes a different API: `POST /voice/voice_orderApiCreate.do`
with form-encoded fields, `subAction=20`, and numeric language IDs (`1` is default English).
Its password fields are `beforePassword`, `passwordText`, and `afterPassword`. This adapter follows
the reference integration's JSON `/messages/omnimsg` contract instead; do not mix the form API's
language IDs, field names, or `ApiResponse.StatusCode` response format with this JSON interface.

### Optional Soprano provider JWT

**The Azure Function obtains the provider JWT from Entra. SAS supplies only the JWE delivery
payload, not a Soprano token.** SAS still authenticates its HTTP call with a Function-audience token
in `Authorization`, validated by Easy Auth. The outbound provider token is separate. A `providerJwt`
field or provider-token header in the incoming request is ignored and never forwarded.

For live Soprano SMS/Voice with `EPP_PROVIDER_JWT_ENABLED=true`, after checking the API-ID/key and
provider URL, `ManagedIdentityCredential` uses `EPP_PROVIDER_MI_CLIENT_ID` to obtain an assertion for
`api://AzureADTokenExchange/.default`. `ClientAssertionCredential` exchanges it in `EPP_PROVIDER_TENANT_ID`
as `EPP_PROVIDER_APPLICATION_ID` for `EPP_PROVIDER_SCOPE`. Only the final application token is forwarded.
The scope is the provider API's Application ID or Application ID URI plus `/.default`; there is no default.
The provider identity must be an attached user-assigned identity. Key Vault's existing identity selection
(`AZURE_CLIENT_ID`, or system-assigned when unset) is unchanged and independent.
No application secret, additional vault secret, or manually signed JWT is required for token acquisition.
Request `tenantId`, incoming Authorization, developer login, and the decryption key are never used to
select or authenticate this identity. Provider API ID/key secrets remain mandatory.

| Configuration / acquisition result | Soprano request |
|---|---|
| Flag missing, false, or unrecognized | API-ID/key only; no token acquisition |
| Flag true; federation settings missing, identity unavailable, either token request fails, or result is unusable | API-ID/key only |
| Flag true; usable token obtained from Entra | API-ID/key plus `Authorization: Bearer <access_token>` |
| API ID or key missing | Fail before token acquisition or provider HTTP |

Only the string `true`, case-insensitive with surrounding whitespace ignored, enables
`EPP_PROVIDER_JWT_ENABLED`. It applies only to Soprano SMS and Voice. Evaluation mode still skips
provider lookup, credentials, token acquisition, and provider HTTP. Live payloads keep `shutterMode: false`;
Voice still uses the full `voice.text2voice` object with a provider-supported language such as `en-US`.

Acquisition runs in [JavaScript `acquireToken`](../javascript/src/functions/providers/soprano.js),
[Python `acquire_token`](../python/src/providers/soprano.py), and
[.NET `AcquireTokenAsync`](../dotnet/Src/Providers/SopranoProvider.cs). All three use Azure Identity
`ManagedIdentityCredential` plus `ClientAssertionCredential` and reuse both so the SDK handles token caching
and refresh. Changing the provider tenant, calling application or managed identity creates new credentials. Each request passes its
configured scope to the SDK, so cached tokens cannot be reused for a different resource. Tokens
must have more than 30 seconds of remaining lifetime. No disk token cache is enabled, and the
application does not create service principals or credentials. Azure manages identity credentials.

JavaScript SDK calls in each stage receive a 2.5-second cancellation signal; .NET passes its
2.5-second cancellation token into both stages. Configurable SDK transport
retries are disabled. Python uses 2.5-second connect/read inactivity timeouts, not a total wall-clock
deadline. Managed-identity discovery can involve additional SDK operations. Provider-key lookup and
the provider send have separate timeout behavior; there is no end-to-end 2.5-second guarantee.
Cold-start and uncached identity latency must be measured before production use. JavaScript suppresses
Azure SDK log output only in the asynchronous token-request context. Python applies a context-local
Azure Identity/Core/MSAL filter to configured logging handlers, including SDK-specific handlers.
Both preserve unrelated requests' logs; .NET disables credential diagnostics. Configure logging sinks
before handling requests. Keep platform/proxy body tracing disabled; never log tokens, credential
exceptions, or provider bodies.

**Entra issues and signs the JWT; the Function does not create or sign it.** The Function checks for a
nonempty token and usable expiry metadata. It treats the access token as opaque, without custom
JWT parsing, alphabet checks, or regex. The SDK obtains tokens through Azure's managed-identity
mechanism, so the Function does not need a second inbound-style JWT validator for them.
Soprano must validate signature, issuer, audience, expiry, and caller claims at its boundary.
If Soprano rejects the combined credentials, the Function does not resend with API keys alone.
API-key fallback occurs only before the one provider submission when no usable token was acquired.

The supplied QA4 guide describes an Entra ID v2.0 application token with:

| Claim / token request | QA4 requirement |
|---|---|
| `aud` | `32dfc82a-86dd-4515-a0a2-f20ef2f5c7fe` |
| `iss` | `https://login.microsoftonline.com/{tenantId}/v2.0` for the onboarded tenant |
| `azp` | The calling app's `EPP_PROVIDER_APPLICATION_ID`, authorized by Soprano for the intended account; not the managed identity's Client ID |
| Scope requested by the Function | `32dfc82a-86dd-4515-a0a2-f20ef2f5c7fe/.default` |

Configure `EPP_PROVIDER_ENDPOINT=https://qa4.devops.sopranodesign.com/cgpapi`; the adapter appends
`/messages/omnimsg`. Use an account allowed to send both credentials. The guide does not establish
whether Soprano accepts API keys alone on every account, or which identity takes precedence when
both are present. Verify that behavior with Soprano before enabling the flag. The resource app controls
the access-token version; requesting `/.default` does not guarantee a v2 token. Agree on the issuer,
audience, token version, calling Application ID, API app-role assignments, and provider-side
account mapping with Soprano. Key Vault RBAC grants do not grant application permissions to the API.

**Federated trust is required.** The calling app registration and user-assigned identity must share
the same home tenant. The app's federated credential trusts that tenant's v2 issuer, the identity's
Object (principal) ID as subject, and `api://AzureADTokenExchange` as audience. For a different provider
tenant, the calling app must be multitenant and its service principal provisioned and authorized there.
This exchange does not require the provider API to be provisioned in the identity's home tenant.
System-assigned identities are not supported as the federated credential in this documented flow.
See [Microsoft's federation guidance](https://learn.microsoft.com/entra/workload-id/workload-identity-federation-config-app-trust-managed-identity).
The earlier live client-secret tests do not verify this flow. New live verification must demonstrate
token attachment, the expected issuer/audience/Application ID, and provider acceptance after onboarding.

Service-principal-per-customer provisioning remains an onboarding decision to agree with Soprano;
this code does not create service principals or assume that `azp` identifies a Marketplace purchase.
Marketplace subscription ID is not a standard Entra access-token claim. Do not substitute the Azure
subscription ID or tenant ID. Agree on an explicit provider-side account/subscription mapping or
supported claim extension before relying on JWTs for metered billing.

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
  - `id`: provider id selected by `EPP_PROVIDER_NAME`; its base URL is `EPP_PROVIDER_ENDPOINT`
  - `auth`: `{ mode: 'apiKey', keyVaultSecretName, identityKeyVaultSecretName? }`; other modes fail closed
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

This model is internal: do not serialize it into the endpoint response or log its fields. Public HTTP
responses still expose only the existing nonce/correlation/status or sanitized error contract.
Provider requests are serialized only when building the outbound HTTP body; incoming provider JSON
is parsed once and normalized inside its adapter. No serialization framework or provider-specific
class hierarchy is required.

Adapters require registration in the chosen runtime. Consult the selected adapter and its manifest
for required credentials and options: the manifest declares secret names and protocol mappings;
the implementation reads adapter-specific options from app settings. Individual API contracts remain
in the adapters; the [onboarding credential naming table](ONBOARDING.md#provider-credential-names)
lists the exact manifest secret names for provisioning and authorized local tests. Keep that table
aligned with the manifests; never include secret values in documentation or the settings sample.

### Telesign CYOT integration

SMS and Voice both use `POST https://verify.telesign.com/integration/msft/cyot` with JSON. Configure
the base URL as `https://verify.telesign.com`. The adapter supplies `recipient.phone_number`, the
unchanged `message.text`, optional `message.language`, one selected `channels[].channel`, and
`correlation_id`. Keep the leading `+` in the E.164 phone number; the guide's example `12345678`
does not satisfy its own required phone-number pattern.

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
| `EPP_PROVIDER_ENDPOINT` | absolute HTTPS base URL with a hostname, port 1–65535, and no userinfo or fragment; the final adapter URL is also validated; redirects are not followed |
| `EPP_PROVIDER_ACCOUNT_NAME` | sender/source only when required by the selected adapter |
| `EPP_PROVIDER_TIMEOUT_MS` | trimmed ASCII decimal milliseconds; default 1500 for missing/invalid/nonpositive values; capped at 2500. Not a whole-invocation deadline |
| `EPP_PROVIDER_JWT_ENABLED` | Optional, default off. Soprano only: exchange a managed-identity assertion for a provider-tenant application token when `true`; API-ID/key headers remain mandatory |
| `EPP_PROVIDER_TENANT_ID` | Provider/resource tenant for the final application token |
| `EPP_PROVIDER_APPLICATION_ID` | Application (client) ID of the calling app registration, not the provider API's ID |
| `EPP_PROVIDER_MI_CLIENT_ID` | Client ID of the attached user-assigned managed identity trusted by the calling app's federated credential; distinct from its Object (principal) ID |
| `EPP_PROVIDER_SCOPE` | Required for JWT acquisition. Provider API Application ID or Application ID URI plus `/.default`; no default |
| `EPP_DECRYPTION_KEY_PEM` | single RSA private key for JWE decryption, PEM or base64-encoded PEM; use a Key Vault secret reference in Azure, not a plaintext private key in shared settings |
| `EPP_ENCRYPTION_KEY_ID` | optional expected JWE `kid`; after successful decryption, a mismatch emits only `encryption_key_id_mismatch`. Advisory, not a key selector or authentication check |
| `KEY_VAULT_URL` | Key Vault URI (provider API keys) |
| `AZURE_CLIENT_ID` | Optional Client ID of the attached user-assigned identity for Key Vault only; empty/unset uses system-assigned identity. Independent of `EPP_PROVIDER_MI_CLIENT_ID` |

Provider credential values live in **Key Vault**, under the names in the selected adapter's manifest,
and are fetched via **managed identity** with the *Key Vault Secrets User* role. Do not put credential
values in code or app settings. No additional customer-private configuration or new environment
variable is needed for this guidance.

Caller trust is configured in **Easy Auth**, not application environment variables: pin the trusted
tenant issuer, the endpoint-app audience and the authorized SAS caller application ID. Incoming
`tenantId` is routing metadata and cannot select any of these. There is no application host-detection
guard or backup token validation. See [platform onboarding](ONBOARDING.md#2-provision-encryption-and-deployment-trust).

### Default provider and configuration readers

Provision `EPP_PROVIDER_NAME` with the customer's selected provider, plus that account's
`EPP_PROVIDER_ENDPOINT` and Key Vault credentials. A missing or unknown provider fails closed;
there is no implicit default or automatic failover. Request-body provider fields are not used.

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
  raw exceptions or provider responses. There is no plaintext diagnostic override. Each handler
  writes one summary with a generated request ID, the first 16 lowercase hex characters of the
  correlation ID's SHA256 hash, HTTP status,
  elapsed milliseconds and evaluation flag. Original wire correlation IDs and the required nonce
  echo remain unchanged. Hashes are pseudonymous, not anonymous; restrict log access and retention.
  Before a live Soprano submission, the engine also logs `SopranoAuth=api-key` or
  `SopranoAuth=api-key+jwt` with the same correlation hash, based on the actual outgoing headers.
  This distinguishes token attachment from API-key fallback; it does not expose token values or claims.
  A configured encryption-key-ID mismatch adds a fixed warning, never either key ID or the JWE header.
  Disable SDK, platform and proxy body tracing separately.
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

---

## 6. Lightweight tests

Each language keeps lightweight offline tests covering representative application checks for:

- Bundled adapter request formats and static provider credentials.
- Fail-closed outcomes, missing credentials, HTTPS guards and timeouts.
- Envelope validation and real JWE decryption/tamper rejection.
- Evaluation without provider I/O.
- Awaited delivery, nonce acknowledgement and privacy-safe logging.

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
