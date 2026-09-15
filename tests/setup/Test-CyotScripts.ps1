#Requires -Version 7.0

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$setupDirectory = Join-Path $PSScriptRoot '..\..\setup\cyot'
$scriptNames = @(
    'Step1-Register-CyotApplication.ps1'
    'Step2-Setup-ExternalPhoneProvider.ps1'
    'Step3-Set-CyotPolicy.ps1'
)
$scriptAsts = @{}

foreach ($name in $scriptNames) {
    $path = (Resolve-Path -LiteralPath (Join-Path $setupDirectory $name)).Path
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $path, [ref] $tokens, [ref] $parseErrors)
    if ($parseErrors.Count) {
        $details = $parseErrors | ForEach-Object {
            "Line $($_.Extent.StartLineNumber): $($_.Message)"
        }
        throw "PowerShell syntax errors in ${name}:`n$($details -join "`n")"
    }

    $commands = $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst]
    }, $true)
    foreach ($command in $commands) {
        if ($command.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Dot -or
            $command.GetCommandName() -match '\.ps1$') {
            throw "$name must remain standalone; found a script import/invocation at line $($command.Extent.StartLineNumber)."
        }
    }

    Write-Host "${name}: syntax and standalone-import checks passed."
    $scriptAsts[$name] = $ast
}

& (Join-Path $PSScriptRoot 'Test-CyotBehavior.ps1') -ScriptAsts $scriptAsts
