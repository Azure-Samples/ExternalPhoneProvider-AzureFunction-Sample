# EPP endpoint setup

**Only Step 2 is scripted.** Register the customer application manually, run one downloaded
PowerShell script to deploy the endpoint, and activate policy manually after validation.

The customer does not clone this repository or download Bicep/support scripts separately.
`Setup-Epp.ps1` retrieves those files and the selected provider's JSON from GitHub.

Start at the [customer checklist](../../README.md) and complete the
[access/eligibility gate and values worksheet](../../docs/ONBOARDING.md#before-purchasing-or-deploying)
first. Provider purchase is through [Microsoft Security Store](https://securitystore.microsoft.com/private-solutions);
purchase alone does not enable the Microsoft tenant feature or authorize the provider API.

This guide deploys **one Function endpoint in one Azure region**. It does not provision Azure
Front Door or a second region. For the optional multi-region design, use the
[manual Front Door onboarding guide](../../docs/FRONTDOOR.md). No Front Door setup script is
provided. Running this setup again in another region won't coordinate encryption keys or
Front Door origins. A successful deployment or evaluation doesn't prove live delivery or seamless failover.

## Availability

Choose **SMS or voice**, a **Global or EU provider route** (the prompt calls it **Tenant scope**),
**Telesign or Soprano**, and an
Azure Function **platform**: Node.js, .NET, or Python, plus a **service plan**: Flex Consumption FC1
or Premium EP1. By default, setup resolves the source repository's latest stable
`epp-packages-*` release produced by CI. A public fork's test branch can use its matching fork release.
There is no package URL or checksum to enter. Setup verifies `SHA256SUMS.txt` automatically and
performs the required build and publication for the selected language.

Provider profiles contain complete channel/region route objects. Telesign contains its supplied
route URLs, tenant, authentication, and timings. Soprano contains its provider tenant, Global/EU
routes, API application ID, scope, authentication, and timings. The provider files contain the
complete deployment contract.

The current profiles use identical Global/EU URLs, and Soprano uses the same app ID/scope.
This label is not proof of data residency or a choice of Azure region; confirm processing/routing
with the provider. Infobip/Sinch are bundled adapters but have no guided deployment profiles.

To test unpublished upstream changes, publish them to a public fork with a matching stable package
release, then use `-SourceRepository <owner/repository>` and
`-SourceRef <branch-or-full-commit-sha>`. Both options must identify the same source as the downloaded
launcher. Use `-PackageReleaseTag` if the fork contains more than one stable package release.
Unpublished worktree changes are not downloadable from GitHub.

## Service plan selection

Setup offers these two Linux hosting plans, with the same cache app settings for every language:

| Option | Hosting | `EPP_KEY_VAULT_CACHE_ENABLED` | `EPP_ACCESS_TOKEN_CACHE_ENABLED` |
|---|---|---|---|
| 1. Flex Consumption (FC1) | On-demand with a free usage grant; zero always-ready instances, 2048 MB, up to 40 on-demand instances | `"false"` | `"false"` |
| 2. Premium (EP1) | Existing Premium configuration with one warm instance | `"true"` | `"true"` |

**FC1 is not an always-free deployment.** Its on-demand compute has a
[free usage grant](https://learn.microsoft.com/azure/azure-functions/flex-consumption-plan#billing);
usage beyond the grant, Key Vault, storage, telemetry, and provider services can incur charges.
FC1 can scale to zero and cold-start; these settings do not remove cold-start latency or force a
new worker on every invocation.

EP1 allocates paid warm capacity even without OTP traffic. Set an Azure Cost Management budget
and notify the resource owner; a budget notification does not stop spending. Include storage,
Key Vault, telemetry ingestion/retention, and the provider's charges, not just Function executions.
Stopping a Function does not necessarily stop its plan or supporting-service charges.

**Cache settings require runtime support.** Setup only writes the two app settings above; they do
not change caching in a Function package that does not read them. Runtime cache-reader changes are
separate and must be released and deployed before these settings take effect. Rerunning setup
restores the selected plan's values. The decryption-key Key Vault reference remains platform-managed.

Use `-ServicePlan FC1` or `-ServicePlan EP1` to skip the prompt. Unattended setup requires this
parameter; it never silently chooses a paid plan. The approval and deployment summary include
the selected plan and both cache settings.

**Use a different resource prefix to change plans.** In-place FC1/EP1 migration is not supported.
Preflight rejects a mismatch with the existing resource-group tag or actual hosting-plan SKU,
including older EP1 deployments without the new tag. Existing EP1 deployments can be rerun with
`-ServicePlan EP1`.
For an active endpoint, onboard a new dedicated Step 1 application as well, or coordinate an
encryption-key continuity migration with its owner. A new prefix creates a new vault and encryption
key; it does not bypass the existing application's certificate-continuity checks. Setup does not
automatically migrate keys or activate the replacement endpoint.

## Step 1 - manually create the application

Use a dedicated nonproduction tenant/subscription for the first deployment.

1. In the customer tenant's **Microsoft Entra admin center > App registrations**, register a
   dedicated application with **Accounts in this organizational directory only** as its initial
   supported account type; setup changes it to organizational multi-tenant after approval.
   No redirect URI, client secret, API permission, app role,
   or enterprise-application configuration is required manually.
2. Record the **Directory (tenant) ID** and **Application (client) ID**. The script requires the
   client ID, not the application's object ID, and will not create a replacement registration.
3. Complete provider purchase and account/sender registration, and arrange API onboarding for the selected adapter.
   Telesign uses `telesign-api-key` and `telesign-customer-id` in Key Vault. Soprano uses OAuth
   client-assertion exchange with the selected provider tenant/scope/application ID. Setup does not
   grant provider API consent or application roles. Finish the
   [provider authentication handoff](../../docs/ONBOARDING.md#complete-provider-authentication)
   after setup creates the vault and identity identifiers needed for those steps.

After the single Step 2 approval, PowerShell makes the dedicated app organizational multi-tenant,
restricts it through the Entra allowed-tenants preview to its home tenant plus the selected provider
tenant from the provider JSON,
adds the `Epp.Invoke` application permission, creates/reuses its enterprise application, requires
assignment, creates/reuses the Microsoft phone-provider service principal, and assigns `Epp.Invoke`.
It also grants that Microsoft service principal tenant-wide Microsoft Graph `Application.Read.All`,
adds the hostname-based identifier URI and public JWE encryption certificate, and configures Easy
Auth to allow only the Microsoft phone-provider application. Soprano additionally creates the
disclosed outbound managed-identity federated credential.

## Prerequisites for Step 2

- **Windows with PowerShell 7+** is the supported customer deployment environment. Certificate
  issuance now happens inside Key Vault, without Windows certificate cmdlets or the local certificate
  store. End-to-end deployment from Linux or Azure Cloud Shell has not been validated.
- Azure CLI **2.60.0+ for FC1** or **2.48.1+ for EP1** on `PATH`, with access to GitHub, Azure, Microsoft Graph, and Key Vault.
  Setup installs the Azure CLI Bicep component after confirmation when it is missing. Azure CLI itself
  must be installed before running the script. FC1 publication and EP1 Python builds also need
  network access to SCM.
- Microsoft Graph PowerShell modules `Microsoft.Graph.Authentication` and
  `Microsoft.Graph.Applications`. Setup installs missing 2.x+ modules from PSGallery for CurrentUser
  after a separate confirmation.
- An Azure **user** account permitted to deploy at subscription scope, create the listed resources,
  and create the scoped Azure role assignments. Bicep grants the operator **Key Vault Certificates
  Officer** for issuance and **Key Vault Secrets Officer** for provider credentials,
  scoped to this deployment's vault.
- A Microsoft Entra **Privileged Role Administrator** for granting the Microsoft first-party service
  principal Graph `Application.Read.All`, plus delegated Graph scopes `User.Read`,
  `Application.ReadWrite.All`, `Application.Read.All`, and `AppRoleAssignment.ReadWrite.All`.
  `User.Read` is for the setup operator's `/me` lookup; it is not granted to the first-party service
  principal or the endpoint app.
- Microsoft Graph **beta** access for the Entra `signInAudienceRestrictions` allowed-tenants preview.
  The selected provider tenant is allowed in addition to the app's home tenant, which Entra always allows.
- The selected **Linux Flex Consumption FC1 or Premium EP1** plan available in the chosen region,
  with sufficient subscription quota. Availability is checked for that plan only; regional service
  availability and resource-provider registration do not guarantee quota. If deployment reports
  `SubscriptionIsOverQuotaForSku`, resolve the
  [regional quota issue](Troubleshooting.md#deployment-fails-with-subscriptionisoverquotaforsku)
  before retrying. Setup registers missing required Azure
  resource providers automatically after the single approval. The Azure account needs the
  providers' subscription-scoped `/register/action` permission (included in Contributor/Owner).
- **.NET selection only:** install the .NET 8 SDK and allow NuGet access. Setup runs `dotnet publish`
  automatically for `linux-x64`, packages the publish output, and deploys it. No manual build step
  or upload is required. JavaScript and Python do not require this SDK.
- **Python selection:** Azure performs the Linux dependency build. No local Python, pip, or Windows
  dependency installation is needed. The source archive is never used directly as run-from-package.

### Permissions are separate

For an Azure built-in-role example, **Owner at the selected subscription** includes deployment,
resource-provider registration, and role-assignment rights. **Contributor alone is insufficient**
for `Microsoft.Authorization/roleAssignments/write`; Contributor plus **Role Based Access Control
Administrator** at the required scope is another administrator-reviewed option, subject to any
role-assignment conditions. Setup deploys at subscription scope and creates a new resource group;
a role on an unrelated existing group is not sufficient. Request only approved scope/duration
and activate eligible PIM roles before setup. See [Azure roles](https://learn.microsoft.com/azure/role-based-access-control/built-in-roles).

Azure roles do not grant Entra/Graph permissions, and Entra roles do not grant Azure/vault access.
The Entra Privileged Role Administrator and delegated Graph scopes above are for setup.
The later Authentication Policy Administrator and policy permissions are a **separate activation**
step. Setup grants vault data roles to its Azure operator and Function identity; it does not
automatically grant them to every member of your operations team.

### Install and check workstation tools

Use the official [PowerShell installation](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows),
[Azure CLI installation](https://learn.microsoft.com/cli/azure/install-azure-cli-windows), and
[.NET 8 SDK download](https://dotnet.microsoft.com/download/dotnet/8.0) instructions (SDK only for C#).
Open a new **PowerShell 7** window after installation, then check:

```powershell
$PSVersionTable.PSVersion
az version
Get-Module -ListAvailable Microsoft.Graph.Authentication, Microsoft.Graph.Applications |
    Select-Object Name, Version
# Only when choosing dotnet:
dotnet --list-sdks
```

Missing Graph modules or Bicep can be installed by interactive setup after confirmation.
These version checks do not establish Azure permissions, quota, feature availability, or provider access.

| Choice | Azure runtime | Automatic deployment path |
|---|---|---|
| JavaScript | Node.js 22, Functions v4 | Verify and publish the ready ZIP with its production dependencies |
| .NET | .NET 8 isolated, Functions v4 | Verify source ZIP, publish for Linux with .NET 8, repackage and publish |
| Python | Python 3.11, Functions v4 | Verify source ZIP; One Deploy with remote build on FC1, or validate/download and publish the SCM-built output on EP1 |

Package hashes are still checked; removing the **customer prompt** does not disable integrity
verification. Source and deployed-package hashes are recorded separately when a build changes the bytes.
For FC1 Python, One Deploy builds and stores the output inside Azure; the summary records the
verified source hash and leaves `packageSha256` null rather than reporting it as the built-output hash.

Setup normally detects these automatically. For noninteractive execution, preinstall prerequisites
or explicitly allow missing Graph/Bicep installation with `-InstallPrerequisites`; see the
[complete example](#noninteractive-example).

Install Azure CLI through its official installation instructions if necessary. Setup checks the
explicitly supplied subscription and tenant without changing the CLI's selected subscription. If no
matching Azure user session exists, it runs `az login --tenant <tenant-id>`. It separately requests
Graph sign-in before displaying the plan if the delegated session is missing required scopes,
including `User.Read` for operator identity readback. The
consent includes broad app-role-management scopes because the approved deployment grants
`Application.Read.All` to the Microsoft phone-provider service principal. Authentication, module
installation, Bicep installation, MFA, and consent prompts are not resource-creation approvals.

Use `-ForceAuthentication` when the machine has ambiguous cached identities. It requires interactive
device-code authentication for Azure CLI and Microsoft Graph, does not clear shared token caches,
and cannot be combined with `-NonInteractive`. Azure RBAC always uses the selected ARM token's
validated `oid`; Graph `/me` is tracked separately for application-management operations.

## Step 2 - download and run one script

Download and inspect [Setup-Epp.ps1](../Setup-Epp.ps1), or save it from the upstream raw URL:

```powershell
Invoke-WebRequest `
    -Uri 'https://raw.githubusercontent.com/Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample/main/setup/Setup-Epp.ps1' `
    -OutFile .\Setup-Epp.ps1
.\Setup-Epp.ps1
```

Force explicit account selection when testing on a shared or multi-account computer:

```powershell
.\Setup-Epp.ps1 -ForceAuthentication
```

The flow is:

1. **Collect missing customer inputs:** tenant, subscription, existing application client ID, Azure
   region, and resource prefix. Supplied values are reused without prompts. Credentials are never
   requested as ordinary string parameters.
2. **Choose SMS or voice**, then the **Global or EU provider route** (shown as **Tenant scope**).
3. **Choose a provider**, then an Azure Function **platform**: Node.js, .NET, or Python. Setup downloads the provider JSON,
   resolves one complete route containing endpoint, authentication, app-ID/scope
   when applicable, timeout, and retry interval. Explicit test values are allowed, shown as test
   configuration, and passed to Azure settings. It also resolves the latest stable CI package
   release and looks up the language asset name in `packages/catalog.json`; there are no
   `PackageUrl` or `PackageSha256` inputs. Use
   `-PackageReleaseTag epp-packages-<run>-<attempt>` to pin a previous CI release. Malformed or
   disabled profiles still fail before resource creation.
4. **Service plan selection:** choose **Flex Consumption FC1** (free usage grant, zero always-ready
   instances, both cache settings `"false"`) or **Premium EP1** (warm instance, both cache settings `"true"`).
   Supply `-ServicePlan FC1` or `-ServicePlan EP1` to reuse a known selection.
5. **Enter a resource prefix**, such as `contoso`. All resources created by the script start with
   this prefix. Use 2-8 lowercase letters or digits, starting with a letter. Every top-level
   resource name then adds the meaningful `epp` marker, for example
   `contoso-epp-rg-<suffix>`. A deterministic suffix derived from the
   subscription, application ID, and prefix reduces global-name collisions. Reruns use the same names.
6. **Check prerequisites and sign in.** Missing Graph modules or Bicep can be installed after a
   separate confirmation. Azure and Graph interactive sign-in starts only when the supplied tenant
   and subscription do not already have suitable user contexts.
7. **Review the complete plan**, including resource names, tenant/subscription, language, service plan,
   both cache settings, automatic package verification/build, provider
   settings, scoped roles, certificate creation, and application configuration. Bicep receives these
   exact names; it does not independently calculate a different naming scheme.
   The plan also lists the six required **Azure resource providers** and their registration states.
   This is separate from the Telesign/Soprano provider selection.
8. **Type `Yes` once to deploy.** `No` or Enter cancels without Azure changes. Invalid answers prompt
   again; individual resources do not request additional approvals.

After approval, setup rechecks the selected subscription and registers only missing
`Microsoft.Web`, `Microsoft.Storage`, `Microsoft.KeyVault`, `Microsoft.OperationalInsights`,
`Microsoft.Insights`, and `Microsoft.ManagedIdentity` providers. Already registered providers are
left alone; existing registrations in progress are reused. Registration and regional checks happen
before certificate creation or Bicep deployment. The read-only preflight does not register anything.

Azure registers providers region by region. Setup does not unnecessarily wait for a global
`Registered` state when a provider is already `Registering` and exposes the requested region.
Registration metadata is polled with a bounded limit, and recognized regional registration
propagation errors are retried during capability checks/deployment. Permission failures and
unsupported regions remain explicit errors. Registration is subscription-wide and isn't undone
automatically if a later deployment step fails.

Supply known values to shorten the prompts:

```powershell
.\Setup-Epp.ps1 `
    -TenantId '<customer-tenant-id>' `
    -SubscriptionId '<subscription-id>' `
    -ApplicationId '<existing-client-id>' `
    -Location westus2 `
    -Language javascript `
    -ServicePlan FC1 `
    -Provider telesign `
    -Channel sms `
    -EndpointRegion global `
    -ResourcePrefix contoso
```

Replace the ID placeholders with quoted GUID strings before execution. For an independent
second channel/provider deployment, use a different prefix **and a dedicated app**.
The suffix does not include channel/provider/region, so changing those inputs with the same
subscription/app/prefix can reconfigure the existing endpoint. See
[deployment separation and key constraints](../../docs/ONBOARDING.md#inputs-you-supply-to-setup).

The plan creates or updates a dedicated resource group, selected Linux FC1 or EP1 hosting plan, Function App,
storage account/private package container, Key Vault, Log Analytics workspace, Application Insights,
outbound managed identity, diagnostics, Easy Auth, and scoped role assignments. Storage/package
access uses managed identity, not account keys or SAS. Telemetry uses the system identity; the
outbound identity is selected explicitly, not through a global `AZURE_CLIENT_ID`.

The Function starts with public ingress disabled. After Bicep creates the vault and permissions,
setup asks Key Vault to issue or reuse `phone-provider-encryption`, a self-signed, exportable RSA-2048
certificate. Its subject and Entra certificate display name are both **`CN=ExternalPhoneProvider`**,
without an application ID, resource prefix, or thumbprint in the name. Setup registers the public
certificate in Entra with `Usage=Encrypt` and pins `EPP_DECRYPTION_KEY_PEM` to its **versioned PEM
backing secret**. It **reads back and verifies Easy Auth before enabling ingress**.
SCM basic authentication stays disabled for both plans. FC1 uses Entra-authenticated **One Deploy**
for every language, with remote build for Python. Its `functionAppConfig` defines runtime, scaling,
and managed-identity deployment storage; setup does not write Premium-only runtime/build or
`WEBSITE_RUN_FROM_PACKAGE` settings. One Deploy handles publication and trigger synchronization.
EP1 Python uses the Entra-authenticated SCM remote build: setup validates the built Python payload,
stores it in private Blob storage, and switches to managed-identity run-from-package.
It never mounts the unbuilt Python source ZIP. EP1 then restarts and synchronizes triggers.
Both plans verify that `SendOtp` is registered before reporting success.
On publication/startup failure it disables public ingress again; failure to close ingress is reported
explicitly rather than hidden.
App-setting changes refresh Key Vault references through App Service. Setup does not separately poll
secret-resolution status; the required deployed evaluation request verifies decryption before policy activation.

The public certificate and a timestamped identifier
summary are saved to `epp-output` beside the downloaded script, or to `-OutputDirectory`.
The summary includes certificate/secret version identifiers, thumbprint, expiry, and manual renewal
mode. Its service-plan and cache fields record configured settings, not verified runtime cache behavior.
Setup never downloads, writes, or imports the private key locally: only the Function receives
it through its managed-identity Key Vault reference. Certificate creation automatically supplies the
backing secret; setup no longer writes a separate `phone-provider-decryption-key` secret.

For unattended runs, supply every input including `-ServicePlan FC1` or `-ServicePlan EP1`,
authenticate both clients first, and explicitly authorize
the whole displayed plan with **both** `-NonInteractive -ApproveDeployment`. `-NonInteractive`
alone never approves changes. There is no `-Stage`, `-Resume`, `-ConfigPath`, or policy-approval switch.

### Noninteractive example

This is a fully specified Telesign/SMS/Global JavaScript deployment example, not a credential
script. Replace the three IDs and choose a permitted region/prefix/plan before running.
The preliminary user sign-ins can require MFA and consent; `-NonInteractive` does not create a
headless service-principal deployment path. Install the Graph modules/Bicep beforehand using
interactive setup's prerequisite prompts or your approved installation process.

```powershell
$tenantId = '<customer-tenant-guid>'
$subscriptionId = '<subscription-guid>'
$applicationId = '<dedicated-app-client-guid>'

az login --tenant $tenantId
if ($LASTEXITCODE -ne 0) { throw 'Azure sign-in failed.' }
Connect-MgGraph -TenantId $tenantId -ContextScope Process `
    -Scopes 'User.Read', 'Application.ReadWrite.All', 'Application.Read.All', 'AppRoleAssignment.ReadWrite.All'

.\Setup-Epp.ps1 `
    -TenantId $tenantId `
    -SubscriptionId $subscriptionId `
    -ApplicationId $applicationId `
    -Location westus2 `
    -Provider telesign `
    -Channel sms `
    -EndpointRegion global `
    -Language javascript `
    -ServicePlan FC1 `
    -ResourcePrefix contoso `
    -OutputDirectory .\epp-output `
    -NonInteractive `
    -ApproveDeployment
```

Use `-InstallPrerequisites` only when authorizing automatic missing-dependency installation.
Use the [source/version options](#source-versioning) to pin repeatable deployments.
Review the corresponding interactive plan first; `-ApproveDeployment` authorizes the complete
mutation set, not just package upload. Do not use it as a dry run.

### Read the deployment summary

Open the timestamped JSON under `epp-output` in a private editor. It contains identifiers and
configuration metadata, not provider credentials or private-key bytes. Keep it access-controlled.

| Summary field | How to use it |
|---|---|
| `tenantId`, `subscriptionId`, `applicationId` | Verify the intended customer directory, Azure subscription, and endpoint **client ID**. |
| `resources.functionApp`, `resources.keyVault`, `resources.applicationInsights`, `resources.logAnalytics` | Find the exact Azure resources; do not guess names or use a different environment's vault. |
| `provider`, `channel`, `endpointRegion`, `providerTenantId` | Confirm provider routing, separate from the customer's directory and Azure location. |
| `endpointUrl`, `identifierUri` | Exact SendOtp URL and registered app audience information for the authorized test/policy operator. |
| `encryptionKeyId`, `certificateThumbprint`, `certificateId`, `certificateSecretId`, `certificateExpiresUtc` | Public-key identification and version/renewal inventory. A secret **ID** is not its value; do not fetch its private-key contents. |
| `endpointServicePrincipalId`, `microsoftPhoneProviderServicePrincipalId` | Tenant-local enterprise-application Object IDs; neither is the endpoint app client ID. |
| `source`, `packageUrl`, `sourcePackageSha256`, `packageSha256`, `language`, `servicePlan` | Source/package provenance and runtime/plan. FC1 Python's built hash can be null; source and built hashes describe different artifacts. |
| `policyChanged` | Expected `false`: deployment has not activated policy. |

For example, a healthy record can contain `"provider": "telesign"`, `"channel": "sms"`,
`"endpointRegion": "global"`, `"certificateRenewal": "manual"`, and `"policyChanged": false`.
Those fields do not prove credentials, delivery, or monitoring work. Follow
[provider authentication](../../docs/ONBOARDING.md#complete-provider-authentication) next,
**even if the script's completion text does not prompt for your provider**.

### Encryption certificate lifecycle

The issuance policy uses **12-month validity, key reuse, and manual renewal**. It specifies
`EmailContacts` 30 days before expiry, **not `AutoRenew`**. Email is sent only if the customer
separately configures Key Vault certificate contacts; setup does not create contacts or guarantee
notifications. Track the saved expiry and arrange renewal before the certificate expires.

In **Key Vault > Certificates > Certificate contacts**, add the approved operations/renewal
contact and verify the address and ownership. Portal labels can vary; follow
[certificate renewal and contacts](https://learn.microsoft.com/azure/key-vault/certificates/overview-renew-certificate).
Record `certificateExpiresUtc` in your inventory and create an independent scheduled reminder
before the 30-day window, with an escalation owner. EmailContacts is not an Azure Monitor alert
rule, and setup does not test email delivery. Monitor both the vault certificate's and Entra
credential's expiration; renewing one does not renew the other automatically.

Reruns reuse a valid matching cloud certificate. Only a certificate-not-found response triggers
`az keyvault certificate create`; Azure CLI waits for self-signed issuance. Other errors, including
pending-operation conflicts, stop setup rather than starting a custom recovery workflow. Disabled,
incompatible, or near-expiry certificates also stop setup. Keep more than 30 days of validity remaining.
Certificates issued with an earlier per-application subject require a coordinated manual reissuance
with `CN=ExternalPhoneProvider`, retaining the same RSA key. Renaming the Entra display name alone
does not change the signed certificate's subject.

For a planned renewal, coordinate with the EPP owner, create a new version in Key Vault using the same
policy with **reuse key enabled**, then rerun setup before the old certificate expires. Setup verifies
that the RSA public key still matches every registered encryption credential, pins the Function to the
new secret version, and adds the renewed public certificate to Entra while preserving existing
credentials. It does not automatically remove old versions or Entra credentials. Validate evaluation
requests before an administrator retires old credentials through the supported EPP procedure.

Key Vault renewal alone does **not** update the uploaded Entra certificate or its expiration.
Version-pinning deliberately prevents an unattended secret switch. Do not enable `AutoRenew` or
generate a different RSA key without implementing coordinated Entra updates and overlapping
decryption-key support. The Function still decrypts in-process with a single private key.

**Existing local-certificate deployments are not automatically migrated.** Coordinate migration with
the EPP owner before running this setup on an active endpoint. After infrastructure deployment,
setup refuses to update Entra or the Function's encryption settings if the public key differs from
an existing encryption credential. This is not a pre-deployment migration check: resources may already
be updated and ingress disabled when it stops. Do not delete encryption credentials to bypass it.

### Source versioning

`-SourceRepository` defaults to `Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample`.
The small entry point resolves `-SourceRef` (default `main`) to a single commit in that repository. All supporting
PowerShell, Bicep, the catalog, and the selected provider profile are downloaded from that commit.
The package catalog supplies asset names, while setup resolves the latest stable `epp-packages-*`
release from the same repository and verifies the selected asset against that release's
`SHA256SUMS.txt`. The plan and saved summary record the concrete versioned URL and hashes.
For a fully repeatable deployment, use both a reviewed full commit SHA and
`-PackageReleaseTag epp-packages-<run>-<attempt>`. Provider JSON selects data only; it cannot
redirect execution to another script. Download failures stop setup, and temporary downloads are
removed on completion or failure. Select only a repository whose code you trust: its supporting
PowerShell is executed locally.

### Offline setup checks

From the repository root, run the certificate regression suite, compile the infrastructure, and
check both service plans without Azure sign-in or resource changes:

```powershell
pwsh -NoProfile -File .\setup\tests\Certificates.Tests.ps1
az bicep build --file .\setup\infra\main.bicep --outfile "$env:TEMP\epp-main.json"
pwsh -NoProfile -File .\setup\tests\ServicePlans.Tests.ps1 -TemplatePath "$env:TEMP\epp-main.json"
```

The focused tests replace certificate/Graph calls and verify creation, reuse, errors, naming, key
mismatch, and versioned settings. The service-plan suite checks selections, approval details, regional
checks, CLI requirements, migration guards, parameter forwarding, and plan-specific publication
with mocked Azure calls. CI runs both on Windows and Linux. They do not certify live deployments,
RBAC propagation, Key Vault issuance, Entra behavior, or provider delivery.

## Step 3 - manually validate and activate policy

First complete [provider authentication and the deployed acceptance checks](../../docs/ONBOARDING.md#complete-provider-authentication).
The customer onboarding owner must arrange an authorized Microsoft EPP caller; this repository's
offline tests and an ordinary Azure CLI token do not supply that caller.

**Activation is an assisted, product-specific gate, not an executable public Graph recipe.**
The public beta [SMS](https://learn.microsoft.com/en-us/graph/api/resources/smsauthenticationmethodconfiguration?view=graph-rest-beta)
and [Voice](https://learn.microsoft.com/en-us/graph/api/resources/voiceauthenticationmethodconfiguration?view=graph-rest-beta)
resource definitions do **not** document EPP `url` and `appId` fields. The general method
configuration APIs alone do not establish EPP feature availability or an EPP update contract.
Do not invent a PATCH payload, assume a Graph success means activation, or use the general
Delete operation as an EPP rollback.

Before a policy change, the **Authentication Policy Administrator** must obtain Microsoft's
current approved EPP procedure for the selected tenant/channel: tool, API/version and exact
field placement, required consent/roles, readback, validation, and rollback semantics.
Delegated `Policy.ReadWrite.AuthenticationMethod` is a policy-management permission, not proof
of EPP entitlement; confirm the approved procedure's permission requirements separately from setup.
If this information or the feature is unavailable, leave policy unchanged and record the blocker.

Once that procedure is available:

1. Save the existing selected-channel configuration, including EPP settings if present, target
   groups, state, and other properties, with the tenant ID, UTC time, and change owner. Protect
   the snapshot as tenant configuration. Agree on a maintenance window and rollback trigger.
2. Re-read immediately before changing; stop if another administrator changed the policy.
   Use conditional updates only where the approved endpoint documents their support.
3. Apply only the reviewed EPP changes using `endpointUrl` and `applicationId` from the saved
   deployment summary in the **approved field locations**. Preserve other policy properties
   and group targeting. Setup's endpoint Service Principal Object ID is not `applicationId`.
4. Read back and compare both changed values and preserved settings. Have the authorized
   operator verify the selected channel through an actual controlled Entra flow; record
   acceptance and separate recipient delivery, not secrets or OTPs.
5. If validation fails, execute the agreed rollback below. Do not leave a broken channel
   activated while deleting its resources or changing authentication to debug it.

### Rollback and decommissioning

Policy rollback, package/configuration rollback, and resource deletion are different operations.
Setup does none of them automatically.

1. The policy administrator restores only the reviewed prior EPP configuration through the
   approved procedure (or its documented removal operation if there was no prior EPP endpoint).
   Preserve unrelated settings, read back, and validate the restored authentication route.
   Keep the old endpoint available until traffic has safely moved.
2. For an endpoint release rollback, use the retained package/source version and reviewed
   settings. Do not blindly rerun setup on an active app: it can mutate Entra, reset settings,
   and disable ingress. Coordinate certificate/key continuity; never delete credentials to
   bypass a mismatch. Repeat the authorized evaluation and live checks.
3. Only after policy/traffic and rollback retention are confirmed, have the Azure owner inventory
   and retire the dedicated resource group and any separately created monitors/Front Door resources.
   Confirm exact subscription/resource IDs and dependencies before deletion. Respect vault
   soft-delete/purge protection and approved log/certificate retention; do not purge for a rerun.
4. Have the Entra/provider administrators separately review app registrations, enterprise
   applications, app-role assignments/consents, federated credentials, and provider subscriptions.
   Azure resource deletion does not remove these. The Microsoft phone-provider service principal
   and its Graph grant may be shared with other endpoints: do not delete/revoke shared objects
   without an impact review.
5. Confirm billing and provider subscription status, retain required audit evidence, and close
   alerts only after decommissioning. Stopping a Function or removing policy alone is not teardown.