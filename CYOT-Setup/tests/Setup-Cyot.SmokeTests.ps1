#Requires -Version 7.0

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$packageRoot = Split-Path -Parent $PSScriptRoot
$entryPoint = Join-Path $packageRoot 'Setup-Cyot.ps1'
$failures = [Collections.Generic.List[string]]::new()

function Invoke-TestProcess {
    param([string[]] $Arguments)

    $output = & (Get-Command pwsh -ErrorAction Stop).Source -NoProfile -File $entryPoint @Arguments 2>&1 | Out-String
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
}

function Test-Condition {
    param([string] $Name, [bool] $Condition, [string] $Detail)

    if ($Condition) {
        Write-Host "PASS: $Name" -ForegroundColor Green
        return
    }
    $failures.Add("${Name}: $Detail")
    Write-Host "FAIL: $Name - $Detail" -ForegroundColor Red
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) "cyot-smoke-$([Guid]::NewGuid().ToString('N'))"
try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

    $diagnostics = Invoke-TestProcess -Arguments @('-Stage', 'Diagnostics', '-StatePath', (Join-Path $testRoot 'diagnostics-state.json'))
    Test-Condition 'Diagnostics completes locally' ($diagnostics.ExitCode -eq 0 -and $diagnostics.Output -match 'Diagnostics completed') $diagnostics.Output

    $invalidConfigPath = Join-Path $testRoot 'invalid.json'
    [IO.File]::WriteAllText($invalidConfigPath, '{ invalid json', [Text.UTF8Encoding]::new($false))
    $invalidConfig = Invoke-TestProcess -Arguments @('-Stage', 'Diagnostics', '-ConfigPath', $invalidConfigPath, '-StatePath', (Join-Path $testRoot 'invalid-state.json'))
    Test-Condition 'Invalid JSON is rejected' ($invalidConfig.ExitCode -ne 0 -and $invalidConfig.Output -match 'JSON') $invalidConfig.Output

    $activationStatePath = Join-Path $testRoot 'activation-state.json'
    @{
        schemaVersion = 1; updatedAtUtc = [DateTime]::UtcNow.ToString('o')
        tenantId = '11111111-1111-1111-1111-111111111111'
        applicationId = '22222222-2222-2222-2222-222222222222'
        endpointUrl = 'https://example.com/api/SendOtp'
        graphSchemaSupported = $true; policyUpdated = $false
        completedStages = @('Register', 'Deploy', 'Validate')
    } | ConvertTo-Json | Set-Content -LiteralPath $activationStatePath -Encoding utf8NoBOM
    $activation = Invoke-TestProcess -Arguments @('-Stage', 'Activate', '-NonInteractive', '-StatePath', $activationStatePath)
    Test-Condition 'Noninteractive activation requires explicit approval' `
        ($activation.ExitCode -ne 0 -and $activation.Output -match 'requires -ApprovePolicyActivation') $activation.Output

    $temporaryPackage = Join-Path $testRoot 'package'
    New-Item -ItemType Directory -Path (Join-Path $temporaryPackage 'stages') -Force | Out-Null
    Copy-Item -LiteralPath $entryPoint -Destination (Join-Path $temporaryPackage 'Setup-Cyot.ps1')
    $temporaryEntryPoint = Join-Path $temporaryPackage 'Setup-Cyot.ps1'
    $entryPoint = $temporaryEntryPoint

    $missingStage = Invoke-TestProcess -Arguments @('-Stage', 'Register', '-NonInteractive', '-StatePath', (Join-Path $testRoot 'missing-stage-state.json'))
    Test-Condition 'Missing stage is reported before execution' `
        ($missingStage.ExitCode -ne 0 -and $missingStage.Output -match 'Packaged Register stage script is missing') $missingStage.Output

    @'
