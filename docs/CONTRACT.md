# Send OTP

<a id="external-phone-provider-function-language-agnostic-contract"></a>
<a id="http-contract"></a>
<a id="send-otp-api"></a>

[Documentation](README.md) | [Technical details](../TECHNICAL.md) | [Add Twilio](BRING-YOUR-OWN-PROVIDER.md)

Receive an encrypted SMS or voice request from **Microsoft Entra ID**.

| | |
| --- | --- |
| **Method** | `POST` |
| **Path** | `/api/SendOtp` |
| **Authentication** | Easy Auth |
| **Content type** | `application/json` |

> [!IMPORTANT]
> Easy Auth must validate the approved Microsoft caller before the Function runs. The encrypted
> payload protects request data. It does not authenticate the caller.

## Authentication

Configure Easy Auth with:

- HTTPS required.
- Unauthenticated requests returned as `401`.
- The endpoint application audience.
- The trusted tenant issuer.
- A nonempty allowlist for the approved Microsoft caller.

See the [Easy Auth checklist](ONBOARDING.md#manual-deployment-trust-checklist).

## HTTP request

<a id="1-http-api"></a>

```http
POST https://<function-host>/api/SendOtp
Content-Type: application/json
Authorization: Bearer <access-token>
```

## Request headers

| Header | Value |
| --- | --- |
| `Authorization` | Required bearer token. Easy Auth consumes it. |
| `Content-Type` | Required. Use `application/json`. |
| `x-ms-correlation-id` | Optional correlation value. |
| `x-ms-client-request-id` | Optional request identifier. |

The Function does not forward the bearer token to the phone provider.

## Request body

<a id="epp-request-body-envelope-cleartext-envelope"></a>
<a id="epp-request-body"></a>

```json
{
  "type": "microsoft.mfa.otpDeliver.v1",
  "channel": 1,
  "mode": 1,
  "encryptedDeliveryContext": "<compact JWE>",
  "tenantId": "<tenant ID>",
  "correlationId": "<correlation ID>",
  "ttlSeconds": 30
}
```

| Field | Required | Description |
| --- | --- | --- |
| `type` | Yes | Use `microsoft.mfa.otpDeliver.v1`. |
| `channel` | Yes | `1` or `"sms"` for SMS. `2` or `"voice"` for voice. |
| `mode` | Yes | `1` or `"live"` to send. `2` or `"evaluation"` for no-send validation. |
| `encryptedDeliveryContext` | Yes | Compact JWE containing the delivery data. |
| `tenantId` | No | Routing metadata supplied by Microsoft Entra ID. |
| `correlationId` | No | Sign-in correlation value. |
| `ttlSeconds` | No | Positive integer up to `2147483647`. |

Send integer channel, mode, and TTL values in their documented forms for consistent behavior across
all runtimes. See [request validation and runtime differences](../TECHNICAL.md#request-validation-and-runtime-differences).

### Encrypted delivery context

<a id="encrypteddeliverycontext-jwe"></a>

The JWE uses `RSA-OAEP-256` and `A256GCM`. After decryption, the JSON contains:

```json
{
  "nonce": "<nonce>",
  "phoneNumber": "+15551234567",
  "message": "Your verification code is 012345.",
  "otp": "012345",
  "locale": "en-US",
  "riskContext": {
    "exampleSignal": "exampleValue"
  }
}
```

| Field | Required | Description |
| --- | --- | --- |
| `nonce` | Yes | Returned unchanged after evaluation or provider acceptance. |
| `phoneNumber` | Yes | Recipient phone number. |
| `message` | Yes | Localized message containing the passcode. |
| `otp` | No | Separate six-digit passcode. It remains a string so leading zeros are preserved. |
| `locale` | No | Voice locale. |
| `extension` | No | Office-voice data. |
| `riskContext` | No | JSON object containing extensible risk fields; may be `null`. |
| `textToVoice` | No | Legacy speech data. |

Microsoft Entra ID supplies `otp` for SMS and voice, with a generated test code in evaluation
mode. It belongs inside the encrypted delivery context, not the outer request body. Requests
that omit it or set it to `null` remain supported.

`riskContext` has no fixed field schema. Unknown keys, nested objects and arrays, and values such
as `false`, `0`, and `null` are preserved. Missing fields are not filled with defaults.
The shared handler does not interpret, log, return, or forward risk fields to the built-in
providers. A custom adapter must explicitly map any approved fields it needs.

See [JWE validation and key handling](../TECHNICAL.md#jwe-validation-and-key-handling) for limits,
algorithms, key settings, and runtime behavior.

## Modes

<a id="evaluation-no-provider-send"></a>
<a id="evaluation"></a>
<a id="live"></a>

- **Evaluation:** validates authentication, the envelope, and decryption. It returns the nonce
  without reading provider credentials or sending a message.
- **Live:** sends through the configured provider and returns success after recognized provider
  acceptance.

Provider acceptance is not proof of recipient delivery.

## Response

<a id="epp-response-json"></a>
<a id="success-response"></a>

If successful, the endpoint returns `200 OK`:

```http
HTTP/1.1 200 OK
Content-Type: application/json
```

```json
{
  "nonce": "<decrypted nonce>",
  "correlationId": "<correlation value>",
  "providerStatus": "accepted"
}
```

| Field | Description |
| --- | --- |
| `nonce` | Original decrypted nonce. |
| `correlationId` | Request correlation value or generated request ID. |
| `providerStatus` | `"accepted"` for evaluation or recognized live acceptance. |

Failures omit `nonce` and `providerStatus`.

## Error response

The Function returns JSON for application errors:

```json
{
  "error": "provider_delivery_failed",
  "requestId": "<request ID>",
  "correlationId": "<correlation ID>"
}
```

| Field | Description |
| --- | --- |
| `error` | Stable public error category. |
| `requestId` | Request identifier for safe log correlation. |
| `reason` | Validation detail when it is safe to return. Usually present only for `400` responses. |
| `correlationId` | Correlation value when available. |

Provider configuration, credentials, network failures, and provider response details use the
public `provider_delivery_failed` category. For example, unavailable provider credentials return
`502 Bad Gateway`; the safe diagnostic detail is recorded as
`failureStage=provider_credentials` and `failureReason=credential_unavailable` in application
logs, not exposed in the response.

### Diagnose a credential failure

A current-package credential failure follows this sequence:

| Signal | Meaning |
| --- | --- |
| `request_received` | The Function received the CYOT request. |
| `envelope_validated` or `payload_validated` | The outer request passed validation. |
| `delivery_context_decrypted` | The encrypted delivery context was decrypted. |
| `provider_selected` | The configured provider was selected. |
| `provider_credential_resolution_started` | The Function started resolving provider credentials. |
| `request_failed` with `failureStage=provider_credentials`, `failureReason=credential_unavailable`, and `httpStatus=502` | Credential resolution failed before the provider request started. |
| `response_prepared`, then `request_completed` with HTTP `502` | The Function returned `provider_delivery_failed`. |

This pattern points to provider authentication or credential configuration, not envelope validation,
decryption, or provider delivery. Check the selected provider's Key Vault secrets or OAuth managed
identity, federation, tenant, scope, and permissions.

Current packages resolve credentials during live requests and do not emit
`credential_refresh_failed`. If older deployments show that event, update the deployed package
before comparing event sequences.

Use `ResultCode`, `request_failed`, and `request_completed` together. If the platform request
`Success` value disagrees with `ResultCode=502`, treat the HTTP result and correlated application
events as the request outcome. See [provider credential acquisition fails](../setup/docs/Troubleshooting.md#provider-credential-acquisition-fails)
for corrective steps.

## HTTP status codes

<a id="2-outcome--http-status-mapping"></a>

| Status | Description |
| --- | --- |
| `200 OK` | Evaluation completed or the provider accepted the request. |
| `400 Bad Request` | Invalid request or encrypted content. |
| `401 Unauthorized` | Caller or provider authentication failed. |
| `403 Forbidden` | Caller access was denied or the provider blocked the request. |
| `429 Too Many Requests` | Provider throttling. |
| `500 Internal Server Error` | Unexpected Function failure. |
| `502 Bad Gateway` | Provider configuration, network, or response failure. |
| `504 Gateway Timeout` | Provider request timed out. |

Check a timed-out live request before retrying. The provider might already have accepted it.

## Related guidance

<a id="runtime-binding-differences"></a>
<a id="runtime-notes"></a>
<a id="3-provider-contract"></a>
<a id="provider-implementation"></a>
<a id="soprano-provider-jwt"></a>
<a id="telesign-epp-integration"></a>
<a id="4-configuration-app-settings--env"></a>
<a id="default-provider-and-configuration-readers"></a>
<a id="credential-caching-and-refresh"></a>
<a id="5-required-behaviors"></a>
<a id="application-logs"></a>
<a id="6-lightweight-tests"></a>
<a id="production-limitations"></a>
<a id="production-readiness-considerations"></a>
<a id="production-readiness"></a>
<a id="required-behavior"></a>

- [Technical implementation details](../TECHNICAL.md#http-implementation-details)
- [Built-in providers](../TECHNICAL.md#built-in-providers)
- [Add Twilio](BRING-YOUR-OWN-PROVIDER.md)
- [Application log reference](LOGGING.md)
- [Deployment validation](ONBOARDING.md#validate-the-deployed-endpoint)
