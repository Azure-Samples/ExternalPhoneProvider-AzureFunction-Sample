#Requires -Version 7.0

<#
> **Produced by:** GitHub Copilot | **Session:** S0915a

.SYNOPSIS
    Guided setup for Custom OTP (CYOT) with Microsoft Entra ID.

.DESCRIPTION
    Runs application registration, endpoint setup, validation, and policy activation as one guided
    experience. Each stage remains independently rerunnable. Progress is written atomically to a
    local state file so an interrupted setup can resume without storing credentials or access tokens.

    Policy activation remains a separate safety gate. The live Microsoft Graph metadata contract is
    checked before policy permissions are requested or a write is attempted.

.PARAMETER Stage
    Stage to run. Omit for the guided menu. All runs Register, Deploy, Validate, then Activate.

.PARAMETER Resume
    Continue with the first incomplete stage recorded in the state file.

.PARAMETER ConfigPath
    Optional JSON configuration file. Values supplied as parameters or collected by stage scripts
    take precedence over omitted configuration values.

.PARAMETER StatePath
    Progress file. Defaults to state/cyot-setup-state.json beside this script.

.PARAMETER NonInteractive
    Do not display the setup menu or allow stage scripts to request missing values.

.PARAMETER ApprovePolicyActivation
    Explicitly authorizes policy activation in noninteractive mode. This does not bypass Graph schema,
    concurrency, backup, or readback safeguards.

.EXAMPLE
    .\Setup-Cyot.ps1

.EXAMPLE
    .\Setup-Cyot.ps1 -Resume

.EXAMPLE
    .\Setup-Cyot.ps1 -NonInteractive -ConfigPath .\customer-config.json
#>
[CmdletBinding()]
param(
    [ValidateSet('All', 'Register', 'Deploy', 'Validate', 'Activate', 'Diagnostics')]
    [string] $Stage,

    [switch] $Resume,

    [string] $ConfigPath,

    [string] $StatePath = (Join-Path $PSScriptRoot 'state/cyot-setup-state.json'),

    [switch] $NonInteractive,

    [switch] $ApprovePolicyActivation
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:PackageRoot = $PSScriptRoot
$script:StageDirectory = Join-Path $PSScriptRoot 'stages'
$script:LogDirectory = Join-Path $PSScriptRoot 'logs'
$script:PolicyBackupDirectory = Join-Path $PSScriptRoot 'policy-backups'
$script:StageScripts = @{
    Register = Join-Path $script:StageDirectory 'Step1-Register-CyotApplication.ps1'
    Infrastructure = Join-Path $script:StageDirectory 'Deploy-CyotInfrastructure.ps1'
    Deploy   = Join-Path $script:StageDirectory 'Step2-Setup-ExternalPhoneProvider.ps1'
    Activate = Join-Path $script:StageDirectory 'Step3-Set-CyotPolicy.ps1'
}
$script:StageOrder = @('Register', 'Deploy', 'Validate', 'Activate')
$script:EventLogPath = $null

function Protect-CyotLogText {
    param([AllowEmptyString()][string] $Text)

    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $safeText = $Text -replace '(?i)(Authorization\s*[:=]\s*Bearer\s+)[^\s,;]+', '$1[REDACTED]'
    $safeText = $safeText -replace '(?i)([?&](?:sig|token|code|client_secret|password)=)[^&\s]+', '$1[REDACTED]'
    return $safeText
}

function Write-CyotEvent {
    param(
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string] $Level,
        [string] $Message
    )

    $safeMessage = Protect-CyotLogText -Text $Message
    $entry = '{0:o} [{1}] {2}' -f [DateTimeOffset]::Now, $Level, $safeMessage
    Add-Content -LiteralPath $script:EventLogPath -Value $entry -Encoding utf8
    Write-Host $entry -ForegroundColor ($Level -eq 'ERROR' ? 'Red' : ($Level -eq 'WARN' ? 'Yellow' : 'DarkGray'))
}

