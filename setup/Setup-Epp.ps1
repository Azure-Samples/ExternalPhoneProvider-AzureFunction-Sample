#Requires -Version 7.0
<#
.SYNOPSIS
    Download the EPP deployment tools, collect settings, and review one deployment plan.
.DESCRIPTION
    Download only this file. Supporting PowerShell, Bicep, and provider JSON files come from
    the selected public GitHub repository (Azure-Samples by default).
    Microsoft Graph operations reuse the Azure CLI user session through az ad and az rest.
    Interactive setup can select cached tenants, subscriptions, applications, and Azure regions.
    The endpoint supports SMS and voice, selected by each request.
    Application registration and policy activation are manual steps.
    No Azure resources are changed until you approve the complete plan.
.PARAMETER SourceRepository
    Public GitHub owner/repository containing the setup files. Use with SourceRef to test a fork.
.PARAMETER PackageReleaseTag
    Optional stable epp-packages release tag. By default, setup uses the latest stable CI package release.
.PARAMETER ServicePlan
    FC1 for Flex Consumption with a free usage grant, or EP1 for Premium with a warm instance.
    Prompts when omitted; required for unattended setup.
.PARAMETER InstallPrerequisites
    Install the Azure CLI Bicep component after explicit opt-in. The Graph SDK is not required.
.PARAMETER ForceAuthentication
    Require fresh tenant-specific Azure CLI device-code sign-in. Graph reuses that CLI session.
.PARAMETER PassThru
    Return the structured deployment result in addition to console output. The summary JSON is
    saved whether or not this switch is supplied.
.PARAMETER CertificateAction
    Create when no encryption certificate is registered, Reuse a selected certificate, or Replace
    all registered encryption certificates. Existing certificates require an explicit choice.
.PARAMETER EncryptionKeyId
    App-registration key ID to keep when reusing a certificate. Required for unattended reuse.
.PARAMETER KeyVaultCertificateId
    Versioned Key Vault certificate URL for reuse, not a public certificate file or secret value.
.PARAMETER KeyVaultSubscriptionId
    Subscription containing the reused certificate's vault. Defaults to the deployment subscription.
.EXAMPLE
    .\Setup-Epp.ps1
.EXAMPLE
    .\Setup-Epp.ps1 -TenantId <tenant-id> -SubscriptionId <subscription-id> -ApplicationId <client-id>
#>
[CmdletBinding()]
param(
    [string] $TenantId,
    [string] $SubscriptionId,
    [string] $ApplicationId,
    [string] $Location,
    [string] $Provider,
    [string] $EndpointRegion,
    [string] $ResourcePrefix,
    [string] $Language,
    [string] $ServicePlan,
    [ValidateSet('Create', 'Reuse', 'Replace')]
    [string] $CertificateAction,
    [string] $EncryptionKeyId,
    [string] $KeyVaultCertificateId,
    [string] $KeyVaultSubscriptionId,
    [string] $OutputDirectory = (Join-Path $PSScriptRoot 'epp-output'),
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$')]
    [string] $SourceRepository = 'Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample',
    [string] $SourceRef = 'main',
    [string] $PackageReleaseTag,
    [switch] $NonInteractive,
    [switch] $InstallPrerequisites,
    [switch] $ForceAuthentication,
    [switch] $ApproveDeployment,
    [switch] $PassThru
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repository = $SourceRepository
$arguments = @{} + $PSBoundParameters
$arguments.Remove('SourceRef')
$arguments.OutputDirectory = $OutputDirectory
$arguments.SourceRepository = $SourceRepository
$downloadDirectory = Join-Path ([IO.Path]::GetTempPath()) "epp-download-$([Guid]::NewGuid().ToString('N'))"
$module = $null

try {
    # Resolve once so a branch update cannot mix scripts, templates, and provider profiles.
    $revision = $SourceRef
    if ($revision -notmatch '^[0-9a-fA-F]{40}$') {
        $commit = Invoke-RestMethod -Uri "https://api.github.com/repos/$repository/commits/$([Uri]::EscapeDataString($SourceRef))" `
            -Headers @{ 'User-Agent' = 'EPP-Setup'; Accept = 'application/vnd.github+json' } -TimeoutSec 60
        $revision = $commit.sha
    }
    if ($revision -notmatch '^[0-9a-fA-F]{40}$') { throw 'GitHub did not return a valid commit ID.' }
    $sourceBaseUri = "https://raw.githubusercontent.com/$repository/$revision/setup"
    Write-Host "Downloading deployment tools from $repository at $revision"

    foreach ($file in @('support/Epp.Setup.psm1', 'support/Epp.Packages.ps1', 'support/Epp.Graph.ps1', 'providers/catalog.json', 'packages/catalog.json', 'infra/main.bicep', 'infra/resources.bicep')) {
        $destination = Join-Path $downloadDirectory $file
        New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
        Invoke-WebRequest -Uri "$sourceBaseUri/$file" -OutFile $destination -TimeoutSec 60 -MaximumRedirection 0
        if ((Get-Item -LiteralPath $destination).Length -eq 0) { throw "GitHub returned an empty file: $file" }
    }

    $providerCatalog = Get-Content -LiteralPath (Join-Path $downloadDirectory 'providers/catalog.json') -Raw |
        ConvertFrom-Json -ErrorAction Stop
    if ($providerCatalog.schemaVersion -ne 1 -or -not @($providerCatalog.providers).Count) {
        throw 'The downloaded provider catalog is unsupported or empty.'
    }
    $providerFiles = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($providerEntry in @($providerCatalog.providers)) {
        $file = [string]$providerEntry.file
        if ($file -cnotmatch '^[a-z][a-z0-9-]{1,31}\.json$' -or -not $providerFiles.Add($file)) {
            throw 'The downloaded provider catalog contains an invalid or duplicate file.'
        }
        $relativePath = "providers/$file"
        $destination = Join-Path $downloadDirectory $relativePath
        Invoke-WebRequest -Uri "$sourceBaseUri/$relativePath" -OutFile $destination -TimeoutSec 60 -MaximumRedirection 0
        if ((Get-Item -LiteralPath $destination).Length -eq 0) { throw "GitHub returned an empty file: $relativePath" }
    }

    $module = Import-Module (Join-Path $downloadDirectory 'support/Epp.Setup.psm1') -PassThru -Force
    Invoke-EppSetup @arguments -AssetDirectory $downloadDirectory -SourceBaseUri $sourceBaseUri
}
finally {
    try {
        if ($module) { Remove-Module -ModuleInfo $module -ErrorAction Stop }
    }
    catch {
        Write-Warning "Could not unload the temporary EPP helper: $($_.Exception.Message)" -WarningAction Continue
    }
    try {
        if (Test-Path -LiteralPath $downloadDirectory) {
            Remove-Item -LiteralPath $downloadDirectory -Recurse -Force -ErrorAction Stop
        }
    }
    catch {
        Write-Warning "Could not remove temporary downloads at '$downloadDirectory': $($_.Exception.Message)" -WarningAction Continue
    }
}
