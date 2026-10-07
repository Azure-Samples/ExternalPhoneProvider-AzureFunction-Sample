# EPP endpoint setup

**Only Step 2 is scripted.** Register the customer application manually, run one downloaded
PowerShell script to deploy the endpoint, and activate policy manually after validation.

The customer does not clone this repository or download Bicep/support scripts separately.
`Setup-Epp.ps1` retrieves those files and the selected provider's JSON from GitHub.

This guide deploys **one Function endpoint in one Azure region**. It does not provision Azure
Front Door or a second region. For the optional multi-region design, use the
[Front Door onboarding guide](../../docs/FRONTDOOR.md), which includes a separate JavaScript/EP1
expansion script. Running this single-region setup again in another region won't coordinate encryption keys or
Front Door origins. A successful deployment or evaluation doesn't prove live delivery or seamless failover.

## Availability

Choose **SMS or voice**, a **Global or EU tenant scope**, **Telesign or Soprano**, and an
Azure Function **platform**: Node.js, .NET, or Python, plus a **service plan**: Flex Consumption FC1
or Premium EP1. By default, setup resolves the source repository's latest stable
`epp-packages-*` release produced by CI. A private test branch can use its matching fork release.
There is no package URL or checksum to enter. Setup verifies `SHA256SUMS.txt` automatically and
performs the required build and publication for the selected language.

Provider profiles contain complete channel/region route objects. Telesign contains its supplied
route URLs, tenant, authentication, and timings. Soprano contains its provider tenant, Global/EU
routes, API application ID, scope, authentication, and timings. The provider files contain the
complete deployment contract.

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
   dedicated organizational application. No redirect URI, client secret, API permission, app role,
   or enterprise-application configuration is required manually.
2. Record the **Directory (tenant) ID** and **Application (client) ID**. The script requires the
   client ID, not the application's object ID, and will not create a replacement registration.
3. Complete provider purchase, account/sender registration, and onboarding for the selected adapter.
   Telesign uses `telesign-api-key` and `telesign-customer-id` in Key Vault. Soprano uses OAuth
   client-assertion exchange with the selected provider tenant/scope/application ID. Setup does not
   grant provider API consent or application roles.

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

| Choice | Azure runtime | Automatic deployment path |
|---|---|---|
| JavaScript | Node.js 22, Functions v4 | Verify and publish the ready ZIP with its production dependencies |
| .NET | .NET 8 isolated, Functions v4 | Verify source ZIP, publish for Linux with .NET 8, repackage and publish |
| Python | Python 3.11, Functions v4 | Verify source ZIP; One Deploy with remote build on FC1, or validate/download and publish the SCM-built output on EP1 |

Package hashes are still checked; removing the **customer prompt** does not disable integrity
verification. Source and deployed-package hashes are recorded separately when a build changes the bytes.
For FC1 Python, One Deploy builds and stores the output inside Azure; the summary records the
verified source hash and leaves `packageSha256` null rather than reporting it as the built-output hash.

Setup normally detects these automatically. For unattended execution, allow installation explicitly:

```powershell
.\Setup-Epp.ps1 -NonInteractive -InstallPrerequisites ...
```

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
2. **Choose SMS or voice**, then the **Global or EU tenant scope**.
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
    -TenantId <customer-tenant-id> `
    -SubscriptionId <subscription-id> `
    -ApplicationId <existing-client-id> `
    -Location westus2 `
    -Language javascript `
    -ServicePlan FC1 `
    -Provider telesign `
    -ResourcePrefix contoso
```

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

### Encryption certificate lifecycle

The issuance policy uses **12-month validity, key reuse, and manual renewal**. It specifies
`EmailContacts` 30 days before expiry, **not `AutoRenew`**. Email is sent only if the customer
separately configures Key Vault certificate contacts; setup does not create contacts or guarantee
notifications. Track the saved expiry and arrange renewal before the certificate expires.

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

1. Save the Step 2 summary and confirm its tenant, application client ID, endpoint URL, encryption
   key ID, and certificate with the EPP onboarding owner. **Replace all test provider values** and
   provision the adapter-named API credentials in Key Vault. Verify the package's channel routing
   and retry behavior.
2. Validate the deployed endpoint with synthetic, non-delivering evaluation requests first.
   Missing/invalid credentials and unauthorized callers must be rejected by Easy Auth. An admitted
   caller's valid encrypted request must return the matching nonce. Then verify live SMS/voice
   provider acceptance and handset delivery through the supported test procedure. Never put
   phone numbers, messages, tokens, private keys, or nonce values in shared logs.
3. An **Authentication Policy Administrator**, using the approved Microsoft Graph tool and delegated
   `Policy.ReadWrite.AuthenticationMethod`, must read the selected channel configuration:
   `https://graph.microsoft.com/beta/policies/authenticationMethodsPolicy/authenticationMethodConfigurations/Sms`
   for SMS or the same path ending in `/Voice` for voice. If the selected configuration or its
   `url` and `appId` properties are unavailable, stop and obtain the supported onboarding procedure
   from Microsoft rather than sending a guessed update.
4. Save the existing channel configuration with the tenant ID and timestamp. Re-read it immediately
   before a manual change, stop if it changed, and use `If-Match` when an ETag is available.
5. Update `url` with the highlighted Function endpoint and `appId` with the highlighted endpoint
   application client ID printed by setup. Preserve all other properties, then read the configuration
   back and compare those values before considering activation complete.

Policy activation, policy backups, and policy rollback are administrator-owned manual operations.
No policy API is called by the setup package. For rollback, restore only the reviewed prior EPP
value through the still-supported contract; resource deletion is not a policy rollback.