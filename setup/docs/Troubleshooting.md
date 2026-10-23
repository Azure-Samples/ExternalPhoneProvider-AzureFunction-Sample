# Setup and onboarding troubleshooting

[Documentation](../../docs/README.md) | [Setup reference](README.md) | [Resume onboarding](../../docs/GETTING-STARTED.md)

Select the failed stage and keep existing resources. Before rerunning, use
[safe recovery](#recover-without-destructive-cleanup). Check provider outcomes before retrying timeouts.

## Find your symptom

| Stage / symptom | Start here |
| --- | --- |
| Account missing or wrong tenant | [Account picker](#the-expected-cached-account-or-subscription-is-missing), [directory context](#azure-cli-directory-context-does-not-match-the-selected-tenant) |
| Permission or prerequisite failure | [Preflight](#authentication-permission-or-runtime-preflight-fails), [Graph 403](#az-ad-or-az-rest-returns-403-forbidden), [PrincipalNotFound](#principalnotfound-for-the-azure-operator) |
| New or existing app reports an unsupported provider-tenant restriction | [Unrestricted application audience](#new-app-fails-with-an-unsupported-provider-tenant-restriction) |
| Region or hosting rejected | [Tenant scope and EU recommendations](#tenant-scope-discovery-or-eu-region-recommendations-fail), [quota](#deployment-fails-with-subscriptionisoverquotaforsku), [plan selection](#service-plan-selection-or-availability-fails), [FC1 object-reference error](#fc1-deployment-preflight-reports-an-object-reference-error), [EP1 location check](#appservice-list-locations-rejects-ep1) |
| Certificate or resource registration fails | [Certificate selection](#certificate-selection-reuse-or-cleanup-fails), [resource providers](#a-required-azure-resource-provider-is-not-registered) |
| Download, build, or parser failure | [Old package prompts](#setup-still-asks-for-packageurl-or-packagesha256), [checksum/download](#a-checksum-or-package-download-fails), [.NET](#net-build-fails), [Python](#python-remote-build-fails), [CLI JSON](#azure-cli-warnings-break-json-parsing) |
| Deployment stops after approval | [Combined Azure CLI paths](#azure-cli-paths-are-combined-during-deployment), [publication and startup](#deployment-stops-after-approval) |
| Endpoint rejects calls, does not deliver, or has no logs | [After-deployment triage](#after-deployment-triage), [401/live delivery](#the-endpoint-returns-401-or-live-delivery-fails), [credential acquisition](#provider-credential-acquisition-fails) |
| Optional regional routing fails | [Front Door checks](#optional-front-door-deployments) |

## After-deployment triage

Keep the error and timestamped summary. For private support, record the tenant, subscription,
resource group, runtime/release, UTC time, and safe correlation IDs. Exclude settings, tokens,
phone numbers, OTPs, private keys, encrypted bodies, and raw responses. Keep body tracing off.

| Symptom | First checks / owner | Safeguard |
|---|---|---|
| Cannot see an offer or EPP activation/test capability | Customer onboarding owner verifies the [Security Store and feature-access gate](../../docs/ONBOARDING.md#before-purchasing-or-deploying) with provider/Microsoft support. | Do not infer eligibility from Azure Owner or a successful purchase. |
| Setup reports success, but no OTP delivery | Finish [Telesign vault entry or Infobip/Soprano provider consent](../../docs/ONBOARDING.md#complete-provider-authentication); confirm authorized testing and policy activation are separately complete. | Do not redeploy all runtimes or paste credentials into local settings. |
| Endpoint returns 401/403 with no invocation | Azure operator checks Easy Auth, issuer/audience/caller restrictions, network access, and available platform/auth logs. An ordinary customer CLI token is not the allowlisted Microsoft caller. | Do not disable Easy Auth, add a test caller, or interpret rejection as readiness. |
| App failure after invocation, including 401 | Inspect correlated `request_failed` and provider-response events. A provider's 401/403 is mapped to a handler 401; this differs from Easy Auth rejection. | Do not change inbound trust to fix outbound provider authorization. |
| `decryption_failed` or unresolved key reference | Compare summary certificate/thumbprint/key ID and versioned reference; verify Function identity vault access and reference resolution, then use an authorized evaluation. | Do not export the private key, remove certificates outside approved cleanup, or assume new vault versions automatically update Entra. |
| Provider credentials unavailable | Check secret names/enabled versions/vault access for Telesign; customer federation plus provider-side authorization/tenant/scope for Infobip or Soprano. Allow RBAC propagation. | Do not assume evaluation validates outbound credentials. |
| Timeout, 502/504, or provider acceptance without handset receipt | Separate credential, outbound HTTP, host, and caller timings; ask the provider for supported delivery evidence. Confirm locale/digit clarity for voice. | Do not blindly resend: the first request may already have been accepted. |
| No requests/traces in Application Insights | Check the exact component/workspace, UTC window, actual authorized traffic, host/worker startup, ingestion identity/network, filters/sampling/caps, and effective exporter. Use [collection guidance](../../docs/APPLICATION-INSIGHTS.md). | Do not treat an empty table/Failures view as healthy or search every runtime for a JSON request summary. |
| Requests exist but Python/.NET event query is empty | Use [runtime-specific discovery](../../docs/MONITORING.md#runtime-specific-log-discovery). Python extras/.NET scopes may not be exported; .NET host OpenTelemetry does not initialize direct worker export. | Do not apply JavaScript's JSON parser to other runtimes or promise complete dependencies/exceptions. |
| No expiry email or alert | Operations owner checks vault certificate contacts/lifetime policy, independently configured reminders/action groups/rules, and notification tests. | Do not assume setup created alerts, or diagnostic settings deliver Key Vault expiry events. |

Keep nonce-match **booleans**, statuses, latency, safe IDs, and delivery outcomes. Complete
[acceptance checks](../../docs/ONBOARDING.md#validate-the-deployed-endpoint) before activation.

## Recover without destructive cleanup

1. **Locate the failure.** Before approval, only sign-in or Bicep installation can change the
   environment. After approval, partial Azure or Microsoft Entra ID changes can remain. Inspect
   the error and **resource group > Deployments**.
2. **Fix, then rerun with the same inputs:** tenant, subscription, app, runtime, plan, prefix,
   provider/route, and source/package versions. Active endpoints need a change window; setup has
   no general deployment resume or automatic undo. Outbound federation is
   [configured automatically](README.md#outbound-federation) by the normal setup flow.
   Select **Reuse** when keeping an already registered certificate. If setup created the app, find its client ID in the
   printed output or `application-<client-id>.json` and rerun with `-ApplicationId` and the same
   prefix. Do not choose **Create a new application** again for that deployment.
3. **Verify the failed stage and complete acceptance checks.** Keep resource-group deletion,
   vault purge/recreation, encryption-credential removal, and shared-grant revocation out of
   retry steps. Use the separate [rollback procedure](README.md#rollback-and-decommissioning)
   when retiring a deployment.

## Certificate selection, reuse, or cleanup fails

**Check:** compare the application key ID and exact vault version using
[certificate selection](README.md#encryption-certificate-selection).
For existing credentials, the interactive default is **Replace** (clean up registered encryption
credentials and create a new certificate after final approval). Select **Reuse** explicitly to keep
one, or **0/Cancel** to stop. Unattended runs still require an explicit **Reuse** or **Replace**.

| Failure | Safe recovery |
|---|---|
| Missing `CertificateAction`, `EncryptionKeyId`, or `KeyVaultCertificateId` in unattended mode | Supply an explicit action. Reuse requires the exact key ID and versioned `/certificates/` URL even when only one credential exists. `-ApproveDeployment` is not a certificate choice. |
| Key Vault certificate does not match the selected app credential | Compare the displayed key ID and public thumbprint with the exact Key Vault certificate version. A same-name or renewed certificate is not necessarily the registered certificate. Correct the location or explicitly choose replacement. |
| Expired, not-yet-valid, disabled, or incompatible certificate/secret | Select a valid certificate with more than 30 days remaining and an exportable RSA key of at least 2048 bits in a certificate-managed PEM secret. A public `.cer` file or standalone PEM secret is not a reuse location. |
| Certificate not found or metadata read denied | Check the vault, name, exact version, and operator certificate/secret-metadata read permissions. Use `-KeyVaultSubscriptionId` for a vault in a different subscription in the same tenant. Reuse does not fall back to creation on errors. |
| Function reference is denied or cannot resolve | Check the Function's **system-assigned** identity, its secret-read permission, and network access to the source vault. Operator access is not proof of Function access. Setup waits a bounded time for propagation and does not open external-vault networking. |
| Credentials or the source vault's permission model changed after approval | Stop competing changes and rerun selection/approval against the current state. Do not force an outdated cleanup plan. |
| An encryption credential has an unsupported type, or a non-encryption credential cannot be read | Have the application owner review the credential and read permissions. Setup cannot safely preserve or interpret it and will not blindly reset the credential collection. |

**Recover:** a failed key-reference check leaves registered encryption credentials intact, but
resources or settings may have changed. If registration succeeded, choose **Reuse** with the
printed certificate ID and same prefix.

**Expected:** one approved encryption credential. Cleanup removes only approved
`AsymmetricX509Cert` / `Encrypt` entries. Coordinate every endpoint sharing the app.

<a id="optional-front-door-deployments"></a>
## Multi-region Front Door deployments

Follow the [Front Door guide](../../docs/FRONTDOOR.md), including readiness and origin checks.

- A 401/403/404 probe is unhealthy. Check the readiness path, origin host header, and profile-pinned
  network restriction. Never exempt SendOtp or disable Easy Auth.
- An authenticated SendOtp 403 is a failure, not proof of regional recovery. Check origin, ingress, and auth.
- A shared-URL success does not prove every origin works; verify each with safe regional telemetry.
- Distinguish delayed aggregate metrics from event timestamps and client observations. Review
  [regional recovery behavior](../../docs/FRONTDOOR.md#regional-recovery-behavior) before setting recovery expectations.

## Deployment fails with SubscriptionIsOverQuotaForSku

**Check:** the selected subscription's regional **EP1 VMs** quota, not authentication or resource
registration. A supported Linux EP1 region can still have zero quota for your subscription.

1. Confirm the tenant, subscription, region, and SKU in the plan and Azure error.
2. In **Quotas > App Service**, filter to that subscription/region and inspect **EP1 VMs** usage
   and limit. This is not a general Compute VM quota.
3. Request enough quota for deployment and scaling, then verify the effective approved limit.
4. If the portal cannot adjust it, open a **Service and subscription limits (quotas)** request for
   **Function or Web App (Windows and Linux)**. Include region, Linux/EP1, current/requested limits,
   and the tracking ID.
5. Alternatively, choose another region only after checking its quota, service availability,
   and your residency and provider requirements. Review the updated deployment plan before approval.

**Expected:** the approved quota is visible and sufficient. See
[quota support](https://learn.microsoft.com/azure/quotas/quotas-overview). Rerun with the reviewed
inputs after quota is available.

## Tenant scope discovery or EU region recommendations fail

Verify the selected tenant ID and network access to
`https://login.microsoftonline.com/<tenant-id>/v2.0/.well-known/openid-configuration`.
Setup requires valid public-cloud tenant metadata and `tenant_region_scope`; it does not infer a
scope from country or Azure region, and it does not silently fall back to Global on lookup failure.
If `-EndpointRegion` conflicts with the detected route, omit it or use the matching value.

EU recommendations use the subscription's Azure-recommended physical regions and EU/EFTA
geography. The United Kingdom is outside the EU Data Boundary even though Azure groups it under
Europe. If Azure returns no verified EU recommendations, inspect the full region list and your
organization's residency requirements. An explicit `-Location` or manual selection remains
possible, but an out-of-boundary or unverifiable selection warns and still requires plan review.
Non-EU tenants retain the original recommendation behavior.

## Service plan selection or availability fails

**Check:** `-ServicePlan FC1` needs Azure CLI **2.60.0+**; `EP1` needs **2.48.1+**.
The parameter is required unattended. FC1 availability uses `az functionapp list-flexconsumption-locations`;
EP1 uses the [ARM check below](#appservice-list-locations-rejects-ep1). Availability is plan-specific.
FC1 has zero always-ready instances and a usage grant, not a zero-cost guarantee.

**Fix:** follow [plan selection and migration rules](README.md#service-plan-selection). Use a
different prefix and a dedicated app or approved key-continuity plan. A new prefix does not authorize key rotation.
Existing EP1 deployments use `-ServicePlan EP1`; setup checks actual SKU when tags are absent.
Never remove tags to bypass this guard.

## FC1 deployment preflight reports an object-reference error

**Symptom:** `InvalidTemplateDeployment` against
`Microsoft.Web/serverfarms` and the inner message `Object reference not set to an instance of an object`.
An older template wraps all Function `properties` in `union()` with a storage `reference()`.
ARM defers `serverFarmId` with it, hiding the Function-to-plan association during preflight.
This does not establish that FC1 or the region is unsupported.

**Fix:** download the corrected launcher with matching `-SourceRepository` and
`-SourceRef <source-branch-or-fixed-commit>`. The fixed template keeps literal `properties` and
explicit `serverFarmId`, with only `functionAppConfig` conditional; storage lookup, scaling,
identity, authentication, and ingress behavior are unchanged. An old pinned commit still loads the old template.
Keep the original deployment inputs rather than switching plans.

**Verify:** `az deployment sub validate` checks the template without creating resources.
It does not verify publication, startup, Easy Auth, or delivery.

<a id="credential-caching-does-not-match-the-selected-plan"></a>
## Provider credential acquisition fails

**Signal:** `request_failed` with stage `provider_credentials`, reason `credential_unavailable`,
and HTTP `502`. The request has not reached the provider.

**Check:** for API keys, verify managed-identity access to the configured vault and the exact
provider secret names. For OAuth, verify the attached outbound managed identity, application
federation, provider tenant/scope, and provider permissions using the
[authentication handoff](../../docs/ONBOARDING.md#complete-provider-authentication).
Match diagnostics to the deployed package version. Regardless of event names, verify permissions
and identity configuration.

An attached managed identity is not application federation. Compare the issuer, identity
**principal ID** subject and `api://AzureADTokenExchange` audience, not just the credential name.
[Normal OAuth setup](README.md#outbound-federation) automatically creates or reuses the matching
trust and confirms it before certificate changes and again before publication. It preserves
older identities' trusts and retries transient creation/readback failures; no separate recovery
switch is needed. If rerunning an older deployment, keep the original inputs and select **Reuse**
when certificate rotation is not intended. Setup does not depend on provider-account readiness
and cannot grant missing provider-directory authorization.

Current packages acquire credentials only during live requests, retain SDK token caching, and
have no custom failure cooldown. The next live request can retry acquisition. Confirm the deployed
package version before comparing event sequences. If moving to current behavior, upgrade through
the normal reviewed deployment process; obsolete cache switches have no effect on current packages.
Restart after configuration changes. See
[credential acquisition](../../TECHNICAL.md#provider-settings-and-credential-acquisition).
Evaluation does not prove provider credentials work.

## appservice list-locations rejects EP1

`EP1` is an Azure Functions Elastic Premium plan SKU, but older Azure CLI versions do not accept
it in the `az appservice list-locations --sku` command. The current setup uses the subscription-scoped
`Microsoft.Web/geoRegions` ARM API with `sku=ElasticPremium` and `linuxWorkersEnabled=true` instead.
Query parameters are passed in a file to avoid Windows command-shell escaping problems.
The actual deployment remains **EP1**; it is not changed to a Dedicated App Service Premium SKU.

The accompanying 32-bit Python cryptography message is a performance warning, not the cause of
the invalid-SKU error. Rerun with the reviewed current-main helper; changing the SKU or installing
another Python runtime is not required to fix this check.

## A required Azure resource provider is not registered

Setup lists missing providers such as `Microsoft.Web` during preflight. After approval, it
registers only the six required namespaces. Declining approval registers nothing.

Registered providers are skipped. Setup proceeds from `Registering` when the region is exposed.
Polling is limited to 60 checks at 10-second intervals and 12 regional propagation retries.
It does not reverse `Unregistering`.

If registration fails, inspect the Azure CLI error. The account needs subscription-scoped
`/register/action`, generally included in Contributor or Owner. Setup leaves completed registration
requests in place for the rerun.

## Azure CLI directory context does not match the selected tenant

**Check:** `az account show` must identify an AzureCloud **user** session in the selected tenant.
Setup does not change the CLI default tenant; Graph uses that directory through `az ad`/`az rest`.
**Fix:** choose **Refresh subscriptions from Azure** or **Sign in to Azure (device code)**,
or authenticate before rerunning:

```powershell
az login --tenant '<customer-tenant-id>' --use-device-code
az account show --subscription '<subscription-id>' --output table
az ad signed-in-user show --output table
```

In Azure Cloud Shell, first switch the portal to the intended directory and start a PowerShell
session there. Setup does not silently switch Cloud Shell to another tenant. On a shared
workstation, `-ForceAuthentication` requests a fresh tenant-specific Azure CLI device-code login
after account selection. It does not run `az logout`, `az account clear`, or delete shared caches.

## The expected cached account or subscription is missing

The picker includes enabled AzureCloud subscriptions from an Azure CLI **user** login. Refresh
the cache or use device-code sign-in. Setup never replaces a supplied subscription ID.

For unattended setup, establish the user session first and verify both the tenant and subscription:

```powershell
az login --tenant '<customer-tenant-id>'
az account show --subscription '<subscription-id>' --output json
az account get-access-token --subscription '<subscription-id>' `
    --resource-type ms-graph --output none
```

Do not use `-ForceAuthentication` with `-NonInteractive`; the former intentionally requires an
interactive device-code flow.

## Setup still asks for PackageUrl or PackageSha256

**Fix:** refresh `Setup-Epp.ps1` and its reviewed `-SourceRepository`/`-SourceRef`; remove old
URL/hash arguments. **Expected:** one language choice, with package URL/checksum read automatically.

## A checksum or package download fails

**Check:** GitHub access, the selected `epp-packages-*` release, asset, and `SHA256SUMS.txt`.
Exactly one valid checksum entry must match; missing, duplicate, malformed, or mismatched entries
fail closed. **Never bypass verification or supply a replacement hash.**

**Fix:** align the launcher and [source/package versions](README.md#source-versioning).
Pin `-PackageReleaseTag` to reproduce a release. Public-fork branches need both source options;
a full SHA avoids branch-resolution API rate limits. Private raw downloads are unsupported.

## .NET build fails

**Fix:** install the **.NET 8 SDK**, allow NuGet access, and inspect the reported `dotnet` error.
**Expected:** setup selects 8.x, publishes verified source for Linux in its temporary workspace,
checks output, and packages it before Azure resource creation. Source ZIPs are not runnable.
Do not replace the source checksum with the built ZIP hash; setup calculates that separately.

## Python remote build fails

**FC1:** use Azure CLI **2.60.0+** and One Deploy with `--build-remote true`. Flex stores the Azure-built
payload in its configured managed-identity deployment container. Do not add
`SCM_DO_BUILD_DURING_DEPLOYMENT`, `ENABLE_ORYX_BUILD`, `FUNCTIONS_WORKER_RUNTIME`, or
`WEBSITE_RUN_FROM_PACKAGE`; these are not Flex configuration. The source hash is recorded, while the
built-output hash is left null because the setup workstation does not download it.

**EP1:** use Azure CLI **2.48.1+** with a user account allowed to publish to the Function App and network
access to its SCM endpoint. Setup enables `SCM_DO_BUILD_DURING_DEPLOYMENT` and `ENABLE_ORYX_BUILD`,
without `WEBSITE_RUN_FROM_PACKAGE` during the build, and requests Azure remote build explicitly.
It never installs Windows Python dependencies for the Linux app.

SCM basic authentication remains disabled. For EP1, `site/wwwroot` must contain the Python
dependency payload; setup rejects unbuilt source, stores the built output in private Blob storage,
and clears temporary build settings.

After build or startup failure, setup closes public ingress. If that fails, inspect it immediately.

## Azure CLI paths are combined during deployment

**Symptom:** `Invoke-EppAz` reports an `EndInvoke` failure because a command such as
`/usr/bin/az /bin/az` is not recognized, even though earlier Azure CLI operations succeeded.

**Cause:** PowerShell can discover multiple Azure CLI paths. Older animated progress runners
passed all discovered paths to the worker as one command instead of selecting the first match.
The static status path does not have this problem.

**Fix:** use a setup source revision containing the command-resolution fix. The corrected runner
selects the first discovered executable, preserving its path and argument boundaries. Do not
reinstall Azure CLI, edit `PATH`, or change hosting plans to work around this error.

**Temporary workaround:** save the current `$ProgressPreference`, set it to `SilentlyContinue`,
and rerun the same reviewed launcher revision with the original deployment inputs. Restore the
previous preference afterward. This disables only progress animation, not deployment approval,
validation, or error reporting. Reuse the printed `-ApplicationId` and original `-ResourcePrefix`;
do not create another app or delete partially created resources.

## Azure CLI warnings break JSON parsing

**Fix:** refresh the reviewed launcher/source revision.
**Expected:** stdout JSON is parsed separately from visible stderr warnings; nonzero exits still fail.

## Authentication, permission, or runtime preflight fails

1. Check [tools and permissions](README.md#prerequisites-for-step-2): PowerShell 7/Cloud Shell,
   installed Azure CLI, and a customer-tenant **user** session. Graph reuses that session; no Graph
   PowerShell SDK. ARM uses the selected subscription without adopting unrelated resource groups
   or changing the CLI default subscription.
2. Resolve missing Bicep through its interactive confirmation, or preinstall/use
   `-InstallPrerequisites` unattended. Azure CLI itself is not installed by setup.
3. Verify the [dedicated app and approved grants](README.md#step-1---manually-create-the-application).
   Azure roles do not grant Graph permissions; the user needs application/service-principal
   management and app-role assignment permissions, including active Privileged Role Administrator
   for the approved `Application.Read.All` grant.
4. Confirm beta `signInAudienceRestrictions` availability. If tenant policy/preview access blocks it,
   stop; setup does not silently allow all tenants. Unattended runs still need the user session
   and separate `-ApproveDeployment`.

## New app fails with an unsupported provider-tenant restriction

**Symptom:** setup creates the application and prints **Resolved Azure resource names**, then
stops with `The application has an unsupported provider-tenant restriction`. This can also
affect provider selection or preflight for an existing registration.

**Cause:** Microsoft Graph can return a
[`unrestrictedAudience`](https://learn.microsoft.com/graph/api/resources/unrestrictedaudience?view=graph-rest-beta)
object with `kind: unrestricted` instead of a null `signInAudienceRestrictions` value.
This is a valid unconfigured state; a single-tenant app still permits only its home tenant.
Older helpers accepted only null or an `allowedTenants` restriction and rejected this response.

**Recover:** use a setup source revision containing the fix. The launcher downloads its helpers
from `-SourceRepository` / `-SourceRef` (`main` by default), so an old pinned revision or a local
helper edit alone does not update the downloaded code. Rerun with the original `-ApplicationId`
and `-ResourcePrefix`, retaining the other deployment inputs. For a setup-created app, use the
client ID printed before the error or saved in `application-<client-id>.json`. Do not create
another registration, delete resources, or manually broaden tenant access to bypass the check.

The corrected helper recognizes the unrestricted state but still requires the approved provider
allowlist before successful deployment. Unknown or inconsistent restrictions and changes made
after plan approval still stop setup.

## `az ad` or `az rest` returns 403 Forbidden

Microsoft Graph requests use the Azure CLI user session. Verify that it belongs to the selected
tenant and can resolve the signed-in directory user:

```powershell
az account show --output table
az ad signed-in-user show --output json
az rest --method get `
    --url 'https://graph.microsoft.com/v1.0/me?$select=id,userPrincipalName' `
    --resource 'https://graph.microsoft.com/' `
    --output json
```

A 403 indicates directory authorization, Conditional Access, or role activation. Azure
Owner/Contributor does not grant this access. Verify application-management permissions and
Privileged Role Administrator activation, then rerun. Do not paste tokens into tickets.

The Graph user ID is tracked for directory operations only. Azure role assignments continue to
use the validated `oid` from the selected subscription's ARM access token.

## PrincipalNotFound for the Azure operator

Azure RBAC and Microsoft Graph can expose different object IDs for the same interactive account,
especially with brokered, guest, or aliased identities. Setup must not use Graph `/me` as an Azure
role-assignment principal. The current script decodes the selected subscription's ARM access token
in memory, validates its tenant, and passes its `oid` to Bicep. The token is never printed or saved.

Use `-ForceAuthentication` to require fresh Azure CLI device-code sign-in when account selection
is ambiguous. Microsoft Graph reuses that same CLI session. This does not replace ARM-token
identity selection and does not run
`az logout`, `az account clear`, or delete shared authentication caches. If a correct ARM `oid`
still receives `PrincipalNotFound`, wait for actual directory/RBAC replication and rerun with the
same prefix; retries must not substitute a Graph object ID.
Use a distinct resource prefix for each language; setup rejects changing a previously tagged
app to another runtime with the same prefix.

## Deployment stops after approval

**Check:** the named deployment and original error. Partial resources remain; setup does not
delete, purge/recover vaults, activate policy, or roll back. Follow
[safe recovery](#recover-without-destructive-cleanup) before a same-input rerun.

For **Create a new application**, a successful registration can remain even if later steps fail.
Its `application-<client-id>.json` record is not proof of deployment success. If the creation request
itself fails or times out, inspect the selected tenant before retrying; setup does not automatically
repeat that non-idempotent request. A permission error requires app-registration rights in addition
to the [other setup permissions](README.md#prerequisites-for-step-2).

Recognized storage/Key Vault RBAC propagation errors are retried for at most twelve attempts.
Transient Function startup errors also have bounded retries. This includes the specific ARM
`BadRequest` response `Encountered an error (InternalServerError) from host runtime`, which Azure can
return while a newly restarted host is still loading an otherwise valid package. Generic
`InternalServerError` responses are not retried. A successful upload alone is not success:
`SendOtp` must appear in Azure's function metadata. No success summary is written if publication or
registration fails.

**Verify:** inspect [host/worker logs](../../docs/APPLICATION-INSIGHTS.md#single-region-configuration)
for startup/discovery failures. Expected messages include `Worker process started and initialized`,
`Found the following functions: Host.Functions.SendOtp`, and `Job host started`.
Setup closes public ingress after persistent publication failure.

## The endpoint returns 401 or live delivery fails

1. **Before invocation:** use the [Easy Auth checklist](../../docs/ONBOARDING.md#manual-deployment-trust-checklist).
   Check issuer, token version, audience, HTTPS, and the nonempty Microsoft caller allowlist.
   Keep Easy Auth enabled and app `tokenEncryptionKeyId` null; bearer validation and payload JWE are separate.
2. **After invocation:** correlate [runtime events](../../docs/MONITORING.md#runtime-specific-log-discovery).
   Confirm `EPP_PROVIDER_SMS_ENDPOINT` or `EPP_PROVIDER_VOICE_ENDPOINT` and account access.
   The selected URL is required and the handler does not use the other channel's URL; deploy a supporting package.
3. Complete [provider authentication](../../docs/ONBOARDING.md#complete-provider-authentication):
   exact vault secrets for Telesign, provider-side authorization for Infobip or Soprano.
   Arrange [authorized evaluation, then controlled live checks](../../docs/ONBOARDING.md#validate-the-deployed-endpoint).
   Verify acceptance and receipt separately; never blindly resend a timeout.

**Activation remains separate:** use the [assisted policy procedure](README.md#step-3---manually-validate-and-activate-policy).
Setup does not change policy, and public Graph SMS/voice schemas do not document the EPP fields.
