# Send OTP API

[Documentation](README.md) | [Technical reference](../TECHNICAL.md) | [Application logs](LOGGING.md)

Receive an encrypted SMS or voice request from Microsoft Entra ID.

| Property | Value |
| --- | --- |
| Method | `POST` |
| Path | `/api/SendOtp` |
| Authentication | Microsoft Entra ID bearer token, validated by Easy Auth |
| Content type | `application/json` |

> [!IMPORTANT]
> Easy Auth must validate the approved Microsoft caller before the Function runs.
> Encryption protects the request data; it does not authenticate the caller.

## Authentication

Configure HTTPS, the trusted tenant issuer, endpoint application audience, and approved Microsoft
caller allowlist. Unauthenticated requests return `401`.
See the [Easy Auth checklist](ONBOARDING.md#manual-deployment-trust-checklist).

<a id="1-http-api"></a>
## HTTP request

```http
POST https://<function-host>/api/SendOtp
Content-Type: application/json
Authorization: Bearer <access-token>
```

### Request headers

| Header | Value |
| --- | --- |
| `Authorization` | Bearer token consumed by Easy Auth |
| `Content-Type` | `application/json` |
| `x-ms-correlation-id` | Optional correlation value |
| `x-ms-client-request-id` | Optional request identifier |

The provider request uses a separate OAuth token.

### Request body

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
| `type` | Yes | `microsoft.mfa.otpDeliver.v1` |
| `channel` | Yes | `1` or `"sms"` for SMS; `2` or `"voice"` for voice |
| `mode` | Yes | `1` or `"live"` to send; `2` or `"evaluation"` for no-send validation |
| `encryptedDeliveryContext` | Yes | Compact JWE containing the delivery data |
| `tenantId` | No | Tenant metadata; provider selection comes from deployment configuration |
| `correlationId` | No | Correlation value, preferred over the header when present |
| `ttlSeconds` | No | Positive integer up to `2147483647`; validated as request metadata, not enforced as a delivery deadline |

Use JSON integers for numeric values. See
[runtime validation details](../TECHNICAL.md#request-validation-and-runtime-differences).

### Encrypted delivery context

The JWE uses `RSA-OAEP-256` and `A256GCM`. After decryption:

```json
{
  "nonce": "<nonce>",
  "phoneNumber": "+15551234567",
  "message": "Your verification code is 012345.",
  "otp": "012345",
  "locale": "en-US",
  "riskContext": {
    "scenario": "sign-in",
    "ipAddress": "203.0.113.10"
  }
}
```

The values above are illustrative.

| Field | Required | Description |
| --- | --- | --- |
| `nonce` | Yes | Nonblank string returned unchanged after evaluation or provider acceptance |
| `phoneNumber` | Yes | Nonblank recipient number; use E.164 format for provider delivery |
| `message` | Yes | Nonblank localized message containing the passcode |
| `otp` | No | Separate passcode string; leading zeros are preserved |
| `extension` | No | Separate voice extension string; supported by the JavaScript Twilio adapter as described below |
| `locale` | No | Message or voice locale used by the adapter |
| `riskContext` | No | Risk-signal object or `null` |

`otp` can be omitted or `null`. `riskContext.scenario` and `riskContext.ipAddress` are optional
strings or `null`. Telesign forwards these two fields to its API unchanged; use values accepted
by the provider. See [provider mapping](../TECHNICAL.md#built-in-providers).

### Twilio voice extensions (JavaScript)

For Twilio voice delivery, keep `phoneNumber` in E.164 format and supply the extension separately
inside the encrypted delivery context, for example `"extension": "00123"`. The adapter forwards
it unchanged as the Verify API's
[`SendDigits`](https://www.twilio.com/docs/verify/api/verification) parameter for `Channel=call`.
Leading zeros are preserved; an extension must not be appended to `phoneNumber`.

Supported characters are `0`-`9`, `A`-`D`, `*`, `#`, `w`, and `W`. Lowercase `w` introduces a
0.5-second pause and uppercase `W` a one-second pause, following
[Twilio's sendDigits rules](https://www.twilio.com/docs/voice/twiml/number#attributes-senddigits).
For example, `"extension": "ww00123#"` waits one second before dialing `00123#`.
The adapter does not add pauses automatically; timing depends on the destination PBX.

Omitted, `null`, or empty extensions do not send `SendDigits`. Invalid nonempty values fail live
Twilio voice request building with `502` and `provider_delivery_failed`, without calling Twilio.
SMS and the other adapters ignore `extension`. Evaluation remains no-send and does not validate
Twilio-specific extension rules. Extension values must stay out of logs and public responses.

Keep decrypted fields and encrypted payloads out of logs.
See [JWE validation](../TECHNICAL.md#jwe-validation-and-key-handling) for key handling and limits.

<a id="evaluation-no-provider-send"></a>
## Modes

- **Evaluation:** validates the envelope and decryption, then returns the nonce before provider work.
- **Live:** sends through the configured provider and returns success after recognized acceptance.

Easy Auth validates the caller before either mode runs. Evaluation tests the endpoint path;
controlled live tests verify provider authorization and delivery.

## Success response

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
| `nonce` | Original decrypted nonce |
| `correlationId` | Selected request correlation value or generated request ID |
| `providerStatus` | `"accepted"` for evaluation or live acceptance |

Live acceptance is not confirmation of recipient delivery.

## HTTP status codes

| Status | Meaning |
| --- | --- |
| `200 OK` | Evaluation completed or the provider accepted the request |
| `400 Bad Request` | Invalid request or encrypted content, missing/unrecognized provider selection, or provider `4xx` other than throttling |
| `401 Unauthorized` | Inbound caller authentication failed |
| `403 Forbidden` | Inbound caller authorization or platform access denied |
| `422 Unprocessable Entity` | Explicit provider risk or policy block |
| `429 Too Many Requests` | Provider throttling |
| `500 Internal Server Error` | Unexpected handler failure |
| `502 Bad Gateway` | Provider configuration, credential acquisition, network, or response-processing failure |
| `504 Gateway Timeout` | Provider request timed out |

Provider HTTP `401` and `403` map to endpoint `400`; investigate outbound provider authorization,
not the inbound caller policy. Check a timed-out live request before retrying because the
provider might already have accepted it.

### Provider blocks

A recognized provider block, such as Telesign `3072` or Soprano `BLOCKED`, maps to endpoint
`422` with `error: "provider_blocked"`. Failed and blocked responses omit `nonce` and
`providerStatus`.

This response describes the sample's attempt. Microsoft Entra ID routing and fallback behavior
are governed by the tenant's authentication configuration.

## Error response

```json
{
  "error": "provider_delivery_failed",
  "requestId": "<request ID>",
  "correlationId": "<correlation ID>"
}
```

| Error | Meaning |
| --- | --- |
| `bad_request` | Invalid request data or incomplete decrypted context |
| `decryption_failed` | Encrypted content could not be decrypted or parsed |
| `provider_delivery_failed` | Provider selection, configuration, credential, transport, or response failure |
| `provider_blocked` | Explicit provider risk or policy block |
| `delivery_failed` | Unexpected handler failure |

Errors include a generated `requestId`. A `correlationId` and safe validation `reason` are included
when available. Easy Auth and C# input-binding failures occur before the handler and can have a
different response format.

For credential acquisition failures, use the correlated application events:
`request_failed`, stage `provider_credentials`, reason `credential_unavailable`, and status `502`.
See [credential diagnostics](LOGGING.md#credential-diagnostics) and
[troubleshooting](../setup/docs/Troubleshooting.md#provider-credential-acquisition-fails).
