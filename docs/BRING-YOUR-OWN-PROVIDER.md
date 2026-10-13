# BYOT integration: the SAS request and response

**SAS (Strong Authentication Service)** sends your **External Phone Provider (EPP)** endpoint
an encrypted phone number and one-time passcode message. Your endpoint verifies the caller,
decrypts the details, and either evaluates the request without sending or uses your phone service.
It then responds to SAS. **Your team owns the connection to that service.**

Before deploying, ask your tenant administrator to confirm
[eligibility, testing, and activation with Microsoft](ONBOARDING.md#before-purchasing-or-deploying).
Deploying the endpoint alone does not enable tenant policy.

<a id="1-establish-caller-authentication"></a>

## 1. Verify the caller

SAS sends **`POST /api/SendOtp` over HTTPS**, with a signed Entra bearer token in `Authorization`.
In this sample, **Easy Auth** (Azure App Service Authentication) checks the token and authorizes
the caller before the Function runs. The Function's trigger is anonymous and has no backup
authentication check, so do not expose it with Easy Auth disabled or bypassed.

Require HTTPS and authentication, return `401` for unauthenticated requests, and restrict access
to the trusted tenant issuer, endpoint-app audience, and authorized SAS caller application ID.
Your Azure operator should use the endpoint app registration and
[approved setup configuration](../setup/support/Epp.Setup.psm1) for these values, then verify
**Function App > Authentication**. Follow the
[trust checklist](ONBOARDING.md#manual-deployment-trust-checklist) for exact settings,
caller-ID guidance, and token-version details.

**Encryption is not caller authentication.** Anyone with the public key can create a JWE
(JSON Web Encryption) payload. Neither its nonce, the body's `tenantId`, nor tracing or
forwarded principal headers prove that SAS sent it.

<a id="2-read-the-sas-envelope"></a>

## 2. Read and decrypt the request

The JSON body is an envelope with these fields. Use the forms below across all sample runtimes:

| Field | Required | Value |
| --- | --- | --- |
| `type` | Yes | String, exactly `microsoft.mfa.otpDeliver.v1`. |
| `channel` | Yes | Integer `1` or string `"sms"`; integer `2` or string `"voice"`. |
| `mode` | Yes | Integer `1` or string `"live"`; integer `2` or string `"evaluation"`. |
| `encryptedDeliveryContext` | Yes | Nonblank string containing the compact JWE. |
| `tenantId` | No | String containing routing metadata, not a source of trust or service selection. |
| `correlationId` | No | Nonempty string for sign-in tracing. |
| `ttlSeconds` | No | Positive JSON integer up to `2147483647`, or omit it. Use `60`, not `"60"`, `60.0`, `6e1`, or null. |

Channel and mode names are case-insensitive. Reject unsupported versions, channels, or modes.
TTL is only checked as a number; it does not enforce passcode expiry or a delivery deadline.

<a id="3-decrypt-and-validate-the-delivery-context"></a>

Decrypt `encryptedDeliveryContext` using only **`RSA-OAEP-256`** for key wrapping and **`A256GCM`**
for content encryption. Accept exactly five nonempty compact-JWE segments, at most **16,384
characters**. Pass the original JWE, including its protected-header bytes, to a JOSE library.
Verify the authentication tag before using the decrypted UTF-8 JSON.

The sample decrypts in-process with one RSA private key in `EPP_DECRYPTION_KEY_PEM`: a PEM key
or certificate bundle containing it, as text or base64-encoded PEM. In Azure, use a
managed-identity-resolved Key Vault secret reference. The matching public encryption credential
belongs to the endpoint app registration.

The header's `kid` does not select a key in this sample. `EPP_ENCRYPTION_KEY_ID` only enables
a warning on mismatch after successful decryption. Setup pins one certificate's secret version;
renewal needs coordination because Key Vault renewal alone does not update the app registration
or pinned reference. See the [certificate lifecycle](../setup/docs/README.md#encryption-certificate-lifecycle).

The decrypted delivery context contains:

| Field | Required | Value and handling |
| --- | --- | --- |
| `nonce` | Yes | Nonblank string. Keep it unchanged for the response. It is not replay protection. |
| `phoneNumber` | Yes | Nonblank string, expected in E.164 form. Full E.164 validation is not implemented. |
| `message` | Yes | Nonblank string containing the localized message and passcode. Preserve them; do not generate a new code. |
| `locale` | No | String for voice selection where supported; no shared locale validation. |
| `extension` | No | Office-voice data; no shared type validation or forwarding. |
| `riskContext` | No | Contextual JSON data; no shared schema validation, risk evaluation, or forwarding. |
| `textToVoice` | No | Legacy speech data; no portable schema or shared forwarding. |

Do not assume an optional field is supported just because it appears in the request.
For parser and wrong-type handling, see [runtime binding differences](CONTRACT.md#runtime-binding-differences).

<a id="4-complete-the-customer-owned-service-integration"></a>

## 3. Evaluate or send

**Evaluation (`mode: 2` or `"evaluation"`):** authenticate, validate, and decrypt, then return
the success response below **without sending anything**. This request path skips service
selection, credential lookup, and outbound HTTP; no service configuration is needed.
Configured workers may independently prepare or refresh credentials, but that does not send a message.

**Live (`mode: 1` or `"live"`):** your team implements and maintains the service integration.
Map the requested SMS or voice delivery to your service, preserving the destination, message,
and passcode. Handle voice rendering and locales as needed. Authenticate with your own service
credentials; **never forward SAS's bearer token**.

Wait for recognized acceptance before returning success. A queued or pending result counts
only if your integration recognizes it as acceptance. Unknown or incomplete responses must fail,
and a success-looking body on a failed HTTP response is not acceptance. Return the result through
the shared response behavior below, not as raw service JSON.

The sample uses one configured service per deployment. A custom integration does not add
guided setup support; use the [runtime source guides](../TECHNICAL.md) when building your package.

<a id="5-respond-to-sas"></a>

## 4. Respond to SAS

Return **HTTP `200` with a JSON object containing exactly these fields** after a successful
evaluation or recognized live acceptance:

| Field | Value |
| --- | --- |
| `nonce` | The original decrypted nonce string. |
| `correlationId` | The request body's correlation string, then `x-ms-correlation-id` as fallback, then a generated request ID. |
| `providerStatus` | The literal string `"accepted"`, also used for evaluation. |

Correlation header sanitization and empty-value handling differ by runtime; see the
[binding reference](CONTRACT.md#runtime-binding-differences). `x-ms-client-request-id` supplies
the internal attempt `messageId`, with a generated fallback. These IDs do not provide deduplication.

**For live requests, echo the nonce only after acceptance, not before sending.**
Acceptance is not proof of handset receipt. SAS treats a `2xx` response with a matching nonce
as handled; a mismatched nonce, non-`2xx` response, or timeout causes SAS to fall back to native delivery.

On failure, omit both the nonce and accepted status. Handler errors contain `error` and a
generated `requestId`, plus a fixed `reason` for validation errors and `correlationId` where
available. Do not return raw exceptions or service responses. Authentication and host-binding
errors can occur before the handler and need not use this JSON shape. Use the
[error reference](CONTRACT.md#epp-response-json) and
[HTTP status mapping](CONTRACT.md#2-outcome--http-status-mapping) for the exact failure response.

<a id="step-7-check-endpoints-timeouts-and-privacy"></a>
<a id="6-validate-before-activation"></a>

## Before activation

Run [authorized endpoint checks](ONBOARDING.md#validate-the-deployed-endpoint): rejected callers,
invalid or tampered payloads, evaluation without a send, and controlled live tests for each channel.
Check handset receipt or voice audio separately from acceptance. For local tests, use test keys
and fake service responses on loopback only, without tunnels; Core Tools has no Easy Auth.

The sample has **no early acknowledgement/background delivery, durable queue, automatic send
retry, or deduplication**. Its outbound timeout is not a whole-request deadline. A timed-out send
may already have been accepted, so retries or caller fallback can cause duplicates.

Keep phone numbers, messages, passcodes, nonces, tokens, keys, JWE contents, and raw service
responses out of logs. Disable body tracing in the application, platform, and proxies.
Review the remaining [production limitations](CONTRACT.md#production-limitations) before activation.