function Initialize-CyotWorkspace {
    foreach ($directory in @($script:LogDirectory, (Split-Path -Parent $StatePath), $script:PolicyBackupDirectory)) {
        if (-not [string]::IsNullOrWhiteSpace($directory)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }
    }
    $script:EventLogPath = Join-Path $script:LogDirectory "setup-cyot-$([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))-$PID.log"
    New-Item -ItemType File -Path $script:EventLogPath -Force | Out-Null
}

function ConvertTo-CyotHashtable {
    param($InputObject)

    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [Collections.IDictionary]) {
        $dictionary = @{}
        foreach ($key in $InputObject.Keys) { $dictionary[$key] = ConvertTo-CyotHashtable $InputObject[$key] }
        return $dictionary
    }
    if ($InputObject -is [Management.Automation.PSCustomObject]) {
        $dictionary = @{}
        foreach ($property in $InputObject.PSObject.Properties) {
            $dictionary[$property.Name] = ConvertTo-CyotHashtable $property.Value
        }
        return $dictionary
    }
    if ($InputObject -is [Collections.IEnumerable] -and $InputObject -isnot [string]) {
        return @($InputObject | ForEach-Object { ConvertTo-CyotHashtable $_ })
    }
    return $InputObject
}

function Read-CyotConfig {
    if ([string]::IsNullOrWhiteSpace($ConfigPath)) { return @{} }
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "Configuration file not found: $ConfigPath"
    }
    $resolvedPath = (Resolve-Path -LiteralPath $ConfigPath).Path
    Write-CyotEvent -Level INFO -Message "Loading configuration from $resolvedPath."
    return ConvertTo-CyotHashtable (Get-Content -LiteralPath $resolvedPath -Raw | ConvertFrom-Json)
}

function New-CyotState {
    return [ordered]@{
        schemaVersion   = 1
        updatedAtUtc    = [DateTime]::UtcNow.ToString('o')
        tenantId        = $null
        applicationId   = $null
        subscriptionId  = $null
        resourceGroup   = $null
        functionAppName = $null
        endpointUrl     = $null
        identifierUri   = $null
        encryptionKeyId = $null
        certThumbprint  = $null
        policyUpdated   = $false
        completedStages = @()
    }
}

function Read-CyotState {
    if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) { return New-CyotState }
    try {
        $state = ConvertTo-CyotHashtable (Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json)
        if ($state.schemaVersion -ne 1) { throw "Unsupported state schema version '$($state.schemaVersion)'." }
        $state.completedStages = @($state.completedStages)
        return $state
    }
    catch {
        throw "Could not read state file '$StatePath'. $($_.Exception.Message)"
    }
}

function Save-CyotState {
    param([Collections.IDictionary] $State)

    $State.updatedAtUtc = [DateTime]::UtcNow.ToString('o')
    $stateDirectory = Split-Path -Parent $StatePath
    $temporaryPath = Join-Path $stateDirectory ".cyot-state-$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        $json = ConvertTo-Json -InputObject $State -Depth 10
        [IO.File]::WriteAllText($temporaryPath, $json, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporaryPath -Destination $StatePath -Force
    }
    finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-CyotValue {
    param(
        [Collections.IDictionary] $Config,
        [Collections.IDictionary] $State,
        [string] $Name,
        [string] $StateName = $Name
    )

    foreach ($sectionName in @('setup', 'registration', 'endpoint', 'activation')) {
        if ($Config.Contains($sectionName) -and $Config[$sectionName] -is [Collections.IDictionary] -and
            $Config[$sectionName].Contains($Name) -and $null -ne $Config[$sectionName][$Name]) {
            return $Config[$sectionName][$Name]
        }
    }
    if ($Config.Contains($Name) -and $null -ne $Config[$Name]) { return $Config[$Name] }
    if ($State.Contains($StateName) -and $null -ne $State[$StateName]) { return $State[$StateName] }
    return $null
}

function Add-CyotArgument {
    param([hashtable] $Arguments, [string] $Name, $Value)

    if ($null -eq $Value) { return }
    if ($Value -is [string] -and [string]::IsNullOrWhiteSpace($Value)) { return }
    $Arguments[$Name] = $Value
}

function Assert-CyotStageScript {
    param([string] $Name)

    $path = $script:StageScripts[$Name]
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Packaged $Name stage script is missing: $path"
    }
    return $path
}

