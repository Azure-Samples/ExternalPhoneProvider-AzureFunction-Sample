#Requires -Version 7.4
<#
.SYNOPSIS
    Create new JavaScript EP1 origins behind Front Door using an existing EPP deployment as the source.
.DESCRIPTION
    Run from a reviewed repository checkout. The source Function, app registration, and authentication
    policy are not changed. Review the plan before approval. Verification and policy activation are separate.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][guid]$SubscriptionId,
    [Parameter(Mandatory)][guid]$TenantId,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_.()-]+$')][string]$SourceResourceGroup,
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9-]+$')][string]$SourceFunctionApp,
    [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9]{2,9}$')][string]$ResourcePrefix,
    [Parameter(Mandatory)][ValidateCount(2, 3)][string[]]$Locations,
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'frontdoor-output'),
    [switch]$EvaluationOnly,
    [switch]$ApproveDeployment,
    [switch]$NonInteractive
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'support/Epp.FrontDoor.psm1') -Force
Invoke-EppFrontDoor @PSBoundParameters -AssetDirectory $PSScriptRoot
