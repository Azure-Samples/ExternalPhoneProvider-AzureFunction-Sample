# Configure and validate the deployment

[Documentation](README.md) | [Deployment guide](GETTING-STARTED.md) | [Troubleshooting](../setup/docs/Troubleshooting.md)

Use this reference to gather setup values, authorize your provider, and validate the endpoint.

<a id="before-purchasing-or-deploying"></a>
## Before deployment

Review [Microsoft's telephony-provider guidance](https://learn.microsoft.com/entra/identity/authentication/concept-phone-providers)
for availability and provider offers in [Microsoft Security Store](https://securitystore.microsoft.com/).
Confirm account access, sender registration, supported countries and channels, pricing, and support.

Assign an onboarding owner and arrange the Microsoft Entra ID test and activation procedure for
your tenant. Start in a separate test environment. See
[production readiness](../TECHNICAL.md#production-readiness) before live use.

## Values and ownership

<a id="inputs-you-supply-to-setup"></a>
### Values you provide

| Input | Source | Setup option |
| --- | --- | --- |
| Customer tenant ID | Microsoft Entra admin center > Overview | `-TenantId` |
| Azure subscription ID | Azure portal > Subscriptions | `-SubscriptionId` |
| Application client ID | Dedicated app registration, or create an app interactively | `-ApplicationId` |
| Azure region | Available region that meets quota and organization requirements | `-Location` |
| Provider | Your selected integration | `-Provider infobip`, `-Provider soprano`, or `-Provider telesign` |
| Runtime | JavaScript, C#, or Python | `-Language javascript` (default), `-Language csharp`, or `-Language python` |
| Hosting plan | Flex Consumption or Premium | `-ServicePlan FC1` or `-ServicePlan EP1` |
| Resource prefix | 2-8 lowercase letters or digits, starting with a letter | `-ResourcePrefix`; interactive default `epp` |
| Existing encryption certificate | Registered key ID and versioned Key Vault certificate URL | [Certificate options](../setup/docs/README.md#encryption-certificate-selection) |

Use the application **client ID**, not its Object ID. Setup detects the EU or Global provider
route from the tenant's replication scope. This route is separate from the Azure deployment region.

Guided setup configures one provider and supports both SMS and voice. Reuse the same tenant,
subscription, application, and prefix when rerunning that deployment. Use a dedicated application
and different prefix for an independent endpoint.

### Values setup configures

Save the deployment summary and compare it with the approved plan.

| Value | Purpose |
| --- | --- |
| `endpointUrl`, `applicationId` | SendOtp URL and application client ID for testing and activation |
| `EPP_PROVIDER_NAME` | Registered provider adapter |
| `EPP_PROVIDER_SMS_ENDPOINT`, `EPP_PROVIDER_VOICE_ENDPOINT` | Complete provider URLs for each channel |
| `EPP_PROVIDER_AUTH_MODE` | `oauth` |
| `EPP_PROVIDER_TENANT_ID`, `EPP_PROVIDER_SCOPE` | Provider token tenant and API scope |
| `EPP_OUTBOUND_CLIENT_ID`, `EPP_OUTBOUND_MI_CLIENT_ID` | Customer application and outbound managed identity used for OAuth |
| `EPP_DECRYPTION_KEY_PEM`, `EPP_ENCRYPTION_KEY_ID` | Versioned Key Vault reference and registered encryption key ID |
| Easy Auth issuer, audience, and caller allowlist | Inbound Microsoft caller validation |

The provider profile supplies the OAuth values. `deployment.AccessTokenScopeTenant`, when
present, identifies the token-issuing tenant; otherwise setup uses `deployment.tenantId`.
The summary records these as `accessTokenScopeTenant` and `providerTenantId`, respectively.

The [technical reference](../TECHNICAL.md#configure-environment-variables) lists runtime settings.
The [deployment summary reference](../setup/docs/README.md#read-the-deployment-summary)
explains the saved fields.

<a id="complete-provider-authentication"></a>
<a id="provider-credential-names"></a>
## Provider authentication

All three bundled providers use **OAuth client assertions through managed identity federation**.
Setup configures the customer-side federation. The provider administrator must authorize the
customer application and provider account.

| Provider | Profile used by setup | Confirm with the provider |
| --- | --- | --- |
| Infobip | [infobip.json](../setup/providers/infobip.json) | Account access to SMS, voice, the selected regional host, and provider-managed sender/caller selection |
| Soprano | [soprano.json](../setup/providers/soprano.json) | Customer application authorization, account access, and enabled channels |
| Telesign | [telesign.json](../setup/providers/telesign.json) | Customer application authorization, account access, and enabled channels |

The profiles include the token tenant, API application ID, scope, and channel URLs used by setup.

<a id="oauth-provider-administrator-handoff"></a>
### Complete provider OAuth authorization

1. Send the following identifiers through the provider's onboarding channel:
   customer tenant ID, endpoint application client ID, intended channels, provider URLs,
   `EPP_PROVIDER_TENANT_ID`, `EPP_PROVIDER_APP_ID`, and `EPP_PROVIDER_SCOPE`.
2. Ask the provider administrator to confirm the required consent or app roles and account access.
3. In **App registrations** > **Certificates & secrets** > **Federated credentials**, verify the
   customer-side trust:

   | Field | Expected value |
   | --- | --- |
   | Issuer | Customer tenant-specific v2 issuer |
   | Subject | Outbound managed identity's **Principal ID** |
   | Audience | `api://AzureADTokenExchange` |

4. Verify the integration with the controlled live checks below.

The managed identity's client ID and Principal ID serve different purposes. Keep assertions,
access tokens, and private keys out of support messages and logs.

<a id="validate-the-deployed-endpoint"></a>
<a id="4-package-deploy-and-verify"></a>
## Validate the endpoint

Use the authorized Microsoft caller and test procedure provided for your tenant.
An ordinary Azure CLI token represents a different caller.

Provide the test operator with the endpoint URL, customer tenant ID, application client ID,
identifier URI, encryption key ID, and public certificate or thumbprint. Agree on the test window
and controlled recipients.

| Check | Expected result |
| --- | --- |
| Read back HTTPS and Easy Auth settings | Match the [trust checklist](#manual-deployment-trust-checklist) |
| Send a request without a token | `401` with the default Easy Auth configuration |
| Use invalid or unauthorized caller credentials | Request rejected |
| Send a valid encrypted evaluation request | `200` and a matching nonce, without a provider send |
| Send a controlled live request for each intended channel | Provider acceptance and separately confirmed recipient delivery |
| Review monitoring | Correlated requests and application events; tested alert notifications |

This missing-token check sends no OTP:

```powershell
$endpoint = 'https://<function-host>/api/SendOtp'
$response = Invoke-WebRequest -Uri $endpoint -Method Post -ContentType 'application/json' `
    -Body '{}' -SkipHttpErrorCheck -MaximumRedirection 0 -TimeoutSec 30
$response.StatusCode
```

Expect `401`. Investigate other results using [troubleshooting](../setup/docs/Troubleshooting.md).
This check covers only unauthenticated rejection.

Evaluation validates the authenticated, encrypted request path. Test provider authorization and
delivery through controlled live requests. For live requests, `200` confirms provider acceptance.
Check the provider's outcome before retrying a timeout.

Retain UTC times, status codes, latency, safe correlation IDs, and delivery outcomes. Keep phone
numbers, OTPs, nonces, tokens, private keys, and raw request or provider bodies out of the evidence.
Repeat validation after package, authentication, provider, or certificate changes.

<a id="activate-operate-and-retire"></a>
## Operations

After validation, follow [activation and rollout](../setup/docs/README.md#activate-the-endpoint).
Save the previous policy and read back each change.

Assign owners for request failures, provider access, certificate renewal, alerting, retention,
costs, and rollback. Configure [alert rules and notification routes](MONITORING.md#alerts)
after setup, and retain the deployment summary and policy snapshots in restricted storage.

<a id="optional-local-development-and-manual-deployment"></a>
## Custom deployment

For code changes, follow the [JavaScript](../javascript/README.md), [C#](../dotnet/README.md), or
[Python](../python/README.md) guide. Use local test keys and offline tests. Keep local Functions
hosts accessible only from the local machine; Easy Auth runs in Azure.

For manual deployment:

1. [Build or download the matching package](../TECHNICAL.md#download-a-function-zip).
2. Configure the runtime, settings, storage, managed identities, and Key Vault reference.
3. Apply the Easy Auth configuration below before opening the endpoint.
4. Run the deployed endpoint checks above.

Keep local settings, private keys, credentials, tests, and diagnostics out of deployment packages.

<a id="manual-deployment-trust-checklist"></a>
### Easy Auth checklist

| Setting | Required value |
| --- | --- |
| `platform.enabled` | `true` |
| `globalValidation.requireAuthentication` | `true` |
| `globalValidation.unauthenticatedClientAction` | `Return401` |
| `httpSettings.requireHttps` | `true` |
| `identityProviders.azureActiveDirectory.enabled` | `true` |
| `identityProviders.azureActiveDirectory.registration.clientId` | Endpoint application client ID |
| `identityProviders.azureActiveDirectory.registration.openIdIssuer` | Trusted tenant-specific issuer |
| `identityProviders.azureActiveDirectory.validation.allowedAudiences` | Exact endpoint audience |
| `identityProviders.azureActiveDirectory.validation.defaultAuthorizationPolicy.allowedApplications` | Approved Microsoft caller app-ID allowlist |
| `globalValidation.excludedPaths` | Empty |

Keep `SendOtp` protected. The Function relies on Easy Auth for bearer-token validation.
Keep the app registration's `tokenEncryptionKeyId` null: the JWE delivery payload uses its own
encryption certificate.
