# Bring your own telephony provider (BYOT)

<a id="byot-integration-the-entra-id-request-and-response"></a>
<a id="bring-your-own-provider"></a>

[Documentation](README.md) | [Send OTP API](CONTRACT.md) | [Technical details](../TECHNICAL.md)

Add a provider adapter to one runtime. This guide uses Twilio as an example; use your provider's
approved API, credentials, endpoints, sender configuration, and response contract.

> [!NOTE]
> BYOT providers are not included or configured by guided setup. Adding one requires code, tests,
> packaging, deployment settings, and an approved provider account.

<a id="understand-the-request"></a>
## Before you start

Confirm these prerequisites before editing code:

- The [Send OTP API contract](CONTRACT.md).
- A separate nonproduction environment and controlled test recipients.
- An approved provider account with the required SMS and voice access.
- The provider's current API documentation, base URLs or operation URLs, authentication method,
  credential names, sender or caller IDs, request limits, timeout guidance, and success responses.
- One runtime: [JavaScript](../javascript/README.md), [C#](../dotnet/README.md), or
  [Python](../python/README.md).
- The selected runtime's local tools and dependencies.
- A local test encryption key and untracked `local.settings.json`.
- Test credentials and sandbox or test endpoints that do not reach production recipients.
- Azure access for the later deployment, including a Function App, Key Vault, managed identity,
  Easy Auth configuration, and monitoring.

Confirm the provider supports every channel, destination, sender, locale, and account feature you
plan to enable. Provider purchase or API access does not prove sender approval or recipient
delivery.

Keep Easy Auth, envelope validation, JWE decryption, evaluation mode, and public responses in the
shared handler. The provider adapter builds the outbound request and interprets the response.

## Set up the runtime

1. Clone the repository and open the selected runtime folder.
2. Follow its setup guide:
   [JavaScript](../javascript/README.md#setup-and-deployment),
   [C#](../dotnet/README.md#setup-and-deployment), or
   [Python](../python/README.md#setup-and-deployment).
3. Install dependencies and run the existing offline tests before changing the adapter code.
4. Create an untracked `local.settings.json` from
   [local.settings.sample.json](local.settings.sample.json).
5. Configure only a local test key for evaluation first. Add provider settings only when testing
   the live adapter path with approved test credentials.
6. Keep Core Tools on loopback without tunnels. Local Core Tools does not provide Easy Auth.

Do not copy production credentials or encryption keys to a workstation. Keep credentials out of
source, commands, test output, screenshots, and logs.

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

1. Use a fixed lowercase provider ID, such as `twilio`.
2. Define the authentication mode and credential names.
3. Map SMS and voice requests to the approved provider API.
4. Map recognized provider responses to `Continue`, `Block`, or `Fail`.
5. Return the shared `ProviderResult`.
6. Keep sending in the shared runtime transport.

Return success only for a recognized acceptance. Acceptance does not confirm delivery.

Do not forward the incoming Microsoft Entra ID bearer token or return raw provider JSON.

<a id="add-and-register-the-provider"></a>
## Register the adapter

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
## Configure the provider

<a id="provider-settings"></a>
<a id="credential-caching"></a>

Set:

- `EPP_PROVIDER_NAME=twilio`
- `EPP_PROVIDER_AUTH_MODE` to the mode implemented by the adapter.
- `EPP_PROVIDER_SMS_ENDPOINT` and `EPP_PROVIDER_VOICE_ENDPOINT` for supported channels.
- Provider credential references and any additional adapter settings.

Replace `twilio` with the fixed ID used by your adapter. Set each channel endpoint to the exact URL
form expected by the adapter. Some providers use a base URL and others use a complete operation
URL. Require HTTPS and reject credentials, user information, query strings, or fragments in
endpoint settings.

Keep credentials in Key Vault and use managed identity to read them. Use the shared credential and
timeout services. Do not add a cache, refresher, or send-retry loop.

See [provider settings and credential acquisition](../TECHNICAL.md#provider-settings-and-credential-acquisition).

## Test the adapter

Cover:

- Registration and configuration.
- SMS and voice request mapping.
- Missing or invalid credentials.
- Accepted, rejected, unknown, and malformed responses.
- Network errors and timeouts.
- Evaluation mode with no provider call.
- Privacy-safe logs with no phone number, message, passcode, nonce, token, key, or raw response.
- Both configured channels and every supported provider region or route.
- Approved sender or caller IDs and test-recipient restrictions.

Use fake credentials and service responses for offline tests.

<a id="configure-test-and-package"></a>
<a id="implementation-steps"></a>
## Package and deploy

1. Run the selected runtime tests.
2. [Build a new package](../TECHNICAL.md#build-zips-locally).
3. Follow [manual deployment](ONBOARDING.md#optional-local-development-and-manual-deployment).
4. Set `EPP_PROVIDER_NAME` to the new adapter ID and configure both channel endpoints.
5. Add provider credentials to Key Vault and grant only the Function identity the required access.
6. Configure Easy Auth, app settings, monitoring, and any provider-side authorization.
7. Run the [approved endpoint checks](ONBOARDING.md#validate-the-deployed-endpoint).

Do not deploy an unchanged public release after adding the adapter.

<a id="step-7-check-endpoints-timeouts-and-privacy"></a>
<a id="6-validate-before-activation"></a>
<a id="before-activation"></a>
<a id="production-readiness"></a>

## Before live use

Confirm authentication, evaluation, controlled live acceptance, recipient delivery, monitoring,
renewal, rollback, retry handling, and duplicate-send protection.

See [production readiness](../TECHNICAL.md#production-readiness).
