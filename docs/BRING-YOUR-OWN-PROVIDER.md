# Add Twilio

<a id="byot-integration-the-entra-id-request-and-response"></a>
<a id="bring-your-own-provider"></a>

[Documentation](README.md) | [Send OTP API](CONTRACT.md) | [Technical details](../TECHNICAL.md)

Use this guide to add a Twilio adapter to one runtime.

> [!NOTE]
> Twilio is not included in the sample or configured by guided setup. Adding it requires code,
> tests, packaging, deployment settings, and your approved Twilio account configuration.

<a id="understand-the-request"></a>
## Before you start

Prepare:

- The [Send OTP API contract](CONTRACT.md).
- An approved Twilio account and API design for SMS and voice.
- One runtime: [JavaScript](../javascript/README.md), [C#](../dotnet/README.md), or
  [Python](../python/README.md).
- Test credentials and endpoints that do not send to production recipients.

Keep Easy Auth, envelope validation, JWE decryption, evaluation mode, and public responses in the
shared handler. The Twilio adapter should only build the outbound request and interpret the response.

<a id="1-establish-caller-authentication"></a>
<a id="3-decrypt-and-validate-the-delivery-context"></a>
<a id="4-complete-the-customer-owned-service-integration"></a>
<a id="1-verify-the-caller"></a>
<a id="2-read-and-decrypt-the-request"></a>
<a id="3-evaluate-or-send"></a>
<a id="4-respond-to-entra-id"></a>

<a id="where-to-add-your-integration"></a>
## Add the adapter

<a id="provider-request-and-response-mapping"></a>

1. Use a fixed lowercase provider ID such as `twilio`.
2. Define the authentication mode and credential names.
3. Map SMS and voice requests to the approved Twilio API.
4. Map recognized Twilio responses to `Continue`, `Block`, or `Fail`.
5. Return the shared `ProviderResult`.
6. Keep sending in the shared runtime transport.

Only a recognized accepted response can return success. A successful provider response does not
confirm recipient delivery.

Do not forward the incoming Microsoft Entra ID bearer token or return raw Twilio JSON.

<a id="add-and-register-the-provider"></a>
## Register it

### JavaScript

1. Add the adapter under [providers/](../javascript/src/functions/providers/).
2. Import it in [providers/index.js](../javascript/src/functions/providers/index.js).
3. Add its ID to `selectProvider` and export it.
4. Implement `name`, `authenticationMode`, `credentialSpec`, `createRequest`, and
   `interpretResponse`.
5. Add tests under [javascript/test/](../javascript/test/).

### C#

1. Add the class under [Providers/](../dotnet/Src/Providers/).
2. Register it in [Program.cs](../dotnet/Program.cs) as a singleton `PhoneProviderBase`.
3. Implement `Name`, `AuthenticationMode`, `FetchCredentialsAsync`, and `SendOtpAsync`.
4. Use `SendJsonAsync` and return `ProviderResult`.
5. Add tests under [dotnet/tests/](../dotnet/tests/).

### Python

1. Add the class under [providers/](../python/src/providers/).
2. Add an instance to `_providers` in [function_app.py](../python/function_app.py).
3. Derive from `PhoneProviderBase`.
4. Implement `name`, `authentication_mode`, `credential_spec`, `build_request`, and `map_response`.
5. Return `OutboundRequest` and `ProviderResult`.
6. Add tests under [python/tests/](../python/tests/).

<a id="authentication-and-credential-caching"></a>
<a id="authentication"></a>
<a id="caching"></a>
<a id="provider-and-endpoint"></a>
## Configure it

<a id="provider-settings"></a>
<a id="credential-caching"></a>

Set:

- `EPP_PROVIDER_NAME=twilio`
- `EPP_PROVIDER_AUTH_MODE` to the mode implemented by the adapter.
- `EPP_PROVIDER_SMS_ENDPOINT` and `EPP_PROVIDER_VOICE_ENDPOINT` for supported channels.
- Twilio credential references and any additional adapter settings.

Keep credentials in Key Vault and read them through managed identity. Use the shared cache and
timeout services instead of adding another credential cache or send-retry loop.

See [provider settings and credential caching](../TECHNICAL.md#provider-settings-and-credential-caching).

## Test it

Cover:

- Registration and configuration.
- SMS and voice request mapping.
- Missing or invalid credentials.
- Accepted, rejected, unknown, and malformed responses.
- Network errors and timeouts.
- Evaluation mode with no provider call.
- Privacy-safe logs with no phone number, message, passcode, nonce, token, key, or raw response.

Use fake credentials and service responses for offline tests.

<a id="configure-test-and-package"></a>
<a id="implementation-steps"></a>
## Package and deploy

1. Run the selected runtime tests.
2. [Build a new package](../TECHNICAL.md#build-zips-locally).
3. Follow [manual deployment](ONBOARDING.md#optional-local-development-and-manual-deployment).
4. Configure Easy Auth, app settings, Key Vault access, and monitoring.
5. Run the [approved endpoint checks](ONBOARDING.md#validate-the-deployed-endpoint).

Do not deploy an unchanged public release after adding the adapter.

<a id="step-7-check-endpoints-timeouts-and-privacy"></a>
<a id="6-validate-before-activation"></a>
<a id="before-activation"></a>
<a id="production-readiness"></a>

## Before live use

Confirm authentication, evaluation, controlled live acceptance, recipient delivery, monitoring,
renewal, rollback, retry handling, and duplicate-send protection.

See [production readiness](../TECHNICAL.md#production-readiness).
