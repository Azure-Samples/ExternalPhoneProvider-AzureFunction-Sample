# Add a provider adapter

[Documentation](README.md) | [Send OTP API](CONTRACT.md) | [Built-in providers](../TECHNICAL.md#built-in-providers)

Use the existing provider interfaces to extend one runtime. Start from the bundled Infobip,
Soprano, or Telesign adapter and your provider's documented API.

This is a development guide. For a standard deployment, use the
[deployment guide](GETTING-STARTED.md).

## Before you start

- Choose [JavaScript](../javascript/README.md), [C#](../dotnet/README.md), or [Python](../python/README.md).
- Confirm the provider's authentication, SMS and voice schemas, endpoints, and acceptance statuses.
- Prepare offline fixtures and an authorized provider test account.
- Review the [HTTP contract](CONTRACT.md) and [logging requirements](LOGGING.md).

Keep caller authentication, envelope validation, JWE decryption, evaluation, and public responses
in the shared request flow. The adapter owns provider credentials, request mapping, and response
interpretation.

## Implement and register the adapter

### JavaScript

1. Add the adapter under [providers](../javascript/src/functions/providers/).
2. Implement `name`, `authenticationMode`, `credentialSpec`, `createRequest`, and `interpretResponse`.
3. Register its fixed lowercase ID in `selectProvider` in [index.js](../javascript/src/functions/providers/index.js).
4. Return a `ProviderResult` using the shared outcome and safe failure classifications.
5. Add tests under [javascript/test](../javascript/test/).

### C#

1. Derive from [PhoneProviderBase](../dotnet/Src/PhoneProviderBase.cs) under
   [Providers](../dotnet/Src/Providers/).
2. Implement `Name`, `AuthenticationMode`, `FetchCredentialsAsync`, and `SendOtpAsync`.
3. Use `SendJsonAsync` for the shared JSON transport and return `ProviderResult`.
4. Register the provider as a singleton `PhoneProviderBase` in [Program.cs](../dotnet/Program.cs).
5. Add tests under [dotnet/tests](../dotnet/tests/).

### Python

1. Derive from [PhoneProviderBase](../python/src/provider.py) under
   [providers](../python/src/providers/).
2. Implement `name`, `authentication_mode`, `credential_spec`, `build_request`, and `map_response`.
3. Return `OutboundRequest` and `ProviderResult`.
4. Register an instance in `_providers` in [function_app.py](../python/function_app.py).
5. Add tests under [python/tests](../python/tests/).

## Configure and test

Set `EPP_PROVIDER_NAME` to the registered adapter ID and supply its authentication and complete
channel URLs. Reuse the shared credential-acquisition and timeout services.
See [runtime settings](../TECHNICAL.md#configure-environment-variables).

Verify:

- Provider selection, required settings, and SMS/voice mapping.
- Accepted, blocked, rejected, unknown, and malformed responses.
- Missing credentials, network failures, and timeouts.
- Evaluation returns before provider work.
- Logs and responses exclude phone data, OTPs, nonces, tokens, private keys, and raw provider bodies.

Only recognized provider acceptance can produce a live success response. Provider acceptance
and recipient delivery are separate outcomes.

## Package and deploy

1. Run the runtime's offline tests.
2. [Build a package](../TECHNICAL.md#build-zips-locally) containing the new adapter.
3. Follow the [custom deployment instructions](ONBOARDING.md#custom-deployment).
4. Complete provider authorization and the [endpoint checks](ONBOARDING.md#validate-the-deployed-endpoint).
5. Review [production readiness](../TECHNICAL.md#production-readiness).

Deploy your custom package rather than a standard release. Guided setup selects the providers
listed in its [catalog](../setup/providers/catalog.json).
