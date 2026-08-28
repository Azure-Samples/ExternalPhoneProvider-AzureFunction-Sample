# External Phone Provider Function — Language-Agnostic Contract

This is the **source of truth** every language implementation (`javascript/`, `dotnet/`, `python/`)
must conform to. If an implementation disagrees with this document, the implementation is wrong.

> **Naming.** "CYOT" (Choose Your Own Telecom) is the internal code name for this feature. It still
> appears in wire-level identifiers that must not change — type names (`SendCyotOtpRequest`,
> `CyotDeliveryContext`) and the caller's `User-Agent`. App settings use the `EPP_` prefix.

The design is intentionally simple: **one dispatch engine + drop-in provider adapters**. Adding a
provider is adding one adapter file; adding a language is re-implementing this contract.

---

## 1. HTTP API

**Endpoint:** `POST /api/SendOtp` (Functions HTTP trigger, `authLevel: anonymous`; trust comes from
the Entra token when `EPP_REQUIRE_AUTH=true`). This is the interface **SAS (StrongAuthenticationService)**
calls. PII (phone number + the rendered message, which contains the passcode) is **encrypted** inside a
JWE; the cleartext envelope carries routing/scheduling only.

### Request headers

| Header | Notes |
|--------|-------|
| `Authorization` | `Bearer <Entra token>` (audience = `EPP_EXPECTED_AUDIENCE`) |
| `User-Agent` | e.g. `Microsoft-AzureMFA-SAS-CYOT/1.0` (logged) |
| `x-ms-correlation-id` | sign-in correlation id (fallback for envelope `correlationId`) |
| `x-ms-client-request-id` | per-attempt id (used as `messageId`) |

### Request body — `SendCyotOtpRequest` (cleartext envelope)

| Field | Required | Notes |
|-------|----------|-------|
| `type` | ✅ | envelope contract version, e.g. `microsoft.mfa.otpDeliver.v1` |
| `tenantId` | | opaque routing guid (says nothing about the tenant) |
| `correlationId` | | sign-in correlation; stitches SAS ↔ provider traces |
| `channel` | ✅ | `CyotChannel` int: `1`=Sms, `2`=Voice (`0`=Undefined); the string forms `sms`/`voice` are also accepted |
| `mode` | ✅ | `CyotDeliveryMode` int: `1`=Live, `2`=Evaluation (rehearsal — do **NOT** deliver); the string forms `live`/`evaluation` are also accepted |
| `ttlSeconds` | | passcode validity remaining; `<= 0` is **logged as a warning** — the delivery still proceeds |
| `encryptedDeliveryContext` | ✅ | JWE compact serialization (see below) |

`channel` not in `{1,2}`/`{sms,voice}` → `400`. `mode` not in `{1,2}`/`{live,evaluation}` → `400`. Missing/empty `encryptedDeliveryContext` → `400`.

### `encryptedDeliveryContext` (JWE)

Alg: **RSA-OAEP-256** (CEK wrap) + **A256GCM** (content). The JOSE protected header carries `kid`; the
endpoint resolves the matching RSA private key (`EPP_DECRYPTION_KEY_PEM`, a Key Vault reference) and
local dev) and decrypts. The compact JWE must have **exactly five non-empty segments** and stay within a
size limit; `alg`/`enc` are pinned (only `RSA-OAEP-256` + `A256GCM` accepted) and the AES-GCM auth tag is
verified before any plaintext is used. Decrypted plaintext = `CyotDeliveryContext`:

| Field | Required | Notes |
|-------|----------|-------|
| `nonce` | ✅ | value the endpoint MUST echo to prove decryption |
| `phoneNumber` | ✅ | E.164, single canonical string |
| `message` | ✅ | fully rendered + localized text; **contains the passcode**. For `voice`, the passcode digits are spaced so TTS reads them individually |
| `extension` | | office voice only |
| `locale` | | selects TTS voice for the voice channel |
| `riskContext` | | `CyotRiskContext` (scenario, familiarity flags, ip/asn/geo, ja4/ja4h, …) |

Decryption failure → `400`. Missing `nonce` / `phoneNumber` / `message` → `400`.

### Response — `CyotEndpointResponse` (JSON)

```json
{ "nonce": "<echo of request nonce>", "correlationId": "<echo>", "providerStatus": "accepted" }
```

`accepted`/`pending` are **not** failures (provider queued it; acceptance ≠ delivery to the handset).
The endpoint returns **`200`** on acceptance (any `2xx` counts as transport acceptance). On `2xx` **with a
matching nonce**, SAS treats the send as handled. **Nonce mismatch / non-2xx / timeout → SAS falls back
to native CAPP delivery.** `Evaluation` mode returns `200` + nonce echo without delivering.

---

## 2. Outcome → HTTP status mapping

The provider's parsed status is mapped via the adapter's `responseMapping` to an **outcome**, then to
an HTTP status. **Fail-closed:** an unknown/unmapped status is treated as `Fail`.

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
  - `id` — provider id (also the `Provider` value; endpoint app setting is `<ID>_ENDPOINT`)
  - `auth` — `{ mode: 'apiKey', keyVaultSecretName, identityKeyVaultSecretName? }` or `{ mode: 'oauth2' }`
  - `responseMapping` — map of provider status → `Continue` | `Fail` | `Block` | `StepUp` (+ `default`)
