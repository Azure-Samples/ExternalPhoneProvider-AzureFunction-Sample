#Requires -Version 7.0
<#
.SYNOPSIS
    Deploy both CYOT ARM templates. Certificate, Graph and secret setup runs in Azure.
.DESCRIPTION
    Requires an existing resource group and a pre-authorized deployment identity.
    If both parameter files are missing, collect the required values here and save them.
    ARM supplies the resource-name defaults. No other PowerShell script is required.
    Existing files are reused without prompting or overwriting.
    Each deployment uses ARM what-if confirmation. Step 3 is not invoked.
    Function code publishing is separate; this script deploys infrastructure and configuration.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][guid] $TenantId,
    [Parameter(Mandatory)][guid] $SubscriptionId,
    [Parameter(Mandatory)][string] $ResourceGroup,
    [string] $InfrastructureParameters = (Join-Path $PSScriptRoot 'arm\infrastructure.parameters.local.json'),
    [string] $ConfigurationParameters = (Join-Path $PSScriptRoot 'arm\function-config.parameters.local.json')
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
if ($TenantId -eq [guid]::Empty -or $SubscriptionId -eq [guid]::Empty) { throw 'TenantId and SubscriptionId must be nonempty GUIDs.' }
function Read-Value($Name, $Default = '') {
    $value = Read-Host "$Name [$Default]"
    if ([string]::IsNullOrWhiteSpace($value)) { $value = $Default }
    if ([string]::IsNullOrWhiteSpace($value)) { throw "$Name is required." }
    return $value.Trim()
}
$deployments = @(
    @{ Template = Join-Path $PSScriptRoot 'arm\infrastructure.json'; Parameters = $InfrastructureParameters }
    @{ Template = Join-Path $PSScriptRoot 'arm\function-config.json'; Parameters = $ConfigurationParameters }
)
$missing = @($deployments | Where-Object { -not (Test-Path -LiteralPath $_.Parameters -PathType Leaf) })
if ($missing.Count) {
    if ($missing.Count -ne 2) { throw 'Only one parameter file exists. Restore the missing file; existing files will not be overwritten.' }
    $shared = @{ tenantId = $TenantId.ToString() }
    foreach ($name in @('functionAppName', 'applicationId', 'preparationIdentityResourceId')) { $shared[$name] = Read-Value $name }
    $shared.planType = Read-Value 'planType (FlexConsumption/Premium)' 'FlexConsumption'
    $shared.tokenVersion = [int](Read-Value 'tokenVersion' '1')
    if ($shared.planType -notin @('FlexConsumption', 'Premium') -or $shared.tokenVersion -notin @(1, 2)) { throw 'Invalid plan type or token version.' }
    $shared.planType = if ($shared.planType -eq 'Premium') { 'Premium' } else { 'FlexConsumption' }
    $provider = @{ EPP_PROVIDER_TIMEOUT_MS = '1500'; EPP_PROVIDER_RETRY_INTERVAL_MS = '0' }
    foreach ($name in @('EPP_PROVIDER_NAME', 'EPP_PROVIDER_ENDPOINT', 'EPP_PROVIDER_ACCOUNT_NAME', 'EPP_PROVIDER_TENANT_ID', 'EPP_PROVIDER_SCOPE')) {
        $provider[$name] = Read-Value $name
    }
    foreach ($value in @($shared.applicationId, $provider.EPP_PROVIDER_TENANT_ID)) {
        $id = [guid]::Empty
        if (-not [guid]::TryParse($value, [ref]$id) -or $id -eq [guid]::Empty) { throw 'Application and provider tenant IDs must be nonempty GUIDs.' }
    }
    $endpoint = $null
    if (-not [uri]::TryCreate($provider.EPP_PROVIDER_ENDPOINT, [UriKind]::Absolute, [ref]$endpoint) -or
        $endpoint.Scheme -ne 'https' -or $endpoint.UserInfo -or $endpoint.Query -or $endpoint.Fragment) { throw 'Use an HTTPS provider base URL without credentials, a query or a fragment.' }
    $sets = @($shared.Clone(), $shared.Clone())
    $sets[0].location = Read-Value 'location' 'westus2'
    $sets[1].managedSettings = $provider
    for ($i = 0; $i -lt 2; $i++) {
        $parameters = @{}
        foreach ($name in $sets[$i].Keys) { $parameters[$name] = @{ value = $sets[$i][$name] } }
        $json = @{ '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'; contentVersion = '1.0.0.0'; parameters = $parameters } | ConvertTo-Json -Depth 10
        $file = [IO.File]::Open($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($deployments[$i].Parameters), [IO.FileMode]::CreateNew)
        try { $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json); $file.Write($bytes, 0, $bytes.Length) }
        finally { $file.Dispose() }
    }
}
foreach ($deployment in $deployments) {
    foreach ($path in @($deployment.Template, $deployment.Parameters)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing file: $path" }
    }
    $deployment.Parameters = (Resolve-Path -LiteralPath $deployment.Parameters).Path
    $values = (Get-Content -LiteralPath $deployment.Parameters -Raw | ConvertFrom-Json -AsHashtable).parameters
    $deployment.Values = $values
    if ($values.Contains('tenantId') -and $values.tenantId.value -ne $TenantId.ToString()) {
        throw 'The parameter-file tenant does not match -TenantId.'
    }
}
$infra = $deployments[0].Values
$config = $deployments[1].Values
foreach ($name in @('functionAppName', 'storageAccountName', 'keyVaultName', 'outboundIdentityName', 'preparationIdentityResourceId', 'tenantId', 'applicationId', 'tokenVersion', 'planType', 'contentShareName')) {
    if ($infra.Contains($name) -ne $config.Contains($name)) { throw "Set '$name' in both parameter files, or omit it in both to use ARM defaults." }
    if ($infra.Contains($name) -and $config.Contains($name) -and "$($infra[$name].value)" -cne "$($config[$name].value)") {
        throw "The two parameter files disagree on '$name'."
    }
}
$outboundName = if ($infra.Contains('outboundIdentityName')) { $infra.outboundIdentityName.value } else { "$($infra.functionAppName.value)-outbound" }
$runtimeIdentity = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$outboundName"
if ($infra.preparationIdentityResourceId.value -eq $runtimeIdentity) { throw 'Use a separate deployment identity, not the Function outbound identity.' }
if ($infra.Contains('existing') -and $infra.existing.value.Contains('userAssignedIdentities') -and
    $infra.existing.value.userAssignedIdentities.Contains($infra.preparationIdentityResourceId.value)) {
    throw 'The preparation identity must not be attached to the Function.'
}

az login --tenant $TenantId --output none
if ($LASTEXITCODE -ne 0) { throw 'Azure sign-in failed.' }
$selectedTenant = az account show --subscription $SubscriptionId --query tenantId --output tsv
if ($LASTEXITCODE -ne 0 -or "$selectedTenant".Trim() -ne $TenantId.ToString()) {
    throw 'The subscription is unavailable or belongs to a different tenant.'
}

foreach ($deployment in $deployments) {
    az deployment group create --subscription $SubscriptionId --resource-group $ResourceGroup `
        --template-file $deployment.Template --parameters "@$($deployment.Parameters)" `
        --mode Incremental --confirm-with-what-if --output json
    if ($LASTEXITCODE -ne 0) { throw "Deployment failed: $(Split-Path -Leaf $deployment.Template). Later steps were not run." }
}
