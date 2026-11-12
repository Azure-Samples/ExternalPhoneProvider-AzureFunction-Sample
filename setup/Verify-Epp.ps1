#Requires -Version 7.0
<#
.SYNOPSIS
    Verify existing EPP trust and certificate references and report supported update deltas.
.DESCRIPTION
    Download this file alone. Reads Azure and Graph metadata; never refreshes Key Vault
    references, creates certificates, modifies resources, or sends OTPs.
    Without a summary, guides Azure sign-in and discovers tagged endpoints in a selected
    subscription. Local reports and a recovered deployment summary are written on success.
#>
[CmdletBinding()]
param(
    [string] $DeploymentSummaryPath,
    [string] $TenantId,
    [string] $SubscriptionId,
    [string] $ResourceGroupName,
    [string] $FunctionAppName,
    [string] $KeyVaultSubscriptionId,
    [switch] $NonInteractive,
    [string] $PackageReleaseTag,
    [string] $OutputDirectory = (Join-Path $PSScriptRoot 'epp-output'),
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$')]
    [string] $SourceRepository = 'Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample',
    [string] $SourceRef = 'main',
    [switch] $PassThru
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$arguments = @{} + $PSBoundParameters
$arguments.OutputDirectory = $OutputDirectory
$arguments.SourceRepository = $SourceRepository
$revision = $SourceRef
if ($revision -notmatch '^[0-9a-fA-F]{40}$') {
    $commit = Invoke-RestMethod -Uri "https://api.github.com/repos/$SourceRepository/commits/$([Uri]::EscapeDataString($SourceRef))" `
        -Headers @{ 'User-Agent' = 'EPP-Maintenance'; Accept = 'application/vnd.github+json' } -TimeoutSec 60
    $revision = $commit.sha
}
if ($revision -notmatch '^[0-9a-fA-F]{40}$') { throw 'GitHub did not return a valid commit ID.' }
$arguments.SourceRef = $revision
$directory = Join-Path ([IO.Path]::GetTempPath()) "epp-verify-$([Guid]::NewGuid().ToString('N'))"
try {
    New-Item -ItemType Directory -Path $directory | Out-Null
    $launcher = Join-Path $directory 'Setup-Epp.ps1'
    Invoke-WebRequest -Uri "https://raw.githubusercontent.com/$SourceRepository/$revision/setup/Setup-Epp.ps1" `
        -OutFile $launcher -TimeoutSec 60 -MaximumRedirection 0
    & $launcher @arguments -Operation Verify
}
finally {
    if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force }
}
