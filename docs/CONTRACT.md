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
| `x-ms-correlation-id` | Optional correlation fallback. |
| `x-ms-client-request-id` | Optional request identifier. |

The Function does not forward the bearer token to the phone provider.

## Request body

<a id="epp-request-body-envelope-cleartext-envelope"></a>
<a id="epp-request-body"></a>

- **`type`** — Required string. Use `microsoft.mfa.otpDeliver.v1`.
- **`channel`** — Required integer or string. `1` or `"sms"` for SMS. `2` or `"voice"` for voice.
- **`mode`** — Required integer or string. `1` or `"live"` to send. `2` or `"evaluation"`
  for no-send validation.
- **`encryptedDeliveryContext`** — Required compact JWE string.
- **`tenantId`** — Optional routing metadata.
- **`correlationId`** — Optional sign-in correlation value.
- **`ttlSeconds`** — Optional positive integer up to `2147483647`.

Send integer channel, mode, and TTL values in their documented forms for consistent behavior across
all runtimes. See [request validation and runtime differences](../TECHNICAL.md#request-validation-and-runtime-differences).

### Encrypted delivery context

<a id="encrypteddeliverycontext-jwe"></a>

The JWE uses `RSA-OAEP-256` and `A256GCM`. After decryption, the JSON contains:

- **`nonce`** — Required. Returned unchanged after evaluation or provider acceptance.
- **`phoneNumber`** — Required phone number.
- **`message`** — Required localized message containing the passcode.
- **`locale`** — Optional voice locale.
- **`extension`** — Optional office-voice data.
- **`riskContext`** — Optional context data.
- **`textToVoice`** — Optional legacy speech data.

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
| `correlationId` | Request correlation value or generated fallback. |
| `providerStatus` | `"accepted"` for evaluation or recognized live acceptance. |

Failures omit `nonce` and `providerStatus`.

## HTTP status codes

<a id="2-outcome--http-status-mapping"></a>

| Status | Description |
| --- | --- |
| `200 OK` | Evaluation completed or the provider accepted the request. |
| `400 Bad Request` | Invalid request or encrypted content. |
| `401 Unauthorized` | Caller or provider authentication failed. |
| `403 Forbidden` | Caller access was denied or the provider blocked the request. |
| `429 Too Many Requests` | Provider throttling. |
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
