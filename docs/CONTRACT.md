# Send OTP API

<a id="external-phone-provider-function-language-agnostic-contract"></a>
<a id="http-contract"></a>

[Documentation](README.md) | [Build a provider integration](BRING-YOUR-OWN-PROVIDER.md) | [Settings and packages](../TECHNICAL.md)

Use this API to receive an encrypted SMS or voice request from **Microsoft Entra ID**.

| | |
| --- | --- |
| **Method** | `POST` |
| **Path** | `/api/SendOtp` |
| **Authentication** | Easy Auth |
| **Function trigger** | `authLevel: anonymous` |
| **Content type** | `application/json` |
| **Success** | `200 OK` with the decrypted nonce |

## HTTP request

<a id="1-http-api"></a>

```http
POST https://<function-host>/api/SendOtp
Content-Type: application/json
Authorization: Bearer {access-token}
```

Easy Auth validates the bearer token before the Function runs. Configure the trusted issuer,
endpoint audience, and authorized Microsoft caller by following the
[Easy Auth checklist](ONBOARDING.md#manual-deployment-trust-checklist).

The JWE protects the request data. It does not authenticate the caller.

Easy Auth must use `requireAuthentication=true`, `unauthenticatedClientAction=Return401`,
`requireHttps=true`, the endpoint audience in `allowedAudiences`, and a nonempty Microsoft caller
allowlist.

## Request headers

| Header | Use |
| --- | --- |
| `Authorization` | **Required.** Bearer token consumed by Easy Auth. The Function does not parse or forward it. |
| `Content-Type` | **Required.** Must be `application/json`. |
| `x-ms-correlation-id` | Optional correlation fallback when the body does not contain `correlationId`. |
| `x-ms-client-request-id` | Optional per-attempt identifier used internally as `messageId`. |
| `User-Agent` | Optional. Not interpreted or logged by the sample. |

Forwarded platform headers, including `x-ms-client-principal`, are context only.

## Request body

<a id="epp-request-body-envelope-cleartext-envelope"></a>
<a id="epp-request-body"></a>

| Field | Description |
| --- | --- |
| `type` | **Required string.** Must be `microsoft.mfa.otpDeliver.v1`. |
| `channel` | **Required integer or string.** `1` or `"sms"` for SMS. `2` or `"voice"` for voice. Names are case-insensitive. |
| `mode` | **Required integer or string.** `1` or `"live"` for delivery. `2` or `"evaluation"` for no-send evaluation. Names are case-insensitive. |
| `encryptedDeliveryContext` | **Required string.** Compact JWE containing the delivery data. |
| `tenantId` | Optional string with routing metadata. It does not select authentication or a provider. |
| `correlationId` | Optional sign-in correlation string. |
| `ttlSeconds` | Optional positive JSON integer up to `2147483647`. |

Use an integer such as `60` for `ttlSeconds`. Do not send `"60"`, `60.0`, `6e1`, `null`, a
boolean, or a nonpositive value. TTL validation does not enforce passcode expiry or a delivery
deadline.

Unknown versions, unsupported channel or mode values, invalid TTL values, and missing encrypted
content return `400 Bad Request`.

### Encrypted delivery context

<a id="encrypteddeliverycontext-jwe"></a>

The compact JWE must:

- Use `RSA-OAEP-256` for key wrapping.
- Use `A256GCM` for content encryption.
- Contain exactly five nonempty segments.
- Be no longer than 16,384 characters.
- Pass authentication-tag validation before the plaintext is used.

Pass the original compact JWE to the JOSE library. Do not rebuild its protected header.
The protected `alg` and `enc` values are fixed. `RSA-OAEP`, `A128GCM`, and
`A256CBC-HS512` are rejected.

The sample decrypts with the single RSA private key in `EPP_DECRYPTION_KEY_PEM`. In Azure, use a
Key Vault secret reference. `EPP_ENCRYPTION_KEY_ID` checks the JWE `kid` after decryption and logs
only `encryption_key_id_mismatch` on a mismatch. It does not select a key.

See [certificate lifecycle](../setup/docs/README.md#encryption-certificate-lifecycle) for renewal
and key synchronization.

The decrypted JSON contains:

| Field | Description |
| --- | --- |
| `nonce` | **Required string.** Returned unchanged after evaluation or provider acceptance. |
| `phoneNumber` | **Required string.** Expected in E.164 form. |
| `message` | **Required string.** Localized message containing the passcode. |
| `locale` | Optional voice locale when supported by the provider. |
| `extension` | Optional office-voice data. The shared dispatcher does not forward it. |
| `riskContext` | Optional context data. The sample does not evaluate it. |
| `textToVoice` | Optional legacy speech data. |

`nonce`, `phoneNumber`, and `message` must be nonblank strings. Decryption or completeness
failures return `400 Bad Request`.
The nonce confirms decryption in the response. It is not caller authentication or replay protection.

Provider-specific message mapping belongs in the
[provider implementation guide](BRING-YOUR-OWN-PROVIDER.md#provider-request-and-response-mapping).

## Modes

<a id="evaluation-no-provider-send"></a>

### Evaluation

Use `mode: 2` or `"evaluation"` to validate authentication, envelope parsing, and JWE decryption.
The Function returns the nonce without selecting a provider, reading provider credentials, or
sending a message.

Easy Auth and the decryption-key reference still apply in Azure. Core Tools does not provide Easy
Auth, so local evaluation must stay on loopback without tunnels.

### Live

Use `mode: 1` or `"live"` to send through the configured provider. The Function returns success
only after the adapter recognizes provider acceptance.

Provider acceptance is not proof of recipient delivery. Check delivery through the provider's
supported evidence.

## Response

<a id="epp-response-json"></a>

### Success response

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

The response contains:

| Field | Description |
| --- | --- |
| `nonce` | Original decrypted nonce. |
| `correlationId` | Body value, then `x-ms-correlation-id`, then a generated request ID. |
| `providerStatus` | Always `"accepted"` for evaluation or recognized live acceptance. |

Failures omit `nonce` and `providerStatus`. Handler errors include a generated `requestId` and
may include a fixed `reason` and `correlationId`. Platform authentication and .NET host-binding
errors can occur before this JSON response is created.

The caller uses a successful response with the matching nonce as the handled result. This
repository does not implement or guarantee caller fallback, retry, or timing behavior. Validate
those behaviors through the approved EPP procedure.

Handler failures use `error: "bad_request"` or `error: "decryption_failed"`. Fixed validation
reasons include:

- `invalid JSON body`
- `invalid envelope`
- `invalid payload`
- `unsupported envelope type`
- `unsupported payload type`
- `encryptedDeliveryContext is required`
- `unsupported channel`
- `unsupported mode`
- `invalid ttlSeconds`
- `ttlSeconds expired`
- `incomplete delivery context`

## HTTP status codes

<a id="2-outcome--http-status-mapping"></a>

| Status | Meaning |
| --- | --- |
| `200 OK` | Evaluation completed or the provider returned a recognized accepted status. |
| `400 Bad Request` | Invalid JSON, envelope, JWE, delivery context, or provider request. |
| `401 Unauthorized` | Easy Auth rejected the caller, or the provider rejected its credentials. |
| `403 Forbidden` | Easy Auth denied the caller, or the provider returned a recognized block. |
| `429 Too Many Requests` | The provider returned `429`. |
| `502 Bad Gateway` | Missing provider configuration, network failure, or unrecognized provider response. |
| `504 Gateway Timeout` | The provider request timed out. |

Unknown, incomplete, or unsuccessful provider responses fail closed. A provider `2xx` response is
not enough unless the adapter recognizes its status as accepted.

A timed-out live request might already have reached the provider. Check its outcome before retrying.

## Runtime notes

<a id="runtime-binding-differences"></a>

Use the request forms above for every runtime.

- **Parsing:** JavaScript and Python parse JSON inside the handler. .NET binds to
  `EntraSendOtpPayload` first, so malformed JSON or incompatible types can fail before the normal
  error body is created.
- **Channel and mode:** .NET can bind numeric strings such as `"1"`. JavaScript and Python reject
  them. Use integer codes or the documented names.
- **TTL:** JavaScript normalizes `60.0` and `6e1` to `60`. Python and .NET reject those forms.
  .NET treats `null` as omitted. Send an integer or omit the field.
- **Validation:** .NET uses `unsupported payload type` where JavaScript and Python use
  `unsupported envelope type`. A null .NET payload returns `invalid payload`. Incompatible
  decrypted field types can return `decryption_failed` in .NET before its completeness check.
- **Delivery context:** .NET models `locale`. JavaScript and Python also retain `extension` and
  `riskContext`. Shared dispatch does not forward the latter fields.
- **Correlation:** normal string values use the body, then `x-ms-correlation-id`, then a generated
  ID. JavaScript uses the raw header. Python and .NET sanitize it. .NET preserves an empty body
  value while JavaScript and Python fall back. Early validation errors omit correlation.
- **Request ID:** `x-ms-client-request-id` supplies `messageId`. JavaScript uses the raw header.
  Python and .NET sanitize it. Request and correlation IDs do not provide deduplication.

See the runtime handlers for exact binding behavior:
[JavaScript](../javascript/src/functions/SendOtp.js),
[Python](../python/function_app.py), and
[.NET](../dotnet/Functions/SendOtp.cs).

## Provider implementation

<a id="3-provider-contract"></a>
<a id="soprano-provider-jwt"></a>
<a id="telesign-epp-integration"></a>
<a id="4-configuration-app-settings--env"></a>
<a id="default-provider-and-configuration-readers"></a>
<a id="credential-caching-and-refresh"></a>

The HTTP contract is provider-neutral. Use
[Bring your own provider](BRING-YOUR-OWN-PROVIDER.md) for:

- Provider request and response mapping.
- Settings and channel endpoints.
- API-key and OAuth authentication.
- Credential caching and refresh.
- Soprano and Telesign behavior.
- Packaging, tests, and production planning.

App settings keep the `EPP_` prefix. Shared code uses the `Envelope` and `DeliveryContext` models.

## Required behavior

<a id="5-required-behaviors"></a>
<a id="application-logs"></a>
<a id="6-lightweight-tests"></a>
<a id="production-limitations"></a>
<a id="production-readiness-considerations"></a>
<a id="production-readiness"></a>

- Keep Easy Auth enabled for every public `/api/SendOtp` route.
- Use managed identity for Key Vault access.
- Keep phone numbers, messages, passcodes, nonces, tokens, keys, JWE contents, raw exceptions,
  and provider responses out of logs.
- Do not forward the incoming bearer token to a provider.
- Do not retry an uncertain live send without checking the provider outcome.
- Test evaluation, live acceptance, recipient delivery, caller rejection, invalid payloads, and
  tampered JWE independently.

See:

- [Application log reference](LOGGING.md)
- [Provider tests and production readiness](BRING-YOUR-OWN-PROVIDER.md#before-activation)
- [Deployment validation](ONBOARDING.md#validate-the-deployed-endpoint)
