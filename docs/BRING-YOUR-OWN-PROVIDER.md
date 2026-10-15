# Bring your own provider

<a id="byot-integration-the-entra-id-request-and-response"></a>

[Documentation](README.md) | [Exact HTTP contract](CONTRACT.md) | [Runtime guides](README.md#develop)

Connect a phone service to the **External Phone Provider (EPP)** contract. **Microsoft Entra ID**
sends an encrypted delivery request. The endpoint verifies, decrypts, evaluates, or sends it.

Confirm [eligibility, testing, and activation](ONBOARDING.md#before-purchasing-or-deploying)
before deployment.

Read the [API contract](CONTRACT.md), then [add your integration](#where-to-add-your-integration)
and [validate it](#before-activation).

<a id="1-establish-caller-authentication"></a>
<a id="3-decrypt-and-validate-the-delivery-context"></a>
<a id="4-complete-the-customer-owned-service-integration"></a>
<a id="1-verify-the-caller"></a>
<a id="2-read-and-decrypt-the-request"></a>
<a id="3-evaluate-or-send"></a>
<a id="4-respond-to-entra-id"></a>

## Understand the request

The [Send OTP API reference](CONTRACT.md) is the single source for:

- Authentication and headers.
- Envelope and JWE fields.
- Evaluation and live modes.
- Success and error responses.
- HTTP status codes.
- Runtime parsing differences.

Provider code starts after caller authentication, envelope validation, and decryption. It receives
validated delivery data and returns a normalized provider result.

Keep these boundaries:

- Easy Auth verifies the caller.
- The shared handler validates and decrypts the request.
- The provider adapter builds the outbound request and interprets the response.
- The shared handler creates the response to Microsoft Entra ID.

Do not forward the incoming bearer token. Do not return raw provider JSON. Echo the nonce only
after evaluation or recognized provider acceptance.

## Where to add your integration

Choose **one runtime** and work in its source directory. Keep Easy Auth and the shared handler's
envelope validation, JWE decryption, evaluation branch, and nonce responses. Your provider code
builds the outbound request and interprets the service result. It does not authenticate the
incoming caller or write the HTTP response to Entra ID.

<a id="provider-request-and-response-mapping"></a>
### Provider request and response mapping

Each provider implementation owns:

- Its fixed provider ID and authentication mode.
- Its required credentials and settings.
- SMS and voice request construction.
- Response parsing and accepted-status rules.
- Safe failure classification.

The shared transport owns:

- HTTPS URL validation.
- Disabled redirects.
- The configured provider timeout.
- Response-body reading.
- Network and timeout errors.

Return a normalized result to the handler. Do not return raw provider JSON to Microsoft Entra ID
or write it to logs. The shared handler applies the
[HTTP status mapping](CONTRACT.md#2-outcome--http-status-mapping).

A provider `2xx` response is not enough unless the adapter recognizes its status as accepted.
Acceptance is not recipient delivery.
The shared outcomes are `Continue`, `Block`, and `Fail`. There is no `StepUp` or `409` mapping.
Use the existing safe failure reasons: `provider_http_error`, `provider_rejected`,
`unrecognized_provider_status`, `missing_provider_message_id`, and `invalid_provider_json`.

JavaScript and .NET pass cancellation through response reading. Python uses connect and read
inactivity timeouts.

<a id="provider-settings"></a>
### Provider settings

#### Provider and endpoint

- **`EPP_PROVIDER_NAME`** is the fixed ID of the registered adapter.
- **`EPP_PROVIDER_SMS_ENDPOINT`** is the required SMS URL for a live SMS request.
- **`EPP_PROVIDER_VOICE_ENDPOINT`** is the required voice URL for a live voice request.
- **`EPP_PROVIDER_ENDPOINT_REGION`** is the `global` or `eu` routing label from guided setup.
- **`EPP_PROVIDER_TIMEOUT_MS`** is the provider timeout in milliseconds. The default is `1500`.
  The maximum is `2500`.
- **`EPP_PROVIDER_ACCOUNT_NAME`** is the sender or account value when required.

#### Authentication

- **`EPP_PROVIDER_AUTH_MODE`** is `apiKey` or `oauth`, matching the adapter.
- **`KEY_VAULT_URL`** identifies the vault containing API-key credentials.
- **`AZURE_CLIENT_ID`** selects a user-assigned identity for Key Vault when needed.
- **`EPP_PROVIDER_TENANT_ID`** identifies the provider tenant for OAuth.
- **`EPP_PROVIDER_SCOPE`** is the provider OAuth scope.
- **`EPP_OUTBOUND_CLIENT_ID`** identifies the client application used for OAuth exchange.
- **`EPP_OUTBOUND_MI_CLIENT_ID`** identifies the user-assigned identity used for OAuth exchange.

#### Caching

- **`EPP_KEY_VAULT_CACHE_ENABLED`** controls API-key credential caching.
- **`EPP_ACCESS_TOKEN_CACHE_ENABLED`** controls OAuth credential caching.

Each live request uses the endpoint for its selected channel. There is no shared endpoint fallback.
Endpoints must be absolute HTTPS URLs with a hostname, valid port, no user information, and no
fragment. Redirects are not followed.

Settings select registered code. They do not install an adapter. Evaluation does not require a
provider name, endpoint, or provider credential.

There is no default provider or automatic failover. The request body does not select a provider.
Telesign and Soprano use the selected URL unchanged. Infobip and Sinch append their API paths to
the selected base URL. The request channel selects the SMS or voice endpoint.
The legacy `EPP_PROVIDER_CHANNEL` setting is not used.

<a id="credential-caching"></a>
### Authentication and credential caching

Use managed identity to read provider credentials from Key Vault. Keep secrets out of code,
settings, logs, and documentation.
The default runtime resolver uses `ManagedIdentityCredential`, not the developer's CLI identity.

For OAuth, exchange the outbound managed-identity assertion for the provider token. Do not use a
client-secret fallback and never forward the incoming Microsoft Entra ID token.

Soprano uses `EPP_PROVIDER_AUTH_MODE=oauth`. With
`EPP_ACCESS_TOKEN_CACHE_ENABLED=true`, the runtime reuses its credential and SDK token caches.

Cache settings accept trimmed, case-insensitive `true` or `false`. Unset values default to `true`.
Other values fail live credential acquisition without blocking evaluation. Restart workers after
a change.

| Runtime | Enabled cache behavior |
| --- | --- |
| JavaScript | Warms at startup and polls every 30 seconds. OAuth uses `getToken`. |
| Python | Uses the same polling model. OAuth uses `get_token_info` when available, then `get_token`. |
| .NET | Warms once and refreshes on the next cache miss through `GetOrCreateAsync`. It has no polling loop. |

With caching disabled, each live request obtains credentials for that request. There is no startup
preparation, polling, or cross-request reuse. Evaluation still skips provider credential work.
The platform's decryption-key reference is separate from these provider caches.

Credential acquisition uses a 2.5-second budget in each runtime. That budget is not the total
Function deadline. Failed credential acquisition never sends an OTP.

### Built-in provider notes

<a id="soprano-integration"></a>
#### Soprano

Soprano uses OAuth client-assertion exchange with:

- `EPP_PROVIDER_TENANT_ID`
- `EPP_PROVIDER_SCOPE`
- `EPP_OUTBOUND_CLIENT_ID`
- `EPP_OUTBOUND_MI_CLIENT_ID`

The endpoint app and outbound identity share a home tenant. The app must be multitenant and
authorized in the provider tenant. The federated credential uses the identity principal ID,
home-tenant v2 issuer, and `api://AzureADTokenExchange` audience.

The managed identity first requests `api://AzureADTokenExchange/.default`. The selected provider
scope is used for the final application token. The Function sends that token to the
`/messages/omnimsg` API and does not store a Soprano client secret.

Only the final provider token is sent. The Function does not forward the managed-identity
assertion or incoming Microsoft Entra ID token. Missing settings, token failures, blank tokens, and
tokens with 30 seconds or less remaining fail before provider HTTP. There is no API-key fallback or
provider retry. The Function treats the token as opaque. The provider validates its claims.

The selected SMS or voice URL is used unchanged.

For voice, the adapter:

1. Finds the first six consecutive digits in `message`, preserving leading zeros.
2. Splits the text into `beforePasswordText`, `password`, and `afterPasswordText`.
3. Uses the request locale or `en-US`.
4. Sends `gender: 1` and `loop: 2` in `voice.text2voice`.

A message without six consecutive digits fails before provider HTTP. SMS forwards `message`
unchanged. Voice does not send a top-level `text` field.

<a id="telesign-integration"></a>
#### Telesign

Telesign uses the complete configured SMS or voice URL. It sends:

- `recipient.phone_number`
- `message.text`
- Optional `message.language`
- One `channels[].channel`
- `correlation_id`

Responses use `reference_id`, `status.code`, and `status.description`. Only safe normalized fields
are logged.

`phoneNumber` must match `^\+[1-9][0-9]{1,14}$`, including the leading `+`. A nonblank locale
becomes `message.language`. `correlation_id` uses the request correlation ID or the generated
message ID.

SMS forwards the message unchanged. Voice separates standalone six-digit runs with commas and
repeats the full message twice.

Basic authentication uses:

```text
base64(UTF8(customer-id:api-key))
```

Set the header to `Authorization: Basic {encoded-value}`. Provider documentation can abbreviate
this as `Basic YOUR_API_KEY`. Do not send that text literally.

Read `telesign-customer-id` and `telesign-api-key` from Key Vault. Digest and provider-token
authentication are not implemented.

Recognized success codes are:

- SMS: `200`, `203`, `290`, `291`, `292`
- Voice: `100`, `101`, `102`, `103`
- Either channel: `3001` on a successful HTTP response

Unknown or malformed statuses fail closed. `3001` means the provider accepted the operation. It
does not confirm handset receipt or completed audio.

The adapter does not send `account_lifecycle_event`, `originating_ip`, or `X-Shutter-Mode: true`.
The legacy `TELESIGN_VOICE` setting has no effect.
Use Function evaluation mode for a no-send endpoint test.

### Add and register the provider

Choose a fixed lowercase provider ID.

#### JavaScript

1. Add the module under [providers/](../javascript/src/functions/providers/).
2. Import it in [providers/index.js](../javascript/src/functions/providers/index.js), add its ID to
   `selectProvider`, and export it.
3. Export `name`, `authenticationMode`, `credentialSpec`, `createRequest`, and `interpretResponse`.
4. Return [ProviderResult](../javascript/src/functions/providerResult.js).
5. Add tests under [javascript/test/](../javascript/test/).

`createRequest` receives the delivery data, credentials, and `env`. Keep sending in the shared
[transport](../javascript/src/functions/providerTransport.js).

#### C#

1. Add the class under [Providers/](../dotnet/Src/Providers/).
2. Register it in [Program.cs](../dotnet/Program.cs) as a singleton `PhoneProviderBase`.
3. Implement `Name`, `AuthenticationMode`, `FetchCredentialsAsync`, and `SendOtpAsync`.
4. Use `SendJsonAsync` and return [ProviderResult](../dotnet/Src/Models.cs).
5. Add tests under [dotnet/tests/](../dotnet/tests/).

Use `IEnv` for settings and [ISecretResolver](../dotnet/Src/ISecretResolver.cs) for vault secrets.
Return credentials with a valid `ExpiresOn` and honor cancellation.

#### Python

1. Add the class under [providers/](../python/src/providers/).
2. Add an instance to the `_providers` tuple in [function_app.py](../python/function_app.py).
3. Derive from [PhoneProviderBase](../python/src/provider.py).
4. Implement `name`, `authentication_mode`, `credential_spec`, `build_request`, and `map_response`.
5. Return `OutboundRequest` and [ProviderResult](../python/src/models.py).
6. Add tests under [python/tests/](../python/tests/).

Use the supplied `env` for extra settings. Keep sending in the base `send_otp` transport.

Your hooks own service-specific mapping, outbound authentication, and recognition of acceptance
or failure. Keep credential caching in the existing services:
[JavaScript credentials.js](../javascript/src/functions/credentials.js),
[C# CredentialTokenService](../dotnet/Src/CredentialTokenService.cs), and
[Python credentials.py](../python/src/credentials.py). JavaScript/Python resolve the provider's
credential specification. C# calls `FetchCredentialsAsync`. Do not add a separate credential cache
or send-retry loop. Keep service secrets in Key Vault, not in settings or source.

Configuration readers are [JavaScript `readConfig`](../javascript/src/functions/config.js),
[Python `read_config`](../python/src/config.py), and
[.NET `AppConfig.Read`](../dotnet/Src/AppConfig.cs).

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
   [provider settings](#provider-settings).
   **Settings select registered code. They do not create or register an adapter.**
3. Add tests in the directory above for registration, request mapping, missing credentials,
   recognized acceptance, rejection, unknown responses, and timeouts on each supported channel.
   Check that evaluation sends nothing, live success waits for acceptance, and failures omit the
   nonce. Use fake credentials and service responses. Run your runtime's tests and build.
4. [Package your changed source](../TECHNICAL.md#build-zips-locally), not an unchanged public
   release. C# needs publish output. Python needs the documented Linux remote build.
   Follow [manual deployment](ONBOARDING.md#optional-local-development-and-manual-deployment)
   to deploy the custom package and apply cloud settings and vault permissions separately.
   Keep the [Easy Auth trust checks](ONBOARDING.md#manual-deployment-trust-checklist), then
   complete the validation below.

<a id="step-7-check-endpoints-timeouts-and-privacy"></a>
<a id="6-validate-before-activation"></a>

## Before activation

<a id="production-readiness"></a>

Run [authorized endpoint checks](ONBOARDING.md#validate-the-deployed-endpoint): rejected callers,
invalid or tampered payloads, evaluation without a send, and controlled live tests for each channel.
Check handset receipt or voice audio separately from acceptance. For local tests, use test keys
and fake service responses on loopback only, without tunnels. Core Tools has no Easy Auth.

The sample completes the request after provider acceptance. Plan any additional production
capabilities your design needs:

- Durable queues or background delivery.
- Duplicate-send protection and safe retries.
- End-to-end timing for cold starts, Key Vault, and provider calls.
- Overlapping encryption-key rotation.
- E.164 and body-size validation.
- Provider delivery confirmation.
- Voice locale, passcode, and audio validation.

The outbound timeout covers only the provider call. Check a timed-out send before retrying because
the provider may already have accepted it.

Keep phone numbers, messages, passcodes, nonces, tokens, keys, JWE contents, and raw service
responses out of logs. Disable body tracing in the application, platform, and proxies.
Complete setup certification, provider account checks, monitoring, renewal, rollback, and the
approved Microsoft activation procedure before live use.
