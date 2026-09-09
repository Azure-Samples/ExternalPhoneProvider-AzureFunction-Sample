# External Phone Provider Function — Language-Agnostic Contract

This defines the shared contract for [JavaScript](../javascript/), [Python](../python/) and
[.NET](../dotnet/). See [production limitations](#production-limitations) before production use.

> **Naming.** "CYOT" (Choose Your Own Telecom) is the internal code name for this feature. It still
> appears in wire-level identifiers that must not change — type names (`SendCyotOtpRequest`,
> `CyotDeliveryContext`) and the caller's `User-Agent`. App settings use the `EPP_` prefix.

The design is **one dispatch engine + registered provider adapters**, with one selected provider per
deployment. API-specific paths, headers, payloads and status rules belong in adapters, not this guide.

---

## 1. HTTP API

**Endpoint:** `POST /api/SendOtp` (Functions HTTP trigger, `authLevel: anonymous`; trust comes from
the Entra token when `EPP_REQUIRE_AUTH=true`). This is the interface **SAS (StrongAuthenticationService)**
calls. PII (phone number + the rendered message, which contains the passcode) is **encrypted** inside a
JWE; the cleartext envelope carries routing/scheduling only.

### Request headers

| Header | Notes |
|--------|-------|
| `Authorization` | `Bearer <Entra token>`; validate signature, configured audience/issuer, lifetime and caller before trusting claims |
| `User-Agent` | e.g. `Microsoft-AzureMFA-SAS-CYOT/1.0`; not logged |
| `x-ms-correlation-id` | tracing only; fallback for envelope `correlationId`, not authentication |
| `x-ms-client-request-id` | per-attempt tracing id (used as `messageId`), not authentication |

Forwarded headers, including `x-ms-client-principal`, do not establish trust by themselves and cannot
replace JWT validation. Configure Easy Auth as described in section 5.

### Request body — `SendCyotOtpRequest` (cleartext envelope)

| Field | Required | Notes |
|-------|----------|-------|
| `type` | yes | exactly `microsoft.mfa.otpDeliver.v1`; unknown versions are rejected |
| `tenantId` | no | opaque request routing metadata; never selects the trusted issuer, signing keys or provider |
| `correlationId` | no | sign-in tracing metadata |
| `channel` | yes | request delivery channel: `1`/`sms` or `2`/`voice`; not deployment configuration |
| `mode` | yes | request delivery mode: `1`/`live` or `2`/`evaluation`; evaluation does not deliver |
| `ttlSeconds` | no | positive JSON integer, at most `2147483647`; null, booleans, strings, fractions and nonpositive values are rejected. Use canonical integer notation (`60`, not `60.0` or `6e1`) across runtimes |
| `encryptedDeliveryContext` | yes | JWE compact serialization (see below) |

Unknown `type`, malformed or expired `ttlSeconds`, unsupported `channel` or `mode`, or missing/empty `encryptedDeliveryContext` → `400`. Arrays, objects and booleans are not channel/mode values.

These are request data, not settings to provision. The TTL check validates the supplied value; it
does not verify passcode expiry or implement a delivery deadline. Deployment trust comes only from
the authentication configuration and validated token, not the body or tracing headers.

### `encryptedDeliveryContext` (JWE)

Alg: **RSA-OAEP-256** (CEK wrap) + **A256GCM** (content). The JOSE protected header carries `kid`;
this sample uses the single configured RSA private key (`EPP_DECRYPTION_KEY_PEM`, a Key Vault
reference in Azure), not a multi-key lookup. The compact JWE must have **exactly five non-empty
segments** and at most **16,384 characters**; `alg`/`enc` are pinned (only `RSA-OAEP-256` + `A256GCM` accepted) and the AES-GCM auth tag is
verified before any plaintext is used. Decrypted plaintext = `CyotDeliveryContext`:

| Field | Required | Notes |
|-------|----------|-------|
| `nonce` | yes | value the endpoint MUST echo to prove decryption |
| `phoneNumber` | yes | caller supplies an E.164 string; full E.164 validation is an implementation gap |
| `message` | yes | fully rendered, localized text containing the passcode; forward unchanged, including caller-supplied voice digit spacing. Do not extract, infer or guess a passcode |
| `extension` | no | office-voice contract field; not currently forwarded by the shared dispatch model |
| `locale` | no | voice selection input where supported by the selected adapter |
| `riskContext` | no | contextual request data; no risk-policy evaluation is implemented here |

Decryption failure → `400`. Missing `nonce` / `phoneNumber` / `message` → `400`.

### Response — `CyotEndpointResponse` (JSON)

```json
{ "nonce": "<echo of request nonce>", "correlationId": "<echo>", "providerStatus": "accepted" }
```

`accepted`/`pending` are **not** failures (provider queued it; acceptance ≠ delivery to the handset).
The endpoint returns **`200`** on acceptance (any `2xx` counts as transport acceptance). On `2xx` **with a
matching nonce**, SAS treats the send as handled. **Nonce mismatch / non-2xx / timeout → SAS falls back
to native CAPP delivery.** `Evaluation` mode returns `200` + nonce echo without delivering.

Live handlers await provider acceptance; they do not launch background delivery after replying.
Failures omit the nonce and accepted status and return a sanitized error with a request ID
and, after envelope processing, a correlation ID.

### Evaluation (generic shutter)

The only shared non-delivery control is the existing incoming `mode: 2` or `mode: "evaluation"`,
for every provider and language. Authentication, envelope validation and authenticated JWE decryption
still run; provider lookup, provider Key Vault reads and outbound provider HTTP are skipped. No
provider name, endpoint or credentials are needed. Authentication metadata retrieval and platform
resolution of the decryption-key reference may still require network access.

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
| — | `504` | request to the provider timed out |
| — | `502` | network error to the provider (non-timeout) |

---

## 3. Provider adapter contract

Each provider is one unit exposing three things:

- **`manifest`** — protocol facts only:
  - `id` — provider id selected by `EPP_PROVIDER_NAME`; its base URL is `EPP_PROVIDER_ENDPOINT`
  - `auth` — `{ mode: 'apiKey', keyVaultSecretName, identityKeyVaultSecretName? }`; other modes fail closed on this branch
  - `responseMapping` — map of provider status → `Continue` | `Fail` | `Block` | `StepUp` (+ `default`)
- **`buildRequest({ channel, endpoint, dispatch, credential, env })`** → `{ url, method, headers, body }`
- **`parseResponse({ httpStatus, ok, json })`** → `{ success, providerHttpStatus, providerMessageId,
  providerStatusName | providerStatusCode, providerStatusDescription }`

Adapters require registration in the chosen runtime. Consult the selected adapter and its manifest
for required credentials and options: the manifest declares secret names and protocol mappings;
the implementation reads adapter-specific options from app settings. Do not duplicate individual
API contracts or credential catalogs in shared onboarding documentation.

---

## 4. Configuration (app settings / env)

Set by provisioning. **Identical names across all languages.**

| Key | Purpose |
|-----|---------|
| `EPP_PROVIDER_NAME` | registered id of the selected provider; `<adapter-id>` is a placeholder, not a bundled default |
| `EPP_PROVIDER_ENDPOINT` | absolute HTTPS base URL with a hostname, port 1–65535, and no userinfo or fragment; the final adapter URL is also validated; redirects are not followed |
| `EPP_PROVIDER_ACCOUNT_NAME` | sender/source only when required by the selected adapter |
| `EPP_PROVIDER_TIMEOUT_MS` | trimmed ASCII decimal milliseconds; default 1500 for missing/invalid/nonpositive values; capped at 2500. Not a whole-invocation deadline |
| `EPP_DECRYPTION_KEY_PEM` | single RSA private key for JWE decryption, PEM or base64-encoded PEM; use a Key Vault secret reference in Azure, not a plaintext private key in shared settings |
| `EPP_ENCRYPTION_KEY_ID` | optional expected JWE `kid`; after successful decryption, a mismatch emits only `encryption_key_id_mismatch`. Advisory, not a key selector or authentication check |
| `EPP_REQUIRE_AUTH` | **must be `true` on Azure**, with `EPP_EXPECTED_CLIENT_ID` configured; missing/disabled auth is permitted only in local development |
| `EPP_EXPECTED_AUDIENCE` | required with auth: exact inbound token `aud`, the endpoint app client-ID GUID for v2; an explicitly configured v1 deployment may use its App ID URI. Not the selected provider's audience |
| `EPP_EXPECTED_ISSUER` | optional exact issuer pin: `https://login.microsoftonline.com/<issuer-tenant-guid>/v2.0` for v2 or `https://sts.windows.net/<issuer-tenant-guid>/` for v1. Without a pin, both forms for the configured trusted tenant are accepted |
| `EPP_TENANT_ID` | existing trusted issuer-tenant GUID used for issuer/JWKS configuration; required when auth is enabled, even with an explicit issuer pin. It is not body `tenantId`; the runtime does not derive this setting from the issuer URL or request |
| `EPP_EXPECTED_CLIENT_ID` | required on Azure: admitted caller app client-ID GUID supplied by onboarding; checked against validated `azp`/`appid` as well as the Easy Auth application allowlist |
| `KEY_VAULT_URL` | Key Vault URI (provider API keys) |
| `AZURE_CLIENT_ID` | set for a user-assigned managed identity |

Provider credential values live in **Key Vault**, under the names in the selected adapter's manifest,
and are fetched via **managed identity** with the *Key Vault Secrets User* role. Do not put credential
values in code or app settings. No additional customer-private configuration or new environment
variable is needed for this guidance.

There is no `OnAzure` setting or shared configuration field. Authentication uses the existing,
host-injected `WEBSITE_INSTANCE_ID`, `WEBSITE_HOSTNAME` and `WEBSITE_SITE_NAME` metadata internally to
prevent local authentication bypass in Azure. Customers do not provision these markers.

The required issuer tenant determines the trusted signing-key location. `EPP_EXPECTED_ISSUER` is an
optional tighter issuer pin and is omitted from the minimal sample. Neither is inferred from request
`tenantId` or unverified token claims. This avoids letting a request choose its own trust authority.

### Default provider and configuration readers

Provision `EPP_PROVIDER_NAME` with the customer's selected provider, plus that account's
`EPP_PROVIDER_ENDPOINT` and Key Vault credentials. A missing or unknown provider fails closed;
there is no implicit default or automatic failover. Request-body provider fields are not used.

The shared configuration readers are [JavaScript `readConfig`](../javascript/src/functions/config.js),
[Python `read_config`](../python/src/config.py), and [.NET `AppConfig.Read`](../dotnet/Src/AppConfig.cs).
They expose authentication, encryption and selected-provider settings. Provider-specific options
remain ordinary app settings passed to the selected adapter.

All customers call the same `POST /api/SendOtp` handler in their chosen language. Its registry selects
the configured adapter, which builds the provider's SMS or voice API call. Purchasing an unsupported
provider does not install an adapter: add and register that provider's adapter first. Purchase,
subscription activation and changing tenant policy belong to provisioning, not this Function.

---

## 5. Required behaviors

- **Fail-closed** — only `Continue` → `200 accepted`; unknown status → `Fail`.
- **Managed identity** — Key Vault access via managed identity only (user-assigned if `AZURE_CLIENT_ID`
  set, else system-assigned). No static credentials.
- **Privacy** — never log phone numbers, passcodes, nonce values, JWTs, API keys, JWE headers/payloads,
  raw exceptions or provider responses. There is no plaintext diagnostic override. Each handler
  writes one summary with a generated request ID, the first 16 lowercase hex characters of the
  correlation ID's SHA256 hash, HTTP status,
  elapsed milliseconds and evaluation flag. Original wire correlation IDs and the required nonce
  echo remain unchanged. Hashes are pseudonymous, not anonymous; restrict log access and retention.
  A configured encryption-key-ID mismatch adds a fixed warning, never either key ID or the JWE header.
  Disable SDK, platform and proxy body tracing separately.
- **Auth** — enable Easy Auth with `unauthenticatedClientAction=Return401` and `allowedApplications`
  pinned to the admitted caller. The trigger is `authLevel: anonymous`; Azure deployments also require
  in-process validation using the provisioned audience, trusted issuer tenant and caller, RS256/JWKS
  and required `exp`. Failed JWT validation returns `401`; an additional principal-header mismatch
  check, where implemented, returns `403` but never grants access. Local-only auth bypass must not be
  internet-accessible. Neither request data nor an unvalidated forwarded header establishes identity.
- **Timeout boundaries** — auth metadata and Key Vault retrieval happen outside the outbound HTTP
  timer. Python uses connect/read inactivity timeouts, not a hard elapsed-time deadline. The cap
  therefore does not guarantee a 3.2-second end-to-end response, especially on cold starts.
  A timed-out POST may already have been accepted; avoid blind retries that duplicate messages.

---

## 6. Lightweight tests

Each language keeps three small offline test files covering representative checks for:

- Bundled adapter request formats and static provider credentials.
- Fail-closed outcomes, missing credentials, HTTPS guards and timeouts.
- Envelope validation and real JWE decryption/tamper rejection.
- Inbound authentication and evaluation without provider I/O.
- Awaited delivery, nonce acknowledgement and privacy-safe logging.

The sample deliberately omits exhaustive input permutations and SDK internals. These tests use
local keys and mocked external services; they do not send SMS or replace deployment, provider
integration or handset-delivery checks. Runtime requirements in the sections above still apply.

## Production limitations

This is a sample, not production certification. Successful provider acceptance and nonce checks do
not prove handset delivery or support for every provider feature.

- The Function imports one private PEM through a Key Vault secret reference and decrypts in-process;
  vault-resident cryptographic operations and overlapping key rotation are not implemented.
- The outbound timeout is not an end-to-end deadline. Cold starts, authentication metadata and Key
  Vault access can exceed the caller's budget; Python uses connect/read inactivity timeouts.
- Full body-size/content-type and E.164 validation, subscription provisioning, certification,
  least-cost routing and voice-callback workflows are outside this sample. Native fallback belongs
  to the caller, not this Function.
