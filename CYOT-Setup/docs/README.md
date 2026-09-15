> **Produced by:** GitHub Copilot | **Session:** S0915a

# CYOT guided setup

Use one entry point to register the Entra application, configure the delivery endpoint, validate the public Microsoft Graph contract, and explicitly activate the Custom OTP (CYOT) policy.

## Prerequisites

- PowerShell 7.0 or later
- Azure CLI for an Azure-hosted endpoint
- Microsoft Graph PowerShell modules `Microsoft.Graph.Authentication` and `Microsoft.Graph.Applications`
- An account that can consent to `Application.ReadWrite.All` for registration
- Authentication Policy Administrator for policy activation with `Policy.ReadWrite.AuthenticationMethod`
- Azure permissions to create or configure the selected endpoint resources

Run local prerequisite checks without signing in:

```powershell
.\Setup-Cyot.ps1 -Stage Diagnostics
```

## Step-by-step runbook

Use a nonproduction tenant and subscription for the first live test. Run these commands from PowerShell 7 in the `Projects/CYOT-Setup` directory.

### 1. Install and verify prerequisites

Install the required Microsoft Graph modules for the current user:

```powershell
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -Repository PSGallery -Force
Install-Module Microsoft.Graph.Applications -Scope CurrentUser -Repository PSGallery -Force
```

Install Azure CLI if it isn't already available. On Windows, one supported option is:

```powershell
winget install --exact --id Microsoft.AzureCLI
```

Open a new PowerShell 7 session after installing Azure CLI, then verify the tools and run the package diagnostics:

```powershell
$PSVersionTable.PSVersion
az version
Get-Module Microsoft.Graph.Authentication, Microsoft.Graph.Applications -ListAvailable
.\Setup-Cyot.ps1 -Stage Diagnostics
```

Continue only when all nine diagnostics pass.

### 2. Collect the required values

Have these values ready before starting:

- Customer Microsoft Entra tenant ID
- Azure subscription ID
- Dedicated test resource group and Azure region
- Globally unique Function App name
- Provider tenant ID and provider API scope ending in `/.default`
- Provider API endpoint and any provider-specific account settings
- Local endpoint ZIP path or a time-limited package URL, when deploying code

Never put passwords, client secrets, access tokens, private keys, or SAS-bearing URLs in a committed configuration file.

### 3. Create the customer configuration

Copy the example outside the repository's tracked files and edit every placeholder:

```powershell
Copy-Item .\examples\customer-config.example.json "$HOME\cyot-customer-config.json"
notepad "$HOME\cyot-customer-config.json"
```

Keep `endpoint.infrastructureMode` set to `Bicep` for the secure infrastructure path. Remove that property to use the original Azure CLI provisioning path. Use a dedicated test resource group so cleanup can't affect unrelated resources.

Confirm that the JSON is valid:

```powershell
Get-Content "$HOME\cyot-customer-config.json" -Raw | ConvertFrom-Json | Out-Null
```

### 4. Sign in to the test tenant and subscription

The guided stages can request Microsoft Graph sign-in when needed. Sign in to Azure CLI first and verify the selected context:

```powershell
$tenantId = '<customer-tenant-id>'
$subscriptionId = '<test-subscription-id>'

az config set core.login_experience_v2=false --only-show-errors
az login --tenant $tenantId
az account set --subscription $subscriptionId
az account show --query '{tenantId:tenantId,subscriptionId:id,subscription:name}' --output table
```

Stop if the displayed tenant or subscription isn't the intended test environment. Bicep mode currently requires an interactive Azure user because setup assigns that user Key Vault Secrets Officer.

### 5. Register the Microsoft Entra application

```powershell
.\Setup-Cyot.ps1 -ConfigPath "$HOME\cyot-customer-config.json" -Stage Register
```

Review `state/cyot-setup-state.json` and record the `applicationId`. Give that client ID to the selected provider and complete the provider's purchase and onboarding process. Don't continue until the provider supplies its tenant ID, API scope, endpoint, and any required account settings. Add those values to the customer configuration without adding secrets.

### 6. Deploy and configure the endpoint

```powershell
.\Setup-Cyot.ps1 -ConfigPath "$HOME\cyot-customer-config.json" -Stage Deploy
```

Approve only the resources shown for the dedicated test environment. If the stage stops, correct the reported issue and continue from the saved state:

```powershell
.\Setup-Cyot.ps1 -ConfigPath "$HOME\cyot-customer-config.json" -Resume
```

### 7. Verify the deployment

Inspect the saved identifiers and completed stages:

```powershell
$state = Get-Content .\state\cyot-setup-state.json -Raw | ConvertFrom-Json
$state | Format-List tenantId, applicationId, subscriptionId, resourceGroup, functionAppName, endpointUrl, completedStages
```

For an Azure-hosted endpoint, verify resource and Function App health:

```powershell
az resource list --resource-group $state.resourceGroup --output table
az functionapp show --resource-group $state.resourceGroup --name $state.functionAppName `
	--query '{name:name,state:state,host:defaultHostName,httpsOnly:httpsOnly}' --output table
