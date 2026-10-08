# Setup and onboarding troubleshooting

Return to the [customer checklist](../../README.md) for the complete path. This guide separates
setup failures from provider, validation, and telemetry failures; a successful deployment is
only one onboarding gate.

## After-deployment triage

Keep the timestamped deployment summary and original error. Record the intended tenant,
subscription, resource group, runtime/release, test UTC time, and safe correlation IDs in a private
support case. Never attach complete app settings, tokens, phone numbers, OTPs, private keys,
encrypted request bodies, or raw provider responses. Do not enable body tracing for diagnosis.

| Symptom | First checks / owner | Do not do this |
|---|---|---|
| Cannot see an offer or EPP activation/test capability | Customer onboarding owner verifies the [Security Store and feature-access gate](../../docs/ONBOARDING.md#before-purchasing-or-deploying) with provider/Microsoft support. | Do not infer eligibility from Azure Owner or a successful purchase. |
| Setup reports success, but no OTP delivery | Finish [Telesign vault entry or Soprano provider consent](../../docs/ONBOARDING.md#complete-provider-authentication); confirm authorized testing and policy activation are separately complete. | Do not redeploy all runtimes or paste credentials into local settings. |
| Endpoint returns 401/403 with no invocation | Azure operator checks Easy Auth, issuer/audience/caller restrictions, network access, and available platform/auth logs. An ordinary customer CLI token is not the allowlisted Microsoft caller. | Do not disable Easy Auth, add a test caller, or interpret rejection as readiness. |
| App failure after invocation, including 401 | Inspect correlated `request_failed` and provider-response events. A provider's 401/403 is mapped to a handler 401; this differs from Easy Auth rejection. | Do not change inbound trust to fix outbound provider authorization. |
| `decryption_failed` or unresolved key reference | Compare summary certificate/thumbprint/key ID and versioned reference; verify Function identity vault access and reference resolution, then use an authorized evaluation. | Do not export the private key, delete registered certificates, or assume new vault versions automatically update Entra. |
| Provider credentials unavailable | Check secret names/enabled versions/vault access for Telesign; customer federation plus provider-side authorization/tenant/scope for Soprano. Allow RBAC propagation. | Do not assume evaluation validates outbound credentials. |
| Timeout, 502/504, or provider acceptance without handset receipt | Separate credential, outbound HTTP, host, and caller timings; ask the provider for supported delivery evidence. Confirm locale/digit clarity for voice. | Do not blindly resend: the first request may already have been accepted. |
| No requests/traces in Application Insights | Check the exact component/workspace, UTC window, actual authorized traffic, host/worker startup, ingestion identity/network, filters/sampling/caps, and effective exporter. Use [collection guidance](../../docs/APPLICATION-INSIGHTS.md). | Do not treat an empty table/Failures view as healthy or search every runtime for a JSON request summary. |
| Requests exist but Python/.NET event query is empty | Use [runtime-specific discovery](../../docs/MONITORING.md#runtime-specific-log-discovery). Python extras/.NET scopes may not be exported; .NET host OpenTelemetry does not initialize direct worker export. | Do not apply JavaScript's JSON parser to other runtimes or promise complete dependencies/exceptions. |
| No expiry email or alert | Operations owner checks vault certificate contacts/lifetime policy, independently configured reminders/action groups/rules, and notification tests. | Do not assume setup created alerts, or diagnostic settings deliver Key Vault expiry events. |

An accepted provider response, HTTP 200, a matching evaluation nonce, and actual recipient
delivery are different evidence. Retain only nonce-match booleans, statuses, latency, safe support
IDs, and delivery-confirmation outcomes. [Run the complete acceptance checks](../../docs/ONBOARDING.md#validate-the-deployed-endpoint)
before activation.

## Recover without destructive cleanup

Before approval, setup's read-only checks can fail without Azure resource mutation (local module
installation and sign-in may already have occurred). After approval, partial Azure/Entra changes
can remain even if no success summary was written. Inspect the Azure subscription/resource-group
deployment operations and the original failure before retrying.

Correct the underlying error, then use the same reviewed tenant, subscription, app, runtime,
plan, prefix, provider/channel/route, and intended source/package versions for a recovery rerun.
Changing identifiers can create new resources or break certificate continuity; changing a route
can reconfigure the existing endpoint. Setup does not resume from a checkpoint or undo previous
steps. For an active endpoint, arrange a change window because reruns can disable ingress and
update app settings/Entra.

Do not delete a resource group, purge/recreate the vault, remove encryption credentials, or revoke
shared Microsoft service-principal grants as a generic retry strategy. Use the separate
[rollback and decommissioning procedure](README.md#rollback-and-decommissioning) if retirement
is actually intended.

## Optional Front Door deployments

The single-region setup script does not provision Front Door or a multi-region readiness endpoint.
Use the [manual Front Door guide](../../docs/FRONTDOOR.md) for that option.

- A probe returning 401/403 or 404 is not healthy. Verify the dedicated readiness handler, its exact
  path, the origin host header, and the profile-pinned network restrictions. Do not exempt SendOtp
  or disable Easy Auth to make probes pass.
- An authenticated SendOtp request returning 403 during an outage still failed. Check origin state,
  access restrictions, and authentication diagnostics; do not assume every 403 is a normal failover
  transition or that the caller retries it.
- A successful request through the shared URL does not prove every origin works. Correlate safe
  request identifiers with regional telemetry and verify each origin after recovery.
- Distinguish delayed aggregate metrics from event timestamps and client observations. See the
  [recorded test results and limitations](../../docs/FRONTDOOR.md#observed-failover-results-and-limitations).

## Deployment fails with SubscriptionIsOverQuotaForSku

This is a subscription quota check, not an authentication failure or a missing resource-provider
registration. A region can support Linux Premium EP1 while your subscription has an **EP1 VMs**
limit of zero there. Quotas are regional: an allowance in one region does not establish an
allowance in another.

1. Confirm the tenant, subscription, region, and SKU in the deployment plan and Azure error.
2. In the Azure portal, open **Quotas**, select **App Service**, and filter to the intended
   subscription and region. Review **EP1 VMs**, its current usage, and the requested deployment's
   requirements. This is an App Service quota, not a general-purpose Compute VM quota.
3. Request an increase sufficient for the deployment and any planned scaling. Requesting an
   increase does not mean it is approved; verify the effective limit after approval.
4. If the quota is not adjustable in the portal or the request is rejected, create an Azure
   support request under **Service and subscription limits (quotas)** for
   **Function or Web App (Windows and Linux)**. Include the region, Linux deployment type, EP1
   SKU, current limit, requested limit, and the error's tracking ID.
5. Alternatively, choose another region only after checking its quota, service availability,
   and your residency and provider requirements. Review the updated deployment plan before approval.

See the [Azure quotas overview](https://learn.microsoft.com/azure/quotas/quotas-overview) for the
quota-management and support options. Setup does not request or guarantee a quota increase.
Do not change the hosting SKU, disable Easy Auth, or change provider credentials to bypass this
error. After resolving quota, rerun setup and complete the normal deployed validation checks.

## Service plan selection or availability fails

Choose `-ServicePlan FC1` for Flex Consumption or `-ServicePlan EP1` for Premium. The parameter is
required in noninteractive mode. FC1 requires Azure CLI **2.60.0+**, while EP1 keeps **2.48.1+**.
FC1 regional checks use `az functionapp list-flexconsumption-locations`; EP1 uses its existing ARM
check below. Availability in one plan does not imply availability in the other.

FC1 offers a free usage grant, not a zero-cost guarantee. It configures zero always-ready instances;
supporting services and usage beyond the grant can still incur charges.

Setup refuses to switch an existing prefix between FC1 and EP1. Use a different prefix and validate
the new endpoint before manually changing policy. For an active endpoint, also onboard a new
dedicated application or coordinate key continuity; a new prefix creates a different encryption key
and cannot bypass the existing application's certificate checks.
For older deployments without a service-plan tag,
preflight checks the actual hosting-plan SKU. Use `-ServicePlan EP1` when rerunning an existing EP1
deployment; do not delete tags to bypass the migration guard.

## FC1 deployment preflight reports an object-reference error

An affected setup template can fail with `InvalidTemplateDeployment` against
`Microsoft.Web/serverfarms` and the inner message `Object reference not set to an instance of an object`.
The cause is the Function App's entire `properties` object being wrapped in a `union()` expression
that contains the Flex deployment storage endpoint's runtime `reference()`. ARM defers that whole
expression, including `serverFarmId`, so the provider cannot see the Function-to-plan association
during preflight. This error is not evidence that the FC1 SKU or selected region is unsupported.

The corrected Bicep keeps `properties` as a literal object with an explicit `serverFarmId` and makes
only `functionAppConfig` conditional on FC1. The storage endpoint lookup, hosting-plan configuration,
scaling, managed identities, authentication, and public-access settings are unchanged.

Download the updated `Setup-Epp.ps1` from the intended source branch and rerun it with matching
`-SourceRepository` and `-SourceRef <source-branch-or-fixed-commit>` values. A command pinned to an
older commit still downloads the old support files and template. Keep the original tenant, subscription, application,
language, service plan, and resource prefix rather than changing plans to bypass this error.
`az deployment sub validate` can check the corrected template without creating resources. Passing
validation does not prove successful publication, runtime startup, Easy Auth enforcement, or delivery.

## Credential caching does not match the selected plan

Check `EPP_KEY_VAULT_CACHE_ENABLED` and `EPP_ACCESS_TOKEN_CACHE_ENABLED` on the serving Function App.
Setup writes both as `"false"` for FC1 or `"true"` for EP1; rerunning setup restores those values.
These settings only affect a deployed Function package that implements the cache readers.
This setup change does not add runtime cache control, so `"false"` alone does not disable caching
in an unsupported package. Deploy a supporting runtime release before relying on these settings.

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

The current setup detects missing providers such as `Microsoft.Web` during read-only preflight
and lists them in the resource plan instead of asking the customer to register them manually.
After `Yes` (or explicit noninteractive approval), it registers only the six namespaces needed by
this deployment in the supplied subscription. No registration occurs if approval is declined.

Already registered providers are skipped. `Registering` is not a failure: Azure registers each
region separately, so setup proceeds when the needed region is exposed and retries recognized
registration-propagation errors. Metadata polling is limited to 60 checks with 10-second pauses;
regional propagation retries are limited to 12 attempts. An actively `Unregistering` provider is
not reversed automatically.

If registration fails, inspect the original Azure CLI error. The account needs subscription-scoped
resource-provider `/register/action` permission, generally included in Contributor or Owner.
Setup cannot grant this permission or bypass a subscription policy. It stops before creating the
certificate or deployment resources. Registrations already requested are left in place for a rerun;
the script does not unregister services that other workloads might now use.

## Get-MgContext reports SessionNotInitialized

This is different from simply not being signed in. A failed attempt to remove Graph Authentication
can run the SDK's cleanup hook and clear its internal session even though Graph Applications keeps
the module loaded. Reimporting an already loaded module normally does not initialize it again.
See the upstream [Graph SDK issue](https://github.com/microsoftgraph/msgraph-sdk-powershell/issues/2457).

Setup now detects this exact error during its initial context check, reloads the **same loaded
Authentication version** once, and then uses the normal sign-in flow. It does not force-remove the
SDK, upgrade modules, suppress unrelated errors, or automatically reconnect after deployment approval.
A healthy existing Graph session is reused unchanged. Noninteractive runs still require prior sign-in.

For immediate recovery, start a new process with `pwsh -NoProfile` and rerun the downloaded script.
If initialization still fails after the one reload, setup gives this same clean-process instruction
instead of repeatedly retrying or hiding the error.

## Remove-Module says Graph Authentication is required by Graph Applications

Older setup versions imported the Graph SDK inside the temporary EPP module. Unloading that
helper could then attempt to remove its Graph dependencies in the wrong order, producing this
cleanup error. The current version imports both Graph modules into the PowerShell session's global
scope and unloads only its temporary EPP helper. Your Graph modules and sign-in context remain
available for subsequent commands and reruns.

Do not add `-Force` to remove the Graph SDK. Download the updated launcher and open a fresh
PowerShell 7 window to discard module state left by the old version. Cleanup failures are now
reported as warnings, temporary-file cleanup is attempted independently, and an earlier setup
error is preserved. A cleanup error alone does not establish whether Azure deployment succeeded;
review the original output and saved deployment summary.

## Setup still asks for PackageUrl or PackageSha256

You are running an older launcher or source revision. Download `Setup-Epp.ps1` again and supply
the intended `-SourceRepository` and `-SourceRef`. The current version asks for **one language**
and reads its package URL and published checksum automatically. Remove old package URL/hash
arguments from saved commands.

## A checksum or package download fails

Setup resolves the latest stable `epp-packages-*` CI release by default, then downloads the selected
catalog asset and that release's `SHA256SUMS.txt`. Use `-PackageReleaseTag` when reproducing a
specific release. The checksum file must contain exactly one valid entry for that asset. Missing,
duplicate, malformed, or mismatched checksums fail closed; there is no manual-hash or
skip-verification workaround. Verify the release assets and your access to GitHub.

Supporting tools, Bicep, catalogs, and provider JSON all come from the commit selected at startup.
For a public-fork branch, pass both source options. A full commit SHA avoids branch-resolution
API rate limits. Private repositories are not supported by these unauthenticated raw downloads.

## .NET build fails

Install the **.NET 8 SDK** and allow NuGet access. Setup selects an installed 8.x SDK, extracts the
verified source into its temporary workspace, runs a Linux-targeted Release publish, checks the
publish output, and creates the ready ZIP. The source ZIP is not uploaded as runnable code.
Build failures occur before Azure resource creation and include the `dotnet` failure output.

Do not manually replace the published source checksum with a hash of the build output. These
represent different artifacts; setup computes the built artifact's hash itself.

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

SCM basic authentication remains disabled for both plans. The CLI uses Microsoft Entra authentication.
For EP1, the built
`site/wwwroot` snapshot must include the Python Functions dependency payload; an unbuilt source
archive is rejected even when an upload command returned success. The built output is then stored
in private Blob storage, and temporary remote-build settings are cleared.

If build, snapshot, publication, or startup fails after opening SCM ingress, setup attempts to
disable public ingress again. An inability to close ingress is an explicit error requiring
immediate administrator inspection. Do not bypass certificate errors or enable basic auth.

## Azure CLI warnings break JSON parsing

The current helper separates stdout from stderr. Successful command JSON is parsed independently
of SDK warnings, while stderr warnings are shown and nonzero exit codes still fail. Upgrade an
older downloaded helper by refreshing the launcher/source revision.

## Authentication, permission, or runtime preflight fails

Use PowerShell 7 on Windows, Azure CLI with Bicep, and the documented Graph modules. Sign into the
customer tenant with a user account. ARM requests use the supplied subscription; setup does not
change the CLI's default subscription or adopt unrelated resource groups.

Azure CLI itself must be installed before setup. When a matching session is absent, interactive
setup launches `az login` for the supplied tenant. Missing Graph modules and the Azure CLI Bicep
component can be installed after confirmation; noninteractive runs require
`-InstallPrerequisites` or prior installation.

Only the dedicated customer application registration must exist from manual Step 1. After approval,
setup makes it multi-tenant, restricts it to its home tenant plus the provider JSON's `tenantId`
through the Entra allowed-tenants preview, creates both required service principals, adds and assigns
`Epp.Invoke`, and grants the Microsoft phone-provider service principal Graph `Application.Read.All`.

Graph needs delegated `User.Read`, `Application.ReadWrite.All`, `Application.Read.All`, and
`AppRoleAssignment.ReadWrite.All`. Granting a Microsoft Graph application permission normally
requires a Privileged Role Administrator. Noninteractive runs must authenticate both clients first
with these scopes and supply `-ApproveDeployment` separately.

The tenant restriction uses Microsoft Graph beta `signInAudienceRestrictions`. If that preview is
unavailable or the tenant policy blocks it, setup stops before mutation rather than silently allowing
all organizational tenants.

## Graph /me returns 403 Forbidden

`GET /me?$select=id,userPrincipalName` requires delegated
[`User.Read`](https://learn.microsoft.com/en-us/graph/api/user-get?view=graph-rest-1.0#permissions).
The application-management scopes do not authorize this profile lookup. Versions that added the
Graph operator readback without requesting `User.Read` could therefore fail during preflight.
This is a setup sign-in scope issue, not a request for another Azure or Entra administrator role.

Use the updated script and source revision. It requests `User.Read` for the operator's Graph
PowerShell session and reconnects interactively when a cached session lacks it, before calling
`/me`. `-ForceAuthentication` also requests the complete scope set. Noninteractive runs must
authenticate first:

```powershell
Connect-MgGraph -TenantId '<customer-tenant-id>' -ContextScope Process `
    -Scopes 'User.Read', 'Application.ReadWrite.All', 'Application.Read.All', 'AppRoleAssignment.ReadWrite.All'
```

This does not grant `User.Read` to the Microsoft phone-provider service principal or endpoint app.
Azure role assignments continue to use the ARM token's `oid`, not Graph `/me`.

## PrincipalNotFound for the Azure operator

Azure RBAC and Microsoft Graph can expose different object IDs for the same interactive account,
especially with brokered, guest, or aliased identities. Setup must not use Graph `/me` as an Azure
role-assignment principal. The current script decodes the selected subscription's ARM access token
in memory, validates its tenant, and passes its `oid` to Bicep. The token is never printed or saved.

Use `-ForceAuthentication` to require fresh Azure CLI and Graph device-code sign-in when account
selection is ambiguous. This does not replace ARM-token identity selection and does not run
`az logout`, `az account clear`, or delete shared authentication caches. If a correct ARM `oid`
still receives `PrincipalNotFound`, wait for actual directory/RBAC replication and rerun with the
same prefix; retries must not substitute a Graph object ID.
Use a distinct resource prefix for each language; setup rejects changing a previously tagged
app to another runtime with the same prefix.

## Deployment stops after approval

Some resources can remain. No automatic deletion, vault purge/recovery, policy activation, or
rollback occurs. Inspect the named Azure deployment and the reported error, then rerun with the
same tenant, subscription, application, language, service plan, and prefix after correcting it.

Recognized storage/Key Vault RBAC propagation errors are retried for at most twelve attempts.
Transient Function startup errors also have bounded retries. This includes the specific ARM
`BadRequest` response `Encountered an error (InternalServerError) from host runtime`, which Azure can
return while a newly restarted host is still loading an otherwise valid package. Generic
`InternalServerError` responses are not retried. A successful upload alone is not success:
`SendOtp` must appear in Azure's function metadata. No success summary is written if publication or
registration fails.

If setup exhausts the retries, inspect Application Insights for host initialization, worker startup,
and function discovery errors before rerunning. The expected healthy sequence includes `Worker process
started and initialized`, `Found the following functions: Host.Functions.SendOtp`, and `Job host
started`. Setup closes public ingress after a persistent publication failure.

## The endpoint returns 401 or live delivery fails

Keep Easy Auth enabled. Check the trusted tenant, actual token version, audience, HTTPS requirement,
and nonempty Microsoft caller allowlist. Keep `tokenEncryptionKeyId` null on the endpoint app;
payload JWE encryption is separate from signed bearer-token validation.

For live delivery, confirm the setup-selected complete provider URL and its account authorization.
Telesign needs its exact Key Vault secret names; Soprano needs provider-side authorization, not
API-key secrets. Arrange an authorized evaluation through the
[test handoff](../../docs/ONBOARDING.md#validate-the-deployed-endpoint) before controlled live
messages. EPP policy remains a separate assisted administrator-approved operation; no setup code
updates it. Public Graph SMS/voice schemas do not document the EPP activation fields.
