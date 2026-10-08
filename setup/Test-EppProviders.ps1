#Requires -Version 7.0
<#
.SYNOPSIS
    Validate multiple local setup provider profiles without network or credential access.
.DESCRIPTION
    Writes one JSON report. Exits 0 only when every selected provider configuration is valid;
    otherwise exits 1. This does not test provider credentials, entitlement, or delivery.
.EXAMPLE
    .\Test-EppProviders.ps1 -Provider telesign,soprano -Channel sms -EndpointRegion global
#>
[CmdletBinding()]
param(
    [AllowEmptyCollection()] [AllowEmptyString()] [string[]] $Provider = @(),
    [string] $Channel,
    [string] $EndpointRegion,
    [string] $ProfileDirectory = (Join-Path $PSScriptRoot 'providers')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$module = Import-Module (Join-Path $PSScriptRoot 'support/Epp.Setup.psm1') -PassThru -Force
try {
    $report = Test-EppProviderConfiguration -Provider $Provider -Channel $Channel `
        -EndpointRegion $EndpointRegion -ProfileDirectory $ProfileDirectory
    $report | ConvertTo-Json -Depth 6
    if (-not $report.Valid) { exit 1 }
}
finally {
    Remove-Module -ModuleInfo $module
}
exit 0
