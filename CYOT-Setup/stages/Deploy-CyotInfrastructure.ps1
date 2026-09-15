#Requires -Version 7.0

<#
.SYNOPSIS
	Deploys the Azure infrastructure used by the CYOT delivery endpoint.

.DESCRIPTION
	Runs deployment preflight checks, creates or updates the resource group through a subscription-
	scoped Bicep deployment, and returns the generated resource names to the guided setup script.
	This stage never performs Microsoft Graph operations or policy activation.
#>
[CmdletBinding()]
param(
	[string] $SubscriptionId,
	[string] $ResourceGroup = 'rg-external-phone-provider',
	[string] $Location = 'westus2',
	[ValidatePattern('^[a-z0-9-]{2,12}$')]
	[string] $EnvironmentName = 'prod',
	[string] $ResourceTagName = 'Purpose',
	[string] $ResourceTagValue = 'Entra - External Phone Provider',
	[ValidateSet('Premium')]
	[string] $PlanType = 'Premium',
	[switch] $NonInteractive
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-CyotAz {
	param([Parameter(ValueFromRemainingArguments)][string[]] $Arguments)

	$output = & az @Arguments 2>&1
	if ($LASTEXITCODE -ne 0) {
		throw "Azure CLI failed: az $($Arguments -join ' ')`n$($output -join "`n")"
	}
	return $output
}

function Read-CyotRequiredValue {
	param([string] $Name, [string] $Value)

	if (-not [string]::IsNullOrWhiteSpace($Value)) { return $Value }
	if ($NonInteractive) { throw "$Name is required in noninteractive mode." }
	$enteredValue = Read-Host $Name
	if ([string]::IsNullOrWhiteSpace($enteredValue)) { throw "$Name is required." }
	return $enteredValue.Trim()
}

function Test-CyotProviderLocation {
	param([string] $Namespace, [string] $ResourceType, [string] $Region)

	$locations = @((Invoke-CyotAz provider show --namespace $Namespace `
				--query "resourceTypes[?resourceType=='$ResourceType'].locations[]" --output tsv))
	$normalizedRegion = $Region -replace '[^a-zA-Z0-9]', ''
	return @($locations | Where-Object { ($_ -replace '[^a-zA-Z0-9]', '') -ieq $normalizedRegion }).Count -gt 0
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
	throw 'Azure CLI is required for Bicep deployment. Install Azure CLI and run az login.'
}

$SubscriptionId = Read-CyotRequiredValue -Name SubscriptionId -Value $SubscriptionId
$ResourceGroup = Read-CyotRequiredValue -Name ResourceGroup -Value $ResourceGroup
$Location = Read-CyotRequiredValue -Name Location -Value $Location

$account = ((Invoke-CyotAz account show --output json) -join "`n") | ConvertFrom-Json
if ($account.id -ne $SubscriptionId) {
	Invoke-CyotAz account set --subscription $SubscriptionId | Out-Null
	$account = ((Invoke-CyotAz account show --output json) -join "`n") | ConvertFrom-Json
}
if ($account.id -ne $SubscriptionId) { throw "Azure CLI did not select subscription '$SubscriptionId'." }

foreach ($provider in @(
		@{ Namespace = 'Microsoft.Web'; Type = 'sites' },
		@{ Namespace = 'Microsoft.Storage'; Type = 'storageAccounts' },
		@{ Namespace = 'Microsoft.KeyVault'; Type = 'vaults' },
		@{ Namespace = 'Microsoft.OperationalInsights'; Type = 'workspaces' },
		@{ Namespace = 'Microsoft.Insights'; Type = 'components' },
		@{ Namespace = 'Microsoft.ManagedIdentity'; Type = 'userAssignedIdentities' })) {
	$registrationState = (Invoke-CyotAz provider show --namespace $provider.Namespace `
			--query registrationState --output tsv) -join ''
	if ($registrationState -ne 'Registered') {
		throw "Resource provider '$($provider.Namespace)' is not registered in subscription '$SubscriptionId'."
	}
	if (-not (Test-CyotProviderLocation -Namespace $provider.Namespace -ResourceType $provider.Type -Region $Location)) {
		throw "Resource type '$($provider.Namespace)/$($provider.Type)' is not available in '$Location'."
	}
}

$premiumLocations = @((Invoke-CyotAz appservice list-locations --sku EP1 --linux-workers-enabled --output tsv))
$normalizedLocation = $Location -replace '[^a-zA-Z0-9]', ''
if (-not @($premiumLocations | Where-Object { ($_ -replace '[^a-zA-Z0-9]', '') -ieq $normalizedLocation }).Count) {
	throw "Linux Premium Functions SKU EP1 is not available in '$Location'."
}

$deployerObjectId = (Invoke-CyotAz ad signed-in-user show --query id --output tsv) -join ''
if ([string]::IsNullOrWhiteSpace($deployerObjectId)) {
	throw 'Could not resolve the signed-in Azure user for the Key Vault Secrets Officer assignment.'
}

$templatePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'infra/main.bicep'
if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) {
	throw "Bicep template not found: $templatePath"
}

$deploymentName = "cyot-$EnvironmentName-$([DateTime]::UtcNow.ToString('yyyyMMddHHmmss'))"
if (-not $NonInteractive) {
	$confirmation = Read-Host "Deploy or update CYOT infrastructure in '$ResourceGroup' ($Location)? [y/N]"
	if ($confirmation -notmatch '^(?i)y(?:es)?$') { throw 'Infrastructure deployment was cancelled.' }
}

$outputs = ((Invoke-CyotAz deployment sub create `
		--name $deploymentName `
		--location $Location `
		--template-file $templatePath `
		--parameters resourceGroupName=$ResourceGroup location=$Location environmentName=$EnvironmentName `
		resourceTagName=$ResourceTagName resourceTagValue=$ResourceTagValue deployerObjectId=$deployerObjectId `
		--query properties.outputs --output json) -join "`n") | ConvertFrom-Json

[pscustomobject]@{
	Stage              = 'Infrastructure'
	SubscriptionId     = $SubscriptionId
	ResourceGroup      = $outputs.resourceGroupName.value
	Location           = $Location
	PlanType           = 'Premium'
	FunctionAppName    = $outputs.functionAppName.value
	StorageAccountName = $outputs.storageAccountName.value
	KeyVaultName       = $outputs.keyVaultName.value
}
*** End Patch