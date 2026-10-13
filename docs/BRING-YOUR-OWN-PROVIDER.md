# Bring your own phone provider: repository checklist

To connect your own provider, such as Twilio, add an adapter to **one** language
implementation. Your team owns the provider integration and maintains that code.
This checklist covers the repository changes, not the provider's implementation.
Twilio isn't included in the sample or guided setup.

## 1. Choose one language

1. Start with the [JavaScript](../javascript/README.md), [C#](../dotnet/README.md)
   or [Python](../python/README.md) guide and use your own source checkout.
2. Read the [shared contract](CONTRACT.md). Keep Entra's message and code intact,
   preserve caller authentication and decryption, and leave evaluation mode
   ahead of provider work so it never sends a message.
3. Before purchasing or deploying, confirm eligibility and the testing/activation
   process with your tenant administrator and Microsoft using the
   [access guidance](ONBOARDING.md#before-purchasing-or-deploying).
   Until then, work offline with fake credentials and HTTP responses.

## 2. Create and register your provider

Follow only the section for your language. Add a new file rather than changing an
existing provider. Use the existing implementation for the repository's structure;
your team supplies the new provider's send and response handling.

### JavaScript

1. Add a module in [src/functions/providers](../javascript/src/functions/providers/),
   using [telesign.js](../javascript/src/functions/providers/telesign.js) as a reference.
   Implement `name`, `authenticationMode`, `credentialSpec`, `createRequest` and
   `interpretResponse`. Return the existing
   [ProviderResult](../javascript/src/functions/providerResult.js) and use
   [providerTransport.js](../javascript/src/functions/providerTransport.js) for sending.
2. Import it in [providers/index.js](../javascript/src/functions/providers/index.js),
   add its fixed ID to `selectProvider`, and include it in the exports.
3. Use [credentials.js](../javascript/src/functions/credentials.js) for credential
   lookup. [config.js](../javascript/src/functions/config.js) preserves `env`, which
   [SendOtp.js](../javascript/src/functions/SendOtp.js) passes to your adapter.

<a id="c-net"></a>

### C# (.NET)

1. Add a class in [Src/Providers](../dotnet/Src/Providers/), deriving from
   [PhoneProviderBase](../dotnet/Src/PhoneProviderBase.cs). Use
   [TelesignProvider.cs](../dotnet/Src/Providers/TelesignProvider.cs) as a reference
   for `Name`, `AuthenticationMode`, `FetchCredentialsAsync` and `SendOtpAsync`.
   Keep the shared transport and [ProviderResult](../dotnet/Src/Models.cs).
2. Register the class as another singleton `PhoneProviderBase` in
   [Program.cs](../dotnet/Program.cs).
   [SendOtp.cs](../dotnet/Functions/SendOtp.cs) already selects registered providers by name.
3. Use the injected [ISecretResolver](../dotnet/Src/ISecretResolver.cs) and
   [CredentialTokenService](../dotnet/Src/CredentialTokenService.cs) for credentials.
   Read adapter settings through the supplied `IEnv`.

### Python

1. Add a module in [src/providers](../python/src/providers/), deriving from
   [PhoneProviderBase](../python/src/provider.py). Use
   [telesign.py](../python/src/providers/telesign.py) as a reference for `name`,
   `authentication_mode`, `credential_spec`, `build_request` and `map_response`.
   Keep the shared transport and [ProviderResult](../python/src/models.py).
2. Import the class in [function_app.py](../python/function_app.py) and add an
   instance to the tuple that builds `_providers`.
   [providers/__init__.py](../python/src/providers/__init__.py) needs no registration.
3. Use [credentials.py](../python/src/credentials.py) and
   [secrets.py](../python/src/secrets.py) for credential lookup.
   [config.py](../python/src/config.py) preserves the `env` passed to your adapter.

## 3. Set up credentials and app settings

1. Choose the adapter's credential mode and secret names in its code, and keep
   them consistent with your deployment settings. Store provider secrets in
   Key Vault; use the sample's managed-identity lookup and grant the Function's
   reader identity access. Keep the existing
   [credential cache behavior](CONTRACT.md#credential-caching-and-refresh).
2. Start local settings from
   [docs/local.settings.sample.json](local.settings.sample.json). Copy it to an
   untracked `local.settings.json` beside your runtime's `host.json`, set the
   runtime named in its language guide, and keep all `Values` entries as strings.
   Use a local test decryption key and fake credentials for offline development.
3. Set `EPP_PROVIDER_NAME` to the ID you registered, match
   `EPP_PROVIDER_AUTH_MODE` to the adapter, and add the channel settings and any
   extra settings your code actually reads. See the
   [configuration reference](CONTRACT.md#4-configuration-app-settings--env).
   For local evaluation-only runs, omit provider settings to avoid credential warmup.

The local JSON supplies environment variables to the Functions host. It doesn't
register an adapter, configure Azure, or load itself into unit tests. Apply cloud
settings separately when deploying. Provider profile JSON has a different purpose,
described in the optional setup section below.

<a id="step-7-check-endpoints-timeouts-and-privacy"></a>

## 4. Test the adapter

1. Add tests beside the existing [JavaScript tests](../javascript/test/),
   [C# tests](../dotnet/tests/) or [Python tests](../python/tests/).
   Check registration, credential failures, settings, both supported channels,
   successful and failed responses, timeouts, and evaluation without a send.
2. Keep sends on the shared bounded transport, restrict destinations, and fail
   closed on unknown responses. Don't add blind retries: a timed-out send may
   already have been accepted. Never log codes, secrets, message bodies or full
   phone numbers. Use the [contract](CONTRACT.md#production-limitations) for the
   existing safety limits.
3. Run your language's test runner and build before packaging. Keep the handler
   response contract unchanged: live acceptance echoes the nonce; failure omits it.

## 5. Package and deploy your changed source

1. Build your package using the
   [custom packaging instructions](../TECHNICAL.md#build-zips-locally).
   Public release packages won't contain your new adapter. C# source needs publish;
   Python source needs the documented Linux remote build.
2. Have your Azure operator deploy that package through your team's deployment
   process and apply the settings and vault permissions from step 3.
   Follow the [manual trust checklist](ONBOARDING.md#manual-deployment-trust-checklist)
   before opening public access. Easy Auth must remain enabled; the handler has
   no backup caller-authentication check.
3. Arrange the [deployed-endpoint checks](ONBOARDING.md#validate-the-deployed-endpoint)
   with your tenant administrator, including evaluation and receipt on each channel
   you intend to use. Tenant activation is a separate supported administrator/Microsoft
   process, not something adding a provider file or deploying a package enables.

## 6. Optional: extend the guided setup

Skip this for the custom-package route above. If your team also wants to maintain
its own setup integration, review these files together:

1. [setup/providers/telesign.json](../setup/providers/telesign.json) shows an existing
   deployment profile; [setup/providers/catalog.json](../setup/providers/catalog.json)
   lists the profiles offered by setup. These files describe setup choices and
   deployment values. **The Function doesn't read them to create or register providers.**
2. [Epp.Setup.psm1](../setup/support/Epp.Setup.psm1) validates profiles and maps their
   values into settings; [resources.bicep](../setup/infra/resources.bicep) applies
   them. Review the required provider-tenant, authentication and route fields,
   trust configuration, extra adapter settings and provider-specific setup behavior.
   Don't reuse another provider's tenant or assume a new JSON file is sufficient.
3. [setup/packages/catalog.json](../setup/packages/catalog.json) and
   [Epp.Packages.ps1](../setup/support/Epp.Packages.ps1) select and verify release
   assets. Those assets must include your adapter.
   [Setup-Epp.ps1](../setup/Setup-Epp.ps1) downloads supporting files from a selected,
   commit-pinned source; editing local JSON doesn't change what it downloads.
   Test your customized setup with [Providers.Tests.ps1](../setup/tests/Providers.Tests.ps1)
   and the other [setup tests](../setup/tests/), alongside the modified package,
   before offering it to customers.

The current guided catalog has no Twilio profile. This optional work is a customer
setup extension, not built-in provider support.
