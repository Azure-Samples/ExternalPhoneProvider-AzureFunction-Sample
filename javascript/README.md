# External Phone Provider — Azure Function (delivery endpoint)

An Azure Function (Node.js) that receives an OTP dispatch request and forwards it to a telephony
provider (**Infobip**, **Telesign**, **Sinch**, or **Soprano**).

## What it does

- `POST /api/SendOtp` — dispatches the OTP to the selected provider and returns an accepted/failed result.
- Provider secrets from **Azure Key Vault** (managed identity).
- **Correlation id** propagated to the provider and echoed back.
- **Shutter mode** — process the full path but do not send.
- **Token validation** — Easy Auth is the primary gate; `EPP_REQUIRE_AUTH=true` adds an in-process backstop.

> **Turn Easy Auth ON.** The trigger is `authLevel: anonymous`, so App Service Authentication
> (`unauthenticatedClientAction=Return401`, `allowedApplications` pinned to Microsoft's app) is what
> keeps the endpoint closed. Set **`EPP_REQUIRE_AUTH=true`** as well in any real deployment — it is the
> backstop if Easy Auth is ever misconfigured, and the only gate when running locally.

## Deploy

1. **Create the Key Vault** and add what the Function reads:
   - the provider **API key/token** as a **secret** (default name `infobip-api-key` — see [Configuration](#configuration)).
2. **Grant the Function's managed identity** on that vault: **Key Vault Secrets User**.
3. **Set the app settings** — copy [`../docs/local.settings.sample.json`](../docs/local.settings.sample.json) into `src/local.settings.json` locally; in Azure set them under **Function App → Settings → Environment variables**. At minimum set `EPP_DECRYPTION_KEY_PEM`, `EPP_PROVIDER_NAME`, and `EPP_PROVIDER_ENDPOINT`; see [Configuration](#configuration) for the full list.
4. **Publish:**

```bash
cd src
npm install
func azure functionapp publish <your-function-app-name>
```

## Configuration

The endpoint is **plug-and-play by provider**. The **shared infrastructure** — token validation, dispatch,
response normalization, message templating, and
logging — is identical for every provider and needs no per-provider code. You **choose one provider**;
the only provider-specific parts are its **adapter** (the outbound API call) and the **few settings** below.

> A new provider is onboarded by dropping in a single file `providers/<id>.js` that exports its
> `manifest` (built-in defaults: endpoints, channels, auth, responseMapping) plus `buildRequest` /
> `parseResponse` — no change to the shared pipeline.

> **Provisioning model.** The provider's authoritative parameters live in its **Security Store package
> manifest**. At provisioning time, UX reads that manifest and sets the operational values as **app
> settings (env properties)** on the Function — the endpoint URL (`EPP_PROVIDER_ENDPOINT`), sender/source
> id (`EPP_PROVIDER_ACCOUNT_NAME`), `EPP_PROVIDER_TIMEOUT_MS`, and the Key Vault secret references. The values baked
> into `providers/<id>.js` are just **local-dev defaults**; the app settings win. Only the **adapter
> code** (`buildRequest`/`parseResponse`) is provider-specific code — everything else is data.

Provider secrets are read from **Key Vault** by name via the Function's managed identity. Set
`KEY_VAULT_URL` to the vault URI. Each provider's secret name is fixed in its manifest
(`infobip-api-key` / `telesign-api-key` / `sinch-api-token` / `soprano-api-key`); the value lives in
Key Vault and can be rotated there without a redeploy.

### Shared settings (always)

| Key | Purpose |
|-----|---------|
| `EPP_PROVIDER_NAME` | your chosen provider: `infobip` \| `telesign` \| `sinch` \| `soprano` |
| `EPP_PROVIDER_ENDPOINT` | provider base URL (one provider is active per deployment) |
| `EPP_PROVIDER_ACCOUNT_NAME` | sender / source id presented to the provider |
| `EPP_PROVIDER_TIMEOUT_MS` | outbound provider-call timeout in ms (default `1500`) |
| `EPP_DECRYPTION_KEY_PEM` | RSA private key PEM for JWE decryption — a **Key Vault reference** in Azure |
| `EPP_ENCRYPTION_KEY_ID` | expected JOSE `kid`; a mismatch is logged, not fatal |
| `EPP_EXPECTED_CLIENT_ID` | caller `appid`/`azp` to admit; Easy Auth returns `403`, in-process validation returns `401` |
| `EPP_REQUIRE_AUTH` | **set `true` in any real deployment** — validates the token in-process as a backstop to Easy Auth |
| `EPP_EXPECTED_AUDIENCE` | token `aud` (this endpoint's app registration appId) — required when `EPP_REQUIRE_AUTH=true` |
| `EPP_TENANT_ID` | customer tenant id for issuer/JWKS — required when `EPP_REQUIRE_AUTH=true` |
| `EPP_EXPECTED_ISSUER` | optional; pins a single issuer instead of accepting both v1 and v2 |
| `EPP_LOG_PLAINTEXT` | **diagnostics only** — `true` writes the phone number and passcode to the log. Never enable in production |
| `KEY_VAULT_URL` | Key Vault URI (provider API keys) |

### Per-provider settings (set only for the provider you chose)

Set `EPP_PROVIDER_NAME` to your provider, then provision **only that block** — its **Key Vault secret**
(the API key/token — the *only* secret) plus the shared `EPP_PROVIDER_ENDPOINT` /
`EPP_PROVIDER_ACCOUNT_NAME`. Endpoints, sender ids, `KEY_VAULT_URL`, and the Key Vault secret **names**
are all non-secret configuration; only the key/token **value** lives in Key Vault.

**Infobip**
| Setting | Purpose |
|---------|---------|
| Key Vault secret `infobip-api-key` | API key |
| `INFOBIP_SENDER_ID` → `EPP_PROVIDER_ACCOUNT_NAME` | registered sender, app setting (default `Verify`) |

**Telesign**
| Setting | Purpose |
|---------|---------|
| Key Vault secret `telesign-api-key` | API key |
| Key Vault secret `telesign-customer-id` | customer id (the Basic-auth username) |
| `TELESIGN_SENDER_ID` → `EPP_PROVIDER_ACCOUNT_NAME` | sender id, app setting (optional) |
| `TELESIGN_VOICE` | voice language/voice code for voice OTP, app setting (optional; default `f-en-US`) |

**Sinch**
| Setting | Purpose |
|---------|---------|
| Key Vault secret `sinch-api-token` | API token |
| `SINCH_SERVICE_PLAN_ID` | XMS service plan id, app setting |
| `SINCH_SENDER_ID` → `EPP_PROVIDER_ACCOUNT_NAME` | sender, app setting (default `Verify`) |
| `SINCH_VOICE_ENDPOINT` | Sinch Voice API host, app setting (optional; default `https://calling.api.sinch.com`) |

**Soprano**
| Setting | Purpose |
|---------|---------|
| Key Vault secret `soprano-api-key` | API key (sent as the `X-MEMS-API-Key` header) |
| Key Vault secret `soprano-api-id` | API ID (sent as the `X-MEMS-API-ID` header) |
| `EPP_PROVIDER_ENDPOINT` | **required** — your MEMS API base `https://<your-mems-domain>/cgpapi` (per-customer; no default) |
| `EPP_PROVIDER_ACCOUNT_NAME` | the provisioned source/sender endpoint id — Soprano requires a provisioned sender, so a **numeric** value is sent as `endpoints:[{type,id}]`; a non-numeric one falls back to a free-text `source` |
| `SOPRANO_SOURCE_TYPE` | provisioned source endpoint type, app setting (optional; default `1`) |

> `EPP_PROVIDER_ENDPOINT` is the provider base URL for the one active provider (e.g. a sandbox host).

### Identity & permissions (managed identity — no static credentials)

The Function authenticates to Key Vault (and any other Azure resource) with its **managed identity** (user-assigned when `AZURE_CLIENT_ID` is set, else system-assigned) — there are **no secrets, keys, or connection strings in code or config**. Grant it **least-privilege** access on the customer's vault:

| Scope | Role | Why |
|-------|------|-----|
| The provider **secret** (or the vault) | **Key Vault Secrets User** | `get` the provider API key/token |

Also use an **identity-based** `AzureWebJobsStorage` connection (managed identity) instead of a storage connection string, so the runtime holds no static secret either. All resource **names** (`KEY_VAULT_URL`, `EPP_EXPECTED_AUDIENCE`, `EPP_TENANT_ID`) come from app settings — nothing is hard-coded.

### Add your own provider

Onboarding a provider is **one file** — `src/functions/providers/<id>.js` — with no change to the shared pipeline. Copy an existing provider (e.g. [infobip.js](src/functions/providers/infobip.js)) and export three things:

```js
// 1) manifest — the provider's protocol facts the engine reads
const manifest = {
  id: 'acme',                                    // provider id (used as the `Provider` value); the URL
                                                 // app setting is `<ID>_ENDPOINT`, e.g. ACME_ENDPOINT
  auth: { mode: 'apiKey', keyVaultSecretName: 'acme-api-key' },
  responseMapping: { SENT: 'Continue', FAILED: 'Fail', default: 'Fail' }, // provider status → outcome
};

// 2) buildRequest — shape the outbound HTTP call
function buildRequest({ channel, endpoint, dispatch, credential, env }) {
  return {
    url: `${endpoint}/messages`,
    method: 'POST',
    headers: { Authorization: `Bearer ${credential.secret}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ to: dispatch.destination, text: dispatch.message }),
  };
}

// 3) parseResponse — normalize the provider reply
function parseResponse({ httpStatus, ok, json }) {
  return {
    success: ok,
    providerHttpStatus: httpStatus,
    providerMessageId: (json && json.id) || null,
    providerStatusName: (json && json.status) || (ok ? 'SENT' : null),
    providerStatusDescription: (json && json.description) || null,
  };
}

module.exports = { manifest, buildRequest, parseResponse };
```

The engine handles the rest — provider resolution, Key Vault credential fetch (via managed identity), message templating, timeout, `responseMapping` → HTTP status, and fail-closed behavior. Drop the file in, add the Key Vault secret, set `EPP_PROVIDER_NAME=acme`, and it works.

## Request contract

`POST /api/SendOtp` — the SAS → External Phone Provider delivery endpoint. The cleartext body is a routing envelope; the
PII (phone + rendered message, which contains the passcode) is encrypted in a JWE. See
[../docs/CONTRACT.md](../docs/CONTRACT.md) for the full contract.

| Field | Required | Notes |
|-------|----------|-------|
| `type` | yes | envelope version, e.g. `microsoft.mfa.otpDeliver.v1` |
| `channel` | yes | `1`=Sms, `2`=Voice |
| `mode` | yes | `1`=Live, `2`=Evaluation (rehearsal — not delivered) |
| `encryptedDeliveryContext` | yes | JWE (RSA-OAEP-256 + A256GCM); decrypts to `{ nonce, phoneNumber, message, locale?, riskContext? }` |
| `tenantId`, `correlationId`, `ttlSeconds` | no | routing / tracing / passcode validity |

The active provider is deployment config (`EPP_PROVIDER_NAME`), not a request field. The response is the
`CyotEndpointResponse`: `{ "nonce": "<echo>", "correlationId": "<echo>", "providerStatus": "accepted" }`.
A `2xx` with a matching nonce means handled; non-2xx / nonce mismatch / timeout → SAS falls back to CAPP.

## Try it

The private RSA key that decrypts `encryptedDeliveryContext` is resolved from Key Vault by the JOSE `kid`
(`EPP_DECRYPTION_KEY_PEM`, a Key Vault reference). Build the envelope with the matching public key:

```bash
curl -X POST https://<your-function-app>.azurewebsites.net/api/SendOtp \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <Entra token>" \
  -H "x-ms-correlation-id: test-001" \
  -d '{
    "type": "microsoft.mfa.otpDeliver.v1",
    "tenantId": "<tenant-guid>",
    "correlationId": "test-001",
    "channel": 1,
    "mode": 1,
    "ttlSeconds": 60,
    "encryptedDeliveryContext": "<JWE compact serialization>"
  }'
# -> 200 { "nonce": "<echo>", "correlationId": "test-001", "providerStatus": "accepted" }
```

Evaluation mode (`"mode": 2`) runs everything except the actual send and still echoes the nonce.
