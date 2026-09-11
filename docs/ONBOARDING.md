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
	 **The script, command, and prerequisites will be provided later.** Run it using the supplied
	 instructions, verify it succeeded, and retain the app/resource IDs and configuration outputs.
	 Do not assume it creates provider secrets or deploys the Function code.

3. **Fill in app settings.**

	 <a id="provider-credential-names"></a>
	 Reuse your provider's existing cloud API key and matching ID. Store the raw values in Key Vault
	 under these exact names, shared across all three languages:

	 | Provider | API credential secret | Matching identity secret | Authentication |
	 |---|---|---|---|
	 | `telesign` | `telesign-api-key` | `telesign-customer-id` | Basic: base64 of `customer-id:api-key` |
	 | `soprano` | `soprano-api-key` | `soprano-api-id` | `X-MEMS-API-Key` and `X-MEMS-API-ID` |
	 | `infobip` | `infobip-api-key` | None | `Authorization: App <api-key>` |
	 | `sinch` | `sinch-api-token` | None | `Authorization: Bearer <static-api-token>` |

	 Secret names use lowercase and hyphens. Keep `sinch-api-token` unchanged. Store the API key and
	 matching ID separately, not a prebuilt Authorization header, base64 credential pair, or Entra token.
	 The adapter builds the headers; there is no provider OAuth/JWT acquisition flow.

	 Enable the Function's managed identity and grant it **Key Vault Secrets User** access to the
	 required secrets. Confirm vault network access and that the keys match the provider environment.
	 Select one registered provider per deployment; there is no default. Unsupported providers need
	 an adapter first; see [adding a provider](../README.md#contributing-a-language-or-provider).

	 <a id="local-settings-and-cloud-secrets"></a>
	 Start with [local.settings.sample.json](local.settings.sample.json) beside the chosen app's
	 `host.json`. Replace placeholders in `Values`; all values must be strings. For Telesign, use:

	 ```json
	 {
		 "EPP_PROVIDER_NAME": "telesign",
		 "EPP_PROVIDER_ENDPOINT": "https://verify.telesign.com",
		 "KEY_VAULT_URL": "https://<existing-provider-credential-vault>.vault.azure.net/"
	 }
	 ```

	 These are entries in `Values`, not a complete settings file. Use the adapter's **base URL**;
	 it adds the send path. App-setting names use uppercase and underscores. Provider API keys stay
	 in Key Vault, not `Values`: `TELESIGN_API_KEY`, `SOPRANO_API_KEY`, and `EPP_PROVIDER_API_KEY`
	 are not read by the production resolvers. `EPP_PROVIDER_ACCOUNT_NAME` is optional sender metadata,
	 not an API/customer ID. See the [settings catalog](CONTRACT.md#4-configuration-app-settings--env)
	 for adapter options and `AZURE_CLIENT_ID` when using a user-assigned managed identity.

	 Set `FUNCTIONS_WORKER_RUNTIME` to `node`, `python`, or `dotnet-isolated`. Local
	 `UseDevelopmentStorage=true` requires Azurite; configure Azure host storage separately.
	 Use a local test private key for `EPP_DECRYPTION_KEY_PEM`; in Azure, use a Key Vault reference
	 and give the caller the matching public key. Core Tools does not resolve Key Vault references
	 locally. `EPP_ENCRYPTION_KEY_ID` is advisory only; this sample has one decryption key, not
	 multi-key rotation. The decryption key, provider credentials, and caller authentication are separate.

	 For local work, keep the host **loopback-only**, without tunnels or public forwarding. Core Tools
	 has no Easy Auth, and `ManagedIdentityCredential` cannot use your CLI login. `AZURE_CLIENT_ID`
	 does not create a local identity. Use offline tests or evaluation mode by default. An authorized
	 live test can inject a private resolver that reads the same cloud secrets into memory using a
	 signed-in identity with secret-read permission. Do not add a production credential fallback,
	 print secrets, persist a secret cache, or change cloud settings merely to test locally.

	 `KEY_VAULT_URL` selects the provider credential vault independently of the decryption-key reference.
	 Timeout defaults to 1500 ms and caps at 2500 ms; zero does not disable it. Retry settings are unused.
	 Configure caller trust in Easy Auth, not legacy `EPP_EXPECTED_*` or `EPP_TENANT_ID` settings.

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

	 Build and publish only the selected language folder with its runtime dependencies, not the
	 repository root or stale output. Inspect the package: exclude local settings, private keys,
	 credentials, tests, and diagnostic scripts using the runtime's `.funcignore` and publish rules.
	 Apply the settings from step 3 to the Function App's Azure environment; local settings are not
	 published automatically. Verify managed identity access and keep public ingress disabled
	 until authentication is configured. Source changes do not update an existing deployment.

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
