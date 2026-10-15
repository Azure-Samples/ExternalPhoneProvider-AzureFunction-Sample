# Deployment guide

<a id="set-up-an-external-phone-provider-endpoint"></a>

[Documentation](README.md) | [Setup reference](../setup/docs/README.md) | [Troubleshooting](../setup/docs/Troubleshooting.md)

Deploy **one regional endpoint** for Microsoft Entra ID SMS and voice requests. Guided setup
publishes the selected package. Validate each channel you plan to use.

Follow in order: [prepare](#1-get-ready), [register](#2-register-your-application),
[deploy](#3-run-guided-setup), [connect and test](#4-connect-your-provider-and-test),
then [activate and hand over](#5-activate-and-hand-over).
Portal labels may differ from the screenshots.

## 1. Get ready

Start with a **separate test environment** in a nonproduction tenant and subscription. Create a
new application registration and choose a unique resource prefix. This makes the endpoint easy
to identify and keeps testing separate from production.

Before purchasing or deploying, confirm access to a supported provider's EPP integration through
[Microsoft Security Store](https://securitystore.microsoft.com/private-solutions) and arrange
Microsoft's approved testing and activation procedure. See
[access and support](ONBOARDING.md#before-purchasing-or-deploying).

In Security Store, open **Private solutions** and select the approved subscription. Check
[guided provider support](ONBOARDING.md#provider-credential-names).

Use the [SMS cost estimation guide](COST-CALCULATOR.md) to create a planning estimate,
then confirm destination rates, fees, and final costs with your provider.

Prepare:

- **Provider account:** complete account and sender registration for SMS or voice.
- **Shell:** Azure Cloud Shell in PowerShell mode, or PowerShell 7+ with an Azure CLI user login.
  Azure CLI 2.60.0+ is required for Flex Consumption (FC1), or 2.48.1+ for Premium (EP1).
  Allow access to GitHub, Azure, Microsoft Graph, Key Vault, and the deployment endpoints.
  C# also needs the .NET 8 SDK and NuGet access.
- **Administrators:** Azure deployment and role-assignment access, a Privileged Role Administrator
  for setup, and an Authentication Policy Administrator for activation.
- **Azure region and budget:** check availability and subscription quota for your chosen Linux
  plan. Azure resources and provider services can incur charges.

Check the [full prerequisites](../setup/docs/README.md#prerequisites-for-step-2), including the
Microsoft Entra ID allowed-tenants preview. Setup can install Bicep, but not Azure CLI.

Assign an **onboarding owner** and review [production readiness](../TECHNICAL.md#production-readiness).

## 2. Register your application

In the customer tenant's **Microsoft Entra admin center > App registrations > New registration**:

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

Let setup add the required API permission and app role. No client secret is needed.
See [application registration details](../setup/docs/README.md#step-1---manually-create-the-application).

Keep the Azure subscription ID handy. The [setup values worksheet](ONBOARDING.md#inputs-you-supply-to-setup)
lists every input. Use a new app and prefix for an independent endpoint.

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

On a shared workstation, use `.\Setup-Epp.ps1 -ForceAuthentication` for a fresh Azure CLI sign-in.

Select the tenant, subscription, application **client ID**, and region. Then choose:

- **Provider and route:** enter or confirm the provider by name. **Tenant scope** means Global/EU
  provider routing, not Azure region or a data-residency guarantee.
- **Platform:** JavaScript, C#, or Python.
- **Hosting:** FC1 can scale to zero and cold-start; EP1 has paid warm capacity. FC1's usage grant
  does not make deployment free. Review [plan details](../setup/docs/README.md#service-plan-selection).
- **Resource prefix:** 2-8 lowercase letters/digits, starting with a letter.

Complete required sign-in, MFA, or administrator consent. Resolve preflight errors before approval.

For existing encryption credentials, follow
[certificate selection](../setup/docs/README.md#encryption-certificate-selection). Coordinate
changes across every endpoint sharing the application.

**Review the complete deployment plan before typing `Yes`.** Check the accounts, region,
SMS and voice provider URLs, platform, plan, cache settings, and resource names. Also check
permissions, certificate key IDs, and access to any existing vault. The plan includes Microsoft Graph `Application.Read.All` for the Microsoft phone-provider service
principal. `No` or Enter cancels deployment.

**Plan review:** run interactively and choose **No** at the final prompt. See
[plan review](../setup/docs/README.md#reviewing-the-plan-without-deploying).

Wait for **Deployment completed** and the saved summary before Step 4. Setup creates the
Function App, storage, Key Vault, identities, and monitoring as one coordinated deployment.
Begin without precreating these resources so setup can apply the complete reviewed plan.
Keep `epp-output` private. Its [summary](../setup/docs/README.md#read-the-deployment-summary)
identifies the resources, endpoint, app, and encryption key. No private key is downloaded.

Setup verifies the private-key reference and **Easy Auth** before opening public access. Keep
Easy Auth enabled. If setup fails, use the
[troubleshooting guide](../setup/docs/Troubleshooting.md) rather than deleting resources and starting over.

To find the deployed resources, open **Azure portal > Resource groups** and select the group
listed in your deployment summary.

![Example regional resource group showing a Function App, monitoring, Key Vault, managed identity, hosting plan, and storage](images/onboarding/resource-group.png)

*This existing Premium test deployment shows the resource types to look for, not a new
deployment or a guarantee that your resource list will be identical. Use setup rather than
the portal's Create button to deploy the endpoint.*

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

*The **Microsoft** identity provider on this page validates the caller. It is not the phone
provider you selected for SMS or voice.*

Complete the [approved endpoint checks](ONBOARDING.md#validate-the-deployed-endpoint):

1. Confirm that missing or unauthorized caller credentials are rejected.
2. Run an authorized **evaluation** to check authentication and decryption without a provider send.
3. Run a separately approved **live test for each channel you intend to activate** and confirm
   both provider acceptance and receipt of the SMS or voice call. Acceptance alone is not proof of delivery.
4. Check that the request and relevant logs appear in Application Insights.

Use Microsoft's approved caller and test procedure for these checks; an ordinary Azure CLI token
cannot represent that caller. Activate the endpoint after every required check passes. If a live
send times out, investigate its outcome before trying again because the provider may already have
accepted it.

## 5. Activate and hand over

Have an **Authentication Policy Administrator** follow the
[supported activation procedure](../setup/docs/README.md#step-3---manually-validate-and-activate-policy).
They save the existing policy, apply the approved endpoint URL and application client ID,
preserve other settings, and validate the result.

Repeat for each authentication method you intend to enable. SMS and voice can share the same
Function endpoint URL and application client ID; no additional setup run is needed for the second channel.

Before handing over, confirm:

- [ ] Provider authentication, authorized testing, and recipient delivery are verified.
- [ ] Policy is backed up, activated, and checked, with a [rollback plan](../setup/docs/README.md#rollback-and-decommissioning).
- [ ] [Monitoring and alert notifications](MONITORING.md) work for your chosen runtime.
- [ ] Owners are assigned for provider credentials, [certificate renewal](../setup/docs/README.md#encryption-certificate-lifecycle),
  support, and costs.

Setup creates telemetry resources, **not alert rules or renewal notifications**.
Keep the deployment summary and validation evidence in restricted storage.
Deleting Azure resources does not undo an authentication policy change.

## Find more detail

Use the [task-based documentation index](README.md) for operations, developer references,
and advanced topics. For a failed step, go directly to [troubleshooting](../setup/docs/Troubleshooting.md).