```

Test the endpoint using the provider or Microsoft test procedure and expected authenticated request shape. A DNS response or generic HTTP response alone doesn't prove OTP delivery works. Confirm that a test request reaches the Function, the provider accepts it, telemetry contains no secrets, and the expected OTP arrives before activation.

### 8. Validate the public Microsoft Graph contract

This check resolves endpoint DNS and reads public Graph metadata. It doesn't update tenant policy:

```powershell
.\Setup-Cyot.ps1 -ConfigPath "$HOME\cyot-customer-config.json" -Stage Validate
```

Review `graphSchemaSupported` and `graphSchemaReason` in `state/cyot-setup-state.json`. If the live public schema doesn't expose the exact CYOT contract, stop. The package deliberately won't guess a preview contract or activate a different authentication method.

### 9. Review and approve policy activation

Activation requires Authentication Policy Administrator and delegated `Policy.ReadWrite.AuthenticationMethod`. Run it only after endpoint testing and schema validation succeed:

```powershell
.\Setup-Cyot.ps1 -ConfigPath "$HOME\cyot-customer-config.json" -Stage Activate
```

Review the proposed `cyot` payload at the prompt and type `Yes` only when the tenant ID, application ID, endpoint, and migration choice are correct. Setup saves the previous value under `policy-backups/`, checks for concurrent changes, patches only `cyot`, and verifies the result by reading it back.

### 10. Roll back or clean up a test

There is no automatic rollback command. This is intentional because setup can reuse preexisting applications and Azure resources.

For a policy rollback:

1. Stop new CYOT testing and identify the exact timestamped backup under `policy-backups/`.
2. Verify its `TenantId`, `PolicyUri`, and `PreviousCyot` values with the tenant administrator.
3. Restore only the `cyot` property through the currently supported Microsoft Graph contract, then read it back and compare it with the backup.
4. If the live schema no longer exposes that contract, don't send a guessed request. Escalate to the owning Microsoft Graph or CYOT support team.

For Azure cleanup, first confirm the resource group was created solely for this test:

```powershell
az resource list --resource-group <dedicated-test-resource-group> --output table
```

Only after reviewing that inventory, delete the dedicated test resource group:

```powershell
az group delete --name <dedicated-test-resource-group> --yes --no-wait
```

Don't delete a shared or preexisting resource group. Application registration, provider-side onboarding, certificates, and tenant policy require separate owner-approved cleanup. Keep logs, state, and policy backups until rollback and audit needs are complete; they contain identifiers but shouldn't contain credentials.

## Guided setup

```powershell
.\Setup-Cyot.ps1
```

Choose **Run all stages** for the standard flow. The script saves each completed stage to `state/cyot-setup-state.json`. If setup stops, fix the reported issue and continue:

```powershell
.\Setup-Cyot.ps1 -Resume
```

You can also run one stage:

```powershell
.\Setup-Cyot.ps1 -Stage Register
.\Setup-Cyot.ps1 -Stage Deploy
.\Setup-Cyot.ps1 -Stage Validate
.\Setup-Cyot.ps1 -Stage Activate
```

## Configuration

Copy `examples/customer-config.example.json` to a customer-specific location and replace the placeholders. Don't add passwords, access tokens, private keys, provider credentials, or SAS URLs to the file.

```powershell
.\Setup-Cyot.ps1 -ConfigPath .\customer-config.json
```

Set `endpoint.infrastructureMode` to `Bicep` to provision the Function App, storage account, Key Vault, Log Analytics workspace, Application Insights, managed identity, diagnostics, and role assignments from `infra/main.bicep`. Omit the setting to retain the Azure CLI provisioning path in the endpoint stage. The deployment checks that the configured region supports the required resource providers and Premium Functions SKU before making changes.

Bicep mode currently requires an interactive Azure user. Setup resolves that user's object ID for the Key Vault Secrets Officer assignment; service-principal deployment isn't supported. The identity-based ZIP deployment path must also be validated in a live customer subscription before production rollout.

For unattended setup, authenticate Azure CLI and Microsoft Graph in the current process first. Policy activation additionally requires the dedicated approval switch:

```powershell
.\Setup-Cyot.ps1 -NonInteractive -ConfigPath .\customer-config.json -ApprovePolicyActivation
```

Without `-ApprovePolicyActivation`, noninteractive policy activation is rejected. The switch doesn't bypass the live schema check, backup, concurrency check, or post-write verification.

## Safety model

- Azure resources and Microsoft Graph are separate control planes. This package coordinates both.
- Registration and deployment are idempotent and can reuse existing resources.
- Validation checks the live public Graph metadata before activation requests policy permissions.
- Activation patches only the supported `cyot` property.
- Activation saves the previous policy value under `policy-backups/` without overwriting existing files.
- State contains resource identifiers and progress only. It doesn't contain credentials or tokens.
- Logs redact common authorization headers and secret-bearing URL query values.

See [Troubleshooting.md](Troubleshooting.md) for recovery guidance.