function Complete-CyotStage {
    param([Collections.IDictionary] $State, [string] $Name)

    if ($State.completedStages -notcontains $Name) {
        $State.completedStages = @($State.completedStages) + $Name
    }
    Save-CyotState -State $State
    Write-CyotEvent -Level INFO -Message "$Name stage completed. State saved to $StatePath."
}

function Invoke-CyotRegister {
    param([Collections.IDictionary] $Config, [Collections.IDictionary] $State)

    $arguments = @{ LogDirectory = $script:LogDirectory }
    Add-CyotArgument $arguments TenantId (Get-CyotValue $Config $State TenantId tenantId)
    Add-CyotArgument $arguments ApplicationId (Get-CyotValue $Config $State ApplicationId applicationId)
    Add-CyotArgument $arguments DisplayName (Get-CyotValue $Config $State DisplayName)
    if ($NonInteractive) { $arguments.NonInteractive = $true }
    if ((Get-CyotValue $Config $State SkipAzureLogin) -eq $true) { $arguments.SkipAzureLogin = $true }

    Write-CyotEvent -Level INFO -Message 'Starting application registration stage.'
    $outputs = @(& (Assert-CyotStageScript Register) @arguments)
    $applicationId = @($outputs | Where-Object { $_ -is [string] -and $_ -match '^[0-9a-fA-F-]{36}$' }) | Select-Object -Last 1
    if ([string]::IsNullOrWhiteSpace($applicationId)) {
        throw 'Registration stage did not return an application client ID.'
    }
    $State.applicationId = $applicationId
    $tenantId = Get-CyotValue $Config $State TenantId tenantId
    if ($tenantId) { $State.tenantId = $tenantId }
    Complete-CyotStage $State Register
}

