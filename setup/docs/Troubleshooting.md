# Troubleshoot setup and delivery

[Documentation](../../docs/README.md) | [Setup reference](README.md) | [Deployment guide](../../docs/GETTING-STARTED.md)

Start with the failed stage. Keep the error and deployment summary, and reuse the original
deployment inputs when retrying.

## Find your symptom

| Symptom | Section |
| --- | --- |
| Missing account or wrong tenant | [Azure CLI context](#azure-cli-context) |
| Permission or prerequisite failure | [Permissions and tools](#permissions-and-tools) |
| Region, plan, or quota failure | [Regional availability](#regional-availability-and-quota) |
| Resource-provider registration failure | [Resource providers](#a-required-azure-resource-provider-is-not-registered) |
| Certificate selection or decryption failure | [Certificates](#certificate-selection-reuse-or-cleanup-fails) |
| Download, checksum, or startup failure | [Packages](#package-download-or-startup-fails) |
| Failure after deployment approval | [Recovery](#recover-without-destructive-cleanup) |
| Endpoint rejection, provider failure, or missing logs | [After-deployment triage](#after-deployment-triage) |
| Source-version-specific setup failure | [Setup revision recovery](#setup-revision-recovery) |
| Front Door probes or regional routing fail | [Multi-region troubleshooting](#multi-region-troubleshooting) |

## After-deployment triage

For private support, retain the resource IDs, runtime/release, UTC time, HTTP status, and safe
correlation IDs. Exclude credentials, phone numbers, OTPs, private keys, nonces, encrypted bodies,
and raw provider responses.

| Symptom | Check |
| --- | --- |
| Provider offer or configuration unavailable | Confirm [provider availability and access](../../docs/ONBOARDING.md#before-deployment) with the provider or Microsoft support. |
| Setup succeeded but no delivery | Complete provider authorization, endpoint validation, and policy activation as separate steps. |
| `401` or `403` before invocation | Check Easy Auth issuer, audience, caller allowlist, and network access. Keep authentication enabled. |
| `400` after a provider call | Inspect the correlated provider status. Provider `401`/`403` means outbound authorization failed. |
| `422` with `provider_blocked` | Investigate the provider's risk or policy block; this attempt was not accepted. |
| `decryption_failed` | Verify the certificate, registered public key, versioned secret reference, and Function identity access. |
| `502` with `credential_unavailable` in logs | Check [OAuth credential acquisition](#provider-credential-acquisition-fails). |
| Timeout or `504` | Check the provider outcome before retrying; the request might already have been accepted. |
| Provider acceptance without receipt | Request delivery evidence from the provider and confirm the intended recipient/channel. |
| Missing requests or application events | Verify [collection](../../docs/APPLICATION-INSIGHTS.md) and the [runtime log format](../../docs/MONITORING.md#runtime-log-formats). |
| Missing expiry notification | Verify certificate contacts, the independent renewal reminder, and the notification route. |

Complete the [endpoint checks](../../docs/ONBOARDING.md#validate-the-deployed-endpoint)
before activating the endpoint.

## Recover without destructive cleanup

1. Locate the failed stage in the error and **Resource group** > **Deployments**.
   Partial Azure or application changes can remain after approval.
2. Fix the cause and rerun with the original tenant, subscription, application, prefix, runtime,
   plan, provider, and source/package versions.
3. If setup created the application, use the client ID from `application-<client-id>.json`.
   Inspect the tenant before retrying an application-creation request that timed out.
4. If the encryption certificate was already registered, select **Reuse** with that exact
   certificate version.
5. Complete endpoint validation after the rerun.

Schedule a change window for an active endpoint. Keep resource deletion, vault purge, and shared
permission removal out of retry steps. Use [rollback and decommissioning](README.md#rollback-and-decommissioning)
when retiring a deployment.

## Azure CLI context

Setup uses an Azure CLI **user** login in the customer tenant. Select **Refresh subscriptions
from Azure** or **Sign in to Azure (device code)** when the expected account is missing.

To establish and inspect the session manually:

```powershell
az login --tenant '<customer-tenant-id>' --use-device-code
az account show --subscription '<subscription-id>' --output table
az ad signed-in-user show --output table
```

In Cloud Shell, open PowerShell from the intended portal directory. On a shared workstation,
`-ForceAuthentication` requests a fresh device-code login during interactive setup.
Unattended runs use a previously established user session.

## Permissions and tools

1. Check the [PowerShell and Azure CLI requirements](README.md#prerequisites).
2. Install Bicep through setup's confirmation, or use `-InstallPrerequisites` for an approved
   unattended installation.
3. Verify Azure subscription deployment and role-assignment access.
4. Activate the required Microsoft Entra roles, including Privileged Role Administrator for
   the Microsoft Graph `Application.Read.All` grant.
5. Confirm access to the app's Microsoft Graph beta allowed-tenants configuration.

Azure Owner or Contributor does not grant Microsoft Entra directory permissions.

### Microsoft Graph returns 403

Verify the signed-in user and directory context:

```powershell
az account show --output table
az ad signed-in-user show --output json
az rest --method get `
    --url 'https://graph.microsoft.com/v1.0/me?$select=id,userPrincipalName' `
    --resource 'https://graph.microsoft.com/' `
    --output json
```

Check role activation, application-management access, and Conditional Access requirements.
Keep tokens out of support material.

### Azure role assignment returns PrincipalNotFound

Verify the selected subscription and user identity, then allow for directory/RBAC propagation.
Setup uses the object ID from the selected subscription's ARM token for Azure role assignments.
Keep the original deployment inputs when retrying.

## Regional availability and quota

Check the selected Linux plan and region. FC1 availability uses
`az functionapp list-flexconsumption-locations`; EP1 availability uses the subscription's
`Microsoft.Web/geoRegions` API. Availability and quota are separate checks.

### Tenant scope discovery fails

Check the tenant ID and network access to
`https://login.microsoftonline.com/<tenant-id>/v2.0/.well-known/openid-configuration`.
Setup requires `tenant_region_scope` to select the provider route.
If `-EndpointRegion` conflicts with the detected route, omit it or supply the matching value.

For EU tenants, review the [region recommendations](README.md#tenant-scope-and-azure-region-recommendations).
Manual or explicit locations still need to meet your organization's requirements.

### Deployment fails with SubscriptionIsOverQuotaForSku

1. Confirm the subscription, region, and SKU in the Azure error.
2. For EP1, open **Quotas** > **App Service** and check **EP1 VMs** in that region.
3. Request sufficient quota for deployment and scaling, then confirm the approved limit.
4. If needed, use a **Service and subscription limits (quotas)** support request for the
   Function/Web App service.
5. Rerun after quota is available, or choose another approved region with sufficient quota.

See [Azure quota guidance](https://learn.microsoft.com/azure/quotas/quotas-overview).

### Changing the hosting plan

Use a different resource prefix when moving between FC1 and EP1. For an independent endpoint,
use a dedicated application. Review [certificate continuity](README.md#encryption-certificate-selection)
before sharing an existing app.

## A required Azure resource provider is not registered

Setup checks these subscription registrations:

`Microsoft.Web`, `Microsoft.Storage`, `Microsoft.KeyVault`, `Microsoft.OperationalInsights`,
`Microsoft.Insights`, and `Microsoft.ManagedIdentity`.

Missing providers are registered after deployment approval. The operator needs subscription-scoped
`/register/action`, included in Contributor and Owner. Fix permission or regional-availability
errors and rerun; completed registrations remain in place.

## Certificate selection, reuse, or cleanup fails

For an existing encryption credential, **Replace is the interactive default**.
Select **Reuse** explicitly to keep it. See [certificate selection](README.md#encryption-certificate-selection).

| Error | Action |
| --- | --- |
| Unattended run is missing certificate inputs | Supply `-CertificateAction`; reuse also needs the registered key ID and exact versioned certificate URL. |
| Certificate does not match the registration | Compare the public thumbprint and key ID with the selected Key Vault certificate version. |
| Expired, disabled, or incompatible certificate | Use a currently valid, exportable RSA certificate of at least 2048 bits with a PEM backing secret and more than 30 days remaining. |
| Certificate metadata cannot be read | Verify the vault, version, operator access, and `-KeyVaultSubscriptionId` for another subscription. |
| Function cannot resolve the private-key reference | Check its system-assigned identity, secret-read permission, and network path to the vault. |
| Credentials changed after plan review | Stop competing changes and rerun selection and approval against the current registration. |

Setup preserves signing credentials and Key Vault objects. After a successful registration,
reuse the exact new certificate for recovery. A newly issued vault version requires a coordinated
registration and Function-reference update.

## Package download or startup fails

### Download or checksum failure

Check access to the selected stable
[language release](https://github.com/Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample/releases).
The tag suffix must match `javascript`, `dotnet`, or `python`. Use `released-package.zip` and
`SHA256SUMS.txt` from that same release.

Keep checksum verification enabled. Align the launcher and
[source/package versions](README.md#source-versioning).

### C# package fails to load

Use the `-dotnet` release with a **.NET 10 isolated** Function App.
The ZIP includes framework-dependent Linux x64 output, Function metadata, and extension assemblies.
For custom builds, use [package-dotnet.ps1](../../package-dotnet.ps1).

### Python dependencies or startup fail

Use the `-python` release with **Python 3.11**. Its dependencies are under
`.python_packages/lib/site-packages`. Build custom packages on Linux x64 with
[package-python.ps1](../../package-python.ps1).

### Publication completes but the Function is unavailable

Check [host and worker logs](../../docs/APPLICATION-INSIGHTS.md#single-region) for loading or
registration errors. Upload success alone is not startup success.

FC1 uses One Deploy; EP1 uses managed-identity run-from-package from private Blob storage.
Setup keeps SCM basic authentication disabled and verifies Function registration before reporting
success. Persistent publication failure closes public ingress; resolve the failure before reopening it.

## Setup revision recovery

Keep the failing source revision, error, and application client ID before updating the launcher.
Align `-SourceRepository` and `-SourceRef` with the reviewed source, then rerun using the original
application, resource prefix, plan, and provider. See [source versioning](README.md#source-versioning).

| Symptom | Recovery |
| --- | --- |
| FC1 preflight reports `Object reference not set to an instance of an object` for the hosting plan | Use a reviewed setup revision that keeps `serverFarmId` visible in the Function resource. Retain the selected plan and inspect the deployment error rather than assuming the region is unsupported. |
| A command contains combined Azure CLI paths such as `/usr/bin/az /bin/az` | Use a revision that selects one CLI executable. A temporary workaround is to save `$ProgressPreference`, set it to `SilentlyContinue` for the rerun, then restore it. |
| Application configuration reports an unsupported provider-tenant restriction | Review the Graph response and use a revision that recognizes an unconfigured `unrestrictedAudience`. Keep the created application's client ID for the rerun. |
| Azure CLI warnings cause JSON parsing errors | Use a revision that separates JSON stdout from stderr warnings, then retry with the same deployment inputs. |

These are source-revision fixes, not reasons to recreate resources or broaden access.
After recovery, confirm the approved provider allowlist, package startup, and endpoint validation.

## Multi-region troubleshooting

Use the [multi-region resiliency guide](../../docs/MULTI-REGION-RESILIENCY.md) to review both Front Door and its origins.

| Symptom | Check |
| --- | --- |
| Probe returns `401`, `403`, or `404` | Readiness route, exact Easy Auth exclusion, origin host header, and Front Door access rule |
| Direct Function access succeeds | Require both `AzureFrontDoor.Backend` and your profile's `X-Azure-FDID`, with unmatched requests denied |
| Authenticated SendOtp returns `403` through Front Door | Caller token forwarding, audience, issuer, caller allowlist, and origin access restrictions |
| One origin cannot decrypt | Compare the registered certificate with each regional certificate and verify the versioned secret reference |
| Traffic reaches only one region | Check health, priority, latency sensitivity, and weight; equal weights alone do not ensure equal traffic |
| Requests fail during regional recovery | Measure probe detection and client failures against the recovery target; inspect survivor capacity and regional dependencies |

Verify each origin through the shared endpoint. Preserve Easy Auth and origin restrictions while
investigating, and restore the saved routing configuration after tests.

## Provider credential acquisition fails

The application logs `request_failed` with stage `provider_credentials`, reason
`credential_unavailable`, and endpoint status `502`.

Check:

1. The outbound user-assigned managed identity is attached to the Function.
2. `EPP_OUTBOUND_MI_CLIENT_ID` identifies that identity.
3. The customer's application has the correct federated issuer, Principal ID subject, and
   `api://AzureADTokenExchange` audience.
4. `EPP_PROVIDER_TENANT_ID` and `EPP_PROVIDER_SCOPE` match the selected profile.
5. The provider has authorized the application and account.

Use the [OAuth handoff](../../docs/ONBOARDING.md#complete-provider-authentication) and the safe
[AADSTS diagnostics](../../docs/LOGGING.md#credential-diagnostics).
Restart after configuration changes and verify a controlled live request.

Credential acquisition has a 5-second budget. `EPP_PROVIDER_TIMEOUT_MS` controls the subsequent
provider HTTP call. Evaluation returns before this work and therefore cannot validate it.

## The endpoint returns 401 or live delivery fails

Before invocation, check the [Easy Auth configuration](../../docs/ONBOARDING.md#manual-deployment-trust-checklist).
Use the authorized Microsoft caller; keep the caller allowlist and authentication enabled.

After invocation, inspect [correlated application events](../../docs/MONITORING.md#application-events).
Check the selected channel URL and provider account access. Provider `401`/`403` maps to endpoint
`400`; an explicit provider block maps to `422`.

Repeat [evaluation and controlled live checks](../../docs/ONBOARDING.md#validate-the-deployed-endpoint)
after fixing the cause. Activate the endpoint through the
[Microsoft Entra configuration procedure](README.md#activate-the-endpoint) after validation.
