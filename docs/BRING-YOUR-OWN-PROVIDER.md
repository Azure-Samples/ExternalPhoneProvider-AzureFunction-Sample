# Bring your own provider

<a id="byot-integration-the-entra-id-request-and-response"></a>

[Documentation](README.md) | [Exact HTTP contract](CONTRACT.md) | [Runtime guides](README.md#develop)

Connect a phone service to the **External Phone Provider (EPP)** contract. **Microsoft Entra ID**
sends an encrypted delivery request; the endpoint verifies, decrypts, evaluates, or sends it.

Confirm [eligibility, testing, and activation](ONBOARDING.md#before-purchasing-or-deploying)
before deployment.

Follow [caller verification](#1-verify-the-caller), [decryption](#2-read-and-decrypt-the-request),
[evaluation/live handling](#3-evaluate-or-send), and [responses](#4-respond-to-entra-id).
Then [register your integration](#where-to-add-your-integration) and [validate before activation](#before-activation).

<a id="1-establish-caller-authentication"></a>

## 1. Verify the caller

Entra ID sends **`POST /api/SendOtp` over HTTPS** with a signed bearer token. **Easy Auth**
authorizes the caller before the anonymous Function trigger runs.

Require HTTPS, return `401` for unauthenticated requests, and restrict access to the trusted
issuer, audience, and Microsoft caller. Follow the
[trust checklist](ONBOARDING.md#manual-deployment-trust-checklist).

**Encryption is not caller authentication.** A JWE, nonce, `tenantId`, or tracing header does
not prove that Entra ID sent the request.

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

Channel and mode names are case-insensitive. TTL validation does not enforce passcode expiry
or a delivery deadline.

<a id="3-decrypt-and-validate-the-delivery-context"></a>

Decrypt `encryptedDeliveryContext` using only **`RSA-OAEP-256`** for key wrapping and **`A256GCM`**
for content encryption. Accept exactly five nonempty compact-JWE segments, at most **16,384
characters**. Pass the original JWE, including its protected-header bytes, to a JOSE library.
Verify the authentication tag before using the decrypted UTF-8 JSON.

The sample uses one RSA private key in `EPP_DECRYPTION_KEY_PEM` as text or base64 PEM. In Azure,
use a managed-identity-resolved Key Vault reference.

The JWE `kid` does not select a key. `EPP_ENCRYPTION_KEY_ID` only warns after decryption.
See the [certificate lifecycle](../setup/docs/README.md#encryption-certificate-lifecycle).

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

Treat optional fields as available only when the selected integration supports them.
For parser and wrong-type handling, see [runtime binding differences](CONTRACT.md#runtime-binding-differences).

<a id="4-complete-the-customer-owned-service-integration"></a>

## 3. Evaluate or send

**Evaluation (`mode: 2` or `"evaluation"`):** authenticate, validate, decrypt, and return success
without service selection, credential lookup, outbound HTTP, or delivery.

**Live (`mode: 1` or `"live"`):** map SMS or voice to your service while preserving the
destination, message, and passcode. **Never forward the incoming bearer token**.

Return success after the integration recognizes provider acceptance. A queued or pending result
counts only when the integration defines it as accepted. Map unknown, incomplete, or failed HTTP
responses to an error, even when the response body looks successful. Use the shared response
behavior below instead of returning raw service JSON.

The sample uses one configured service per deployment. Follow
[Where to add your integration](#where-to-add-your-integration) for the source files,
registration, settings, packaging, and custom deployment steps.

## 4. Respond to Entra ID

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
Acceptance is not proof of handset receipt. The sample's integration contract expects Entra ID to
recognize a `2xx` response with a matching nonce; failures or timeouts can lead to native fallback.
This repository does not implement or verify the Entra ID caller's current fallback or retry policy.
Confirm that behavior through the [approved test procedure](ONBOARDING.md#validate-the-deployed-endpoint),
including whether a lost response can lead to another send.

On failure, omit both the nonce and accepted status. Handler errors contain `error` and a
generated `requestId`, plus a fixed `reason` for validation errors and `correlationId` where
available. Do not return raw exceptions or service responses. Authentication and host-binding
errors can occur before the handler and need not use this JSON shape. Use the
[error reference](CONTRACT.md#epp-response-json) and
[HTTP status mapping](CONTRACT.md#2-outcome--http-status-mapping) for the exact failure response.

## Where to add your integration

Choose **one runtime** and work in its source directory. Keep Easy Auth and the shared handler's
envelope validation, JWE decryption, evaluation branch, and nonce responses. Your provider code
builds the outbound request and interprets the service result; it does not authenticate the
incoming caller or write the HTTP response to Entra ID.

### Add and register the provider

Choose a fixed lowercase provider ID, then follow the row for your runtime.

| Runtime | Create your module or class here | Register it here | Add tests here |
| --- | --- | --- | --- |
| JavaScript | [javascript/src/functions/providers/](../javascript/src/functions/providers/) | [providers/index.js](../javascript/src/functions/providers/index.js): import the module, add its fixed ID to `selectProvider`, and export it. | [javascript/test/](../javascript/test/) |
| C# | [dotnet/Src/Providers/](../dotnet/Src/Providers/) | [Program.cs](../dotnet/Program.cs): register the class as a singleton `PhoneProviderBase`. The handler selects it by `Name`. | [dotnet/tests/](../dotnet/tests/) |
| Python | [python/src/providers/](../python/src/providers/) | [function_app.py](../python/function_app.py): import the class and add an instance to the tuple that builds `_providers`. | [python/tests/](../python/tests/) |

Implement the hooks for your chosen runtime:

- **JavaScript:** export `name`, `authenticationMode`, `credentialSpec`, `createRequest`, and
  `interpretResponse`. Return the shared [ProviderResult](../javascript/src/functions/providerResult.js).
  [SendOtp.js](../javascript/src/functions/SendOtp.js) passes delivery data, credentials, and `env`
  to `createRequest`; leave sending to its shared [transport](../javascript/src/functions/providerTransport.js).
- **C#:** derive from [PhoneProviderBase](../dotnet/Src/PhoneProviderBase.cs). Implement `Name`,
  `AuthenticationMode`, `FetchCredentialsAsync`, and `SendOtpAsync`. Use the base `SendJsonAsync`
  transport and return [ProviderResult](../dotnet/Src/Models.cs). Read extra send settings through
  the supplied `IEnv`; use injected [ISecretResolver](../dotnet/Src/ISecretResolver.cs) for vault secrets.
  Return credentials with a valid `ExpiresOn` and honor the acquisition cancellation token.
- **Python:** derive from [PhoneProviderBase](../python/src/provider.py). Supply `name`,
  `authentication_mode`, and `credential_spec`; implement `build_request` and `map_response`.
  Return the base module's `OutboundRequest` and the shared [ProviderResult](../python/src/models.py).
  Use the supplied `env` for extra settings and keep the base `send_otp` transport.

Your hooks own service-specific mapping, outbound authentication, and recognition of acceptance
or failure. Keep credential caching in the existing services:
[JavaScript credentials.js](../javascript/src/functions/credentials.js),
[C# CredentialTokenService](../dotnet/Src/CredentialTokenService.cs), and
[Python credentials.py](../python/src/credentials.py). JavaScript/Python resolve the provider's
credential specification; C# calls `FetchCredentialsAsync`. Do not add a separate credential cache
or send-retry loop. Keep service secrets in Key Vault, not in settings or source.

<a id="configure-test-and-package"></a>
### Implementation steps

1. Start from [local.settings.sample.json](local.settings.sample.json). Copy it to an untracked
   `local.settings.json` beside your runtime's `host.json`, keep all `Values` entries as strings,
   and select `node`, `dotnet-isolated`, or `python` as `FUNCTIONS_WORKER_RUNTIME`.
   Use a local test decryption key, never a production key.
2. Set `EPP_PROVIDER_NAME` to your registered ID and `EPP_PROVIDER_AUTH_MODE` to its matching
   `apiKey` or `oauth` mode. Supply `EPP_PROVIDER_SMS_ENDPOINT` and `EPP_PROVIDER_VOICE_ENDPOINT`
   for the channels you support, plus the credential and extra settings your code reads.
   Keep these aligned with [JavaScript config.js](../javascript/src/functions/config.js),
   [C# AppConfig](../dotnet/Src/AppConfig.cs), or [Python config.py](../python/src/config.py) and the
   [configuration reference](CONTRACT.md#4-configuration-app-settings--env).
   **Settings select registered code; they do not create or register an adapter.**
3. Add tests in the directory above for registration, request mapping, missing credentials,
   recognized acceptance, rejection, unknown responses, and timeouts on each supported channel.
   Check that evaluation sends nothing, live success waits for acceptance, and failures omit the
   nonce. Use fake credentials and service responses; run your runtime's tests and build.
4. [Package your changed source](../TECHNICAL.md#build-zips-locally), not an unchanged public
   release. C# needs publish output; Python needs the documented Linux remote build.
   Follow [manual deployment](ONBOARDING.md#optional-local-development-and-manual-deployment)
   to deploy the custom package and apply cloud settings and vault permissions separately.
   Keep the [Easy Auth trust checks](ONBOARDING.md#manual-deployment-trust-checklist), then
   complete the validation below.

<a id="step-7-check-endpoints-timeouts-and-privacy"></a>
<a id="6-validate-before-activation"></a>

## Before activation

Run [authorized endpoint checks](ONBOARDING.md#validate-the-deployed-endpoint): rejected callers,
invalid or tampered payloads, evaluation without a send, and controlled live tests for each channel.
Check handset receipt or voice audio separately from acceptance. For local tests, use test keys
and fake service responses on loopback only, without tunnels; Core Tools has no Easy Auth.

The sample completes the request after provider acceptance. A live design can add early
acknowledgement, background delivery, a durable queue, retries, or duplicate-send protection.
Define the timing and owner for each feature. The outbound timeout covers the provider call,
not the whole request. Check a timed-out send before retrying because the provider may already
have accepted it.

Keep phone numbers, messages, passcodes, nonces, tokens, keys, JWE contents, and raw service
responses out of logs. Disable body tracing in the application, platform, and proxies.
Review the [production-readiness considerations](CONTRACT.md#production-limitations) before activation.
