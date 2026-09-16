# EPP endpoint setup

**Only Step 2 is scripted.** Register the customer application manually, run one downloaded
PowerShell script to deploy the endpoint, and activate policy manually after validation.

The customer does not clone this repository or download Bicep/support scripts separately.
`Setup-Epp.ps1` retrieves those files and the selected provider's JSON from GitHub.

## Availability

Choose **JavaScript, .NET, or Python**, then **Telesign or Soprano**, **SMS or voice**, and a
**Global or EU endpoint**. The private test branch uses its matching fork preview release so the
package and provider-authentication contract stay in sync. There is no package URL or checksum to
enter. Setup verifies `SHA256SUMS.txt` automatically and performs the required build and publication
for the selected language.

Provider profiles contain complete channel/region route objects. Unknown values use **explicit dummy
test values**, not a separate placeholder list or empty fields that block setup. They are written
into the Function App's **actual environment settings** after approval. Telesign's supplied route
URLs and timings are preserved. Soprano uses labelled test tenant, scope, app-ID, endpoint, and
timing values.
The plan and saved summary identify test configuration. Deployment does not make these values
working endpoints or credentials. The provider files contain the complete deployment contract.

The default download URLs below become usable when this change is published upstream. Before merging,
test from a published public fork using `-SourceRepository <owner/repository>` and
`-SourceRef <branch-or-full-commit-sha>`. Both options must identify the same source as the downloaded
launcher. Unpublished worktree changes are not downloadable from GitHub.

## Step 1 - manually register and onboard the application

Use a dedicated nonproduction tenant/subscription for the first deployment.

1. In the customer tenant's **Microsoft Entra admin center > App registrations**, register a
   dedicated application. Select **Accounts in any organizational directory**; do not enable
   personal Microsoft accounts. No redirect URI or client secret is needed for this endpoint.
2. Record the **Directory (tenant) ID** and **Application (client) ID**. The script requires the
   client ID, not the application's object ID, and will not create a replacement registration.
3. Verify the application's enterprise application exists in the same tenant. In **Enterprise
   applications > Properties**, set **Assignment required?** to **No** as required by EPP onboarding.
   Easy Auth will still pin inbound calls to the Microsoft phone-provider application
   `25ec60fa-f18d-41a4-b398-50044c90ce13`; this is not permission to accept arbitrary callers.
4. Verify the app's access-token version in its manifest. Setup reads `api.requestedAccessTokenVersion`
   and configures the corresponding v1 or v2 issuer/audience. Leave **`tokenEncryptionKeyId` null**:
   Easy Auth expects a signed bearer JWT. Payload JWE encryption is separate.
5. Complete provider purchase, account/sender registration, and onboarding for the selected adapter.
   Telesign uses `telesign-api-key` and `telesign-customer-id` in Key Vault. Soprano uses OAuth
   client-assertion exchange with the selected provider tenant/scope/application ID. Setup does not
   grant provider API consent or application roles.

Step 2 still configures endpoint-specific properties on this **existing** application: its
hostname-based identifier URI and public JWE encryption certificate. Those changes are included
in the single deployment approval. Soprano additionally creates the disclosed outbound
managed-identity federated credential; Telesign does not.

## Prerequisites for Step 2

- **Windows with PowerShell 7+**. Certificate generation/reuse uses the current user's Windows
  certificate store; this is not an Azure Cloud Shell or Linux customer deployment script.
- Azure CLI **2.48.1+** and its Bicep compiler, with access to GitHub, Azure, Microsoft Graph, and
  Key Vault. Python additionally needs network access to the Function App's SCM endpoint.
- Microsoft Graph PowerShell modules `Microsoft.Graph.Authentication` and `Microsoft.Graph.Applications`.
- An Azure **user** account permitted to deploy at subscription scope, create the listed resources,
  and create the scoped role assignments. Service-principal provisioning is not supported.
- Application-management permission in the customer tenant and delegated Graph
  `Application.ReadWrite.All` for endpoint-specific application configuration.
- **Linux Premium EP1** available in the chosen region. Setup registers missing required Azure
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
| Python | Python 3.11, Functions v4 | Verify source ZIP, request Azure remote build, validate/download built output, publish that output |

Package hashes are still checked; removing the **customer prompt** does not disable integrity
verification. Source and deployed-package hashes are recorded separately when a build changes the bytes.

Install prerequisites once, if missing:

```powershell
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -Repository PSGallery
Install-Module Microsoft.Graph.Applications -Scope CurrentUser -Repository PSGallery
az bicep install
```

Install Azure CLI through its official installation instructions if necessary. Sign in before
running setup; Azure CLI and Microsoft Graph have separate authentication sessions:

```powershell
az login --tenant <customer-tenant-id>
```

Setup checks the explicitly supplied subscription and tenant without changing the CLI's selected
subscription. It requests Graph sign-in before displaying the plan if a suitable delegated
session is not already available. Authentication/MFA prompts are not resource-creation approvals.

## Step 2 - download and run one script

Download and inspect [Setup-Epp.ps1](../Setup-Epp.ps1), or save it from the upstream raw URL:

```powershell
Invoke-WebRequest `
    -Uri 'https://raw.githubusercontent.com/Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample/main/setup/Setup-Epp.ps1' `
    -OutFile .\Setup-Epp.ps1
.\Setup-Epp.ps1
```

The flow is:

1. **Collect missing customer inputs:** tenant, subscription, existing application client ID, Azure
   region, and provider account/sender name. Supplied values
   are reused without prompts. Credentials are never requested as ordinary string parameters.