function Invoke-CyotDeploy {
    param([Collections.IDictionary] $Config, [Collections.IDictionary] $State)

    if ([string]::IsNullOrWhiteSpace($State.applicationId)) {
        throw 'Deploy requires applicationId. Run the Register stage first.'
    }

    $infrastructureMode = Get-CyotValue $Config $State InfrastructureMode
    $infrastructureResult = $null
    if ($infrastructureMode -eq 'Bicep' -and [string]::IsNullOrWhiteSpace((Get-CyotValue $Config $State EndpointUrl endpointUrl))) {
        $infrastructureArguments = @{}
        foreach ($name in @('SubscriptionId', 'ResourceGroup', 'Location', 'EnvironmentName', 'ResourceTagName', 'ResourceTagValue', 'PlanType')) {
            Add-CyotArgument $infrastructureArguments $name (Get-CyotValue $Config $State $name)
        }
        if ($NonInteractive) { $infrastructureArguments.NonInteractive = $true }

        Write-CyotEvent -Level INFO -Message 'Starting Bicep infrastructure deployment.'
        $infrastructureOutputs = @(& (Assert-CyotStageScript Infrastructure) @infrastructureArguments)
        $infrastructureResult = $infrastructureOutputs |
            Where-Object { $_.PSObject.Properties['Stage'] -and $_.Stage -eq 'Infrastructure' } |
            Select-Object -Last 1
        if ($null -eq $infrastructureResult) {
            throw 'Bicep infrastructure deployment did not return its stage result.'
        }
    }

    $arguments = @{ ApplicationId = $State.applicationId; LogDirectory = $script:LogDirectory }
    $parameterNames = @(
        'FunctionAppName', 'EndpointUrl', 'SubscriptionId', 'ResourceGroup', 'Location',
        'StorageAccountName', 'KeyVaultName', 'ResourceTagName', 'ResourceTagValue', 'PlanType',
        'ZipUrl', 'ZipPath', 'FunctionRoute', 'DisplayName', 'CertificatePath', 'ProviderName',
        'ProviderEndpoint', 'ProviderTimeoutMs', 'ProviderRetryIntervalMs', 'ProviderAccountName',
        'TenantId', 'ProviderTenantId', 'ProviderScope', 'OutboundIdentityName', 'StartFromStep'
    )
    foreach ($name in $parameterNames) { Add-CyotArgument $arguments $name (Get-CyotValue $Config $State $name) }
    if ($null -ne $infrastructureResult) {
        foreach ($name in @('FunctionAppName', 'StorageAccountName', 'KeyVaultName', 'ResourceGroup', 'Location', 'PlanType')) {
            $arguments[$name] = $infrastructureResult.$name
        }
    }
    foreach ($switchName in @('NoEasyAuth', 'UseWindowsBroker')) {
        if ((Get-CyotValue $Config $State $switchName) -eq $true) { $arguments[$switchName] = $true }
    }
    if ($NonInteractive) { $arguments.NonInteractive = $true }

    Write-CyotEvent -Level INFO -Message 'Starting endpoint deployment/configuration stage.'
    $outputs = @(& (Assert-CyotStageScript Deploy) @arguments)
    $result = $outputs | Where-Object { $_.PSObject.Properties['Stage'] -and $_.Stage -eq 2 } | Select-Object -Last 1
    if ($null -eq $result) { throw 'Deploy stage did not return its stage result.' }
    foreach ($mapping in @{
            TenantId = 'tenantId'; EndpointUrl = 'endpointUrl'; ApplicationId = 'applicationId';
            IdentifierUri = 'identifierUri'; EncryptionKeyId = 'encryptionKeyId'; CertThumbprint = 'certThumbprint'
        }.GetEnumerator()) {
        if ($result.PSObject.Properties[$mapping.Key]) { $State[$mapping.Value] = $result.($mapping.Key) }
    }
    foreach ($mapping in @{
            SubscriptionId = 'subscriptionId'; ResourceGroup = 'resourceGroup'; FunctionAppName = 'functionAppName';
            StorageAccountName = 'storageAccountName'; KeyVaultName = 'keyVaultName'; Location = 'location'; PlanType = 'planType'
        }.GetEnumerator()) {
        $value = if ($arguments.Contains($mapping.Key)) { $arguments[$mapping.Key] } else { Get-CyotValue $Config $State $mapping.Key }
        if ($value) { $State[$mapping.Value] = $value }
    }
    Complete-CyotStage $State Deploy
}

function Invoke-CyotValidate {
    param([Collections.IDictionary] $Config, [Collections.IDictionary] $State)

    if ([string]::IsNullOrWhiteSpace($State.endpointUrl)) {
        throw 'Validate requires endpointUrl. Run the Deploy stage first.'
    }
    $endpoint = [Uri]::new($State.endpointUrl)
    if ($endpoint.Scheme -ne 'https' -or $endpoint.IsLoopback -or $endpoint.HostNameType -in @('IPv4', 'IPv6')) {
        throw 'The endpoint must use a public HTTPS hostname.'
    }
    try {
        $addresses = [Net.Dns]::GetHostAddresses($endpoint.DnsSafeHost)
        Write-CyotEvent -Level INFO -Message "Endpoint DNS resolved to $($addresses.Count) address(es)."
    }
    catch {
        throw "Endpoint DNS resolution failed for '$($endpoint.DnsSafeHost)'. $($_.Exception.Message)"
    }

    $schemaArguments = @{ CheckSchemaOnly = $true }
    Add-CyotArgument $schemaArguments GraphApiVersion (Get-CyotValue $Config $State GraphApiVersion)
    $outputs = @(& (Assert-CyotStageScript Activate) @schemaArguments)
    $schemaStatus = $outputs | Where-Object { $_.PSObject.Properties['Supported'] } | Select-Object -Last 1
    if ($null -eq $schemaStatus) { throw 'Policy stage did not return Graph schema status.' }
    $State.graphSchemaSupported = [bool]$schemaStatus.Supported
    $State.graphSchemaReason = $schemaStatus.Reason
    Complete-CyotStage $State Validate
    if (-not $schemaStatus.Supported) {
        Write-CyotEvent -Level WARN -Message "CYOT policy activation is unavailable: $($schemaStatus.Reason)"
    }
}

