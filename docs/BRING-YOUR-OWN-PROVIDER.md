# BYOT integration: the Entra ID request and response

[Documentation](README.md) | [Exact HTTP contract](CONTRACT.md) | [Runtime guides](README.md#develop)

**Microsoft Entra ID** sends your **External Phone Provider (EPP)** endpoint
an encrypted phone number and one-time passcode message. Your endpoint verifies the caller,
decrypts the details, and either evaluates the request without sending or uses your phone service.
It then responds to Entra ID. **Your team owns the connection to that service.**

Before deploying, ask your tenant administrator to confirm
[eligibility, testing, and activation with Microsoft](ONBOARDING.md#before-purchasing-or-deploying).
Deploying the endpoint alone does not enable tenant policy.

Follow [caller verification](#1-verify-the-caller), [decryption](#2-read-and-decrypt-the-request),
[evaluation/live handling](#3-evaluate-or-send), and [responses](#4-respond-to-entra-id).
Then [register your integration](#where-to-add-your-integration) and [validate before activation](#before-activation).

<a id="1-establish-caller-authentication"></a>

## 1. Verify the caller

Entra ID sends **`POST /api/SendOtp` over HTTPS**, with a signed bearer token in `Authorization`.
In this sample, **Easy Auth** (Azure App Service Authentication) checks the token and authorizes
the caller before the Function runs. The Function's trigger is anonymous and has no backup
authentication check, so do not expose it with Easy Auth disabled or bypassed.

Require HTTPS and authentication, return `401` for unauthenticated requests, and restrict access
to the trusted tenant issuer, endpoint-app audience, and authorized Microsoft caller application ID.
Your Azure operator should use the endpoint app registration and
[approved setup configuration](../setup/support/Epp.Setup.psm1) for these values, then verify
**Function App > Authentication**. Follow the
[trust checklist](ONBOARDING.md#manual-deployment-trust-checklist) for exact settings,
caller-ID guidance, and token-version details.

**Encryption is not caller authentication.** Anyone with the public key can create a JWE
(JSON Web Encryption) payload. Neither its nonce, the body's `tenantId`, nor tracing or
forwarded principal headers prove that Entra ID sent it.

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
credentials; **never forward the incoming bearer token**.

Wait for recognized acceptance before returning success. A queued or pending result counts
only if your integration recognizes it as acceptance. Unknown or incomplete responses must fail,
and a success-looking body on a failed HTTP response is not acceptance. Return the result through
the shared response behavior below, not as raw service JSON.

The sample uses one configured service per deployment. A custom integration does not add
guided setup support. Follow [Where to add your integration](#where-to-add-your-integration)
for the files to create, registration, settings, and packaging.

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

### Configure, test, and package

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
   Retain the [Easy Auth trust checks](ONBOARDING.md#manual-deployment-trust-checklist), then
   complete the validation below.

<a id="step-7-check-endpoints-timeouts-and-privacy"></a>
<a id="6-validate-before-activation"></a>

## Before activation

Run [authorized endpoint checks](ONBOARDING.md#validate-the-deployed-endpoint): rejected callers,
invalid or tampered payloads, evaluation without a send, and controlled live tests for each channel.
Check handset receipt or voice audio separately from acceptance. For local tests, use test keys
and fake service responses on loopback only, without tunnels; Core Tools has no Easy Auth.

The sample completes the request after provider acceptance. If your live design adds early
acknowledgement, background delivery, a durable queue, retries, or deduplication, define their
timing and ownership explicitly. The outbound timeout covers the provider call rather than the
whole request; investigate a timed-out send before retrying because it may already be accepted.

Keep phone numbers, messages, passcodes, nonces, tokens, keys, JWE contents, and raw service
responses out of logs. Disable body tracing in the application, platform, and proxies.
Review the [production-readiness considerations](CONTRACT.md#production-limitations) before activation.
