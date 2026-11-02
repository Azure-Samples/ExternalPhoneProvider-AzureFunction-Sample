# Setup reference

[Documentation](../../docs/README.md) | [Deployment guide](../../docs/GETTING-STARTED.md) | [Troubleshooting](Troubleshooting.md)

Use the [deployment guide](../../docs/GETTING-STARTED.md) for your first deployment.
This reference covers permissions, configuration, repeatable deployments, and maintenance.
Use the [documentation index](../../docs/README.md) to choose between guides.

| Task | Section |
| --- | --- |
| Prepare access and tools | [Prerequisites](#prerequisites) |
| Choose hosting | [Service plans](#service-plan-selection) |
| Deploy | [Run setup](#run-setup) |
| Review application changes | [Application registration](#application-registration) |
| Understand provider routing | [Provider configuration](#provider-configuration) |
| Keep or replace a certificate | [Certificate selection](#encryption-certificate-selection) |
| Automate a reviewed deployment | [Noninteractive example](#noninteractive-example) |
| Pin source and packages | [Source versioning](#source-versioning) |
| Find saved values | [Deployment summary](#read-the-deployment-summary) |
| Activate or retire the endpoint | [Activation](#activate-the-endpoint), [rollback](#rollback-and-decommissioning) |

<a id="prerequisites-for-step-2"></a>
## Prerequisites

- **PowerShell 7+** or Azure Cloud Shell in PowerShell mode.
- **Azure CLI 2.60.0+ for FC1** or **2.48.1+ for EP1**, with a customer-tenant user login
  in Azure public cloud.
- Network access to GitHub, Azure, Microsoft Graph, Key Vault, and Function deployment endpoints.
- An available Linux FC1 or EP1 region with sufficient subscription quota.
- Provider account access and the test and activation procedure for your tenant. See
  [before deployment](../../docs/ONBOARDING.md#before-deployment).

Install missing tools using the official
[PowerShell](https://learn.microsoft.com/powershell/scripting/install/install-powershell) and
[Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) instructions, then check:

```powershell
$PSVersionTable.PSVersion
az version
```

Setup can install the Azure CLI Bicep component after confirmation.
For unattended runs, install it beforehand or supply `-InstallPrerequisites`.

### Permissions are separate

| Scope | Required access |
| --- | --- |
| Azure subscription | **Owner**, or **Contributor** plus **Role Based Access Control Administrator** with permission to create the required role assignments |
| Microsoft Entra ID | Application and enterprise-application management, plus **Privileged Role Administrator** for the Microsoft first-party service principal's Graph `Application.Read.All` grant |
| New application | Permission to register applications; an appropriate role such as **Application Developer** can provide this when user registration is restricted |
| Policy activation | **Authentication Policy Administrator**, used after deployment and validation |

Setup deploys at subscription scope and creates a resource group. Activate eligible PIM roles
before running it. Azure roles and Microsoft Entra roles grant access to different resources.
See [Azure built-in roles](https://learn.microsoft.com/azure/role-based-access-control/built-in-roles)
and [application creation permissions](https://learn.microsoft.com/graph/api/application-post-applications?view=graph-rest-1.0#permissions).

Microsoft Graph calls use the Azure CLI user session. Setup uses the Microsoft Graph beta
[allowed-tenants configuration](https://learn.microsoft.com/graph/api/resources/allowedtenantsaudience?view=graph-rest-beta);
confirm that your tenant permits this configuration.

Certificate reuse also requires operator access to the source vault's ARM resource, certificate,
and secret-version metadata. For another vault, the operator must be able to grant the Function
secret-read access. See [certificate selection](#encryption-certificate-selection).

## Service plan selection

| Plan | Configuration deployed by setup |
| --- | --- |
| Flex Consumption (`FC1`, default) | Linux, 2048 MB, up to 40 on-demand instances, zero always-ready instances |
| Premium (`EP1`) | Linux, one warm instance, up to three elastic workers |

FC1 can scale to zero and cold-start. Its
[free usage grant](https://learn.microsoft.com/azure/azure-functions/flex-consumption-plan#billing)
is subject to Azure's billing terms. EP1 incurs a baseline compute charge while idle.
Both plans also use storage, Key Vault, and monitoring. Review the
[cost estimate](../../docs/COST-CALCULATOR.md).

Press Enter to choose FC1 interactively. Unattended runs require `-ServicePlan`.
To change plans, deploy with a different resource prefix. For an independent endpoint, also use
a dedicated application. Coordinate certificate continuity when sharing an application.

<a id="step-2---download-and-run-one-script"></a>
## Run setup

Download the launcher into a private working folder:

```powershell
Invoke-WebRequest `
    -Uri 'https://raw.githubusercontent.com/Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample/main/setup/Setup-Epp.ps1' `
    -OutFile .\Setup-Epp.ps1
```

Review it, then run:

```powershell
.\Setup-Epp.ps1
```

1. Select the customer tenant and subscription.
2. Choose **Create a new application**. For a rerun, select the existing application or enter its client ID.
3. Choose an Azure region. Setup detects the tenant's EU or Global provider route.
4. Enter or confirm the provider name: **Infobip**, **Soprano**, or **Telesign**.
5. Choose the hosting plan and resource prefix. JavaScript is the default runtime; use
   `-Language csharp` or `-Language python` to change it.
6. Review [certificate handling](#encryption-certificate-selection) if the app has existing keys.
7. Review the complete plan. Enter **Yes** or **Y** to deploy; **No**, **N**, or Enter cancels.

Enter accepts a displayed menu default. Provider-name selection has no default.
Use **0** or **Cancel** where offered to stop a selection.

The plan lists the resource names, provider URLs, source and package versions, permissions,
certificate changes, and required Azure resource-provider registrations. For a new application,
it shows name patterns containing `<app-id-hash>`; setup calculates the final names after
creating the app.

Setup keeps public ingress closed while preparing the resources and encryption key. It checks
Easy Auth before opening ingress and verifies Function registration after publication.
Wait for **Deployment completed successfully** and the saved summary.

If a new application is created but deployment fails later, use the client ID saved in
`application-<client-id>.json` and the original prefix when retrying.
See [safe recovery](Troubleshooting.md#recover-without-destructive-cleanup).

### Reviewing the plan without deploying

Run setup interactively and answer **No** at the final deployment prompt.
Leave `-ApproveDeployment` unset.

Preflight downloads and verifies packages, checks permissions and regional availability, and
compiles Bicep. Sign-in and tool-installation prompts are separate from deployment approval.
Azure resources and application configuration change only after deployment approval.

### Supply known values and keep approval interactive

Use parameters to skip selections you have already made while retaining the final plan review.
Replace the IDs, region, provider, and prefix with your deployment values:

```powershell
.\Setup-Epp.ps1 `
    -TenantId '<customer-tenant-id>' `
    -SubscriptionId '<subscription-id>' `
    -ApplicationId '<existing-client-id>' `
    -Location westus2 `
    -Language javascript `
    -ServicePlan FC1 `
    -Provider '<provider-id>' `
    -ResourcePrefix contoso
```

Use `infobip`, `soprano`, or `telesign` for `<provider-id>`.
The resource-name suffix comes from the subscription, application client ID, and prefix.
Keep those values for reruns. Changing the provider or location while retaining them can
reconfigure the existing deployment rather than create another endpoint.

### After approving the plan

Use these milestones to follow the deployment:

| Stage | What setup does | What to retain or check |
| --- | --- | --- |
| Application | Creates the selected new registration, if requested, and resolves resource names | Keep the printed client ID and `application-<client-id>.json` for recovery. |
| Resource providers | Registers missing required Azure namespaces | Resolve permission or regional-availability failures before retrying. |
| Infrastructure | Creates or updates the regional resources with public Function ingress closed | Inspect the named subscription deployment and resource group if this stage fails. |
| Encryption | Creates or reuses the approved certificate and verifies its versioned secret reference | Check the certificate ID, key ID, and expiration in the summary. |
| Application trust | Applies and reads back the application, role, certificate, and federation configuration | Confirm the reviewed permission and certificate changes. |
| Publication | Verifies Easy Auth, opens ingress, publishes the package, and verifies Function registration | Wait for startup verification, not just package upload. |
| Handoff | Saves `deployment-*.json` and prints next steps | Retain the summary and public certificate, then complete provider authorization and validation. |

FC1 publishes through **One Deploy**. EP1 uploads the verified package to private Blob storage
and uses managed-identity run-from-package, followed by restart and trigger synchronization.
Publication and resource deployment can each take several minutes; keep the session open.
If publication fails, setup attempts to close ingress again. Inspect any reported failure to
close it before proceeding.

An application-creation record is a recovery aid. Use the completed deployment summary to
identify the endpoint ready for validation.

<a id="step-1---manually-create-the-application"></a>
## Application registration

For a new deployment, choose **Create a new application** during guided setup. The name defaults
to **EPP Application**, and creation occurs after you approve the deployment plan.
Follow the [download-and-run instructions](../../docs/GETTING-STARTED.md#2-download-and-run-the-setup-script).

For an existing registration, supply its **Application (client) ID**.
Unattended setup requires an existing `-ApplicationId`.

Setup configures:

- Organizational multitenancy and an allowed-tenant list containing the provider tenants,
  while preserving existing allowed tenants. The application home tenant remains allowed.
- The endpoint enterprise application, required assignment, and the `Epp.Invoke` role assigned
  to the Microsoft phone-provider service principal.
- Microsoft Graph `Application.Read.All` for that Microsoft service principal.
- The identifier URI, public encryption certificate, and Easy Auth caller restriction.
- A federated credential for the outbound managed identity.

Exact existing issuer/subject/audience federation matches are reused. Other trusts are preserved.
Complete [provider-side authorization](../../docs/ONBOARDING.md#complete-provider-authentication)
after deployment.

## Provider configuration

Setup reads the selected profile from [providers](../providers/catalog.json). All bundled
profiles use OAuth and supply complete HTTPS URLs for both channels.

| Profile field | Purpose |
| --- | --- |
| `deployment.tenantId` | Provider's Security Store tenant; used for discovery |
| `deployment.AccessTokenScopeTenant` | OAuth token tenant; when omitted, setup uses `tenantId` |
| `deployment.routes.global` / `deployment.routes.eu` | Channel URLs, API application ID, scope, and timing values |

Setup maps the token tenant to `EPP_PROVIDER_TENANT_ID` and includes both provider tenants in
the application's reviewed allowlist. The [Telesign](../providers/telesign.json),
[Soprano](../providers/soprano.json), and [Infobip](../providers/infobip.json) profiles contain
the values used by guided setup.

### Tenant scope and Azure region recommendations

Setup reads `tenant_region_scope` from the selected tenant's OpenID Connect discovery document.
EU tenants use the EU provider route; other scopes use Global.
An explicit `-EndpointRegion eu` or `-EndpointRegion global` must match that detected route.

EU tenants receive a shortlist of Azure-recommended physical regions within the
[EU Data Boundary](https://learn.microsoft.com/privacy/eudb/eu-data-boundary-learn#eu-data-boundary-countries-and-datacenter-locations).
Manual entry and `-Location` remain available. An out-of-boundary or unverifiable EU location
produces a warning for review. Choose a location that meets your organization's requirements;
the recommendation is not a data-residency guarantee.

## Encryption certificate selection

| Existing registered encryption certificates | Available action |
| --- | --- |
| None | Create a certificate automatically |
| One or more | **Replace** (interactive default) or **Reuse** |

> [!IMPORTANT]
> **Replace** removes all registered encryption credentials and registers one new certificate
> after approval. **Reuse** keeps the selected key and removes other encryption entries after
> approval. Coordinate changes across every endpoint sharing the application.

Signing credentials and Key Vault objects are preserved. The final plan lists the exact key IDs
to keep or remove. Unattended runs with existing encryption credentials require an explicit action.

### Reuse a certificate

1. Select **Reuse** and the registered encryption key ID.
2. In **Key Vault** > **Certificates** > **certificate** > **version**, copy the
   **Certificate Identifier**:
   `https://<vault>.vault.azure.net/certificates/<name>/<version>`.
3. Supply `-KeyVaultSubscriptionId` if that vault is in another subscription in the same tenant.
4. Review the matching certificate and required vault permissions in the deployment plan.

The certificate must exactly match the registered certificate. It must use exportable RSA
of at least 2048 bits and an enabled, certificate-managed PEM backing secret.
Both the certificate and registered credential must be valid with more than 30 days remaining.

The Function's **system-assigned identity** reads the private-key reference. For a different vault,
setup grants **Key Vault Secrets User** at the certificate secret's scope in RBAC mode.
For an access-policy vault, the reviewed grant is **Secrets/Get** at vault scope.
Provide a working network path from the Function to the vault.

Setup resolves the backing secret's exact version; certificate and secret version IDs can differ.
It downloads only the public certificate and pins the Function to the versioned secret.

### Replace a certificate

Replacement stages a new certificate before updating the registration. Setup verifies that the
Function can resolve the secret reference, then registers one matching encryption credential.
New certificates are exportable RSA-2048 with subject **`CN=ExternalPhoneProvider`**.

Coordinate a maintenance window: cached or in-flight requests can still use the previous key.
Complete an authorized evaluation before returning the endpoint to service.
After a partial failure, inspect the registration and select **Reuse** if the new key was
already registered.

## Noninteractive example

First review the corresponding interactive plan. Establish an Azure CLI **user** session in the
intended tenant; MFA or consent can still require interaction.

Replace the placeholders and choose the region, plan, and prefix.
For `<provider-id>`, use `infobip`, `soprano`, or `telesign`.

```powershell
$tenantId = '<customer-tenant-guid>'
$subscriptionId = '<subscription-guid>'
$applicationId = '<dedicated-app-client-guid>'

az login --tenant $tenantId
if ($LASTEXITCODE -ne 0) { throw 'Azure sign-in failed.' }
az account get-access-token --subscription $subscriptionId --output none
if ($LASTEXITCODE -ne 0) { throw 'Azure subscription token acquisition failed.' }
az account get-access-token --subscription $subscriptionId --resource-type ms-graph --output none
if ($LASTEXITCODE -ne 0) { throw 'Microsoft Graph token acquisition failed.' }

.\Setup-Epp.ps1 `
    -TenantId $tenantId `
    -SubscriptionId $subscriptionId `
    -ApplicationId $applicationId `
    -Location westus2 `
    -Provider '<provider-id>' `
    -Language javascript `
    -ServicePlan FC1 `
    -ResourcePrefix contoso `
    -OutputDirectory .\epp-output `
    -NonInteractive `
    -ApproveDeployment
```

In Cloud Shell, use the intended directory's existing login in place of `az login`.
Both `-NonInteractive` and `-ApproveDeployment` are required for an unattended deployment.
The example assumes the application has no registered encryption certificate.

For reuse, add these parameters to the setup command:

| Parameter | Value |
| --- | --- |
| `-CertificateAction` | `Reuse` |
| `-EncryptionKeyId` | Registered key ID to keep |
| `-KeyVaultCertificateId` | `https://<vault>.vault.azure.net/certificates/<name>/<version>` |

For deliberate replacement, use `-CertificateAction Replace` instead.

| Additional option | Purpose |
| --- | --- |
| `-ForceAuthentication` | Fresh device-code sign-in for interactive runs |
| `-InstallPrerequisites` | Authorize installation of a missing Azure CLI Bicep component |
| `-OutputDirectory` | Private output folder; default is `epp-output` beside the launcher |
| `-PassThru` | Return the structured deployment result in addition to saving it |
| `-SourceRepository`, `-SourceRef`, `-PackageReleaseTag` | Pin [source and packages](#source-versioning) |

## Source versioning

Defaults are `-SourceRepository Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample` and
`-SourceRef main`. Setup resolves one commit for its supporting scripts, Bicep templates,
catalogs, and profiles.

Packages come from stable [GitHub releases](https://github.com/Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample/releases):

| Runtime | Tag format |
| --- | --- |
| JavaScript | `epp-packages-<run>-<attempt>-javascript` |
| C# | `epp-packages-<run>-<attempt>-dotnet` |
| Python | `epp-packages-<run>-<attempt>-python` |

Each release contains `released-package.zip` and `SHA256SUMS.txt`. Setup verifies the ZIP
against the checksum from the same release.

For a repeatable deployment, pin a reviewed full commit SHA with `-SourceRef` and an exact
matching language tag with `-PackageReleaseTag`. Use the values recorded in the deployment summary.
To deploy custom source, publish a reviewed public fork and matching stable package release,
then select that repository, source commit, and release.

## Read the deployment summary

Open the timestamped `deployment-*.json` in `epp-output`. Keep it in restricted storage.

| Fields | Purpose |
| --- | --- |
| `tenantId`, `subscriptionId`, `applicationId` | Customer context and endpoint application client ID |
| `resources` | Azure resource names |
| `provider`, `endpointRegion`, `tenantRegionScope` | Selected provider and detected routing scope |
| `providerTenantId`, `accessTokenScopeTenant` | Security Store tenant and OAuth token tenant |
| `providerSmsEndpoint`, `providerVoiceEndpoint` | Outbound channel URLs |
| `endpointUrl`, `identifierUri` | Endpoint and application identifier for testing and activation |
| `encryptionKeyId`, `certificateThumbprint`, `certificateId`, `certificateSecretId` | Encryption credential and exact certificate/secret versions |
| `certificateExpiresUtc`, `certificateRenewal` | Expiration and manual renewal requirement |
| `certificateAction`, `removedEncryptionKeyIds` | Approved encryption-credential changes |
| `certificateVaultSubscriptionId`, `certificateReferenceResolved` | Certificate source subscription and result of the Function's reference-resolution check |
| `allowedProviderTenantIds` | Reviewed provider-tenant allowlist |
| `endpointServicePrincipalId`, `microsoftPhoneProviderServicePrincipalId` | Tenant-local enterprise-application object IDs; use `applicationId` for the endpoint client ID |
| `sourceRevision`, `packageReleaseTag`, `packageSha256`, `language`, `servicePlan` | Deployment provenance and runtime |
| `source`, `packageUrl`, `sourcePackageSha256` | Resolved setup-source URL, downloaded package URL, and verified source-package hash |
| `policyChanged` | `false`; activate policy after endpoint validation |

C# is recorded as `csharp` in the summary and uses `dotnet` package tags.
The deployment summary confirms setup completion. Verify
[provider authorization and delivery](../../docs/ONBOARDING.md#validate-the-deployed-endpoint)
before activation.

## Encryption certificate lifecycle

Certificates issued by setup have **12-month validity and manual renewal**.
The lifetime policy uses `EmailContacts` 30 days before expiry. Configure
[Key Vault certificate contacts](https://learn.microsoft.com/azure/key-vault/certificates/overview-renew-certificate)
and an independent renewal reminder with an owner.

The Function uses a pinned secret version. Renewing a certificate in Key Vault requires a
coordinated update to the Microsoft Entra ID registration and the Function reference.

1. Record the certificate and registered credential expiration dates.
2. Schedule renewal before the 30-day remaining-validity limit.
3. Use **Replace** during approved maintenance, or synchronize the renewed certificate through
   your administrator procedure and **Reuse** that exact registered version.
4. Validate decryption and controlled live delivery after the change.

Include every endpoint sharing the application in the maintenance plan. Run setup against an
application one session at a time.

<a id="step-3---manually-validate-and-activate-policy"></a>
## Activate the endpoint

Complete [provider authorization and endpoint validation](../../docs/ONBOARDING.md#validate-the-deployed-endpoint)
first. Then have the **Authentication Policy Administrator** use Microsoft's current
telephony-provider configuration procedure for the tenant and channel.
The [SMS](https://learn.microsoft.com/graph/api/smsauthenticationmethodconfiguration-update?view=graph-rest-beta)
and [voice](https://learn.microsoft.com/graph/api/voiceauthenticationmethodconfiguration-update?view=graph-rest-beta)
policies expose the integration through
[`telecomProviderSettings`](https://learn.microsoft.com/graph/api/resources/telecomprovidersettings?view=graph-rest-beta).

> [!IMPORTANT]
> The examples below use Microsoft Graph **beta**. Microsoft marks beta APIs as subject to change
> and unsupported for production applications. Confirm the supported administration procedure
> and feature availability for your tenant before changing a production policy.

### Back up the current policy

1. Open [Graph Explorer](https://developer.microsoft.com/graph/graph-explorer), sign in, and verify
   that its directory matches `tenantId` in the deployment summary.
2. Activate the **Authentication Policy Administrator** role and select **beta**.
3. Select **GET** and enter the URL for the channel:

   | Channel | URL |
   | --- | --- |
   | SMS | `https://graph.microsoft.com/beta/policies/authenticationMethodsPolicy/authenticationMethodConfigurations/sms` |
   | Voice | `https://graph.microsoft.com/beta/policies/authenticationMethodsPolicy/authenticationMethodConfigurations/voice` |

4. In **Modify permissions**, consent to `Policy.ReadWrite.AuthenticationMethod` for this change.
   If it is not listed, use the profile menu's **Consent to permissions** option.
5. Run the query. Save the `200 OK` policy response in restricted storage with the tenant,
   channel, UTC time, and change owner.
6. Record existing provider settings, method state, targeting, and channel-specific properties.
   Agree on a pilot scope, observation window, and rollback trigger.

Use `Policy.Read.AuthenticationMethod` for a separate read-only policy inspection.
The write permission above is needed when performing the update.

### Configure evaluation in Graph Explorer

1. Run GET again immediately before the change. Stop and review if another administrator has
   changed the saved policy.
2. Change the method to **PATCH**, keeping the same channel URL.
3. In **Request body**, enter the JSON below for SMS. Replace `url` with the summary's `endpointUrl` and `appId`
   with its **application client ID**.

   ```json
   {
     "@odata.type": "#microsoft.graph.smsAuthenticationMethodConfiguration",
     "telecomProviderSettings": {
       "url": "https://<function-host>/api/SendOtp",
       "appId": "<application-client-id>",
       "isEvaluationModeEnabled": true,
       "migrationPercentage": 1
     }
   }
   ```

4. For voice, use the voice URL and change `@odata.type` to
   `#microsoft.graph.voiceAuthenticationMethodConfiguration`.
5. Review the endpoint, client ID, evaluation flag, and percentage. `1` is an illustrative
   starting percentage; use the value agreed for your evaluation.
   Keep the existing method state, targeting, and unrelated properties unchanged.
6. Confirm **Request headers** includes `Content-Type: application/json`.
7. Run PATCH and expect **`204 No Content`**. Switch back to GET and compare the returned settings
   with the intended change and saved policy.
8. Run the authorized evaluation procedure for the channel and check the matching Function logs
   before continuing.

| Provider setting | Value to use |
| --- | --- |
| `url` | Public SendOtp URL, or the validated Front Door SendOtp URL for a multi-region deployment |
| `appId` | Endpoint application client ID from the deployment summary |
| `isEvaluationModeEnabled` | `true` for non-delivering evaluation; `false` for live routing |
| `migrationPercentage` | Integer from `0` through `100`, selected for the rollout stage |

Include all four provider settings when updating the integration, and preserve the other policy
properties. Repeat the procedure independently for SMS and voice if both channels are required.

### Evaluation and percentage rollout

Evaluation checks authenticated routing and decryption without sending through the provider.
Run controlled live tests to verify provider access and recipient delivery.

After evaluation and separately controlled live tests pass, PATCH the full provider settings
with `isEvaluationModeEnabled: false` and the agreed initial `migrationPercentage`.
Read back the result before increasing traffic.

| Stage | Action | Evidence before continuing |
| --- | --- | --- |
| Evaluation | Enable evaluation for each intended channel | Matching nonce, correlated evaluation events, and expected routing |
| Controlled live test | Verify provider authorization and a controlled SMS or voice send | Provider acceptance and separately confirmed recipient delivery |
| Initial live percentage | Start at the agreed percentage and pilot scope | Policy readback, healthy latency/errors, provider outcomes, and no rollback trigger |
| Increase | Change one rollout setting at a time and observe it for the agreed window | Representative traffic remains within the thresholds |
| Complete | Move to the approved final percentage | All intended channels pass, with operational owners and rollback ready |

Record the percentage, channel, UTC time, observation window, and owner at each stage.
Stop the rollout if a threshold is exceeded. A percentage controls routing; verify the observed
traffic rather than assuming an exact count or a stable set of users. See
[migration and evaluation](https://learn.microsoft.com/entra/identity/authentication/phone-providers-faq#migration-and-evaluation).

## Rollback and decommissioning

1. Restore the reviewed previous policy through the supported configuration procedure.
   Read it back and validate the restored authentication route. Keep the previous endpoint
   available until traffic has moved.
2. For a package rollback, use the retained source, package, and settings. Coordinate certificate
   continuity and repeat endpoint validation.
3. After traffic has moved and retention requirements are met, retire the dedicated Azure
   resources and separately review application registrations, federation, provider accounts,
   and monitoring.

Azure resource deletion does not undo policy or directory changes. Shared Microsoft service
principals and grants need an impact review before removal. Respect Key Vault protection and
retention, and confirm the remaining Azure and provider charges.

For a Graph-based rollback, build a PATCH from the saved prior provider settings and the correct
channel `@odata.type`; do not submit the whole GET response as an update. Read back the policy
and verify the restored route. To pause routing to the integration, set `migrationPercentage`
to `0` in the reviewed provider-settings object and validate the resulting authentication behavior.

Before removing Azure resources, have the Azure owner confirm the exact subscription, resource
group, dependencies, and retention requirements. Review app registrations, enterprise applications,
federated credentials, app-role grants, provider subscriptions, and alert rules separately.

## Offline setup checks

From the repository root, compile Bicep and run the setup suites:

```powershell
$templatePath = Join-Path ([IO.Path]::GetTempPath()) "epp-main-$([Guid]::NewGuid().ToString('N')).json"
az bicep build --file .\setup\infra\main.bicep --outfile $templatePath
if ($LASTEXITCODE -ne 0) { throw 'Bicep compilation failed.' }

$tests = @(
    'Launcher.Tests.ps1',
    'Accounts.Tests.ps1',
    'Graph.Tests.ps1',
    'ProviderConfiguration.Tests.ps1',
    'Selections.Tests.ps1',
    'Applications.Tests.ps1',
    'Progress.Tests.ps1',
    'Packages.Tests.ps1',
    'Certificates.Tests.ps1',
    'Providers.Tests.ps1'
)
foreach ($test in $tests) {
    pwsh -NoProfile -File (Join-Path '.\setup\tests' $test)
    if ($LASTEXITCODE -ne 0) { throw "$test failed." }
}

pwsh -NoProfile -File .\setup\tests\ServicePlans.Tests.ps1 -TemplatePath $templatePath
if ($LASTEXITCODE -ne 0) { throw 'ServicePlans.Tests.ps1 failed.' }
Remove-Item -LiteralPath $templatePath
```

CI runs the same eleven suites on Windows and Linux. Network and cloud operations are mocked;
deployed endpoint validation is separate.
