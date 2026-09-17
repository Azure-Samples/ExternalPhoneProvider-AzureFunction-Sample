#Requires -Version 7.0
<#
.SYNOPSIS
    Download the EPP deployment tools, collect settings, and review one deployment plan.
.DESCRIPTION
    Download only this file. Supporting PowerShell, Bicep, and provider JSON files come from
    the selected public GitHub repository (Azure-Samples by default).
    Application registration and policy activation are manual steps.
    No Azure resources are changed until you approve the complete plan.
.PARAMETER SourceRepository
    Public GitHub owner/repository containing the setup files. Use with SourceRef to test a fork.
.PARAMETER PackageReleaseTag
    Optional stable epp-packages release tag. By default, setup uses the latest stable CI package release.
.PARAMETER InstallPrerequisites
    Install missing Microsoft Graph modules and the Azure CLI Bicep component after explicit opt-in.
.PARAMETER ForceAuthentication
    Require fresh tenant-specific device-code sign-in for Azure CLI and Microsoft Graph.
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
    [string] $Channel,
    [string] $EndpointRegion,
    [string] $ResourcePrefix,
    [string] $Language,
    [string] $OutputDirectory = (Join-Path $PSScriptRoot 'epp-output'),
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$')]
    [string] $SourceRepository = 'Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample',
    [string] $SourceRef = 'main',
    [string] $PackageReleaseTag,
    [switch] $NonInteractive,
    [switch] $InstallPrerequisites,
    [switch] $ForceAuthentication,
    [switch] $ApproveDeployment
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

    foreach ($file in @('support/Epp.Setup.psm1', 'support/Epp.Packages.ps1', 'providers/catalog.json', 'packages/catalog.json', 'infra/main.bicep', 'infra/resources.bicep')) {
        $destination = Join-Path $downloadDirectory $file
        New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
        Invoke-WebRequest -Uri "$sourceBaseUri/$file" -OutFile $destination -TimeoutSec 60 -MaximumRedirection 0
        if ((Get-Item -LiteralPath $destination).Length -eq 0) { throw "GitHub returned an empty file: $file" }
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
