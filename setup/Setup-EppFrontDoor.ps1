#Requires -Version 7.4
<#
.SYNOPSIS
    Create new JavaScript EP1 origins behind Front Door using an existing EPP deployment as the source.
.DESCRIPTION
    Run from a reviewed repository checkout. The source Function, app registration, and authentication
    policy are not changed. Review the plan before approval. Use -Verify to test an existing expansion
    without deploying resources. Policy activation remains manual.
.EXAMPLE
    .\Setup-EppFrontDoor.ps1 -Verify -OutputDirectory .\frontdoor-output -AccessToken $token
#>
[CmdletBinding(DefaultParameterSetName = 'Deploy')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Deploy')][guid]$SubscriptionId,
    [Parameter(Mandatory, ParameterSetName = 'Deploy')][guid]$TenantId,
    [Parameter(Mandatory, ParameterSetName = 'Deploy')][ValidatePattern('^[A-Za-z0-9_.()-]+$')][string]$SourceResourceGroup,
    [Parameter(Mandatory, ParameterSetName = 'Deploy')][ValidatePattern('^[a-zA-Z0-9-]+$')][string]$SourceFunctionApp,
    [Parameter(Mandatory, ParameterSetName = 'Deploy')][ValidatePattern('^[a-z][a-z0-9]{2,9}$')][string]$ResourcePrefix,
    [Parameter(Mandatory, ParameterSetName = 'Deploy')][ValidateCount(2, 3)][string[]]$Locations,
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'frontdoor-output'),
    [Parameter(ParameterSetName = 'Deploy')][switch]$EvaluationOnly,
    [Parameter(ParameterSetName = 'Deploy')][switch]$ApproveDeployment,
    [Parameter(ParameterSetName = 'Deploy')][switch]$NonInteractive,
    [Parameter(Mandatory, ParameterSetName = 'Verify')][switch]$Verify,
    [Parameter(Mandatory, ParameterSetName = 'Verify')][Security.SecureString]$AccessToken
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'support/Epp.FrontDoor.psm1') -Force
if ($PSCmdlet.ParameterSetName -eq 'Verify') {
    Test-EppFrontDoor -OutputDirectory $OutputDirectory -AccessToken $AccessToken
} else {
    Invoke-EppFrontDoor @PSBoundParameters -AssetDirectory $PSScriptRoot
}
