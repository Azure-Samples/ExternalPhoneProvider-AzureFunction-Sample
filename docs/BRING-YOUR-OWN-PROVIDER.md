# Bring your own phone provider: Twilio walkthrough

Follow these steps to extend this Azure Function sample for a customer-owned Twilio
integration. This guide tells you **where to change the code and what to implement**;
it links existing repository implementations and official Twilio examples rather than
providing another implementation to copy.

**There is no Twilio adapter in this repository or its release packages.** You must
write, register, test, and maintain one in your own source. Twilio is the requested
illustrative provider, not a preferred provider, endorsement, or statement of Microsoft
Entra External Phone Provider (EPP) eligibility.

Complete steps 1-5, follow **one** language path in step 6, then finish steps 7-9.
These are developer instructions, not an alternative guided setup or an activation procedure.

## Step 1: Confirm access and assign owners

1. Read [access and support guidance](ONBOARDING.md#before-purchasing-or-deploying).
   Before purchasing or deploying, confirm provider eligibility and the approved
   testing/activation procedure with Microsoft and your tenant administrator.
   A Twilio account or this guide does not establish Security Store availability
   or permission to activate EPP. If access is unavailable, limit work to offline development.
2. Check the [guided setup catalog](../setup/providers/catalog.json). It contains
   Telesign and Soprano, not Twilio. Do not select another provider as a stand-in:
   its credentials, provider tenant, authorization, and deployment profile are different.
   Changing app settings or adding a catalog entry alone does not implement an adapter.
3. Assign a developer to maintain the adapter, an operator to own the deployment and
   Key Vault access, a provider-account owner to manage senders/credentials/costs, and
   a tenant administrator to coordinate approved testing and activation.
4. Choose one runtime from the [technical reference](../TECHNICAL.md#implementations).
   Use a customer-owned source checkout and that runtime's documented toolchain.
   Keep offline tests on fake credentials/transports; local Function execution has no
   Easy Auth and must remain loopback-only, without tunnels.

**Checkpoint:** owners understand that this is a custom code extension, not bundled
Twilio support or permission to deploy/activate an unapproved integration.

## Step 2: Collect account, sender, and credential inputs

1. Identify the Twilio account or subaccount that will own the messages/calls.
   Record its Account SID privately: it starts with `AC` followed by 32 hexadecimal
   characters. This identifies the account in operation URLs, not the API-key username.
2. Confirm the required channels and destinations with the account owner. SMS needs
   a sender approved for that account and destination. Voice needs a Twilio number
   or an authorized verified outgoing caller ID. Record E.164 numbers with their
   leading plus sign. Check sender registration, recipient consent, geographic
   permissions, trial-recipient restrictions, capacity, and charges.
3. Read [Create API keys in Twilio Console](https://www.twilio.com/docs/iam/api-keys/keys-in-console).
   Its current and legacy Console sections provide the navigation for the appropriate UI:
   current **Settings > Account settings > API keys & auth tokens**.
   When authorized to provision credentials, select the correct region and a key type
   with the narrowest permissions compatible with Messages and Calls. Do not require
   a broad Main key just because the send URLs contain the Accounts path.
4. Keep the API key SID (`SK` followed by 32 hexadecimal characters) separate from
   its secret. Twilio displays the secret only once; arrange secure capture into
   the approved vault, not a screenshot, ticket, source file, or shared log.
   Follow [regional credential guidance](https://www.twilio.com/docs/global-infrastructure/manage-regional-api-credentials):
   keys are valid only in their own Twilio region.
5. Record the approved vault URL, its reader managed identity, and the nonproduction
   environment used for eventual authorized testing. Do not execute purchases,
   deployments, or sends merely to complete this worksheet.

Use the following as an **input checklist**, not a settings file:

| Input | What to confirm |
| --- | --- |
| Account SID and region | The account owning both operations; credentials and API host use the same Twilio region |
| SMS sender and voice caller ID | E.164 numbers approved for each channel; do not assume one number supports both |
| API key SID and secret | Correct pair and operation permissions; a rotation/revocation owner |
| Supported voice locales | Approved voice/language pairs and a defined policy for absent or unsupported locales |
| Vault and reader identity | Identity attached to the Function when needed, with scoped secret-read permission |
| Test destinations and budget | Explicitly approved nonproduction recipients and channel-specific acceptance checks |

**Checkpoint:** account, API key SID, and API key secret are distinct inputs; sender,
region, locale, and recipient requirements are known before implementation.

## Step 3: Preserve the request and authentication contract

1. Read the [HTTP contract](CONTRACT.md). Keep the existing envelope validation,
   pinned JWE algorithms, decryption, and caller allowlist. Easy Auth authenticates
   the Microsoft caller before the anonymous Function; JWE and nonce possession do
   not authenticate that caller. Never forward the inbound bearer token to Twilio.
2. Deliver Entra's **already rendered, localized message**. Entra generates and
   validates the OTP; the adapter only delivers it. Use Programmable Messaging and
   Voice, not Twilio Verify's OTP-generation/verification workflow. Preserve SMS
   text instead of generating a replacement code or applying another template.
3. Leave the evaluation branch before provider selection/acquisition/send.
   Incoming mode `2` or `evaluation` validates/decrypts and echoes the nonce without
   provider delivery. Enabled credential caches can prewarm/refresh independently;
   those tasks must never send an OTP. Evaluation is not an adapter or delivery test.
4. Keep provider/account/vault/sender/endpoints in server-owned configuration.
   Incoming channel selects SMS or voice, not the account or URL. The current
   `OtpDelivery` includes phone, message, channel, tracing IDs and locale, but not
   the decrypted context's `extension` or `riskContext`. Office extensions and risk
   policy require separate model/contract work; do not claim they are implemented.
5. Keep success responses in the existing handler: only recognized live acceptance
   permits HTTP `200` with the original nonce. Failures omit it. A Twilio SID is
   provider metadata, not the nonce, and tracing IDs are not idempotency keys.

**Checkpoint:** the customer extension changes provider behavior, not the Entra
authentication, encryption, evaluation, or response protocol.

## Step 4: Define SMS, voice, and response behavior

1. Open [Twilio API requests](https://www.twilio.com/docs/usage/requests-to-twilio).
   Use HTTP Basic authentication over HTTPS: **API key SID as username, API key
   secret as password**. Account SID plus Auth Token is a different credential pair
   and is not the pair selected in this walkthrough. Do not use the sample's OAuth
   client-assertion path for these Twilio operations.
2. Open [Create a Message](https://www.twilio.com/docs/messaging/api/message-resource#create-a-message-resource).
   Use its complete account-specific Messages URL for SMS. Map the delivery phone
   to `To`, the approved SMS sender to `From`, and the original rendered message
   to `Body`. This walkthrough uses an immediate send with a From number; Messaging
   Services, templates, scheduling, and other channels need separate reviewed mappings.
3. Open [Create a Call](https://www.twilio.com/docs/voice/api/call-resource#create-a-call)
   and [TwiML Say](https://www.twilio.com/docs/voice/twiml/say).
   Use the complete account-specific Calls URL, mapping destination to `To` and
   caller ID to `From`. Generate speech instructions from the rendered message
   and submit them in the inline `Twiml` field. Do not also supply `Url`, which
   overrides inline TwiML and introduces another endpoint handling OTP content.
4. Encode both requests as `application/x-www-form-urlencoded`, with `POST` and
   JSON responses requested. Use the language's form encoder, not concatenation:
   E.164 plus signs, ampersands, equals signs, Unicode and XML must survive.
   XML is the value of the voice form field, not the HTTP body's content type.
5. Define voice rules before enabling a locale. Escape text with an XML serializer,
   reject characters forbidden in XML 1.0, and enforce Twilio's 4,000-character
   inline TwiML limit **after** serialization. Select supported voice/language pairs
   from the Say reference; do not silently read a localized message in a different
   language. Decide the absent-locale policy and reject unsupported combinations.
   Use the existing Telesign adapters' digit-pacing logic as a reference for
   standalone six-digit runs and leading zeros, not a universal OTP-length rule.
   Agree on repetition and test audio; do not enable recording/transcription for debugging.
6. Define a fail-closed result policy using the official
   [Message states](https://www.twilio.com/docs/messaging/api/message-resource#message-status-values)
   and [Call states](https://www.twilio.com/docs/voice/api/call-resource#call-status-values).
   For this immediate-send policy, require HTTP **201 Created**, a valid
   operation-specific resource SID, and an allowed success state. Reject malformed
   JSON, wrong field types, missing/unknown states or SIDs, and non-201 responses
   even if their body looks successful.

| Channel | SID shape | Allowed success states for this policy | Failure states |
| --- | --- | --- | --- |
| SMS | `SM` plus 32 hexadecimal characters | `queued`, `sending`, `sent`, `delivered` | `failed`, `undelivered`, `canceled` |
| Voice | `CA` plus 32 hexadecimal characters | `queued`, `ringing`, `in-progress`, `completed` | `busy`, `failed`, `no-answer`, `canceled` |

7. Treat SMS `accepted` as a Messaging Service-specific state, not generic success
   for the From-number policy; do not accept `scheduled` for immediate OTP delivery.
   Return the runtime's `ProviderResult` with fixed safe failure classifications
   and let its existing HTTP mapping handle provider errors. Do not invent `Block`
   from a generic error or expose Twilio's raw error text.
8. Stop at provider acceptance rather than waiting/polling for handset delivery.
   Queued does not mean received; completed voice may have reached voicemail or
   an IVR. Use the later channel-specific checks to confirm recipient receipt.

**Checkpoint:** the developer has explicit field mappings, voice rules and response
states, with official references for the selected API rather than another provider's schema.

## Step 5: Plan settings and Key Vault wiring

1. Read [shared configuration](CONTRACT.md#4-configuration-app-settings--env) and
   [credential caching](CONTRACT.md#credential-caching-and-refresh). Use one
   provider/account per deployment; the existing caches are not per-request account routers.
2. Choose and document customer-owned names for the account/sender settings and
   two vault secrets. Use them consistently in adapter code, deployment configuration
   and tests. The table distinguishes those inputs from settings that already exist;
   it does not introduce recognized Twilio options.

| Existing setting or customer-owned input | Customer wiring required |
| --- | --- |
| Existing `EPP_PROVIDER_NAME` | Register a fixed Twilio adapter ID before selecting it here; settings alone cannot add it |
| Existing `EPP_PROVIDER_AUTH_MODE` | Match the adapter's `apiKey` mode; that mode retrieves secrets, while the adapter builds Basic auth |
| Adapter-owned account SID setting | Choose its name, then read and validate the account used in both operation URLs |
| Adapter-owned per-channel sender settings | Choose their names, then read and validate each channel's approved sender/caller ID |
| Existing `EPP_PROVIDER_SMS_ENDPOINT`, `EPP_PROVIDER_VOICE_ENDPOINT` | Complete Messages and Calls URLs from step 4, respectively |
| Customer-defined API key SID/secret vault names | Resolve the SID into credential `identity`, and the secret into credential `secret` |
| Existing `KEY_VAULT_URL`, optional `AZURE_CLIENT_ID` | Use the provider-secret vault and its user-assigned reader identity; without a client ID, use system-assigned identity |
| Existing `EPP_KEY_VAULT_CACHE_ENABLED` | Select API-key caching; omission defaults to true, false acquires per live request |
| Existing `EPP_PROVIDER_TIMEOUT_MS` | Set a positive millisecond budget within the existing 2,500 ms cap; default is 1,500 ms |

3. Keep credential values in Key Vault, not app settings/local files. Have the operator
   attach the chosen user-assigned identity when applicable and grant scoped read
   access, such as Key Vault Secrets User. A client-ID setting alone does neither.
   The sample's resolvers use managed identity, not local Azure CLI sign-in.
   Keep provider credentials separate from the existing decryption-key reference
   and caller-authentication settings.
4. Read adapter-owned settings through the existing JavaScript/Python `config.env`
   or C# `IEnv`; the current shared configuration need not gain Twilio properties
   for that approach. Validate server-owned configuration and restart workers when
   it changes. Configure credentials only after implementing the language path below.
5. Preserve acquisition bounds, sanitized failures and shutdown behavior.
   JavaScript/Python can refresh API-key caches in the background; C# warms at
   startup and fetches on cache miss, without a poller. Coordinate SID/secret rotation
   and cache invalidation. JavaScript checks vault secret metadata; Python/.NET's
   current string resolvers do not expose it. Do not promise identical secret-expiry
   enforcement across runtimes or treat cache lifetime as Twilio-issued expiry.

**Checkpoint:** the new adapter owns its setting/secret names and Basic header; the
shared secret service remains the managed-identity retrieval/cache abstraction.

## Step 6: Implement and register one language path

Follow only your chosen language section, then continue at
[step 7](#step-7-check-endpoints-timeouts-and-privacy).
Read the linked repository files for the sample's shape and the official
[Twilio server-side SDK references](https://www.twilio.com/docs/libraries) for
API-specific examples. SDKs are references, not installed dependencies or a reason
to bypass the sample's bounded transport, logging and result contracts.

### JavaScript

1. Open [telesign.js](../javascript/src/functions/providers/telesign.js).
   Identify `name`, `authenticationMode`, `credentialSpec`, `createRequest` and
   `interpretResponse`. Its two-secret Basic-auth structure is useful prior art,
   but its JSON request and nested numeric status mapping are **not Twilio's API**.
2. Add a new customer-owned provider module beside it in
   [the providers folder](../javascript/src/functions/providers/). Implement those
   same entry points for the Twilio policy in step 4. In `credentialSpec`, use
   `mode`, `keyVaultSecretName` and `identityKeyVaultSecretName` to select API-key
   mode and your secret/SID names from step 5.
3. Open [credentials.js](../javascript/src/functions/credentials.js).
   Reuse `CredentialTokenService` and `ApiKeyCache`; they already return `identity`
   and `secret` from those names. Reject missing/invalid credentials in the adapter
   and construct the Basic header from the API key pair, not the account SID.
4. Open [config.js](../javascript/src/functions/config.js) and
   [SendOtp.js](../javascript/src/functions/SendOtp.js). `createRequest` receives
   channel, endpoint, delivery, credential and the preserved `env`. Read the
   adapter-owned settings there; use `URLSearchParams` for the form. Return the
   request object for [providerTransport.js](../javascript/src/functions/providerTransport.js)
   to send and parse. Do not perform a second fetch inside the adapter.
5. Use [providerResult.js](../javascript/src/functions/providerResult.js) to return
   `ProviderResult` from `interpretResponse`, including recognition, provider HTTP
   status, validated SID, allowed state, outcome and safe failure classification.
   Twilio returns top-level `sid` and string `status`, not Telesign's status object.
6. Open [providers/index.js](../javascript/src/functions/providers/index.js).
   Import the new module, add its fixed ID to `selectProvider`, and expose it beside
   the existing exports. Leave other adapters intact. Keep the handler's evaluation
   short-circuit, credential warmup and termination hooks unchanged.
7. Add cases to [provider-flow.test.js](../javascript/test/provider-flow.test.js),
   [credential-cache.test.js](../javascript/test/credential-cache.test.js) and
   [sendotp.test.js](../javascript/test/sendotp.test.js), using the checks in step 8.
   Run the offline test script defined in [package.json](../javascript/package.json)
   from the JavaScript app folder, following the [JavaScript guide](../javascript/README.md).

**Checkpoint:** the factory selects the new adapter, both channels use the shared
transport, and mocked evaluation never invokes provider delivery.

### C# (.NET)

1. Open [TelesignProvider.cs](../dotnet/Src/Providers/TelesignProvider.cs) and
   [PhoneProviderBase.cs](../dotnet/Src/PhoneProviderBase.cs).
   Add a customer-owned class in [Src/Providers](../dotnet/Src/Providers/) deriving
   from `PhoneProviderBase`. Implement its fixed `Name`, API-key `AuthenticationMode`,
   `FetchCredentialsAsync` and `SendOtpAsync`; do not overwrite an existing provider.
2. Inject [ISecretResolver](../dotnet/Src/ISecretResolver.cs) and follow the
   [SecretResolver](../dotnet/Src/SecretResolver.cs) path to resolve your two vault
   names with cancellation. Validate the API key pair and return
   [ProviderCredentials](../dotnet/Src/Models.cs) with `Identity`, `Secret`, mode
   and a finite `ExpiresOn`. The existing API-key adapters use a five-minute
   cache expiry; this is a cache policy, not a Twilio credential lifetime.
3. Build a standard `HttpRequestMessage` using channel-specific fields from step 4,
   `FormUrlEncodedContent`, the Basic header and JSON response preference.
   Read adapter settings through the supplied `IEnv`. Replace the reference adapter's
   `JsonContent` and response DTO: Twilio's typed response needs top-level SID/status.
4. Use `SendJsonAsync` in `PhoneProviderBase` for transport and typed response mapping.
   Its name describes the **JSON response**, not a JSON request requirement:
   its request factory can return form content. Produce a `ProviderResult` under
   the step 4 policy; preserve the shared failure classifications and HTTP mapping.
5. Open [Program.cs](../dotnet/Program.cs). Register the new class as another singleton
   `PhoneProviderBase` beside existing registrations. Keep the registered
   `ISecretResolver`, `CredentialTokenService` and named HTTP client.
   [SendOtp.cs](../dotnet/Functions/SendOtp.cs)'s `SelectProvider` already searches
   registered providers by name; no replacement selector is needed.
6. Preserve [CredentialTokenService.cs](../dotnet/Src/CredentialTokenService.cs)'s
   startup and cache-miss behavior, the named client's redirect rejection/log
   filtering, the bounded send/body read, and the handler's evaluation branch.
7. Add cases to [ContractTests.cs](../dotnet/tests/ContractTests.cs),
   [CredentialTokenServiceTests.cs](../dotnet/tests/CredentialTokenServiceTests.cs)
   and [SendOtpTests.cs](../dotnet/tests/SendOtpTests.cs). Follow step 8 and run
   the test project [Epp.Otp.Tests.csproj](../dotnet/tests/Epp.Otp.Tests.csproj)
   using the [C# guide](../dotnet/README.md).

**Checkpoint:** dependency injection selects the new class and supplies its resolver;
the form request and typed JSON response use the existing transport.

### Python

1. Open [telesign.py](../python/src/providers/telesign.py) and
   [provider.py](../python/src/provider.py). Add a customer-owned module in
   [src/providers](../python/src/providers/) with a `PhoneProviderBase` subclass.
   Implement `name`, `authentication_mode`, `credential_spec`, `build_request`
   and `map_response`. Replace the reference adapter's JSON payload and numeric
   status rules with the Twilio policy in step 4.
2. In `credential_spec`, select API-key mode and your two secret names through
   `key_vault_secret_name` and `identity_key_vault_secret_name`.
   Reuse [credentials.py](../python/src/credentials.py) and
   [secrets.py](../python/src/secrets.py); they supply the SID as `identity`
   and key secret as `secret`. Validate both before constructing Basic auth.
3. Read your account and per-channel senders from the `env` passed to `build_request`;
   [config.py](../python/src/config.py) already preserves that mapping.
   Use `urllib.parse.urlencode` and return an `OutboundRequest` with a form-encoded
   string body. The shared transport sends this through `data`, not `json`.
4. Map Twilio's top-level SID/string status into
   [models.py](../python/src/models.py)'s `ProviderResult`. Reuse the safe failure
   classifier from `provider.py`, preserve non-success overrides, and keep raw
   response bodies/errors out of logs.
5. Open [function_app.py](../python/function_app.py). Import your class and include
   an instance in the tuple that constructs `_providers`. The current
   [providers/__init__.py](../python/src/providers/__init__.py) needs no registration.
   Keep the existing credential service/secret resolver, startup warmer, `atexit`
   cleanup and evaluation branch.
6. Add cases to [test_engine.py](../python/tests/test_engine.py),
   [test_credential_cache.py](../python/tests/test_credential_cache.py) and
   [test_function_app.py](../python/tests/test_function_app.py). Follow step 8
   and the test instructions in the [Python guide](../python/README.md).

**Checkpoint:** the provider dictionary selects the new subclass; form bodies,
credential refresh and evaluation use the existing shared paths.

## Step 7: Check endpoints, timeouts, and privacy

1. Require HTTPS and the correct host, account and operation path before any send.
   The shared validators reject URL credentials/fragments and transports disable
   redirects, but **HTTPS alone is not an SSRF/destination allowlist**. Pin each
   configured operation to its approved Twilio URL; reject unrelated hosts, extra
   ports, queries, userinfo, wrong accounts and wrong channel paths.
2. For another region/edge or a custom gateway, review the approved host/port list,
   DNS/egress restrictions, account/path binding and matching regional credentials.
   Do not accept endpoints from caller input or weaken checks to any HTTPS address.
   Endpoint paths appear in telemetry: keep OTPs/secrets out of paths and restrict
   access to account identifiers in operational logs.
3. Keep the sample's provider timeout normalization and separate credential-acquisition
   bounds. JavaScript/.NET bound send and response-body read; Python Requests uses
   connect/read inactivity, **not a hard total deadline**. Cold starts and acquisition
   add latency. Validating `ttlSeconds` does not impose an end-to-end delivery deadline;
   the adapter model does not carry it. Assess provider queue lifetime separately.
   Calls' `Timeout` parameter controls ringing, not the Function's HTTP timeout.
4. Disable automatic HTTP/SDK send retries and do not launch background delivery
   after responding. A timeout, lost/malformed response or generic error may occur
   **after acceptance**; returning failure can also trigger Entra native fallback.
   Do not blindly resubmit. The sample has no durable deduplication/idempotency
   contract; read the separate [fallback walkthrough](MULTI-PROVIDER-IMPLEMENTATION.md)
   before designing any secondary attempt.
5. Keep the existing sanitized event helpers. Never log message/OTP, nonce, full phone
   number, decrypted context, form/TwiML, Authorization header, credential objects,
   raw provider bodies or exception strings. Disable body/header tracing in proxies
   and SDKs; restrict Twilio-side records and retention as well.

**Checkpoint:** only approved endpoints receive credentials, each operation has one
bounded submission, and troubleshooting does not expose OTPs or secrets.

## Step 8: Test the customer changes offline

1. Test selection/configuration first: the new ID resolves only after registration,
   existing IDs still work, missing/wrong account, sender, endpoint and auth mode
   fail before send. Fake vault failures and blank/wrong key SIDs must not dispatch.
2. Test credential mapping and lifecycle: exact secret names, SID/secret positions in
   Basic auth, enabled/disabled caching, expiry/rotation, startup failures, concurrent
   acquisition and shutdown. Never use live credentials in unit tests.
3. Test both form encoders: E.164 plus signs and unchanged SMS Unicode text containing
   ampersands/equals signs round-trip. Parse generated voice XML; test injection,
   forbidden control characters, leading-zero pacing, non-six-digit codes, repetition,
   missing/unsupported locale, and the serialized 4,000-character boundary.
4. Test every allowed/failure state from step 4, malformed/missing SID/status,
   wrong field types, invalid JSON and unknown states. A success-looking response
   under HTTP 401/403, 429, other 4xx or 5xx must fail. Check timeouts, connection/read
   errors and redirects with one attempt only.
5. Test the handler boundary: live acceptance echoes the decrypted nonce, failures
   omit it, mode 2 skips provider validation/acquisition/send, and invalid
   envelopes/JWE never reach provider I/O. Background credential preparation must
   not be mistaken for evaluation-path acquisition or delivery.
6. Capture sanitized test logs and assert that fixture OTPs, secrets, phone numbers,
   bodies and headers are absent. Run the chosen runtime's existing test runner
   and build checks; offline success does not prove handset receipt.

**Checkpoint:** tests cover the actual integration shape and failure boundaries,
not just a successful standalone Twilio API request.

## Step 9: Package and arrange approved acceptance checks

1. Build from **your modified source** using
   [custom packaging instructions](../TECHNICAL.md#build-zips-locally).
   The public ZIPs do not contain your adapter. .NET's source ZIP requires publish;
   Python's source ZIP requires Linux remote dependency build. Packaging neither
   deploys infrastructure nor configures provider authorization.
2. Have the operator review customer-managed deployment/IaC, package provenance
   and identity permissions. In the approved environment, apply the adapter's agreed
   settings from step 5 as string values and its secrets through the approved vault
   procedure, then restart and validate the configuration. Preserve the existing
   decryption-key reference, encryption certificate lifecycle, Easy Auth and caller
   allowlist; this walkthrough does not make guided setup accept a custom provider.
3. Only after eligibility and an approved procedure are established, arrange the
   [authorized nonproduction checks](ONBOARDING.md#validate-the-deployed-endpoint):
   caller rejection, evaluation, live SMS receipt and voice receipt/audio for each
   supported locale. Also verify credential rotation, ambiguous outcomes and
   [monitoring](MONITORING.md). Keep Easy Auth enabled throughout.
4. Review [production limitations](CONTRACT.md#production-limitations) with the
   owners before handoff. Record restricted acceptance evidence and rollback/support
   ownership. Do not treat offline tests, HTTP 201, Twilio test credentials or a
   nonce echo as tenant activation permission or a completed live integration.

**Checkpoint:** customer code is packaged and reviewed, while live integration and
activation remain separate approved processes with explicit evidence.

## Official references and visual help

1. Use [Twilio's current API-key Console instructions](https://www.twilio.com/docs/iam/api-keys/keys-in-console)
   and [regional credential navigation](https://www.twilio.com/docs/global-infrastructure/manage-regional-api-credentials)
   for the account owner's UI. These official pages cover current/legacy navigation;
   keep secrets out of screenshots. No copied, private, or fabricated screenshots
   are included here.
2. Open [API requests/authentication](https://www.twilio.com/docs/usage/requests-to-twilio),
   [Messages](https://www.twilio.com/docs/messaging/api/message-resource),
   [Calls](https://www.twilio.com/docs/voice/api/call-resource) and
   [Say](https://www.twilio.com/docs/voice/twiml/say) to view official examples in your
   language. Use [server-side SDK links](https://www.twilio.com/docs/libraries) for
   library-specific details; do not copy message/credential logging or quickstart
   deployment choices into this endpoint.
3. Recheck provider instructions and capabilities before using customer code.
   The linked authentication, API, voice and credential sources were reviewed on
   October 13, 2026. This is source-based guidance, not a live integration test.