2. **Choose one language**. Setup looks up its GitHub release and checksum file in
   `packages/catalog.json`; there are no `PackageUrl` or `PackageSha256` inputs.
3. **Choose a provider**, then **SMS or voice**, then **Global or EU endpoint**. Setup downloads the
   provider JSON and resolves one complete route containing endpoint, authentication, app-ID/scope
   when applicable, timeout, and retry interval. Explicit test values are allowed, shown as test
   configuration, and passed to Azure settings. Malformed or disabled profiles still fail before
   resource creation.
4. **Enter a resource prefix**, such as `contoso`: 2-8 lowercase letters/digits, starting with a
   letter. Every top-level resource name then adds the meaningful `epp` marker, for example
   `contoso-epp-rg-<suffix>`. A deterministic suffix derived from the
   subscription, application ID, and prefix reduces global-name collisions. Reruns use the same names.
5. **Review the complete plan**, including resource names, tenant/subscription, language, automatic
   package verification/build, provider
   settings, scoped roles, certificate creation, and application configuration. Bicep receives these
   exact names; it does not independently calculate a different naming scheme.
   The plan also lists the six required **Azure resource providers** and their registration states.
   This is separate from the Telesign/Soprano provider selection.
6. **Type `Yes` once to deploy.** `No` or Enter cancels without Azure changes. Invalid answers prompt
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
    -Provider telesign `
    -ResourcePrefix contoso
```

The plan creates or updates a dedicated resource group, Linux Premium EP1 hosting plan, Function App,
storage account/private package container, Key Vault, Log Analytics workspace, Application Insights,
outbound managed identity, diagnostics, Easy Auth, and scoped role assignments. Storage/package
access uses managed identity, not account keys or SAS. Telemetry uses the system identity; the
outbound identity is selected explicitly, not through a global `AZURE_CLIENT_ID`.

The Function starts with public ingress disabled. Setup stores the private key in Key Vault and
configures application trust. It **reads back and verifies Easy Auth before enabling ingress**.
Python requires this access for its Entra-authenticated SCM remote build; SCM basic authentication
stays disabled. Setup validates the built Python payload, stores it in private Blob storage, and
switches to managed-identity run-from-package. It never mounts the unbuilt Python source ZIP.
For every language, setup restarts, synchronizes triggers, and verifies that `SendOtp` is registered.
On publication/startup failure it disables public ingress again; failure to close ingress is reported
explicitly rather than hidden.

The public certificate and a timestamped identifier
summary are saved to `epp-output` beside the downloaded script, or to `-OutputDirectory`.
Private keys remain in the user's certificate store and Key Vault, not in that summary. With dummy
profiles, `EPP_PROVIDER_TEST_CONFIGURATION=true` is stored alongside the real environment settings.
This is a label, not a replacement for caller authentication or a guarantee of provider connectivity.

For unattended runs, supply every input, authenticate both clients first, and explicitly authorize
the whole displayed plan with **both** `-NonInteractive -ApproveDeployment`. `-NonInteractive`
alone never approves changes. There is no `-Stage`, `-Resume`, `-ConfigPath`, or policy-approval switch.

### Source versioning

`-SourceRepository` defaults to `Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample`.
The small entry point resolves `-SourceRef` (default `main`) to a single commit in that repository. All supporting
PowerShell, Bicep, the catalog, and the selected provider profile are downloaded from that commit.
Use a reviewed full commit SHA for repeatable deployments. Provider JSON selects data only; it
cannot redirect execution to another script. Download failures stop setup, and temporary downloads
are removed on completion or failure. Select only a repository whose code you trust: its supporting
PowerShell is executed locally.

## Step 3 - manually validate and activate policy

1. Save the Step 2 summary and confirm its tenant, application client ID, endpoint URL, encryption
   key ID, and certificate with the EPP onboarding owner. **Replace all test provider values** and
   provision the adapter-named API credentials in Key Vault. Verify the package's channel routing
   and retry behavior; the tenant/scope metadata and test label do not enable unsupported behavior.
2. Validate the deployed endpoint with synthetic, non-delivering evaluation requests first.
   Missing/invalid credentials and unauthorized callers must be rejected by Easy Auth. An admitted
   caller's valid encrypted request must return the matching nonce. Then verify live SMS/voice
   provider acceptance and handset delivery through the supported test procedure. Never put
   phone numbers, messages, tokens, private keys, or nonce values in shared logs.
3. An **Authentication Policy Administrator**, using the approved Microsoft Graph tool and delegated
   `Policy.ReadWrite.AuthenticationMethod`, must verify that the tenant's currently supported EPP
   contract is available. For the preview contract formerly handled by Step 3, inspect
   `https://graph.microsoft.com/beta/$metadata` for `authenticationMethodsPolicy.cyot` and its
   `endpoint`, `appId`, and `migrated` fields. **If absent or different, stop and obtain the supported
   onboarding procedure from Microsoft; do not send a guessed PATCH or enable a different method.**
4. Read `https://graph.microsoft.com/beta/policies/authenticationMethodsPolicy` using that supported
   contract, save the existing `cyot` value with tenant ID and timestamp, and independently approve
   the migration choice. `migrated` is a routing decision, not a script default.
5. Re-read immediately before a manual change, stop if the policy changed, and use `If-Match` when
   an ETag is available. Patch **only** the `cyot` property with the tested endpoint, the same
   application client ID, and the deliberately chosen migration Boolean. Read it back and compare
   before considering activation complete.

Policy activation, policy backups, and policy rollback are administrator-owned manual operations.
No policy API is called by the setup package. For rollback, restore only the reviewed prior EPP
value through the still-supported contract; resource deletion is not a policy rollback.