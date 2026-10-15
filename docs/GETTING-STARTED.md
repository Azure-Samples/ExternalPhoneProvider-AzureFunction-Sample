# Set up an External Phone Provider endpoint

[Documentation](README.md) | [Setup reference](../setup/docs/README.md) | [Troubleshooting](../setup/docs/Troubleshooting.md)

Deploy **one endpoint in one Azure region** for Microsoft Entra ID SMS and voice requests.
Guided setup downloads and publishes the selected package, so you can start without cloning or
building the repository.
SMS and voice can use different provider URLs on the same endpoint; validate each intended channel.

Follow in order: [prepare](#1-get-ready), [register](#2-register-your-application),
[deploy](#3-run-guided-setup), [connect and test](#4-connect-your-provider-and-test),
then [activate and hand over](#5-activate-and-hand-over).
Portal screenshots hide identifying details; labels and layout may differ.

## 1. Get ready

Start in a **dedicated nonproduction tenant and subscription**.

Before purchasing or deploying, confirm access to a supported provider's EPP integration through
[Microsoft Security Store](https://securitystore.microsoft.com/private-solutions). Arrange
Microsoft's approved testing and activation procedure with your tenant administrator.
Buying an offer does not enable the tenant feature or deploy this sample. If access or the
approved procedure is unavailable, **stop here** and follow the
[access and support guidance](ONBOARDING.md#before-purchasing-or-deploying).

In Security Store, open **Private solutions** and select your approved subscription.
A listing does not guarantee [guided provider support](ONBOARDING.md#provider-credential-names).

Use the [SMS cost estimation guide](COST-CALCULATOR.md) to create a planning estimate,
then confirm destination rates, fees, and final costs with your provider.

Have these ready:

- **Provider account:** complete the provider's account and sender registration for your chosen
  SMS or voice service. Check [guided provider support](ONBOARDING.md#provider-credential-names).
- **Shell:** Azure Cloud Shell in PowerShell mode, or PowerShell 7+ with an Azure CLI user login.
  Azure CLI 2.60.0+ is required for Flex Consumption (FC1), or 2.48.1+ for Premium (EP1).
  Allow access to GitHub, Azure, Microsoft Graph, Key Vault, and the deployment endpoints.
  C# also needs the .NET 8 SDK and NuGet access.
- **Administrators:** an Azure operator with subscription deployment, resource-provider registration,
  and role-assignment permissions; an Entra Privileged Role Administrator for setup; and an
  Authentication Policy Administrator for later activation. These are separate permissions.
- **Azure region and budget:** check availability and subscription quota for your chosen Linux
  plan. Azure resources and provider services can incur charges.

Check the [full prerequisites](../setup/docs/README.md#prerequisites-for-step-2), including the
Microsoft Entra ID allowed-tenants preview. Graph reuses the Azure CLI login; no Graph PowerShell SDK or
separate sign-in is needed. Setup can install Bicep after confirmation, but not Azure CLI.

Assign an **onboarding owner** to coordinate administrators, provider, and Microsoft support.
Review the [sample limitations](CONTRACT.md#production-limitations): no production certification,
automatic send retries, duplicate-send protection, or automatic certificate renewal.

## 2. Register your application

In the customer tenant's **Microsoft Entra admin center > App registrations > New registration**:

1. Give the application a recognizable name.
2. Select **Accounts in this organizational directory only**. Leave the redirect URI blank,
   then select **Register**. Setup will make the app organizational multitenant and restrict
   its allowed tenants after you approve the deployment plan.
3. On **Overview**, save the **Directory (tenant) ID** and **Application (client) ID** privately.
   Use the client ID, not the Object ID.

![App registration form with an example name, Single tenant only selected, and no redirect URI](images/onboarding/app-registration.png)

*Some portal versions label the account type **Single tenant only**. Choose your own directory.
The example above is an unsaved form, not an application you can reuse.*

Use these field labels to find the right IDs:

![App registration Overview with Application client ID and Directory tenant ID identified for setup and Object ID marked DO NOT USE](images/onboarding/app-registration-overview.png)

*Use **Application (client) ID** for `-ApplicationId` and **Directory (tenant) ID** for `-TenantId`.
The **Object ID** is not either of these setup inputs. All ID values are hidden in this example.*

Do not add a client secret, API permission, or app role yourself; setup handles the remaining
configuration. See [application registration details](../setup/docs/README.md#step-1---manually-create-the-application).

Also keep your Azure subscription ID handy. The
[setup values worksheet](ONBOARDING.md#inputs-you-supply-to-setup) explains where to find
each value. Use a new dedicated application and resource prefix for another independent endpoint;
changing the provider or region on a rerun does not create a separate deployment.

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

On a shared or multi-account workstation, use `.\Setup-Epp.ps1 -ForceAuthentication` to request
an explicit Azure CLI device-code sign-in. Microsoft Graph reuses that CLI session.

Select the customer tenant/subscription, dedicated application **client ID**, and Azure region.
Refresh or sign in if the expected account is missing. Then choose:

- **Provider and route:** enter or confirm the provider by name. **Tenant scope** means Global/EU
  provider routing, not Azure region or a data-residency guarantee.
- **One platform:** JavaScript, C#, or Python. Setup verifies, builds as needed, and publishes
  the package, with both channel URLs. No channel prompt, local settings, or separate ZIP upload.
- **Hosting:** FC1 can scale to zero and cold-start; EP1 has paid warm capacity. FC1's usage grant
  does not make deployment free. Review [plan details](../setup/docs/README.md#service-plan-selection).
- **Resource prefix:** 2-8 lowercase letters/digits, starting with a letter.

Complete any required CLI sign-in, MFA, or administrator consent yourself. Setup checks
prerequisites and prepares the deployment plan; resolve any reported failure before continuing.

For a new application, setup creates its encryption certificate. If encryption credentials
already exist, follow [certificate selection](../setup/docs/README.md#encryption-certificate-selection)
to reuse one exact Key Vault certificate version or approve replacement. Coordinate maintenance
first: changing these credentials affects every endpoint sharing the application.

**Review the complete deployment plan before typing `Yes`.** Check the accounts, region,
SMS and voice provider URLs, platform, plan, cache settings, resource names, permissions, and
the exact certificate key IDs to keep or remove and any access to an existing vault. Setup grants the
Microsoft phone-provider service principal Microsoft Graph `Application.Read.All`, a tenant-wide
application-read permission. `No` or Enter cancels deployment; sign-in and prerequisite prompts
are separate from this approval.

**Want to review without deploying?** Run interactively and choose **No** at that final prompt.
This still performs online preflight and downloads. There is no `-DryRun` or `-WhatIf` switch;
see [plan review](../setup/docs/README.md#reviewing-the-plan-without-deploying) for details.

Wait for **Deployment completed** and the saved summary before Step 4. Setup creates the
Function App, storage, Key Vault, identities, and monitoring; **do not create them manually first**.
Keep `epp-output` private. Its public certificate and
[summary](../setup/docs/README.md#read-the-deployment-summary) identify resources, endpoint,
application client ID, and encryption key ID. No private key is downloaded.

Setup verifies that the Function can resolve its selected private-key reference before changing
the registered encryption certificates. It also verifies **Easy Auth**, the endpoint's
caller-authentication protection, before opening public access. Never disable it to fix a setup
or testing problem. If setup fails, use the
[troubleshooting guide](../setup/docs/Troubleshooting.md) rather than deleting resources and starting over.

To find the deployed resources, open **Azure portal > Resource groups** and select the group
listed in your deployment summary.

![Example regional resource group showing a Function App, monitoring, Key Vault, managed identity, hosting plan, and storage](images/onboarding/resource-group.png)

*This existing Premium test deployment shows the resource types to look for, not a new
deployment or a guarantee that your resource list will be identical. Use setup rather than
the portal's Create button to deploy the endpoint.*

## 4. Connect your provider and test

Complete [provider authentication](ONBOARDING.md#complete-provider-authentication); deployment
does not do this for you. API-key integrations use the
[setup-created vault and exact secret names](ONBOARDING.md#where-to-enter-api-key-credentials-in-key-vault).
OAuth uses the provider-administrator handoff, not API-key secrets.
Keep credentials out of source, screenshots, and shared logs.

In your Function App, open **Settings > Authentication**. Check that authentication is
**Enabled**, access is set to **Require authentication**, and unauthenticated requests receive
**HTTP 401 Unauthorized**. These are checks, not instructions to change the approved caller.

![Function Authentication page showing Enabled, Require authentication, and Return HTTP 401 Unauthorized](images/onboarding/authentication.png)

*The **Microsoft** identity provider on this page validates the caller. It is not the phone
provider you selected for SMS or voice.*

Ask your onboarding owner to arrange the
[approved deployed-endpoint checks](ONBOARDING.md#validate-the-deployed-endpoint):

1. Confirm that missing or unauthorized caller credentials are rejected.
2. Run an authorized **evaluation** to check authentication and decryption without a provider send.
3. Run a separately approved **live test for each channel you intend to activate** and confirm
   both provider acceptance and receipt of the SMS or voice call. Acceptance alone is not proof of delivery.
4. Check that the request and relevant logs appear in Application Insights.

The [illustrated monitoring steps](MONITORING.md#find-the-linked-resources-in-the-portal)
show where to open Application Insights and its Logs workspace.

This repository does not supply a self-service token tool for the authorized Microsoft caller.
An ordinary Azure CLI token is not a substitute. If the approved test procedure is unavailable
or any check fails, **do not activate the endpoint**. Do not blindly retry a timed-out live send:
the provider may already have accepted it.

## 5. Activate and hand over

Have an **Authentication Policy Administrator** follow the
[supported activation procedure](../setup/docs/README.md#step-3---manually-validate-and-activate-policy).
They must save the existing policy, apply the approved endpoint URL and application client ID,
preserve other settings, and read back and validate the change. **Setup does not activate policy.**
The EPP policy fields require Microsoft's assisted procedure; do not guess a Graph update.

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
and optional designs. For a failed step, go directly to [troubleshooting](../setup/docs/Troubleshooting.md).
