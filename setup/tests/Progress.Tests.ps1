#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$module = Import-Module (Join-Path $PSScriptRoot '..\support\Epp.Setup.psm1') -Force -PassThru
$directory = Join-Path ([IO.Path]::GetTempPath()) "epp-progress-tests-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $directory | Out-Null
try {
    $fakeAz = Join-Path $directory 'fake-az.ps1'
    @'
param([Parameter(ValueFromRemainingArguments)][string[]] $Arguments)
Microsoft.PowerShell.Utility\Start-Sleep -Milliseconds 450
if ($Arguments[0] -eq 'throw') { throw 'simulated worker failure' }
$pwsh = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
if ($Arguments[0] -in @('failure', 'warning')) {
    $code = if ($Arguments[0] -eq 'failure') { 7 } else { 0 }
    & $pwsh -NoProfile -NonInteractive -Command "[Console]::Error.WriteLine('simulated CLI message https://contoso.invalid/?sig=private-signature Bearer private-token'); exit $code"
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
if ($Arguments[0] -ne 'empty') {
    @{ arguments = @($Arguments) } | ConvertTo-Json -Compress
}
exit 0
'@ | Set-Content -LiteralPath $fakeAz -Encoding utf8NoBOM
    $fakeCommand = $fakeAz
    if ($IsWindows) {
        $fakeCommand = Join-Path $directory 'fake az.cmd'
        "@echo off`r`n`"$PSHOME\pwsh.exe`" -NoProfile -NonInteractive -File `"%~dp0fake-az.ps1`" %*`r`nexit /b %errorlevel%" |
            Set-Content -LiteralPath $fakeCommand -Encoding ascii
    }

    & $module {
        param($FakeAz)

        function script:Assert($Condition, [string] $Message) {
            if (-not $Condition) { throw $Message }
        }
        function script:Assert-Throws([scriptblock] $Action, [string] $Pattern) {
            try { $null = & $Action }
            catch {
                Assert ($_.Exception.Message -match $Pattern) "Unexpected failure: $($_.Exception.Message)"
                Assert ($_.Exception.Message -notmatch 'private-signature|private-token') 'Do not disclose credentials in CLI errors.'
                return
            }
            throw "Expected failure matching '$Pattern'."
        }

        $ProgressPreference = 'SilentlyContinue'
        Assert (-not (Test-EppAnimationEnabled)) 'Honor disabled progress for unattended execution.'
        $ProgressPreference = 'Continue'
        if ([Console]::IsOutputRedirected) {
            Assert (-not (Test-EppAnimationEnabled)) 'Do not animate redirected output.'
        }
        $script:FakeAz = $FakeAz
        $script:Animate = $true
        $script:Messages = [Collections.Generic.List[string]]::new()
        $script:Warnings = [Collections.Generic.List[string]]::new()
        $script:ErrorPaths = [Collections.Generic.List[string]]::new()
        $script:Interrupt = $false
        function script:Test-EppAnimationEnabled { return $script:Animate }
        function script:Get-Command {
            param($Name, $CommandType, $ErrorAction)
            Assert ($Name -ceq 'az') 'Resolve only the Azure CLI command.'
            return @{ Source = $script:FakeAz }
        }
        function script:az {
            & $script:FakeAz @args
            $global:LASTEXITCODE = $LASTEXITCODE
        }
        function script:Get-Content {
            param($LiteralPath, [switch] $Raw)
            $script:ErrorPaths.Add($LiteralPath)
            Microsoft.PowerShell.Management\Get-Content -LiteralPath $LiteralPath -Raw:$Raw
        }
        function script:Write-Host {
            param([Parameter(ValueFromPipeline)] $Object, $ForegroundColor, [switch] $NoNewline)
            process { $script:Messages.Add([string]$Object) }
        }
        function script:Write-Warning { param($Message); $script:Warnings.Add($Message) }
        function script:Start-Sleep {
            param($Milliseconds)
            if ($script:Interrupt) { throw 'simulated cancellation' }
            Microsoft.PowerShell.Utility\Start-Sleep -Milliseconds $Milliseconds
        }

        foreach ($animate in @($true, $false)) {
            $script:Animate = $animate
            $script:Messages.Clear()
            $output = Invoke-EppAz -Activity 'Deploying Azure resources' success --parameters '@path with spaces & symbols.json' --output json
            $parsed = $output | ConvertFrom-Json
            Assert (($parsed.arguments -join '|') -ceq 'success|--parameters|@path with spaces & symbols.json|--output|json|--only-show-errors') 'Preserve CLI argument boundaries and unmodified JSON output.'
            $frames = @($script:Messages | Where-Object { $_ -match '^\r[|/\\-] Deploying Azure resources\.\.\.$' })
            if ($animate) {
                Assert ($frames.Count -ge 2 -and @($frames | Select-Object -Unique).Count -ge 2) 'Update the indicator while the command runs, not just once before it starts.'
                Assert ($script:Messages[-1] -match '^\r +\r$') 'Clear the indicator on success.'
            }
            else {
                Assert ($frames.Count -eq 0 -and $script:Messages.Count -eq 1 -and $script:Messages[0] -ceq 'Deploying Azure resources...') 'Use a single static status line for redirected or unattended output.'
            }
            Assert (($script:Messages -join "`n") -notmatch 'elapsed|remaining|\d+:\d+|%') 'Do not display elapsed time, a countdown, or invented percentages.'

            $script:Warnings.Clear()
            $output = Invoke-EppAz -Activity 'Deploying the Azure Function' warning
            Assert (($output | ConvertFrom-Json).arguments[0] -ceq 'warning') 'Warnings must not contaminate stdout.'
            Assert ($script:Warnings.Count -eq 1 -and $script:Warnings[0] -match '\[REDACTED\]' -and
                $script:Warnings[0] -notmatch 'private-signature|private-token') 'Keep CLI warnings visible and redact sensitive values.'
            Assert-Throws { Invoke-EppAz -Activity 'Deploying the Azure Function' failure --output none } 'failed \(exit 7\)'
            if ($animate) { Assert ($script:Messages[-1] -match '^\r +\r$') 'Clear the indicator on a CLI failure.' }
            Assert ([string]::IsNullOrEmpty((Invoke-EppAz -Activity 'Starting the Azure Function' empty))) 'Support successful commands with no stdout.'
        }
        $script:Animate = $true
        $script:Messages.Clear()
        $output = Invoke-EppAz success --output json
        Assert ((($output | ConvertFrom-Json).arguments -join '|') -ceq 'success|--output|json|--only-show-errors') 'An omitted activity must not consume any native CLI argument.'
        Assert ($script:Messages.Count -eq 0) 'Keep commands without an activity label quiet.'
        Assert-Throws { Invoke-EppAz -Activity 'Deploying Azure resources' throw } 'simulated worker failure'
        Assert ($script:Messages[-1] -match '^\r +\r$') 'Clear the indicator on a terminating worker error.'
        $script:Interrupt = $true
        Assert-Throws { Invoke-EppAz -Activity 'Deploying Azure resources' success } 'simulated cancellation'
        Assert ($script:Messages[-1] -match '^\r +\r$') 'Stop the worker and clear the indicator when interrupted.'
        foreach ($path in $script:ErrorPaths) {
            Assert (-not (Test-Path -LiteralPath $path)) 'Remove captured CLI stderr files after success or failure.'
        }
    } $fakeCommand
    Write-Host 'Deployment animation, argument preservation, stdout/stderr handling, redaction, failure, cancellation, and cleanup checks passed.'
}
finally {
    Remove-Module -ModuleInfo $module -Force
    Remove-Item -LiteralPath $directory -Recurse -Force
}
