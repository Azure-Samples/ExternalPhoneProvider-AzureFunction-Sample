# EPP Onboarding

Follow these five steps for the External Phone Provider (EPP) Function. Choose one language:
[JavaScript](../javascript/README.md), [Python](../python/README.md), or [.NET](../dotnet/README.md).
Use [CONTRACT.md](CONTRACT.md) for the full request contract and production limitations.

1. **Purchase a provider offer from Security Store.**

	 Open **Security Store > Provider offers**, purchase an offer, and activate the provider account.
	 Confirm EPP endpoint access and support for your required channels. Obtain the provider's API key
	 and matching customer/API ID, if required.
	 Purchasing an offer does not deploy this Function or install a missing provider adapter.

2. **Run the app setup script.**

   <a id="setup-script-compatibility"></a>
   Use the [guided EPP setup](../setup/docs/README.md) after manually creating only the dedicated
   endpoint application registration. Download only `setup/Setup-Epp.ps1`; it retrieves commit-pinned support scripts,
   Bicep, provider profiles, and the selected language package. Choose a provider, SMS or voice,
   Global or EU, and a resource prefix, then approve one complete deployment plan.

   After approval, the script configures the app registration and enterprise application, creates
   the Microsoft phone-provider service principal, assigns `Epp.Invoke`, grants it Microsoft Graph
   `Application.Read.All`, and restricts the multi-tenant app through the Entra allowed-tenants
   preview to its home tenant plus the selected provider tenant. It then deploys the Function and
   configures Easy Auth. It does not purchase the provider offer, grant provider API consent/roles,
   or activate the EPP policy.

3. **Complete provider authentication and settings.**

   <a id="provider-credential-names"></a>
   The setup script writes the selected provider route and authentication settings:

   | Provider | API credential secret | Matching identity secret | Authentication |
   |---|---|---|---|
   | `telesign` | `telesign-api-key` | `telesign-customer-id` | Basic: base64 of `customer-id:api-key` |
   | `soprano` | None | None | OAuth client assertion using the outbound user-assigned managed identity |
   | `infobip` | `infobip-api-key` | None | `Authorization: App <api-key>` |
   | `sinch` | `sinch-api-token` | None | Static token authentication |

   For Telesign, store the raw key and customer ID separately and grant the Function identity
   **Key Vault Secrets User** access. For Soprano, complete provider consent/application-role
   onboarding for the existing multitenant application. The setup creates the disclosed federated
   identity credential; it does not grant access to Soprano's API.

   <a id="local-settings-and-cloud-secrets"></a>
   Start with [local.settings.sample.json](local.settings.sample.json) beside the chosen app's
   `host.json`. Replace placeholders in `Values`; all values must be strings. `EPP_PROVIDER_ENDPOINT`
   is the complete provider-approved request URL selected for the channel and Global/EU region.
   `EPP_PROVIDER_AUTH_MODE` must match the adapter: `apiKey` for Telesign or `oauth` for Soprano.
   Provider API keys stay in Key Vault, not `Values`.

   Set `FUNCTIONS_WORKER_RUNTIME` to `node`, `python`, or `dotnet-isolated`. Local
   `UseDevelopmentStorage=true` requires Azurite; configure Azure host storage separately.
   Use a local test private key for `EPP_DECRYPTION_KEY_PEM`; in Azure, use a Key Vault reference
   and give the caller the matching public key. Core Tools does not resolve Key Vault references
   locally. `EPP_ENCRYPTION_KEY_ID` is advisory only; this sample has one decryption key, not
   multi-key rotation. The decryption key, provider credentials, and caller authentication are separate.

   For local work, keep the host **loopback-only**, without tunnels or public forwarding. Core Tools
   has no Easy Auth, and managed identity cannot use your CLI login. Use offline tests or evaluation
   mode by default; do not add a production credential fallback merely to test locally.