function Invoke-CyotActivate {
    param([Collections.IDictionary] $Config, [Collections.IDictionary] $State)

    foreach ($requiredName in @('tenantId', 'applicationId', 'endpointUrl')) {
        if ([string]::IsNullOrWhiteSpace($State[$requiredName])) {
            throw "Activate requires $requiredName. Complete the earlier stages first."
        }
    }
    if ($State.Contains('graphSchemaSupported') -and -not $State.graphSchemaSupported) {
        Write-CyotEvent -Level WARN -Message 'Activation skipped because the validated public Graph schema does not expose CYOT.'
        return
    }
    if ($NonInteractive -and -not $ApprovePolicyActivation) {
        throw 'Noninteractive activation requires -ApprovePolicyActivation. No policy change was attempted.'
    }

    $arguments = @{
        TenantId = $State.tenantId
        ApplicationId = $State.applicationId
        EndpointUrl = $State.endpointUrl
        BackupPath = Join-Path $script:PolicyBackupDirectory "cyot-policy-before-$($State.tenantId)-$([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))-$([Guid]::NewGuid().ToString('N')).json"
    }
    Add-CyotArgument $arguments Migrated (Get-CyotValue $Config $State Migrated)
    Add-CyotArgument $arguments GraphApiVersion (Get-CyotValue $Config $State GraphApiVersion)
    if ($NonInteractive) {
        $arguments.NonInteractive = $true
        $arguments.ApprovePolicyActivation = $true
    }

    Write-CyotEvent -Level INFO -Message 'Starting explicit CYOT policy activation stage.'
    $outputs = @(& (Assert-CyotStageScript Activate) @arguments)
    $result = $outputs | Where-Object { $_.PSObject.Properties['Stage'] -and $_.Stage -eq 3 } | Select-Object -Last 1
    if ($null -eq $result) { throw 'Activation stage did not return its stage result.' }
    $State.policyUpdated = [bool]$result.Updated
    Complete-CyotStage $State Activate
}

function Invoke-CyotDiagnostics {
    param([Collections.IDictionary] $State)

    $checks = @(
        [pscustomobject]@{ Check = 'PowerShell 7+'; Passed = $PSVersionTable.PSVersion.Major -ge 7; Detail = $PSVersionTable.PSVersion.ToString() },
        [pscustomobject]@{ Check = 'Azure CLI'; Passed = $null -ne (Get-Command az -ErrorAction SilentlyContinue); Detail = 'Required for provisioned Azure endpoints' },
        [pscustomobject]@{ Check = 'Graph authentication module'; Passed = $null -ne (Get-Module -ListAvailable Microsoft.Graph.Authentication); Detail = 'Required for Entra and policy operations' },
        [pscustomobject]@{ Check = 'Graph applications module'; Passed = $null -ne (Get-Module -ListAvailable Microsoft.Graph.Applications); Detail = 'Required for application registration' },
        [pscustomobject]@{ Check = 'Register stage'; Passed = Test-Path -LiteralPath $script:StageScripts.Register -PathType Leaf; Detail = $script:StageScripts.Register },
        [pscustomobject]@{ Check = 'Infrastructure stage'; Passed = Test-Path -LiteralPath $script:StageScripts.Infrastructure -PathType Leaf; Detail = $script:StageScripts.Infrastructure },
        [pscustomobject]@{ Check = 'Deploy stage'; Passed = Test-Path -LiteralPath $script:StageScripts.Deploy -PathType Leaf; Detail = $script:StageScripts.Deploy },
        [pscustomobject]@{ Check = 'Activate stage'; Passed = Test-Path -LiteralPath $script:StageScripts.Activate -PathType Leaf; Detail = $script:StageScripts.Activate },
        [pscustomobject]@{ Check = 'State directory'; Passed = Test-Path -LiteralPath (Split-Path -Parent $StatePath) -PathType Container; Detail = Split-Path -Parent $StatePath }
    )
    $checks | Format-Table -AutoSize | Out-Host
    Write-CyotEvent -Level INFO -Message "Diagnostics completed: $(@($checks | Where-Object Passed).Count)/$($checks.Count) checks passed."
    return $checks
}

