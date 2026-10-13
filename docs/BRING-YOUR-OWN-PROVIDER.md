# Bring your own phone provider: Twilio walkthrough

If you want to use your own Twilio account, you'll need a developer to add a provider
adapter to one of this sample's language implementations. The adapter translates the
sample's delivery request into a Twilio API request. **Twilio isn't included in the
release packages or guided setup**, so your team will write, test, and maintain that
code. This guide isn't a ready-to-deploy integration.

The steps below show where to make those changes and what to keep from the existing
sample. They link to repository files and official Twilio examples rather than adding
another implementation to copy. Twilio is the provider used for this walkthrough,
not a recommendation over other providers.

Start with steps 1-5, choose **one language** in step 6, then work through testing
and deployment in steps 7-9.

## 1. Check access and choose a language

Before buying services or deploying, talk to your tenant administrator and Microsoft
about whether this provider can be used with Entra External Phone Provider (EPP).
Follow the [access guidance](ONBOARDING.md#before-purchasing-or-deploying) to confirm
eligibility and the supported testing and activation process. A Twilio account
doesn't establish Security Store availability or enable the tenant feature. If that
access isn't available, you can still work on the adapter offline.

Choose [JavaScript, C#, or Python](../TECHNICAL.md#implementations) and work in your
own source checkout. Ask whoever manages your Azure deployment and Twilio account
to help with the settings, senders, and credentials later in the guide.

The [setup catalog](../setup/providers/catalog.json) contains Telesign and Soprano.
Don't select one as a substitute for Twilio: their credentials, provider tenants
and deployment profiles are different. Adding a catalog entry or changing an app
setting won't create the adapter.

## 2. Gather the details you'll need

Work with your Twilio account owner to collect these details. You don't need a live
API key or Azure resources to start coding; use fake credentials and HTTP responses
until you're ready for the deployment steps.

1. Identify the account or subaccount that will send the messages and calls.
   Its Account SID starts with `AC`, followed by 32 hexadecimal characters.
   This is the account identifier in the API URLs, not the API-key username.
2. Check the SMS sender and voice caller ID separately. SMS needs a sender allowed
   for the account and destination; voice needs a Twilio number or verified outgoing
   caller ID. Use E.164 numbers with a leading plus sign. Check recipient consent,
   sender registration, geographic permissions, trial restrictions, capacity and costs.
   Don't assume one number can serve both channels.
3. Decide which voice languages you'll support and which test recipients you'll use.
   The developer will need these choices when building and testing the voice request.
4. Read [Create API keys in Twilio Console](https://www.twilio.com/docs/iam/api-keys/keys-in-console).
   The current Console path is **Settings > Account settings > API keys & auth tokens**;
   the page also covers the legacy Console. Choose a key type with the permissions
   needed for Messages and Calls. The Accounts segment in a send URL doesn't mean
   you need a broad Main key.
5. Match the key's region to the API host using
   [Twilio's regional credential guidance](https://www.twilio.com/docs/global-infrastructure/manage-regional-api-credentials).
   An API key SID starts with `SK`, followed by 32 hexadecimal characters, and has
   a separate secret. Twilio shows a new secret only once. Arrange to save it directly
   into Key Vault when you create the key in step 9, not into the developer's notes,
   a screenshot or a ticket.

Ask your Azure operator which vault and managed identity the Function will use.
If they don't exist yet, leave their actual URL and identity ID for deployment.
For now, the developer needs to know how those values will reach the adapter.

## 3. Keep Entra's delivery flow intact

Read the [HTTP contract](CONTRACT.md) before changing the handler. The new adapter
should fit into the existing flow, not replace it:

1. Keep caller authentication, envelope validation and JWE decryption as they are.
   Easy Auth authenticates the Microsoft caller before the anonymous Function runs.
   Encryption and nonce possession aren't caller authentication. The incoming bearer
   token must never be sent to Twilio.
2. Deliver the message Entra gives you. It already contains the generated code and
   localized text; Entra also validates that code. Use Programmable Messaging and
   Voice, not Twilio Verify's code-generation/verification workflow. Forward the
   SMS message unchanged rather than generating a new code or applying a template.
3. Leave the evaluation branch before provider lookup, credential acquisition and
   sending. Mode `2` or `evaluation` validates and decrypts, then echoes the nonce
   without delivering anything. Credential caches may warm or refresh independently,
   but those tasks must never send a message.
4. Let the incoming channel choose SMS or voice, while server settings choose the
   account, sender, vault and endpoints. Don't take those settings from the caller.
   `OtpDelivery` carries the phone, message, channel, tracing IDs and locale, but
   not the decrypted context's `extension` or `riskContext`. Supporting office
   extensions or risk policy needs separate model and contract changes.
5. Keep response creation in the handler. A successful live send returns HTTP `200`
   with the original nonce only after recognized provider acceptance; failures omit
   it. Twilio's resource SID is provider metadata, not the nonce, and tracing IDs
   aren't idempotency keys.

## 4. Map the request to Twilio

Use [Twilio's API request reference](https://www.twilio.com/docs/usage/requests-to-twilio)
for authentication: HTTP Basic over HTTPS, with the **API key SID as username and
API key secret as password**. Account SID plus Auth Token is a different pair.
This integration uses the sample's API-key credential path, not its OAuth
client-assertion exchange.

1. For SMS, open [Create a Message](https://www.twilio.com/docs/messaging/api/message-resource#create-a-message-resource)
   and use its complete account-specific Messages URL. Map the destination to `To`,
   your SMS sender to `From`, and the original message to `Body`. This walkthrough
   covers immediate sends from a number; Messaging Services, scheduling, templates
   and other channels need their own mappings.
2. For voice, open [Create a Call](https://www.twilio.com/docs/voice/api/call-resource#create-a-call)
   and [TwiML Say](https://www.twilio.com/docs/voice/twiml/say). Use the complete Calls
   URL, destination in `To`, and caller ID in `From`. Turn the rendered message into
   speech instructions and put the XML in the inline `Twiml` form field. Don't also
   set `Url`: it overrides inline TwiML and adds another endpoint handling the code.
3. Send both requests with `POST`, `application/x-www-form-urlencoded` content and
   JSON responses requested. Use a form encoder so plus signs, ampersands, equals
   signs, Unicode and XML survive unchanged. The voice XML is a form-field value,
   not the HTTP body's content type.
4. Build voice XML with a serializer, reject characters forbidden in XML 1.0, and
   check the 4,000-character TwiML limit after serialization. Choose supported
   voice/language pairs from the Say reference. Decide what to do when locale is
   absent, and reject unsupported combinations instead of reading a localized
   message in the wrong language. The existing Telesign adapters show how to pace
   standalone six-digit runs while keeping leading zeros; don't assume every code
   has that length. Decide how often to repeat the message and test the audio.
5. Map the response using the official
   [Message states](https://www.twilio.com/docs/messaging/api/message-resource#message-status-values)
   and [Call states](https://www.twilio.com/docs/voice/api/call-resource#call-status-values).
   For this immediate-send policy, require HTTP `201 Created`, a valid SID for the
   operation, and one of the success states below.

| Channel | SID shape | Success states for this policy | Failure states |
| --- | --- | --- | --- |
| SMS | `SM` plus 32 hexadecimal characters | `queued`, `sending`, `sent`, `delivered` | `failed`, `undelivered`, `canceled` |
| Voice | `CA` plus 32 hexadecimal characters | `queued`, `ringing`, `in-progress`, `completed` | `busy`, `failed`, `no-answer`, `canceled` |

Fail closed on invalid JSON, wrong field types, missing or unknown SIDs/states,
and non-201 responses, even if the body looks successful. SMS `accepted` belongs
to Messaging Services; `scheduled` isn't success for immediate delivery.
Return the runtime's `ProviderResult` and let its existing HTTP mapping handle
errors. Don't turn a generic Twilio error into `Block` or return raw error text.

You only wait for provider acceptance here, not handset delivery. A queued message
hasn't necessarily arrived, and a completed call may have reached voicemail or an IVR.
You'll check actual receipt during the live tests in step 9.

## 5. Plan the settings and secret lookup

Agree on the settings with your Azure operator before implementing the adapter.
The [shared configuration](CONTRACT.md#4-configuration-app-settings--env) already
provides the common settings below. You'll choose your own names for the additional
account/sender settings and vault secrets, then use those names consistently in
code, deployment configuration and tests.

| Setting or input | How the adapter uses it |
| --- | --- |
| `EPP_PROVIDER_NAME` | Selects the fixed ID you register for the new adapter |
| `EPP_PROVIDER_AUTH_MODE` | Matches the adapter's `apiKey` mode |
| Adapter-owned account SID setting | Supplies the account used in both operation URLs |
| Adapter-owned per-channel sender settings | Supply the SMS sender and voice caller ID |
| `EPP_PROVIDER_SMS_ENDPOINT`, `EPP_PROVIDER_VOICE_ENDPOINT` | Supply the complete Messages and Calls URLs |
| Customer-defined API key SID/secret vault names | Resolve into credential `identity` and `secret`, respectively |
| `KEY_VAULT_URL`, optional `AZURE_CLIENT_ID` | Select the provider-secret vault and its user-assigned reader; omit the client ID for system-assigned identity |
| `EPP_KEY_VAULT_CACHE_ENABLED` | Controls API-key caching; defaults to true, false acquires per live request |
| `EPP_PROVIDER_TIMEOUT_MS` | Sets the provider budget; default 1,500 ms, capped at 2,500 ms |

Keep credentials in Key Vault, separate from the decryption-key reference and
caller-authentication settings. The operator will attach the reader identity, if
user-assigned, and grant scoped secret-read access such as Key Vault Secrets User.
Setting a client ID doesn't attach an identity or grant permission. These resolvers
use managed identity, not your workstation's Azure CLI login.

JavaScript and Python pass raw adapter settings through `config.env`; C# passes
`IEnv`. You can read your new settings there without adding Twilio properties to
the shared configuration class. Validate them in customer code and restart workers
after changing deployed settings.

Keep the [credential cache behavior](CONTRACT.md#credential-caching-and-refresh)
when you add the adapter. JavaScript/Python can refresh in the background; C# warms
at startup and fetches on a cache miss, without a poller. These caches assume one
provider/account per deployment, not account switching per request. Plan key rotation
and cache invalidation with the operator. JavaScript checks vault secret metadata,
while Python/.NET's string resolvers don't expose it; their expiry handling isn't
identical, and cache lifetime isn't a Twilio credential lifetime.

## 6. Add the adapter in your chosen language

Follow just one section below. The Telesign files are useful references for the
sample's structure, but their JSON payloads and numeric status rules aren't Twilio's.
For provider-specific examples, use the official
[server-side SDK references](https://www.twilio.com/docs/libraries). Those libraries
aren't installed in this sample; keep the existing transport, timeout and result
contracts rather than replacing them with a standalone SDK send.

### JavaScript

1. Start with [telesign.js](../javascript/src/functions/providers/telesign.js).
   Add your module beside it in [the providers folder](../javascript/src/functions/providers/)
   with `name`, `authenticationMode`, `credentialSpec`, `createRequest` and
   `interpretResponse`. In `credentialSpec`, select API-key mode with `mode` and
   map the secret/SID vault names through `keyVaultSecretName` and
   `identityKeyVaultSecretName`.
2. Reuse [credentials.js](../javascript/src/functions/credentials.js)'s
   `CredentialTokenService` and `ApiKeyCache` to retrieve `identity` and `secret`.
   In `createRequest`, validate the pair and build the Basic header. Read your
   settings from the `env` preserved by [config.js](../javascript/src/functions/config.js)
   and passed by [SendOtp.js](../javascript/src/functions/SendOtp.js).
3. Use `URLSearchParams` for the form fields from step 4. Return the request object
   for [providerTransport.js](../javascript/src/functions/providerTransport.js)
   to send and parse; don't add another fetch inside the adapter.
4. In `interpretResponse`, read Twilio's top-level `sid` and string `status`.
   Return [ProviderResult](../javascript/src/functions/providerResult.js) with the
   outcome, status recognition, provider HTTP status, validated SID and fixed safe
   failure classification.
5. Import your module in [providers/index.js](../javascript/src/functions/providers/index.js),
   add its ID to `selectProvider`, and include it in the exports. Keep the other
   adapters and SendOtp's evaluation/startup/shutdown behavior.
6. Add tests in [provider-flow.test.js](../javascript/test/provider-flow.test.js),
   [credential-cache.test.js](../javascript/test/credential-cache.test.js) and
   [sendotp.test.js](../javascript/test/sendotp.test.js). The offline runner is in
   [package.json](../javascript/package.json); the [JavaScript guide](../javascript/README.md)
   covers local setup.

<a id="c-net"></a>

### C# (.NET)

1. Read [TelesignProvider.cs](../dotnet/Src/Providers/TelesignProvider.cs) and
   [PhoneProviderBase.cs](../dotnet/Src/PhoneProviderBase.cs). Add your class in
   [Src/Providers](../dotnet/Src/Providers/), deriving from `PhoneProviderBase`.
   Implement `Name`, `AuthenticationMode`, `FetchCredentialsAsync` and `SendOtpAsync`.
2. Inject [ISecretResolver](../dotnet/Src/ISecretResolver.cs) and use
   [SecretResolver](../dotnet/Src/SecretResolver.cs) to read your two vault names
   with cancellation. Validate the pair and return
   [ProviderCredentials](../dotnet/Src/Models.cs) with mode, `Identity`, `Secret`
   and a finite `ExpiresOn`. Existing API-key adapters use a five-minute cache expiry.
3. Build an `HttpRequestMessage` with `FormUrlEncodedContent`, the Basic header and
   JSON response preference. Read your settings through `IEnv`. Replace the reference
   adapter's `JsonContent` and response DTO with the Twilio form and top-level SID/status.
4. Use `PhoneProviderBase.SendJsonAsync` for the send and typed response mapping.
   Despite the name, it expects a JSON **response**, not a JSON request: the request
   factory can return form content. Return `ProviderResult` using the step 4 rules.
5. Register the new class as another singleton `PhoneProviderBase` in
   [Program.cs](../dotnet/Program.cs). Keep the existing resolver,
   [CredentialTokenService](../dotnet/Src/CredentialTokenService.cs) and named HTTP
   client, including redirect rejection and log filtering.
   [SendOtp.cs](../dotnet/Functions/SendOtp.cs) already selects registered providers
   by name; you don't need to replace its selector or evaluation branch.
6. Add tests in [ContractTests.cs](../dotnet/tests/ContractTests.cs),
   [CredentialTokenServiceTests.cs](../dotnet/tests/CredentialTokenServiceTests.cs)
   and [SendOtpTests.cs](../dotnet/tests/SendOtpTests.cs). Use
   [Epp.Otp.Tests.csproj](../dotnet/tests/Epp.Otp.Tests.csproj) and the
   [C# guide](../dotnet/README.md) for local build/test setup.

### Python

1. Read [telesign.py](../python/src/providers/telesign.py) and
   [provider.py](../python/src/provider.py). Add your module in
   [src/providers](../python/src/providers/) with a `PhoneProviderBase` subclass.
   Implement `name`, `authentication_mode`, `credential_spec`, `build_request`
   and `map_response`.
2. In `credential_spec`, select API-key mode and map your vault names through
   `key_vault_secret_name` and `identity_key_vault_secret_name`. Reuse
   [credentials.py](../python/src/credentials.py) and [secrets.py](../python/src/secrets.py)
   to retrieve `secret` and `identity`, then validate them before building the header.
3. Read your settings from `env`, which [config.py](../python/src/config.py)
   preserves for `build_request`. Use `urllib.parse.urlencode` and return an
   `OutboundRequest` with a string form body. The shared transport sends it through
   `data`, not `json`.
4. Map Twilio's SID/string status into [ProviderResult](../python/src/models.py).
   Use `provider.py`'s safe failure classifier and HTTP mapping; unsuccessful
   responses must stay unsuccessful even when the body looks valid.
5. Import your class in [function_app.py](../python/function_app.py) and include
   an instance in the tuple that builds `_providers`.
   [providers/__init__.py](../python/src/providers/__init__.py) needs no registration.
   Keep the existing credential service, startup warmer, `atexit` cleanup and
   evaluation branch.
6. Add tests in [test_engine.py](../python/tests/test_engine.py),
   [test_credential_cache.py](../python/tests/test_credential_cache.py) and
   [test_function_app.py](../python/tests/test_function_app.py). Follow the
   [Python guide](../python/README.md) for local setup and the test runner.

Once the adapter is registered, review the send behavior below before running
the full tests.

<a id="step-7-check-endpoints-timeouts-and-privacy"></a>

## 7. Keep sends safe

1. Check the complete destination before sending credentials. The shared validators
   require HTTPS and reject URL credentials/fragments; transports disable redirects.
   **HTTPS alone isn't an SSRF or destination allowlist.** Also restrict the host,
   account and operation path. Reject unrelated hosts, extra ports, queries, userinfo
   and wrong channel paths. If you need another region/edge or a custom gateway,
   review its host/port list, DNS/egress controls and matching regional credentials.
2. Keep the existing timeout and credential-acquisition bounds. JavaScript/.NET
   bound sending and reading the response body; Python Requests uses connect/read
   inactivity, not a hard total deadline. Cold starts and credential reads add time.
   `ttlSeconds` validation doesn't impose a delivery deadline, and the adapter model
   doesn't carry it. Check provider queue lifetime separately. Calls' `Timeout`
   parameter controls ringing, not the Function's HTTP timeout.
3. Don't add automatic send retries or background delivery after replying. A timeout,
   lost/malformed response or generic error can happen after Twilio accepted the send.
   Returning failure can also trigger Entra's native fallback. The sample has no
   durable deduplication or idempotency contract; read the separate
   [fallback walkthrough](MULTI-PROVIDER-IMPLEMENTATION.md) before adding another attempt.
4. Use the existing sanitized logging helpers. Don't log the message/code, nonce,
   full phone number, decrypted context, form/TwiML, Authorization header, credentials,
   raw provider bodies or exception strings. Turn off body/header tracing in proxies
   and SDKs. Endpoint paths appear in telemetry, so keep secrets out of URLs and
   restrict access to account identifiers. Review Twilio-side retention too, and
   don't enable call recording or transcription to debug code delivery.

## 8. Test before using live credentials

Use fake secret resolvers and HTTP responses in the test files linked for your
language. Cover more than a successful API request:

1. Check that registration selects the new adapter and existing IDs still work.
   Missing or invalid account, sender, endpoint, auth mode or credentials must fail
   before a send, including vault failures and blank/wrong key SIDs.
2. Check the exact vault names and SID/secret positions in Basic auth. Exercise
   caching on/off, expiry, rotation, startup failures, concurrent acquisition and shutdown.
3. Round-trip SMS text and E.164 plus signs through the form encoder, including
   Unicode, ampersands and equals signs. Parse the voice XML and test injection,
   forbidden characters, leading-zero pacing, non-six-digit codes, repetition,
   absent/unsupported locales and the serialized 4,000-character boundary.
4. Test every success/failure state in step 4, plus missing/wrongly typed SID/status,
   invalid JSON and unknown states. Success-looking bodies under 401/403, 429,
   other 4xx or 5xx must fail. Test redirects, timeouts and connection/read errors
   with one attempt only.
5. Check the handler: live acceptance echoes the decrypted nonce, failure omits it,
   evaluation skips provider validation/acquisition/send, and invalid envelopes/JWE
   never reach provider I/O. Background credential refresh isn't evaluation-path
   acquisition or delivery.
6. Check captured logs for fixture codes, secrets, phone numbers, bodies and headers.
   Then run the existing test runner and build for your language.

When these pass, give the operator your modified source, build results and the
settings/secret names you chose. Keep live secrets out of that material.

## 9. Deploy your build and test delivery

This part uses your team's deployment process; the sample doesn't provide a Twilio
deployment workflow. Work with your Azure operator, Twilio account owner and tenant
administrator rather than trying to complete it through the guided provider menu.

1. Package **your modified source** using the
   [custom packaging instructions](../TECHNICAL.md#build-zips-locally).
   The public packages don't contain your adapter. .NET's source ZIP needs publish;
   Python's source ZIP needs Linux remote dependency build. Building a ZIP doesn't
   deploy it or configure authorization.
2. Have the operator prepare the nonproduction resources using the
   [language guide](../TECHNICAL.md#implementations) and
   [manual trust checklist](ONBOARDING.md#manual-deployment-trust-checklist).
   Attach the vault-reader identity and grant its access as planned in step 5.
   Set up the decryption-key reference and certificate lifecycle, then verify Easy Auth
   and the caller allowlist **before opening public ingress**. The anonymous handler
   has no backup token validator.
3. When the vault is ready, have the account owner create the regional API key
   using the Console instructions from step 2, or use the agreed existing pair.
   Store the SID and secret under the names your adapter reads. The operator can
   now set the other app settings as strings and deploy the modified package,
   using publish or remote build as required. Restart and check credential resolution
   without logging values.
4. Arrange the [deployed-endpoint checks](ONBOARDING.md#validate-the-deployed-endpoint)
   with the tenant administrator: caller rejection, evaluation, then live SMS receipt
   and voice receipt/audio for every supported locale. Check credential rotation,
   ambiguous outcomes and [monitoring](MONITORING.md) too. Offline tests, HTTP 201,
   Twilio test credentials and a nonce echo don't replace these delivery checks.
5. Review [production limitations](CONTRACT.md#production-limitations), agree who
   handles support and rollback, and save the test results in restricted storage.
   Tenant activation is a separate administrator/Microsoft process; these steps
   don't change policy or authorize activation.

Twilio's Console and API details can change. The linked references were checked on
October 13, 2026; use the current pages as you implement and deploy.