[CmdletBinding()]
param([string] $TenantId, [string] $ApplicationId, [string] $DisplayName, [switch] $NonInteractive, [switch] $SkipAzureLogin, [string] $LogDirectory)
'33333333-3333-3333-3333-333333333333'
'@ | Set-Content -LiteralPath (Join-Path $temporaryPackage 'stages/Step1-Register-CyotApplication.ps1') -Encoding utf8NoBOM
    $configPath = Join-Path $testRoot 'customer.json'
    @{ setup = @{ tenantId = '11111111-1111-1111-1111-111111111111' }; registration = @{ skipAzureLogin = $true } } |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $configPath -Encoding utf8NoBOM
    $statePath = Join-Path $testRoot 'state/cyot.json'
    $registration = Invoke-TestProcess -Arguments @('-Stage', 'Register', '-NonInteractive', '-ConfigPath', $configPath, '-StatePath', $statePath)
    $state = if (Test-Path -LiteralPath $statePath) { Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json } else { $null }
    Test-Condition 'Registration output is normalized and state is saved' `
        ($registration.ExitCode -eq 0 -and $state.applicationId -eq '33333333-3333-3333-3333-333333333333' -and $state.completedStages -contains 'Register') $registration.Output

    @'
[CmdletBinding()]
param([string] $SubscriptionId, [string] $ResourceGroup, [string] $Location, [string] $EnvironmentName, [string] $PlanType, [switch] $NonInteractive)
[pscustomobject]@{
    Stage = 'Infrastructure'; SubscriptionId = $SubscriptionId; ResourceGroup = $ResourceGroup; Location = $Location
    PlanType = $PlanType; FunctionAppName = 'cyot-prod-func-test'; StorageAccountName = 'cyotprodstoragetest'; KeyVaultName = 'cyot-prod-kv-test'
}
'@ | Set-Content -LiteralPath (Join-Path $temporaryPackage 'stages/Deploy-CyotInfrastructure.ps1') -Encoding utf8NoBOM
    @'
[CmdletBinding()]
param([string] $ApplicationId, [string] $LogDirectory, [string] $SubscriptionId, [string] $ResourceGroup, [string] $Location,
      [string] $FunctionAppName, [string] $StorageAccountName, [string] $KeyVaultName, [string] $PlanType, [switch] $NonInteractive)
[pscustomobject]@{
    Stage = 2; TenantId = '11111111-1111-1111-1111-111111111111'; EndpointUrl = "https://$FunctionAppName.azurewebsites.net/api/SendOtp"
    ApplicationId = $ApplicationId; IdentifierUri = "api://$ApplicationId"; EncryptionKeyId = 'test-key'; CertThumbprint = 'TEST'
}
'@ | Set-Content -LiteralPath (Join-Path $temporaryPackage 'stages/Step2-Setup-ExternalPhoneProvider.ps1') -Encoding utf8NoBOM
    $bicepConfigPath = Join-Path $testRoot 'bicep.json'
    @{
        endpoint = @{
            infrastructureMode = 'Bicep'; subscriptionId = '44444444-4444-4444-4444-444444444444'
            resourceGroup = 'rg-cyot-test'; location = 'eastus'; environmentName = 'prod'; planType = 'Premium'
        }
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $bicepConfigPath -Encoding utf8NoBOM
    $bicepStatePath = Join-Path $testRoot 'bicep-state.json'
    @{
        schemaVersion = 1; updatedAtUtc = [DateTime]::UtcNow.ToString('o')
        applicationId = '33333333-3333-3333-3333-333333333333'; completedStages = @('Register')
    } | ConvertTo-Json | Set-Content -LiteralPath $bicepStatePath -Encoding utf8NoBOM
    $bicepDeploy = Invoke-TestProcess -Arguments @('-Stage', 'Deploy', '-NonInteractive', '-ConfigPath', $bicepConfigPath, '-StatePath', $bicepStatePath)
    $bicepState = if (Test-Path -LiteralPath $bicepStatePath) { Get-Content -LiteralPath $bicepStatePath -Raw | ConvertFrom-Json } else { $null }
    Test-Condition 'Bicep outputs are forwarded and persisted for resume' `
        ($bicepDeploy.ExitCode -eq 0 -and $bicepState.functionAppName -eq 'cyot-prod-func-test' -and
            $bicepState.storageAccountName -eq 'cyotprodstoragetest' -and $bicepState.keyVaultName -eq 'cyot-prod-kv-test' -and
            $bicepState.planType -eq 'Premium' -and $bicepState.completedStages -contains 'Deploy') $bicepDeploy.Output

    Remove-Item -LiteralPath (Join-Path $temporaryPackage 'stages/Step2-Setup-ExternalPhoneProvider.ps1') -Force
    $resumeStatePath = Join-Path $testRoot 'resume-state.json'
    @{
        schemaVersion = 1; updatedAtUtc = [DateTime]::UtcNow.ToString('o')
        tenantId = '11111111-1111-1111-1111-111111111111'
        applicationId = '33333333-3333-3333-3333-333333333333'
        completedStages = @('Register')
    } | ConvertTo-Json | Set-Content -LiteralPath $resumeStatePath -Encoding utf8NoBOM
    $resume = Invoke-TestProcess -Arguments @('-Resume', '-NonInteractive', '-StatePath', $resumeStatePath)
    Test-Condition 'Resume starts with the first incomplete stage' `
        ($resume.ExitCode -ne 0 -and $resume.Output -match 'Packaged Deploy stage script is missing' -and $resume.Output -notmatch 'Packaged Register stage script is missing') $resume.Output
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count) {
    throw "Smoke tests failed:`n$($failures -join "`n")"
}
Write-Host 'All CYOT setup smoke tests passed.' -ForegroundColor Green
exit 0