4. **Deploy the Functions.**

	 <a id="2-provision-encryption-and-deployment-trust"></a>
	 Configure **App Service Authentication (Easy Auth)** before exposing the endpoint. It is the
	 only caller-authentication gate; the Function handler is anonymous and has no backup validator.
	 Never use `-NoEasyAuth`, trust forwarded principal headers, or treat JWE/nonce proof as caller
	 authentication. Anyone with the public encryption key can create a JWE request.

	 | Easy Auth setting | Required value |
	 |---|---|
	 | `globalValidation.requireAuthentication` | `true` |
	 | `globalValidation.unauthenticatedClientAction` | `Return401` |
	 | `httpSettings.requireHttps` | `true` |
	 | `identityProviders.azureActiveDirectory.registration.clientId` | Endpoint app's client ID |
	 | `identityProviders.azureActiveDirectory.registration.openIdIssuer` | Trusted tenant issuer matching the caller's token version; never `common` or `organizations` |
	 | `identityProviders.azureActiveDirectory.validation.allowedAudiences` | Exact endpoint-app audience agreed with SAS |
	 | `identityProviders.azureActiveDirectory.validation.defaultAuthorizationPolicy.allowedApplications` | Nonempty allowlist of authorized SAS caller application IDs, not the endpoint app ID |
	 | `globalValidation.excludedPaths` | No exemption for `/api/SendOtp` or an alternate ingress route |

	 For v1 tokens, use the agreed Application ID URI audience and `https://sts.windows.net/{tenantId}/`
	 issuer; for v2, use the matching v2 issuer and agreed audience, normally the endpoint app client-ID
	 GUID. Do not derive trust from request `tenantId`. Key Vault RBAC for the Function identity is
	 separate from authorizing SAS callers; this code does not check an Entra application role.

	 Leave the endpoint app registration's `tokenEncryptionKeyId` **null**: encrypted Entra access
	 tokens are not supported. If correcting an existing registration, do not delete certificates or
	 change signing keys; request a fresh token afterward. This does **not** disable the required
	 JWE encryption of `encryptedDeliveryContext` or remove `EPP_DECRYPTION_KEY_PEM`.

	 Download the selected language's [Function ZIP](../README.md#download-a-function-zip) from GitHub
	 Releases, or use the [root-level packaging scripts](../README.md#build-zips-locally) for custom builds.
	 The .NET source ZIP must be extracted and built/published with the .NET 8 SDK or a build-enabled
	 deployment pipeline. The Python source ZIP requires Azure remote build on Linux. Neither source
	 ZIP is ready for direct run-from-package. Downloading or building a ZIP does not deploy it.

	 Build and publish only the selected language folder with its runtime dependencies, not the
	 repository root or stale output. Inspect the package: exclude local settings, private keys,
	 credentials, tests, and diagnostic scripts using the runtime's `.funcignore` and publish rules.
	 Apply the settings from step 3 to the Function App's Azure environment; local settings are not
	 published automatically. Verify managed identity access and keep public ingress disabled
	 until authentication is configured. Source changes do not update an existing deployment.

	 The root [.gitignore](../.gitignore) covers all runtimes; publishing uses separate exclusions in
	 [JavaScript](../javascript/.funcignore), [Python](../python/.funcignore), and [.NET](../dotnet/.funcignore).
	 The [.NET project](../dotnet/dotnet.csproj) also excludes local settings from publish output.

5. **Validate.**

	 <a id="4-package-deploy-and-verify"></a>
	 Send an authorized `POST /api/SendOtp` with a valid encrypted envelope and `mode: 2` or
	 `mode: "evaluation"`. Expect `200` and the matching nonce, with no provider lookup, provider
	 secret reads, or outbound provider HTTP. See the [evaluation contract](CONTRACT.md#evaluation-generic-shutter).

	 Before live testing, verify these cases on the deployed endpoint, not just in offline tests:

	 | Check | Expected result |
	 |---|---|
	 | Missing, malformed, expired, or invalidly signed caller token | `401` before the handler |
	 | Wrong issuer/audience or caller outside the allowlist | Rejected before the handler |
	 | Authorized caller and valid evaluation envelope | `200` with matching nonce, no provider I/O |
	 | Alternate routes, hostnames, and serving slots | No authentication or HTTPS bypass |

	 After those checks pass, confirm the destination and channel, use `mode: 1`, and submit once.
	 `200` with a matching nonce confirms provider acceptance, **not handset delivery**. Confirm receipt
	 and spoken digit clarity through the handset/provider reports. The message is forwarded unchanged.
	 Do not blindly retry a timeout: the provider may already have accepted the request. Review the
	 [production limitations](CONTRACT.md#production-limitations), including no durable handoff,
	 early acknowledgement, expiry enforcement, or multi-key rotation.

	 Never record phone numbers, messages, nonce values, tokens, API keys, encrypted request bodies,
	 or raw provider responses in reports. Keep platform/SDK body tracing off. Repeat the deployed
	 checks after deployment, authentication changes, and slot swaps. Local evaluation and passing
	 unit tests do not certify platform authentication or live delivery.
