# Send OTP

<a id="external-phone-provider-function-language-agnostic-contract"></a>
<a id="http-contract"></a>
<a id="send-otp-api"></a>

[Documentation](README.md) | [Technical details](../TECHNICAL.md) | [Add Twilio](BRING-YOUR-OWN-PROVIDER.md)

This endpoint receives encrypted SMS or voice requests from **Microsoft Entra ID**.

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

Before testing the endpoint, configure Easy Auth with:

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

The Function never forwards the bearer token to the phone provider.

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
| `tenantId` | No | Tenant metadata supplied by Microsoft Entra ID. The shared handler does not use it to select a provider. |
| `correlationId` | No | Sign-in correlation value. |
| `ttlSeconds` | No | Positive integer up to `2147483647`. The sample validates this value but does not enforce passcode expiry or a delivery deadline. |

Use the documented channel and mode values. If you supply `ttlSeconds`, use an integer. See
[request validation and runtime differences](../TECHNICAL.md#request-validation-and-runtime-differences).

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
    "scenario": "signIn",
    "ipAddress": "203.0.113.10"
  }
}
```

| Field | Required | Description |
| --- | --- | --- |
| `nonce` | Yes | Nonblank string returned unchanged after evaluation or provider acceptance. |
| `phoneNumber` | Yes | Nonblank recipient phone number. |
| `message` | Yes | Nonblank localized message containing the passcode. |
| `otp` | No | Passcode supplied separately as a string. Leading zeros are preserved. |
| `locale` | No | Voice locale. |
| `extension` | No | Legacy office-voice data. The shared handler does not forward it to built-in providers. |
| `riskContext` | No | JSON key-value object containing risk signals; may be `null`. |

Microsoft Entra ID puts `otp` inside the encrypted delivery context, not the outer request body.
Evaluation uses a generated test code. `otp` can be omitted or `null`.

`riskContext` has optional `scenario` and `ipAddress` strings; other fields retain arbitrary JSON
values. Missing/null common fields are absent, and empty strings are preserved. Non-string common
fields return `400` (`decryption_failed`) before provider work, including evaluation.
Telesign maps the common fields to `account_lifecycle_event` and `originating_ip` unchanged;
other built-in providers ignore them. Risk data is never logged or returned. See
[shared model details](../TECHNICAL.md#request-validation-and-runtime-differences).

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

Provider acceptance does not prove delivery.

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

## HTTP status codes

<a id="2-outcome--http-status-mapping"></a>

| Status | Description |
| --- | --- |
| `200 OK` | Evaluation completed or the provider accepted the request. |
| `400 Bad Request` | Invalid request or encrypted content, a missing or unrecognized provider setting, or a provider `4xx` response other than throttling. Includes provider HTTP `401`/`403`, which indicate outbound provider authorization/configuration failures, not inbound caller authentication. |
| `401 Unauthorized` | SAS-to-Function caller authentication failed. Not used for provider authentication failures. |
| `403 Forbidden` | SAS-to-Function caller authorization or platform access was denied. Not used for provider blocks. |
| `422 Unprocessable Entity` | The provider explicitly blocked delivery for risk or policy reasons. Not an authentication failure or accepted delivery. See existing SAS behavior below. |
| `429 Too Many Requests` | Provider throttling. |
| `500 Internal Server Error` | Unexpected Function or provider response-processing failure. |
| `502 Bad Gateway` | Missing or invalid provider endpoint, mismatched authentication mode, or failure to obtain credentials, reach the provider, or process its response. |
| `504 Gateway Timeout` | Provider request timed out. |

Check a timed-out live request before retrying. The provider might already have accepted it.

### Provider blocks and existing SAS behavior

An explicit provider block, such as Telesign `3072` or Soprano `BLOCKED`, returns HTTP `422` with
`error: "provider_blocked"`. The response contains no nonce or success `providerStatus`.
The existing SAS implementation classifies a completed `422` response as `ClientError`, reported
as `EndpointClientError`, not as a distinct provider-blocked outcome. Like `400` (including mapped
provider HTTP `401`/`403`), it does not trigger an HTTP retry or count toward either the endpoint
failure or slowdown circuit breaker. The Function logs the provider block explicitly; SAS retains its generic client
error classification and the HTTP status.

This status mapping does not disable SAS native fallback when it is enabled and permitted.
A sample-only response change cannot guarantee that a provider risk decision prevents all
delivery through another route. Do not return `200` to suppress fallback: that would falsely
acknowledge delivery. Transport or response-body read failures can also prevent SAS from observing
a completed response and retain their existing timeout/network classification.

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

Error categories are:

- `bad_request` for invalid request data or an incomplete decrypted delivery context.
- `decryption_failed` when the encrypted delivery context cannot be decrypted or parsed.
- `provider_delivery_failed` for provider selection, configuration, credentials, transport, or
  mapped provider-response failures other than explicit blocks.
- `provider_blocked` for an explicit provider risk or policy block (HTTP `422`).
- `delivery_failed` for an unexpected handler failure.

These JSON errors come from the SendOtp handler. Easy Auth can reject a request before the handler
runs. The .NET Functions host can reject input during binding. Those responses can use a different
format. When present, `reason` is a fixed validation message, not an exception.

Unavailable provider credentials, for example, return `502 Bad Gateway`. The safe diagnostic
detail is recorded as
`failureStage=provider_credentials` and `failureReason=credential_unavailable` in application
logs, not exposed in the response.

### Diagnose a credential failure

When a live request cannot obtain provider credentials, current packages emit these events:

| Signal | Meaning |
| --- | --- |
| `request_received` | The Function received the CYOT request. |
| `envelope_validated` or `payload_validated` | The outer request passed validation. |
| `delivery_context_decrypted` | The encrypted delivery context was decrypted. |
| `provider_selected` | The configured provider was selected. |
| `provider_credential_resolution_started` | The Function started resolving provider credentials. |
| `request_failed` with credential stage, unavailable reason, and HTTP `502` | Credential resolution failed before the provider request started. |
| `response_prepared`, then `request_completed` with HTTP `502` | The handler prepared a `provider_delivery_failed` response with HTTP `502`. These events do not confirm that the caller received it. |

This pattern points to provider authentication or credential configuration, not envelope validation,
decryption, or provider delivery. Check the selected provider's Key Vault secrets or OAuth managed
identity, federation, tenant, scope, and permissions.

Field names and export shapes vary by runtime. JavaScript uses fields such as `failureStage`,
`failureReason`, and `httpStatus`; .NET commonly exports `FailureStage`, `FailureReason`, and
`HttpStatus`; Python logging exporters can place the same values in extra properties. Confirm the
deployed shape through [runtime-specific log discovery](MONITORING.md#runtime-specific-log-discovery)
and the [application log reference](LOGGING.md).

Current packages resolve credentials during live requests and do not emit
`credential_refresh_failed`. Older packages can emit different events. Confirm the deployed
package version and use its matching documentation before comparing sequences; upgrade only
through the normal reviewed deployment process.

Use the `ResultCode` field on the workspace `AppRequests` row together with correlated
`request_failed` and `request_completed` application events. The request telemetry records the
observed HTTP transport result; application events record handler progress. Filters, sampling, and
ingestion can omit an event, so a missing trace does not prove that the handler skipped that stage.
See [provider credential acquisition fails](../setup/docs/Troubleshooting.md#provider-credential-acquisition-fails)
for corrective steps.

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