function Show-CyotMenu {
    Write-Host @'

CYOT guided setup
  [1] Register or reuse Entra application
  [2] Deploy or configure endpoint
  [3] Validate deployment and Graph schema
  [4] Activate CYOT policy
  [A] Run all stages
  [R] Resume an interrupted setup
  [D] Run diagnostics
  [Q] Quit
'@
    $selection = (Read-Host 'Choose an action').Trim().ToUpperInvariant()
    switch ($selection) {
        '1' { return 'Register' }
        '2' { return 'Deploy' }
        '3' { return 'Validate' }
        '4' { return 'Activate' }
        'A' { return 'All' }
        'R' { return 'Resume' }
        'D' { return 'Diagnostics' }
        'Q' { return 'Quit' }
        default { throw "Unknown menu selection '$selection'." }
    }
}

function Get-CyotStagesToRun {
    param([string] $SelectedStage, [Collections.IDictionary] $State)

    if ($SelectedStage -eq 'All') { return $script:StageOrder }
    if ($SelectedStage -eq 'Resume') {
        $remaining = @($script:StageOrder | Where-Object { $State.completedStages -notcontains $_ })
        if ($remaining.Count -eq 0) { return @() }
        return $remaining
    }
    return @($SelectedStage)
}

Initialize-CyotWorkspace
Write-CyotEvent -Level INFO -Message "CYOT setup started. Package root: $script:PackageRoot"

try {
    $config = Read-CyotConfig
    $state = Read-CyotState
    $selectedStage = $Stage
    if ($Resume) { $selectedStage = 'Resume' }
    if ([string]::IsNullOrWhiteSpace($selectedStage)) {
        if ($NonInteractive) { $selectedStage = 'All' }
        else { $selectedStage = Show-CyotMenu }
    }
    if ($selectedStage -eq 'Quit') {
        Write-CyotEvent -Level INFO -Message 'Setup cancelled before changes were requested.'
        return
    }
    if ($selectedStage -eq 'Diagnostics') {
        Invoke-CyotDiagnostics -State $state | Out-Null
        return
    }

    $stagesToRun = @(Get-CyotStagesToRun -SelectedStage $selectedStage -State $state)
    if ($stagesToRun.Count -eq 0) {
        Write-CyotEvent -Level INFO -Message 'All stages are already complete. Nothing to resume.'
        return
    }
    foreach ($stageName in $stagesToRun) {
        switch ($stageName) {
            'Register' { Invoke-CyotRegister $config $state }
            'Deploy' { Invoke-CyotDeploy $config $state }
            'Validate' { Invoke-CyotValidate $config $state }
            'Activate' { Invoke-CyotActivate $config $state }
        }
    }
    Write-CyotEvent -Level INFO -Message "Requested workflow completed. Completed stages: $($state.completedStages -join ', ')."
}
catch {
    Write-CyotEvent -Level ERROR -Message $_.Exception.Message
    Write-CyotEvent -Level ERROR -Message "Failure position: $($_.InvocationInfo.PositionMessage)"
    Write-Host "Resume after correcting the issue: .\Setup-Cyot.ps1 -Resume -StatePath '$StatePath'" -ForegroundColor Yellow
    throw
}
finally {
    Write-Host "Event log: $script:EventLogPath" -ForegroundColor DarkGray
}