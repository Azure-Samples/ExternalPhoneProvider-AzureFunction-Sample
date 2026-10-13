# BYOT integration: the SAS request and response

This guide describes the interface between **SAS (Strong Authentication Service)** and your
**External Phone Provider (EPP)** endpoint. In a BYOT integration, your team implements and
operates the connection to its chosen phone service. SAS supplies the destination and rendered
one-time passcode message; your endpoint authenticates the caller, decrypts the delivery context,
and acknowledges the request according to its mode.

The steps below cover that inbound interface, not a phone-service adapter or a guided setup
extension. The [full contract](CONTRACT.md) contains detailed validation, outcome, configuration,
and runtime behavior.

## 1. Establish caller authentication

Before deploying, have your tenant administrator confirm eligibility, the authorized testing
route, and activation with Microsoft through the
[supported onboarding process](ONBOARDING.md#before-purchasing-or-deploying).
Deploying an endpoint does not enable tenant policy, and this repository supplies neither a
self-service token-acquisition tool for the Microsoft caller nor a public policy-activation API.

SAS calls **`POST /api/SendOtp` over HTTPS**, with a signed Entra bearer access token in
`Authorization`. In this sample, Azure App Service Authentication (**Easy Auth**) validates and
authorizes that token **before** the Function runs. The Functions trigger is anonymous; the
handler has no backup token validator, function-key gate, or application-role check.

Configure Easy Auth to require authentication and HTTPS, return `401` for unauthenticated
requests, and permit no authentication bypass for the endpoint. Pin the trusted tenant issuer,
the endpoint application's audience, and a nonempty `allowedApplications` allowlist containing
the authorized SAS caller application ID. A valid token for another audience or caller is not
sufficient. See the exact settings in the
[manual deployment trust checklist](ONBOARDING.md#manual-deployment-trust-checklist).

Use the dedicated endpoint app registration and your approved deployment configuration for the
exact values. The [setup trust configuration](../setup/support/Epp.Setup.psm1) supplies the
Microsoft caller application ID and verifies the deployed Easy Auth settings; it is **not** your
endpoint app's client ID. Setup follows the app's requested access-token version: v1 uses the
Application ID URI audience and tenant-specific v1 issuer; v2 uses the endpoint app client-ID
audience and tenant-specific v2 issuer. Read back **Function App > Authentication** with your
Azure operator rather than guessing values or trusting `EPP_EXPECTED_*` app-setting metadata.
Keep `tokenEncryptionKeyId` unset: the bearer token is signed, not encrypted.

Keep these three mechanisms separate:

| Mechanism | Purpose |
| --- | --- |
| Inbound bearer authentication | Establishes that the authorized SAS caller may invoke this endpoint. |
| JSON Web Encryption (JWE) | Protects the delivery context in transit to the endpoint; the endpoint decrypts it with its private key. |
| Outbound service authentication | Authorizes your customer-owned integration to send through your chosen service. Never forward SAS's bearer token. |

Neither envelope `tenantId`, a nonce, tracing headers, nor forwarded `x-ms-client-principal`
headers authenticate SAS. Anyone possessing the public encryption key can create a JWE.
Local Functions Core Tools has no Easy Auth: keep local tests loopback-only, without tunnels,
and use test keys and fake service responses.

## 2. Read the SAS envelope

The request body is a JSON object. Use the following field names and portable value forms:

| Field | Required | Type and meaning |
| --- | --- | --- |
| `type` | Yes | String, exactly `microsoft.mfa.otpDeliver.v1`. Other versions are unsupported. |
| `tenantId` | No | String containing opaque routing metadata. It does not select the issuer, keys, or outbound service. |
| `correlationId` | No | String for sign-in tracing. Supply a nonempty value when present. |
| `channel` | Yes | Integer `1` or string `"sms"`; integer `2` or string `"voice"`. Names are case-insensitive. |
| `mode` | Yes | Integer `1` or string `"live"`; integer `2` or string `"evaluation"`. Names are case-insensitive. |
| `ttlSeconds` | No | Positive JSON integer up to `2147483647`. Omit if absent; do not send null, a string, boolean, fraction, or nonpositive value. Use integer notation such as `60`, not `60.0` or `6e1`. |
| `encryptedDeliveryContext` | Yes | Nonblank string containing the compact JWE described below. |

The handler validates the envelope before decryption. **TTL validation is only a value check**:
it does not check passcode age, expire a queued message, or establish a delivery deadline.
Use these portable forms rather than relying on a parser's extra accepted values; see
[runtime binding differences](CONTRACT.md#runtime-binding-differences).

`x-ms-correlation-id` is the fallback tracing header when the body has no correlation ID;
if neither is available, the handler uses a generated request ID. `x-ms-client-request-id` identifies the attempt
and supplies the internal delivery `messageId`, with a generated fallback. Neither header is an
idempotency key in this sample. Header sanitization and empty-value handling differ by runtime;
see the [correlation details](CONTRACT.md#runtime-binding-differences).

## 3. Decrypt and validate the delivery context

Accept only **`alg: RSA-OAEP-256`** for key wrapping and **`enc: A256GCM`** for content encryption.
The compact JWE must contain exactly five nonempty segments and be no longer than **16,384
characters**. Use a JOSE library to authenticate and decrypt the original compact value, including
its original protected-header bytes; never use plaintext before the AES-GCM authentication tag
has been verified. Parse the decrypted UTF-8 JSON as a delivery-context object.

The sample uses one configured RSA private key in `EPP_DECRYPTION_KEY_PEM`, accepting a PEM
private key or certificate bundle containing it, either as text or base64-encoded PEM. In Azure,
use a managed-identity-resolved Key Vault secret reference, not private-key text in shared
settings. The corresponding public encryption credential belongs to the endpoint app registration.
The sample decrypts in-process, not through a vault cryptographic operation.

The protected header's `kid` identifies the encryption credential. In this sample,
`EPP_ENCRYPTION_KEY_ID` is only an optional advisory comparison after successful decryption:
a mismatch produces a warning, not rejection or selection of a different key. Guided setup pins
one certificate's backing-secret version and keeps one approved encryption credential on the app.
Assign a renewal owner: Key Vault renewal alone updates neither the registration nor the pinned
reference, and overlapping decryption keys are not implemented. Follow the
[certificate lifecycle](../setup/docs/README.md#encryption-certificate-lifecycle).

| Decrypted field | Required | Type and handling |
| --- | --- | --- |
| `nonce` | Yes | Nonblank string. Preserve it exactly for the response rules in step 5; it is not a credential or replay protection. |
| `phoneNumber` | Yes | Nonblank string, expected in E.164 form. The sample does not fully validate E.164 numbers. |
| `message` | Yes | Nonblank string: the fully rendered, localized message containing the passcode. Preserve the supplied message and code; do not generate a replacement code. |
| `locale` | No | String when supplied, for voice selection where supported. The sample has no shared locale catalog or validation. |
| `extension` | No | Office-voice field; no shared type validation or forwarding to the outbound delivery model is implemented. |
| `riskContext` | No | Contextual JSON data with no shared schema validation or risk-policy evaluation. Not forwarded by the shared delivery model. |
| `textToVoice` | No | Legacy structured speech data. The current shared delivery models do not carry it; no portable schema is defined here. |

Only `nonce`, `phoneNumber`, and `message` are required for a complete delivery context.
Do not infer support for optional fields just because they can appear in the decrypted JSON.
Runtime binding can reject wrong types before the completeness check; the
[full contract](CONTRACT.md#runtime-binding-differences) describes those differences.

## 4. Complete the customer-owned service integration

**This is the customer-owned boundary.** Your team must implement and maintain the outbound
integration; this guide intentionally supplies no adapter recipe or vendor API instructions.
For a valid **live** request:

1. Map the requested SMS or voice delivery to your service, preserving the supplied destination,
   message, and passcode. Decide and validate any required voice rendering and locale handling.
2. Authenticate outbound using your chosen integration and securely managed credentials,
   independently of inbound SAS authentication and the JWE key.
3. Determine recognized acceptance or failure from the service response. Unknown, incomplete,
   or unmapped responses must fail closed; a success-looking body on a failed HTTP response is
   not acceptance.
4. Return that result through the shared endpoint response behavior below. Do not expose raw
   service responses or reply with the nonce before acceptance.

The sample selects one configured service per deployment; request metadata does not choose one.
Adding a custom integration does not add guided setup support. Use the
[JavaScript](../javascript/README.md#source-and-extension-points),
[C#](../dotnet/README.md#source), or [Python](../python/README.md#source) source guide only when
you are ready to build and package your implementation.

## 5. Respond to SAS

**Evaluation:** after caller authentication, envelope validation, decryption, and required-field
checks, return `200` without delivering anything. Skip service selection, credential lookup, and
outbound HTTP on this request path. No service configuration is required. Independently, a worker
with a configured service and caching enabled may prepare credentials at startup or refresh them;
that is not message delivery.

**Live:** wait for recognized service acceptance, then return `200`. Do not acknowledge early
and deliver in the background. A queued or pending status counts only when your integration
recognizes it as acceptance; acceptance does **not** prove handset receipt.

For either successful path, the JSON response has exactly these fields:

| Field | Wire value |
| --- | --- |
| `nonce` | The decrypted request's original nonce string. |
| `correlationId` | The selected correlation string: body value, header fallback, or generated request ID, subject to the runtime differences linked above. |
| `providerStatus` | The literal string `"accepted"`, including for evaluation. |

SAS treats a `2xx` response **with a matching nonce** as handled; this sample returns `200`.
A mismatched nonce, non-`2xx` response, or timeout causes SAS to fall back to native delivery.
Never echo the nonce on a failure or include an accepted status.

Handler errors use JSON fields `error` and generated `requestId`, with a fixed `reason` for
validation errors and `correlationId` where available after envelope processing. The public
error values are `bad_request`, `decryption_failed`, `provider_delivery_failed`, or
`delivery_failed`; do not include raw exceptions, cryptographic details, or service responses.
Platform authentication failures and .NET host-binding failures occur before this handler
response path and need not use its JSON shape. See the
[full error and binding reference](CONTRACT.md#epp-response-json).

The shared outcome mapping is `Continue` to `200`, `Block` to `403`, and `Fail` to `429`
for service throttling, `401` for service authentication rejection, `400` for other service
4xx responses, or `502` otherwise. Detected outbound timeouts return `504`; non-timeout
network failures return `502`. Handler validation/decryption failures return `400`, and unexpected handler
failures generally return `500`. These are endpoint statuses, not a verbatim relay of service
HTTP status. Use the [complete mapping](CONTRACT.md#2-outcome--http-status-mapping) for details.

<a id="step-7-check-endpoints-timeouts-and-privacy"></a>

## 6. Validate before activation

Arrange [authorized endpoint checks](ONBOARDING.md#validate-the-deployed-endpoint) for caller
rejection, evaluation without a send, invalid/tampered payloads, and controlled live requests
on each intended channel. Verify acceptance and actual handset receipt or voice audio separately.
Only then use the administrator/Microsoft-approved activation procedure.

Plan for failures without assuming guarantees the sample does not provide. Its outbound HTTP
timeout defaults to 1500 ms and is capped at 2500 ms; this is **not** a whole-request deadline,
and Python uses connect/read inactivity timeouts. TTL does not enforce expiry. There is no
durable queue, automatic send retry, or deduplication. A timed-out request may already have
been accepted, so blind retries or caller fallback can duplicate delivery.

Never log passcodes, nonce values, messages, full phone numbers, tokens, keys, JWE contents, or
raw service responses. Disable body tracing at the platform and proxy as well as in application
code. Your team must address the remaining
[production limitations](CONTRACT.md#production-limitations), including input validation,
timing, key renewal, and operational monitoring, before relying on this sample in production.
