# Deployment guide

<a id="set-up-an-external-phone-provider-endpoint"></a>

[Documentation](README.md) | [Setup reference](../setup/docs/README.md) | [Troubleshooting](../setup/docs/Troubleshooting.md)

**External Phone Provider (EPP)** connects Microsoft Entra ID to your phone provider for SMS
and voice one-time passwords. This guide deploys one regional endpoint for that integration.

| Step | Task |
| --- | --- |
| 1 | [Prepare access, tools, region, and budget](#1-get-ready) |
| 2 | [Choose the endpoint application](#2-register-your-application) |
| 3 | [Run guided setup](#3-run-guided-setup) |
| 4 | [Connect the provider and test](#4-connect-your-provider-and-test) |
| 5 | [Activate and hand over](#5-activate-and-hand-over) |

Complete the steps in order. Portal labels can differ from the screenshots.

## 1. Get ready

Use a separate test environment with its own application registration and resource prefix.

Before purchasing or deploying, confirm provider EPP access in
[Microsoft Security Store](https://securitystore.microsoft.com/private-solutions) and arrange
Microsoft's approved test and activation process. See
[access and support](ONBOARDING.md#before-purchasing-or-deploying).

In Security Store, open **Private solutions** and select the approved subscription. Check
[guided provider support](ONBOARDING.md#provider-credential-names).

Use the [cost estimate](COST-CALCULATOR.md), then confirm rates and fees with the provider.

Prepare:

- **Provider access:** confirm the selected integration, intended channels, account prerequisites,
  and the approved onboarding route. Complete steps that do not require deployment-generated
  identifiers; finish provider authentication in Step 4.
- **Shell:** Azure Cloud Shell in PowerShell mode, or PowerShell 7+ with an Azure CLI user login.
  Azure CLI 2.60.0+ is required for Flex Consumption (FC1), or 2.48.1+ for Premium (EP1).
  Allow access to GitHub, Azure, Microsoft Graph, Key Vault, and the deployment endpoints.
  C# also needs the .NET 8 SDK and NuGet access.
- **Administrators:** Azure deployment and role-assignment access, a Privileged Role Administrator
  for setup, and an Authentication Policy Administrator for activation.
- **Azure region and budget:** check availability and subscription quota for your chosen Linux
  plan. Azure resources and provider services can incur charges.

Check the [full prerequisites](../setup/docs/README.md#prerequisites-for-step-2). Setup can install
Bicep, but not Azure CLI.

Assign an **onboarding owner** and review [production readiness](../TECHNICAL.md#production-readiness).

## 2. Register your application

You can create the dedicated application during guided setup or register it manually.

**Create during setup:** in Step 3, press Enter to choose **Create a new application**, then Enter to use
**EPP Application** or enter your own display name, and choose a provider by name from the
alphabetized list (**Soprano, Telesign**). Blank provider-name input prompts again instead of
canceling or selecting a default.
Setup creates the registration only after you approve the final deployment plan.
Canceling before approval creates no application. The signed-in user must be allowed to register
applications in the customer tenant.

**Register manually or use an existing dedicated app:** keep its tenant and application client
IDs handy. To register manually, open the customer tenant's
**Microsoft Entra admin center > App registrations > New registration**:

1. Give the application a recognizable name.
2. Select **Accounts in this organizational directory only**. Leave the redirect URI blank,
   then select **Register**. Setup will make the app organizational multitenant and restrict
   its allowed tenants after you approve the deployment plan.
3. On **Overview**, save the **Directory (tenant) ID** and **Application (client) ID** privately.
   Use the client ID, not the Object ID.

![App registration form with an example name, Single tenant only selected, and no redirect URI](images/onboarding/app-registration.png)

*Some portal versions label the account type **Single tenant only**. Select the customer directory.
The example above is an unsaved form and cannot be reused.*

Use these labels to find the IDs:

![App registration Overview with Application client ID and Directory tenant ID identified for setup and Object ID marked DO NOT USE](images/onboarding/app-registration-overview.png)

*Use **Application (client) ID** for `-ApplicationId` and **Directory (tenant) ID** for `-TenantId`.
The **Object ID** is not either of these setup inputs. All ID values are hidden in this example.*

Do not add a client secret, redirect URI, EPP app role, or Microsoft Graph application permission
manually. Setup reviews and applies its required application and enterprise-application changes
only after deployment approval.
See [application registration details](../setup/docs/README.md#step-1---manually-create-the-application).

Keep the Azure subscription ID handy. The [setup values worksheet](ONBOARDING.md#inputs-you-supply-to-setup)
lists every input. Use a new app and prefix for an independent endpoint. After the app exists,
complete provider onboarding steps that require its application client ID; for setup-created
applications, that ID becomes available after deployment approval.

## 3. Run guided setup

After the checks above, open **PowerShell 7** in a private working folder and download the script:

```powershell
Invoke-WebRequest `
    -Uri 'https://raw.githubusercontent.com/Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample/main/setup/Setup-Epp.ps1' `
    -OutFile .\Setup-Epp.ps1
```

Review the downloaded script, then run it:

```powershell
.\Setup-Epp.ps1
```

On a shared workstation, use `.\Setup-Epp.ps1 -ForceAuthentication` for a fresh sign-in.

JavaScript is used by default, without a language prompt. To deploy another language, run
`.\Setup-Epp.ps1 -Language csharp` or `.\Setup-Epp.ps1 -Language python`.

Select the tenant and subscription, then select an existing application, enter its **client ID**,
or choose **Create a new application** and accept **EPP Application** or enter your own display name.
Enter accepts the displayed menu default rather than canceling: the current CLI tenant/subscription
when eligible (otherwise the first eligible option), and **Create a new application** for the app.
Use **0** or **Cancel** where offered to stop.
Setup detects the tenant's replication scope and selects the corresponding provider route;
it does not ask you to choose EU or Global. Select the Azure region, then complete the remaining settings:

- **Azure region:** EU tenants receive recommendations within the EU Data Boundary (EU/EFTA).
  Enter selects the first displayed region.
  Other tenants retain the existing Azure-recommended shortlist. All-region and manual selection,
  including `-Location`, remain available; EU tenants receive a warning for an out-of-boundary or
  unverifiable choice. Recommendations are not a data-residency or GDPR compliance guarantee.
- **Provider:** enter or confirm the provider by name. New applications show all guided providers
  in alphabetical order, with no default selection. Setup downloads the language's matching
  stable release asset, verifies `SHA256SUMS.txt`, and builds when required.
- **Hosting:** Enter defaults to FC1, which can scale to zero and cold-start. EP1 has paid warm capacity. Review
  [plan details](../setup/docs/README.md#service-plan-selection) and the [cost estimate](COST-CALCULATOR.md).
- **Resource prefix:** press Enter to use `epp`, or enter 2-8 lowercase letters/digits, starting
  with a letter. When rerunning an existing deployment, use its original prefix.

Complete required sign-in, MFA, or administrator consent. Resolve preflight errors before approval.

For existing encryption credentials, follow
[certificate selection](../setup/docs/README.md#encryption-certificate-selection).
**Enter defaults to replacing all registered encryption credentials with one new certificate.**
Select **Reuse** explicitly to keep a certificate. Coordinate changes across every endpoint
sharing the application; no cleanup or creation occurs before final deployment approval.

**Review the deployment plan before typing `Yes` or `Y`.** Check accounts, region, provider URLs,
runtime, plan, resource names, permissions, certificate key IDs, and vault access.
The plan includes Microsoft Graph `Application.Read.All` for the Microsoft phone-provider service
principal. `No`, `N`, or Enter cancels. Responses are case-insensitive.

For a new application, the plan shows its display name and resource-name patterns containing
`<app-id-hash>`. After approval, setup creates the registration, uses its real client ID to
calculate the final names, and checks resource ownership before Azure deployment. It prints the
new client ID and saves `application-<client-id>.json` in `epp-output` for recovery. If deployment
then fails, reuse that client ID with `-ApplicationId` and the same prefix; do not create another app.
The registration record is not a successful deployment summary.

**Plan review:** run interactively and choose **No** at the final prompt. See
[plan review](../setup/docs/README.md#reviewing-the-plan-without-deploying).

Azure resource deployment and Function publication can each take several minutes. Keep the session
open; a rotating indicator identifies the operation in progress, without a percentage or estimated
completion time. Unattended or redirected output uses static status messages instead.

Wait for **Deployment completed successfully** and the saved summary before Step 4. Setup creates or updates
the Function App, hosting plan, storage, Key Vault, identities, Log Analytics, Application
Insights, diagnostics, Easy Auth, and scoped role assignments. Do not precreate these resources.
**Save the output: the endpoint URL and Application (client) ID are required for policy updates.**
Keep `epp-output` private. Its [summary](../setup/docs/README.md#read-the-deployment-summary)
records the selected tenant, subscription, provider route, runtime, plan, resource names, endpoint,
application, package provenance, and encryption certificate references. No private key is downloaded.

Setup verifies the private-key reference and **Easy Auth** before opening public access. Keep
Easy Auth enabled. It also verifies that `SendOtp` is registered before reporting success. If setup
fails, use the
[troubleshooting guide](../setup/docs/Troubleshooting.md) rather than deleting resources and starting over.

To find the deployed resources, open **Azure portal > Resource groups** and select the group
listed in your deployment summary.

![Example regional resource group showing a Function App, monitoring, Key Vault, managed identity, hosting plan, and storage](images/onboarding/resource-group.png)

*This Premium test deployment shows the expected resource types. Your list can differ.*

## 4. Connect your provider and test

Next, complete [provider authentication](ONBOARDING.md#complete-provider-authentication).
API-key integrations use the
[setup-created vault and exact secret names](ONBOARDING.md#where-to-enter-api-key-credentials-in-key-vault).
OAuth uses the provider-administrator handoff, not API-key secrets.
Keep credentials out of source, screenshots, and shared logs.

In your Function App, open **Settings > Authentication**. Check that authentication is
**Enabled**, access is set to **Require authentication**, and unauthenticated requests receive
**HTTP 401 Unauthorized**. These are checks, not instructions to change the approved caller.

![Function Authentication page showing Enabled, Require authentication, and Return HTTP 401 Unauthorized](images/onboarding/authentication.png)

*The **Microsoft** identity provider validates the caller. It is not the SMS or voice provider.*

Complete the [approved endpoint checks](ONBOARDING.md#validate-the-deployed-endpoint):

1. Confirm that missing or unauthorized caller credentials are rejected.
2. Run an authorized **evaluation** to check authentication and decryption without a provider send.
3. If the approved pre-activation procedure requires it, run one controlled **live test for each
   channel you intend to activate** and confirm provider acceptance and recipient delivery separately.
4. Check that the request and relevant logs appear in Application Insights.

Use Microsoft's approved caller and test procedure for these checks. An ordinary Azure CLI token
cannot represent that caller. Activate the endpoint after every required check passes. If a live
send times out, investigate its outcome before trying again because the provider may already have
accepted it. Retain only safe evidence: resource IDs, UTC times, status, latency, correlation IDs,
and sanitized outcomes.

## 5. Activate and hand over

Have an **Authentication Policy Administrator** follow the
[supported Graph Explorer activation procedure](../setup/docs/README.md#step-3---manually-validate-and-activate-policy):

1. Verify Graph Explorer shows the deployment summary's tenant, select **beta** and the approved
   SMS or voice endpoint, then consent only to `Policy.ReadWrite.AuthenticationMethod`.
2. GET and save the current policy before changing it. Preserve its state, targeting, and unrelated
   properties; when the approved procedure changes targeting, use its dedicated pilot group.
3. PATCH only the exact EPP changes and field locations in Microsoft's current approved procedure.
   Include the documented `@odata.type`; do not construct an EPP payload from this repository.
4. Expect `204 No Content`, immediately GET the policy again, and compare the approved EPP values
   and every preserved setting with the saved snapshot.
5. Test the pilot in evaluation first, then perform a separately authorized controlled live
   delivery. Restore the saved prior policy if policy readback, evaluation, or delivery fails.

Repeat for each authentication method you intend to enable. SMS and voice can share the same
Function endpoint URL and application client ID. No additional setup run is needed for the second channel.

Before handing over, confirm:

- [ ] Provider authentication, authorized testing, and recipient delivery are verified.
- [ ] Policy is backed up, read back after activation, and checked through the pilot, with a
  [rollback plan](../setup/docs/README.md#rollback-and-decommissioning).
- [ ] [Monitoring and alert notifications](MONITORING.md) work for your chosen runtime.
- [ ] Owners are assigned for provider credentials, [certificate renewal](../setup/docs/README.md#encryption-certificate-lifecycle),
  support, and costs.

Setup creates telemetry resources, **not alert rules or renewal notifications**.
Keep the deployment summary and validation evidence in restricted storage.
Deleting Azure resources does not undo an authentication policy change.

## Find more detail

Use the [task-based documentation index](README.md) for operations, developer references,
and advanced topics. For a failed step, go directly to [troubleshooting](../setup/docs/Troubleshooting.md).
