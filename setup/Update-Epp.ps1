#Requires -Version 7.0
<#
.SYNOPSIS
    Preview or explicitly apply supported updates to an existing EPP endpoint.
.DESCRIPTION
    Download this file alone. Uses commit-pinned setup helpers, not the provisioning workflow.
    Requires a completed or recovered deployment summary and an existing Azure CLI user login.
    Run Verify-Epp.ps1 without a summary to discover and verify an existing deployment first.
    Preview is the default. Apply never creates certificates or changes application trust.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $DeploymentSummaryPath,
    [ValidateSet('All', 'Code', 'Configuration', 'Infrastructure')]
    [string] $UpdateScope = 'All',
    [switch] $Apply,
    [hashtable] $ProviderEnvironment,
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
$directory = Join-Path ([IO.Path]::GetTempPath()) "epp-update-$([Guid]::NewGuid().ToString('N'))"
try {
    New-Item -ItemType Directory -Path $directory | Out-Null
    $launcher = Join-Path $directory 'Setup-Epp.ps1'
    Invoke-WebRequest -Uri "https://raw.githubusercontent.com/$SourceRepository/$revision/setup/Setup-Epp.ps1" `
        -OutFile $launcher -TimeoutSec 60 -MaximumRedirection 0
    & $launcher @arguments -Operation Update
}
finally {
    if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force }
}
