# Troubleshooting Step 2

## appservice list-locations rejects EP1

`EP1` is an Azure Functions Elastic Premium plan SKU, but older Azure CLI versions do not accept
it in the `az appservice list-locations --sku` command. The current setup uses the subscription-scoped
`Microsoft.Web/geoRegions` ARM API with `sku=ElasticPremium` and `linuxWorkersEnabled=true` instead.
Query parameters are passed in a file to avoid Windows command-shell escaping problems.
The actual deployment remains **EP1**; it is not changed to a Dedicated App Service Premium SKU.

The accompanying 32-bit Python cryptography message is a performance warning, not the cause of
the invalid-SKU error. Rerun with the updated test-branch helper; changing the SKU or installing
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

Use Azure CLI **2.48.1+** with a user account allowed to publish to the Function App and network
access to its SCM endpoint. Setup enables `SCM_DO_BUILD_DURING_DEPLOYMENT` and `ENABLE_ORYX_BUILD`,
without `WEBSITE_RUN_FROM_PACKAGE` during the build, and requests Azure remote build explicitly.
It never installs Windows Python dependencies for the Linux app.

SCM basic authentication remains disabled. The CLI uses Microsoft Entra authentication. The built
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
same tenant, subscription, application, language, and prefix after correcting it.

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

For live delivery, replace dummy endpoints and configure the provider's exact Key Vault secret
names. Test with synthetic evaluation requests before live messages. EPP policy remains a
separate, administrator-approved manual operation; no setup code updates it.