- **`buildRequest({ channel, endpoint, dispatch, credential, env })`** → `{ url, method, headers, body }`
- **`parseResponse({ httpStatus, ok, json })`** → `{ success, providerHttpStatus, providerMessageId,
  providerStatusName | providerStatusCode, providerStatusDescription }`

The engine auto-discovers adapters (a `providers/` folder or registration). Endpoints, senders, TTLs,
etc. are **not** in the manifest — they are app settings (see §4).

---

## 4. Configuration (app settings / env)

Set by provisioning. **Identical names across all languages.**

| Key | Purpose |
|-----|---------|
| `EPP_PROVIDER_NAME` | active provider id (`infobip` \| `telesign` \| `sinch` \| `soprano`) |
| `EPP_PROVIDER_ENDPOINT` | provider base URL (one provider is active per deployment) |
| `EPP_PROVIDER_ACCOUNT_NAME` | sender / source id presented to the provider |
| `EPP_PROVIDER_TIMEOUT_MS` | outbound call timeout (default 1500) |
| `EPP_DECRYPTION_KEY_PEM` | RSA private key for JWE decryption — PEM, or **base64 over the PEM** as the setup script writes it. A **Key Vault reference** in Azure |
| `EPP_ENCRYPTION_KEY_ID` | expected JOSE `kid`; a mismatch is logged, not fatal |
| `EPP_REQUIRE_AUTH` | `true` → validate the Entra token in-process. **Recommended `true` in every deployment**; Easy Auth is the primary gate, this is the backstop |
| `EPP_EXPECTED_AUDIENCE` | v1 token `aud` — the identifier URI `api://{host}/{appId}` |
| `EPP_EXPECTED_ISSUER` | v1 issuer `https://sts.windows.net/{tenantId}/` |
| `EPP_TENANT_ID` | your Entra tenant id |
| `EPP_EXPECTED_CLIENT_ID` | caller `appid`/`azp` to admit — Microsoft's app `25ec60fa-f18d-41a4-b398-50044c90ce13`. Enforced by Easy Auth (`403`) and, when `EPP_REQUIRE_AUTH=true`, against the token's own claim (`401`) |
| `EPP_LOG_PLAINTEXT` | **diagnostics only** — `true` writes the phone number and passcode to the log. Never enable in production |
| `KEY_VAULT_URL` | Key Vault URI (provider API keys) |
| `AZURE_CLIENT_ID` | set for a user-assigned managed identity |

**Secrets** (provider API keys, identity secrets like customer/api ids) live in **Key Vault**, referenced
by name in the manifest and fetched at runtime via **managed identity** (needs the *Key Vault Secrets
User* role). Never in code or config.

---

## 5. Required behaviors

- **Fail-closed** — only `Continue` → `200 accepted`; unknown status → `Fail`.
- **Managed identity** — Key Vault access via managed identity only (user-assigned if `AZURE_CLIENT_ID`
  set, else system-assigned). No static credentials.
- **Privacy** — the OTP code and phone number must **never** appear in logs or the response body (they
  appear only in the outbound provider request, which is the delivery itself). The single exception is
  `EPP_LOG_PLAINTEXT=true`, a **diagnostics-only** switch that logs the phone number, message, and
  passcode. It defaults to false and **must not be enabled in production**.
- **Auth** — **Easy Auth must be ON** (`unauthenticatedClientAction=Return401`, `allowedApplications`
  pinned to Microsoft's app); the trigger is `authLevel: anonymous`, so it is the primary gate.
  `EPP_EXPECTED_CLIENT_ID` mismatches return `403`. Deployments should **also** set
  `EPP_REQUIRE_AUTH=true` to validate the Entra JWT in-process (audience = `EPP_EXPECTED_AUDIENCE`,
  issuer tenant = `EPP_TENANT_ID`, RS256, JWKS). No-op pass-through when false (local dev).

---

## 6. Conformance test scenarios

Every implementation ships tests covering at least:

1. Each provider builds an HTTPS request with the code present and the correct auth scheme.
2. `Block` → 403; provider 4xx `Fail` → 400; 429 → 429; 401/403 → 401.
3. Provider HTTP 200 with an **unknown** status still `Fail`s (fail-closed).
4. Missing provider credential → 502; missing endpoint config → 502.
5. Timeout → 504; network error → 502.
6. Envelope validation: `400` on invalid JSON, unsupported `channel`, unsupported `mode`, missing
   `encryptedDeliveryContext`, decryption failure, and an incomplete delivery context.
7. JWE round-trip: a context encrypted with RSA-OAEP-256 + A256GCM decrypts to the expected
   `nonce` / `phoneNumber` / `message`, and the response echoes the `nonce`.
8. `Evaluation` mode → 200 + nonce echo, nothing sent.
9. Privacy: OTP code and phone never in logs or response body.
