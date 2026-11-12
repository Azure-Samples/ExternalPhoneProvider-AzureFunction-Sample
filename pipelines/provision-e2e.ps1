#Requires -Version 7.4
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [guid] $TenantId,
    [Parameter(Mandatory)]
    [guid] $SubscriptionId,
    [string] $ResourceGroup = 'cyote2e-test-rg',
    [string] $Location = 'eastus',
    [string] $DeploymentIdentity = 'cyote2e-deployment-mi'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-AzChecked {
    param([Parameter(ValueFromRemainingArguments)][string[]] $Arguments)
    & az @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Azure CLI failed: az $($Arguments -join ' ')" }
}

$tenant = $TenantId.ToString()
$subscription = $SubscriptionId.ToString()
$account = Invoke-AzChecked account show --output json | ConvertFrom-Json
if ($account.tenantId -cne $tenant -or $account.id -cne $subscription) {
    throw 'Azure CLI must target the approved CYOT E2E tenant and E2E test subscription.'
}

if ($PSCmdlet.ShouldProcess("$subscription/$ResourceGroup", 'Create CYOT E2E resource group')) {
    Invoke-AzChecked group create --subscription $subscription --name $ResourceGroup --location $Location `
        --tags purpose=cyot-e2e managedBy=cyot-pipeline --output none
}

if ($PSCmdlet.ShouldProcess("$ResourceGroup/$DeploymentIdentity", 'Create deployment managed identity')) {
    $identity = Invoke-AzChecked identity create --subscription $subscription --resource-group $ResourceGroup `
        --name $DeploymentIdentity --location $Location --output json | ConvertFrom-Json
    $scope = "/subscriptions/$subscription/resourceGroups/$ResourceGroup"
    Invoke-AzChecked role assignment create --assignee-object-id $identity.principalId `
        --assignee-principal-type ServicePrincipal --role Contributor --scope $scope --output none
}

[ordered]@{
    tenantId = $tenant
    subscriptionId = $subscription
    resourceGroup = $ResourceGroup
    location = $Location
    deploymentIdentity = $DeploymentIdentity
    ready = $false
} | ConvertTo-Json
