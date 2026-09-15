#Requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [hashtable] $ScriptAsts
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Function AST extents are loaded without script entry points or #Requires directives.
# The bounded Stage1 reuse tests also extract non-function statements into the mocked module.
# Every scenario gets its own in-memory module. Unknown commands are denied before loading;
# known service/input commands are throwing guards unless that scenario explicitly mocks them.
$step1 = 'Step1-Register-CyotApplication.ps1'
$step2 = 'Step2-Setup-ExternalPhoneProvider.ps1'
$step3 = 'Step3-Set-CyotPolicy.ps1'
$customerTenant = '11111111-1111-4111-8111-111111111111'
$otherTenant = '22222222-2222-4222-8222-222222222222'
$firstSubscription = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
$selectedSubscription = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
$foreignSubscription = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
$disabledSubscription = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd'
$unknownSubscription = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee'
$script:passed = 0
$script:failures = [Collections.Generic.List[string]]::new()
$script:activeModules = [Collections.Generic.List[object]]::new()

function Assert-True {
    param([bool] $Condition, [string] $Because)
    if (-not $Condition) { throw "Assertion failed: $Because" }
}

function Assert-Equal {
    param($Actual, $Expected, [string] $Because)
    if ($Actual -cne $Expected) {
        throw "Assertion failed: $Because. Expected <$Expected>; got <$Actual>."
    }
}

function Assert-Sequence {
    param([object[]] $Actual, [object[]] $Expected, [string] $Because)
    Assert-Equal $Actual.Count $Expected.Count "$Because (count)"
    for ($index = 0; $index -lt $Expected.Count; $index++) {
        Assert-Equal $Actual[$index] $Expected[$index] "$Because (index $index)"
    }
}

function Assert-Throws {
    param([scriptblock] $Action, [string] $Pattern = '.', [string] $Because = 'the operation must fail', [switch] $PassThru)
    $caught = $null
    try { & $Action | Out-Null }
    catch { $caught = $_ }
    Assert-True ($null -ne $caught) $Because
    if ($caught.Exception.Message -match '\[OFFLINE-GUARD\]') { throw $caught }
    Assert-True ($caught.Exception.Message -match $Pattern) (
        "$Because; expected error matching '$Pattern', got '$($caught.Exception.Message)'")
    if ($PassThru) { return $caught }
}

function Invoke-OfflineTest {
    param([string] $Name, [scriptblock] $Body)
    try {
        & $Body | Out-Null
        foreach ($module in $script:activeModules) {
            & $module {
                if ($script:TestState.UnexpectedCalls.Count) {
                    throw "[OFFLINE-GUARD] A function swallowed an unmocked call: $($script:TestState.UnexpectedCalls -join ', ')."
                }
            }
        }
        $script:passed++
        Write-Host "PASS $Name"
    }
    catch {
        $script:failures.Add("$Name`: $($_.Exception.Message)")
        Write-Host "FAIL $Name`: $($_.Exception.Message)" -ForegroundColor Red
    }
    finally {
        foreach ($module in $script:activeModules) {
            Remove-Module -ModuleInfo $module -Force -ErrorAction SilentlyContinue
        }
        $script:activeModules.Clear()
    }
}

function Get-FunctionAst {
    param([string] $ScriptName, [string] $Name)
    $matches = @($ScriptAsts[$ScriptName].EndBlock.Statements | Where-Object {
        $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -eq $Name
    })
    Assert-Equal $matches.Count 1 "$ScriptName must define exactly one $Name function"
    return $matches[0]
}

function New-OfflineModule {
    param(
        [string] $ScriptName,
        [string[]] $Functions,
        [hashtable] $Variables = @{},
        [hashtable] $State = @{},
        [hashtable] $Mocks = @{},
        [switch] $IncludeStage1ReuseFlow
    )

    $safeCommands = @(
        'ConvertFrom-Json', 'ConvertTo-Json', 'Where-Object', 'ForEach-Object',
        'Select-Object', 'Format-Table', 'Out-Null', 'Out-Host', 'Write-Host',
        'Write-Warning', 'Join-Path', 'Split-Path', 'Resolve-Path', 'Test-Path', 'Set-StrictMode'
    )
    $guardedCommands = @(
        'az', 'Read-Host', 'Invoke-WebRequest', 'Invoke-RestMethod', 'Remove-Item', 'Get-Command', 'Start-Sleep'
    )
    $localFunctions = @($ScriptAsts[$ScriptName].EndBlock.Statements | Where-Object {
        $_ -is [Management.Automation.Language.FunctionDefinitionAst]
    } | ForEach-Object Name)
    $functionAsts = @(foreach ($name in $Functions) { Get-FunctionAst $ScriptName $name })
    $reuseStatements = @()
    if ($IncludeStage1ReuseFlow) {
        Assert-Equal $ScriptName $step1 'only the bounded Stage1 reuse flow may load non-function statements'
        foreach ($parameter in $ScriptAsts[$ScriptName].ParamBlock.Parameters) {
            $name = $parameter.Name.VariablePath.UserPath
            Assert-True ($Variables.ContainsKey($name)) "supply Stage1 parameter variable $name explicitly"
        }
        Assert-True ($Variables.NonInteractive -eq $true) 'Stage1 reuse must never prompt for sign-in or approval'
        foreach ($name in @('Get-MgContext', 'Get-MgApplication', 'Get-MgServicePrincipal')) {
            Assert-True ($Mocks.ContainsKey($name)) "Stage1 reuse requires an explicit $name mock"
        }
        $reuseStatements = @($ScriptAsts[$ScriptName].EndBlock.Statements | Where-Object {
            $_ -isnot [Management.Automation.Language.FunctionDefinitionAst]
        })
        Assert-True ($reuseStatements.Count -gt 0) 'extract the Stage1 statements, not a substitute test implementation'
    }
    foreach ($node in @($functionAsts) + $reuseStatements) {
        $description = "$ScriptName line $($node.Extent.StartLineNumber)"
        foreach ($command in $node.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst]
        }, $true)) {
            $commandName = $command.GetCommandName()
            if (-not $commandName -or $command.InvocationOperator -eq
                [Management.Automation.Language.TokenKind]::Dot) {
                throw "[OFFLINE-GUARD] Dynamic/script invocation in $description is not allowed in offline tests."
            }
            if ($commandName -in $safeCommands -or $commandName -in $Functions) { continue }
            if ($commandName -notin $localFunctions -and $commandName -notin $guardedCommands -and
                $commandName -notmatch '^[A-Za-z]+-Mg[A-Za-z0-9]+$') {
                throw "[OFFLINE-GUARD] Unapproved command '$commandName' in $description."
            }
            $guardedCommands += $commandName
        }
    }
    $State.UnexpectedCalls = [Collections.Generic.List[string]]::new()
    $State.Messages = [Collections.Generic.List[string]]::new()
    $State.Displayed = [Collections.Generic.List[object]]::new()
    $configuration = @{
        Definitions = @($functionAsts | ForEach-Object { $_.Extent.Text })
        ReuseStatements = ($reuseStatements | ForEach-Object { $_.Extent.Text }) -join "`n"
        Guards = @($guardedCommands | Select-Object -Unique)
        Variables = $Variables
        State = $State
        Mocks = $Mocks
        FixtureDirectory = $script:fixtureDirectory
    }
    $module = New-Module -Name "CyotOffline_$([Guid]::NewGuid().ToString('N'))" -ArgumentList $configuration -ScriptBlock {
        param($Configuration)
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        $PSModuleAutoLoadingPreference = 'None'
        $script:TestState = $Configuration.State
        $script:NonInteractive = $true
        $script:TenantId = $null
        $script:SubscriptionId = $null
        $script:GraphTenantId = $null
        $script:AzureCliContext = $null
        $script:FixtureDirectory = $Configuration.FixtureDirectory
        foreach ($entry in $Configuration.Variables.GetEnumerator()) {
            Set-Variable -Name $entry.Key -Value $entry.Value -Scope Script
        }
        function Stop-UnmockedCall {
            param([string] $Name)
            $script:TestState.UnexpectedCalls.Add($Name)
            throw "[OFFLINE-GUARD] Unmocked call: $Name"
        }
        $guard = { Stop-UnmockedCall $MyInvocation.MyCommand.Name }
        foreach ($name in $Configuration.Guards) {
            Set-Item -LiteralPath "Function:script:$name" -Value $guard
        }
        function Write-Host {
            param([object[]] $Object, $ForegroundColor, $BackgroundColor, [switch] $NoNewline)
            $script:TestState.Messages.Add(($Object -join ' '))
        }
        function Write-Warning {
            param([string] $Message)
            $script:TestState.Messages.Add($Message)
        }
        function Format-Table {
            param([Parameter(ValueFromPipeline)] $InputObject, [switch] $AutoSize)
            process { $InputObject }
        }
        function Out-Host {
            param([Parameter(ValueFromPipeline)] $InputObject)
            process { $script:TestState.Displayed.Add($InputObject) }
        }
        function Remove-Item {
            [CmdletBinding()]
            param([string] $LiteralPath, [switch] $Force)
            if ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($LiteralPath)) -ne $script:FixtureDirectory) {
                Stop-UnmockedCall "Cleanup outside the fixture directory: $LiteralPath"
            }
            Microsoft.PowerShell.Management\Remove-Item @PSBoundParameters
        }
        foreach ($definition in $Configuration.Definitions) {
            . ([scriptblock]::Create($definition))
        }
        if ($Configuration.Mocks.ContainsKey('Read-SetupValue')) {
            $script:OriginalReadSetupValue = (Get-Item -LiteralPath Function:Read-SetupValue).ScriptBlock
        }
        foreach ($entry in $Configuration.Mocks.GetEnumerator()) {
            # Recreate mocks here so $script: refers to this module, not the test runner.
            Set-Item -LiteralPath "Function:script:$($entry.Key)" -Value ([scriptblock]::Create($entry.Value.ToString()))
        }
        if ($Configuration.ReuseStatements) {
            $script:Stage1ReuseBody = [scriptblock]::Create($Configuration.ReuseStatements)
        }
        Export-ModuleMember -Function @() -Alias @() -Variable @()
    }
    $script:activeModules.Add($module)
    return $module
}

function Get-CliOption {
    param([string[]] $Arguments, [string[]] $Names)
    foreach ($name in $Names) {
        $index = [Array]::IndexOf($Arguments, $name)
        if ($index -ge 0 -and $index + 1 -lt $Arguments.Count) { return $Arguments[$index + 1] }
    }
    return $null
}

function New-Subscription {
    param([string] $Id, [string] $Tenant = $customerTenant, [string] $State = 'Enabled')
    return [pscustomobject]@{
        id = $Id; tenantId = $Tenant; state = $State
        name = "Synthetic subscription $Id"
        isDefault = ($Id -eq $firstSubscription)
        user = [pscustomobject]@{ type = 'user'; name = 'operator@example.invalid' }
    }
}

function New-CliScenario {
    param(
        [AllowNull()] $Tenant = $customerTenant,
        [AllowNull()] $Subscription = $selectedSubscription,
        [bool] $NonInteractive = $false,
        [object[]] $Subscriptions = @(
            (New-Subscription $foreignSubscription $otherTenant)
            (New-Subscription $disabledSubscription $customerTenant 'Disabled')
            (New-Subscription $firstSubscription)
            (New-Subscription $selectedSubscription)
        ),
        $Account = (New-Subscription $selectedSubscription),
        [string[]] $Answers = @(),
        [string] $FailAt = ''
    )
    $state = @{
        Calls = [Collections.Generic.List[object]]::new()
        Reads = [Collections.Generic.List[object]]::new()
        Prompts = [Collections.Generic.List[string]]::new()
        Answers = [Collections.Generic.Queue[string]]::new()
        Subscriptions = $Subscriptions
        Account = $Account
        FailAt = $FailAt
        FailureMessage = 'Injected CLI authentication failure: AADSTS50076'
    }
    foreach ($answer in $Answers) { $state.Answers.Enqueue($answer) }
    $module = New-OfflineModule -ScriptName $step2 -Functions @(
        'Initialize-AzureCliAuthentication', 'Read-SetupValue', 'Assert-AzCommandSucceeded',
        'Invoke-AzResult', 'Invoke-Az'
    ) -Variables @{
        TenantId = $Tenant; SubscriptionId = $Subscription; NonInteractive = $NonInteractive
        GraphTenantId = $otherTenant
    } -State $state -Mocks @{
        'Read-SetupValue' = {
            param([string] $Name, $DefaultValue, [switch] $Required, [string] $ValueType = 'String',
                [string[]] $Choices = @(), [string] $Hint)
            $script:TestState.Reads.Add([pscustomobject]@{
                Name = $Name; DefaultValue = $DefaultValue; Required = [bool]$Required
                ValueType = $ValueType; Choices = $Choices
            })
            & $script:OriginalReadSetupValue @PSBoundParameters
        }
        'Read-Host' = {
            param([string] $Prompt)
            $script:TestState.Prompts.Add($Prompt)
            if (-not $script:TestState.Answers.Count) { Stop-UnmockedCall "Unexpected prompt: $Prompt" }
            $script:TestState.Answers.Dequeue()
        }
        'Invoke-AzCommand' = {
            param([string[]] $Arguments, [switch] $Interactive)
            $operation = if ($Arguments[0] -eq 'login') { 'login' }
                else { $Arguments[0..1] -join ' ' }
            $script:TestState.Calls.Add([pscustomobject]@{
                Operation = $operation; Arguments = $Arguments; Interactive = [bool]$Interactive
                PublishedContext = $script:AzureCliContext; PublishedTenant = $script:GraphTenantId
            })
            if ($operation -eq $script:TestState.FailAt) {
                return [pscustomobject]@{ ExitCode = 71; Lines = @($script:TestState.FailureMessage) }
            }
            $lines = switch ($operation) {
                'login' { @() }
                'account list' { ConvertTo-Json -InputObject $script:TestState.Subscriptions -Depth 5 -Compress }
                'account show' { ConvertTo-Json -InputObject $script:TestState.Account -Depth 5 -Compress }
                'account set' { @() }
                'resource list' { '[]' }
                'ad signed-in-user' { '{"id":"synthetic-user"}' }
                default { Stop-UnmockedCall "az $($Arguments -join ' ')" }
            }
            [pscustomobject]@{ ExitCode = 0; Lines = @($lines) }
        }
    }
    return @{ Module = $module; State = $state }
}

function Assert-CliNotPublished {
    param($Scenario)
    $context = & $Scenario.Module { $script:AzureCliContext }
    $tenant = & $Scenario.Module { $script:GraphTenantId }
    Assert-True ($null -eq $context) 'failed initialization must not publish an Azure context'
    Assert-Equal $tenant $otherTenant 'failed initialization must not publish a Graph tenant'
    foreach ($call in $Scenario.State.Calls) {
        Assert-True ($null -eq $call.PublishedContext) 'Azure context is published only after account set succeeds'
        Assert-Equal $call.PublishedTenant $otherTenant 'Graph tenant is published only after account set succeeds'
    }
}

function Assert-CliSelection {
    param($Scenario, [string] $Selected = $selectedSubscription, [bool] $Interactive = $true)
    $calls = $Scenario.State.Calls
    $expected = @('account list', 'account show', 'account set')
    if ($Interactive) { $expected = @('login') + $expected }
    Assert-Sequence @($calls | ForEach-Object Operation) $expected 'CLI ordering (no cached account show, preflight or retry)'
    $offset = 0
    if ($Interactive) {
        Assert-Sequence $calls[0].Arguments @(
            'login', '--tenant', $customerTenant, '--output', 'none', '--only-show-errors'
        ) 'login must explicitly target the customer tenant'
        Assert-True $calls[0].Interactive 'login must preserve interactive sign-in'
        $offset = 1
    }
    Assert-True ($calls[$offset].Arguments -contains '--all') 'account list must include all accessible subscriptions'
    Assert-Equal (Get-CliOption $calls[$offset].Arguments @('--output', '-o')) 'json' 'account list must return JSON'
    Assert-Equal (Get-CliOption $calls[$offset + 1].Arguments @('--subscription')) $Selected 'account show must target the selection'
    Assert-Equal (Get-CliOption $calls[$offset + 1].Arguments @('--output', '-o')) 'json' 'account show must return JSON'
    Assert-Equal (Get-CliOption $calls[$offset + 2].Arguments @('--subscription')) $Selected 'account set must target the verified selection'
    foreach ($call in $calls | Select-Object -Skip $offset) {
        Assert-True (-not $call.Interactive) 'only login is an interactive CLI command'
    }
    foreach ($call in $calls) {
        Assert-True ($null -eq $call.PublishedContext) 'context must not be published before account set returns'
        Assert-Equal $call.PublishedTenant $otherTenant 'tenant must not be published before account set returns'
    }
    $context = & $Scenario.Module { $script:AzureCliContext }
    Assert-Equal $context.id $Selected 'publish the selected subscription'
    Assert-Equal $context.tenantId $customerTenant 'publish the verified customer tenant'
    Assert-Equal (& $Scenario.Module { $script:GraphTenantId }) $customerTenant 'pin Graph to the verified tenant'
    Assert-Equal $Scenario.State.Reads[0].Name 'TenantId' 'validate the customer tenant first'
    Assert-Equal $Scenario.State.Reads[0].ValueType 'Guid' 'customer tenant validation uses GUIDs'
    Assert-True $Scenario.State.Reads[0].Required 'customer tenant is required'
    Assert-Equal $Scenario.State.Reads[1].Name 'SubscriptionId' 'validate the optional subscription'
    Assert-Equal $Scenario.State.Reads[1].ValueType 'Guid' 'supplied subscription validation uses GUIDs'
}

function New-GraphContext {
    param([string[]] $Scopes, [string] $Variant = 'Valid')
    if ($Variant -eq 'Missing') { return $null }
    $context = [pscustomobject]@{
        TenantId = $customerTenant; AuthType = 'Delegated'; Environment = 'Global'
        TokenCredentialType = 'InteractiveBrowser'; Scopes = @($Scopes) + @('User.Read')
    }
    switch ($Variant) {
        'WrongTenant' { $context.TenantId = $otherTenant }
        'WrongEnvironment' { $context.Environment = 'USGov' }
        'AppOnly' { $context.AuthType = 'AppOnly' }
        'MissingScope' { $context.Scopes = @('User.Read') }
        'ManualToken' { $context.TokenCredentialType = 'UserProvidedAccessToken' }
    }
    return $context
}

function New-GraphScenario {
    param(
        [string] $ScriptName, $Before, $After, [bool] $NonInteractive = $false,
        [AllowNull()] $Tenant = $customerTenant, [string] $ConnectError = '', [string] $ContextError = ''
    )
    $state = @{
        Before = $Before; After = $After; Reads = 0
        Connections = [Collections.Generic.List[object]]::new()
        ConnectError = $ConnectError; ContextError = $ContextError
    }
    $module = New-OfflineModule -ScriptName $ScriptName -Functions @(
        'Read-SetupValue', 'Connect-EndpointGraph'
    ) -Variables @{ GraphTenantId = $Tenant; NonInteractive = $NonInteractive } -State $state -Mocks @{
        'Get-MgContext' = {
            [CmdletBinding()]
            param()
            $script:TestState.Reads++
            if ($script:TestState.ContextError) { throw $script:TestState.ContextError }
            if ($script:TestState.Connections.Count) { return $script:TestState.After }
            return $script:TestState.Before
        }
        'Connect-MgGraph' = {
            [CmdletBinding()]
            param([string] $TenantId, [string[]] $Scopes, [string] $ContextScope,
                [string] $Environment, [switch] $NoWelcome)
            $script:TestState.Connections.Add([pscustomobject]@{
                TenantId = $TenantId; Scopes = $Scopes; ContextScope = $ContextScope; Environment = $Environment
            })
            if ($script:TestState.ConnectError) { throw $script:TestState.ConnectError }
        }
    }
    return @{ Module = $module; State = $state }
}

function Assert-GraphConnection {
    param($Scenario, [string[]] $Scopes)
    Assert-Equal $Scenario.State.Connections.Count 1 'connect exactly once, without retries or tenant fallback'
    $connection = $Scenario.State.Connections[0]
    Assert-Equal $connection.TenantId $customerTenant 'Graph sign-in must pin the customer tenant'
    Assert-Equal $connection.ContextScope 'Process' 'Graph sign-in must use process context'
    Assert-Equal $connection.Environment 'Global' 'Graph sign-in must use Global'
    Assert-Sequence $connection.Scopes $Scopes 'forward every requested scope'
    Assert-Equal $Scenario.State.Reads 2 'verify context again after sign-in'
    Assert-Equal (& $Scenario.Module { $script:GraphTenantId }) $customerTenant 'never replace the selected tenant'
}

function New-Stage1ReuseScenario {
    param([ValidateSet('ClientId', 'DisplayName')] [string] $Lookup)
    $application = [pscustomobject]@{
        Id = '44444444-4444-4444-8444-444444444444'
        AppId = '33333333-3333-4333-8333-333333333333'
        DisplayName = "Synthetic operator's CYOT"
        SignInAudience = 'AzureADMultipleOrgs'
    }
    $state = @{
        Application = $application
        Principal = [pscustomobject]@{
            Id = '55555555-5555-4555-8555-555555555555'
            AppId = $application.AppId
            AppRoleAssignmentRequired = $false
        }
        Context = New-GraphContext @('Application.ReadWrite.All')
        Calls = [Collections.Generic.List[string]]::new()
    }
    $module = New-OfflineModule -ScriptName $step1 -IncludeStage1ReuseFlow -Functions @(
        'Write-Step', 'Read-SetupValue', 'Connect-EndpointGraph',
        'Get-CyotApplication', 'Ensure-CyotEndpointServicePrincipal'
    ) -Variables @{
        TenantId = $customerTenant
        ApplicationId = $(if ($Lookup -eq 'ClientId') { $application.AppId } else { $null })
        DisplayName = $(if ($Lookup -eq 'DisplayName') { $application.DisplayName } else { '' })
        NonInteractive = $true
    } -State $state -Mocks @{
        'Get-MgContext' = {
            [CmdletBinding()]
            param()
            if ($script:TestState.Calls.Contains('context')) { Stop-UnmockedCall 'Repeated Stage1 context discovery' }
            $script:TestState.Calls.Add('context')
            $script:TestState.Context
        }
        'Get-MgApplication' = {
            [CmdletBinding()]
            param([string] $ApplicationId, [string] $Filter, [string[]] $Property, [switch] $All)
            $application = $script:TestState.Application
            if ($script:GraphTenantId -ne $script:TestState.Context.TenantId) {
                Stop-UnmockedCall 'Stage1 application lookup in the wrong tenant'
            }
            $operation = if ($ApplicationId -eq $application.Id -and -not $Filter) { 'application:object-id' }
                elseif (-not $ApplicationId -and $All -and $Filter -ceq "appId eq '$($application.AppId)'") { 'application:client-id' }
                elseif (-not $ApplicationId -and $All -and
                    $Filter -ceq "displayName eq '$($application.DisplayName.Replace("'", "''"))'") { 'application:name' }
                else { Stop-UnmockedCall 'Unexpected Stage1 application lookup' }
            if ($script:TestState.Calls.Contains($operation)) { Stop-UnmockedCall "Repeated Stage1 $operation" }
            $script:TestState.Calls.Add($operation)
            $application
        }
        'Get-MgServicePrincipal' = {
            [CmdletBinding()]
            param([string] $Filter, [switch] $All)
            if (-not $All -or $Filter -cne "appId eq '$($script:TestState.Application.AppId)'" -or
                $script:TestState.Calls.Contains('service-principal:client-id')) {
                Stop-UnmockedCall 'Unexpected Stage1 service-principal lookup'
            }
            $script:TestState.Calls.Add('service-principal:client-id')
            $script:TestState.Principal
        }
    }
    return @{ Module = $module; State = $state }
}

# Redirect the process-only scratch location before calling functions that use GetTempPath.
# Refuse to run them if .NET resolves anywhere else, and restore the environment in finally.
$savedEnvironment = @{}
$script:fixtureDirectory = $null
Push-Location -LiteralPath $PSScriptRoot
try {
    $fixtureName = ".cyot-offline-$([Guid]::NewGuid().ToString('N'))"
    $script:fixtureDirectory = (New-Item -ItemType Directory -Path $fixtureName).FullName
    foreach ($name in @('TMP', 'TEMP', 'TMPDIR')) {
        $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        [Environment]::SetEnvironmentVariable($name, $script:fixtureDirectory, 'Process')
    }
    $resolvedScratch = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
    Assert-Equal $resolvedScratch $script:fixtureDirectory 'all generated test files must stay under tests\setup'

    foreach ($scriptName in @($step1, $step2, $step3)) {
        $label = $scriptName.Split('-')[0]
        Invoke-OfflineTest "$label has no token preflight or Graph replay wrapper" {
            $preflights = @($ScriptAsts[$scriptName].FindAll({
                param($node)
                ($node -is [Management.Automation.Language.StringConstantExpressionAst] -and
                    $node.Value -eq 'get-access-token') -or
                ($node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -eq 'Invoke-EndpointGraph') -or
                ($node -is [Management.Automation.Language.CommandAst] -and
                    $node.GetCommandName() -eq 'Invoke-EndpointGraph')
            }, $true))
            Assert-Equal $preflights.Count 0 'authentication must not prefetch tokens or replay SDK operations'
        }

        foreach ($value in @($null, '', '   ', 'not-a-guid', [Guid]::Empty.ToString())) {
            Invoke-OfflineTest "$label rejects required invalid GUID <$value> without prompting" {
                $module = New-OfflineModule $scriptName @('Read-SetupValue')
                Assert-Throws {
                    & $module {
                        param($Value)
                        Read-SetupValue -Name TenantId -DefaultValue $Value -Required -ValueType Guid
                    } $value
                } -Pattern 'TenantId.*(required|nonempty GUID)'
            }
        }
        Invoke-OfflineTest "$label normalizes a valid GUID and preserves an omitted optional value" {
            $module = New-OfflineModule $scriptName @('Read-SetupValue')
            $result = & $module {
                Read-SetupValue -Name TenantId -DefaultValue 'ABCDEFAB-1234-4123-8123-ABCDEFABCDEF' -Required -ValueType Guid
            }
            Assert-Equal $result 'abcdefab-1234-4123-8123-abcdefabcdef' 'normalize the supplied GUID'
            Assert-True ($null -eq (& $module { Read-SetupValue -Name ApplicationId -ValueType Guid })) (
                'omitting an optional ID must not prompt or synthesize an ID')
        }
        Invoke-OfflineTest "$label rejects an invalid supplied interactive GUID instead of prompting" {
            $module = New-OfflineModule $scriptName @('Read-SetupValue') -Variables @{ NonInteractive = $false }
            Assert-Throws {
                & $module { Read-SetupValue -Name TenantId -DefaultValue 'invalid' -Required -ValueType Guid }
            } -Pattern 'TenantId.*nonempty GUID'
        }
    }

    foreach ($lookup in @('ClientId', 'DisplayName')) {
        Invoke-OfflineTest "Step1 reuse by $lookup returns exactly one client-ID string, never SDK objects" {
            $scenario = New-Stage1ReuseScenario -Lookup $lookup
            $output = @(& $scenario.Module { & $script:Stage1ReuseBody })
            Assert-Equal $output.Count 1 'the Stage1 success stream contains only the client ID'
            Assert-True ($output[0] -is [string]) 'return a client-ID string, not an application or service-principal object'
            Assert-Equal $output[0] $scenario.State.Application.AppId 'return the application client ID, not either object ID'
            $expectedCalls = @('context')
            if ($lookup -eq 'DisplayName') { $expectedCalls += 'application:name' }
            $expectedCalls += @('application:client-id', 'application:object-id', 'service-principal:client-id')
            Assert-Sequence $scenario.State.Calls.ToArray() $expectedCalls 'reuse the existing application and principal without writes or repeated SDK calls'
            Assert-Equal (& $scenario.Module { $script:GraphTenantId }) $customerTenant 'Stage1 reuse stays in the supplied customer tenant'
        }
    }
    Invoke-OfflineTest 'Step2 initialization remains parameterless' {
        $functionAst = Get-FunctionAst $step2 'Initialize-AzureCliAuthentication'
        Assert-True ($null -eq $functionAst.Body.ParamBlock -or $functionAst.Body.ParamBlock.Parameters.Count -eq 0) (
            'initialization reads TenantId, SubscriptionId and NonInteractive from the standalone script')
    }
    Invoke-OfflineTest 'Step2 explicit interactive selection never reads the cached default first' {
        $scenario = New-CliScenario
        & $scenario.Module { Initialize-AzureCliAuthentication }
        Assert-CliSelection $scenario
        Assert-Equal $scenario.State.Prompts.Count 0 'supplied IDs need no input prompt'
    }
    Invoke-OfflineTest 'Step2 noninteractive initialization validates the existing login without signing in' {
        $scenario = New-CliScenario -NonInteractive $true
        & $scenario.Module { Initialize-AzureCliAuthentication }
        Assert-CliSelection $scenario -Interactive $false
        Assert-Equal $scenario.State.Prompts.Count 0 'noninteractive initialization must not prompt'
    }
    foreach ($invalidTenant in @($null, '', '  ', 'invalid', [Guid]::Empty.ToString())) {
        Invoke-OfflineTest "Step2 invalid noninteractive tenant <$invalidTenant> stops before CLI calls" {
            $scenario = New-CliScenario -Tenant $invalidTenant -NonInteractive $true
            Assert-Throws { & $scenario.Module { Initialize-AzureCliAuthentication } } -Pattern 'TenantId.*(required|nonempty GUID)'
            Assert-Equal $scenario.State.Calls.Count 0 'invalid tenant must be rejected before CLI'
            Assert-Equal $scenario.State.Prompts.Count 0 'noninteractive tenant validation must not prompt'
            Assert-CliNotPublished $scenario
        }
    }
    foreach ($invalidSubscription in @($null, '', '  ', 'invalid', [Guid]::Empty.ToString())) {
        Invoke-OfflineTest "Step2 missing/invalid noninteractive subscription <$invalidSubscription> stops before CLI calls" {
            $scenario = New-CliScenario -Subscription $invalidSubscription -NonInteractive $true
            Assert-Throws { & $scenario.Module { Initialize-AzureCliAuthentication } } -Pattern 'SubscriptionId.*(required|nonempty GUID)'
            Assert-Equal $scenario.State.Calls.Count 0 'invalid subscription must be rejected before CLI'
            Assert-Equal $scenario.State.Prompts.Count 0 'noninteractive subscription validation must not prompt'
            Assert-CliNotPublished $scenario
        }
    }
    Invoke-OfflineTest 'Step2 rejects a malformed supplied interactive subscription before login' {
        $scenario = New-CliScenario -Subscription 'not-a-guid'
        Assert-Throws { & $scenario.Module { Initialize-AzureCliAuthentication } } -Pattern 'SubscriptionId.*nonempty GUID'
        Assert-Equal $scenario.State.Calls.Count 0 'GUID validation precedes interactive login'
        Assert-CliNotPublished $scenario
    }
    foreach ($onlyOne in @($false, $true)) {
        Invoke-OfflineTest "Step2 omitted subscription requires an explicit tenant-filtered choice (one=$onlyOne)" {
            $subscriptions = @(
                (New-Subscription $foreignSubscription $otherTenant)
                (New-Subscription $disabledSubscription $customerTenant 'Disabled')
                (New-Subscription $selectedSubscription)
            )
            if (-not $onlyOne) { $subscriptions += New-Subscription $firstSubscription }
            $scenario = New-CliScenario -Subscription $null -Subscriptions $subscriptions -Answers @($selectedSubscription)
            & $scenario.Module { Initialize-AzureCliAuthentication }
            Assert-CliSelection $scenario
            Assert-Equal $scenario.State.Prompts.Count 1 'never silently select the first/default/only subscription'
            $choice = @($scenario.State.Reads | Where-Object ValueType -eq 'Choice')
            Assert-Equal $choice.Count 1 'selection must go through Read-SetupValue -ValueType Choice'
            Assert-Equal $choice[0].Name 'SubscriptionId' 'prompt for the subscription ID'
            Assert-True $choice[0].Required 'the operator must make a choice'
            Assert-True ([string]::IsNullOrWhiteSpace($choice[0].DefaultValue)) 'do not preselect a subscription'
            $expectedIds = @($selectedSubscription)
            if (-not $onlyOne) { $expectedIds += $firstSubscription }
            Assert-Sequence $choice[0].Choices $expectedIds 'offer only enabled customer-tenant subscription IDs'
            Assert-Sequence @($scenario.State.Displayed | ForEach-Object id) $expectedIds 'display only the filtered subscriptions'
            Assert-Sequence @($scenario.State.Displayed | ForEach-Object name) @(
                $subscriptions | Where-Object { $_.tenantId -eq $customerTenant -and $_.state -eq 'Enabled' } | ForEach-Object name
            ) 'display subscription names alongside their IDs'
        }
    }
    Invoke-OfflineTest 'Step2 rejects an out-of-tenant answer before accepting a valid choice' {
        $scenario = New-CliScenario -Subscription $null -Answers @($foreignSubscription, $selectedSubscription)
        & $scenario.Module { Initialize-AzureCliAuthentication }
        Assert-CliSelection $scenario
        Assert-Equal $scenario.State.Prompts.Count 2 'an invalid choice must be rejected and re-prompted'
    }
    foreach ($case in @('Empty', 'ForeignOnly', 'DisabledOnly')) {
        Invoke-OfflineTest "Step2 refuses no enabled customer subscriptions ($case)" {
            $subscriptions = switch ($case) {
                'Empty' { @() }
                'ForeignOnly' { New-Subscription $foreignSubscription $otherTenant }
                'DisabledOnly' { New-Subscription $selectedSubscription $customerTenant 'Disabled' }
            }
            $scenario = New-CliScenario -Subscriptions @($subscriptions)
            Assert-Throws { & $scenario.Module { Initialize-AzureCliAuthentication } } -Pattern 'No accessible enabled'
            Assert-Sequence @($scenario.State.Calls | ForEach-Object Operation) @('login', 'account list') 'stop before account show/set'
            Assert-CliNotPublished $scenario
        }
    }
    foreach ($case in @('Unknown', 'Foreign', 'Disabled', 'Duplicate')) {
        Invoke-OfflineTest "Step2 refuses an inaccessible or ambiguous supplied ID ($case)" {
            $id = switch ($case) {
                'Unknown' { $unknownSubscription }
                'Foreign' { $foreignSubscription }
                'Disabled' { $disabledSubscription }
                'Duplicate' { $selectedSubscription }
            }
            $scenario = New-CliScenario -Subscription $id
            if ($case -eq 'Duplicate') { $scenario.State.Subscriptions += New-Subscription $selectedSubscription }
            Assert-Throws { & $scenario.Module { Initialize-AzureCliAuthentication } } -Pattern 'not an accessible enabled subscription'
            Assert-Sequence @($scenario.State.Calls | ForEach-Object Operation) @('login', 'account list') 'do not substitute another ID'
            Assert-CliNotPublished $scenario
        }
    }
    foreach ($case in @('Id', 'Tenant', 'State', 'ServicePrincipal', 'MissingUser')) {
        Invoke-OfflineTest "Step2 verifies the selected account before account set ($case)" {
            $account = New-Subscription $selectedSubscription
            switch ($case) {
                'Id' { $account.id = $firstSubscription }
                'Tenant' { $account.tenantId = $otherTenant }
                'State' { $account.state = 'Disabled' }
                'ServicePrincipal' { $account.user.type = 'servicePrincipal' }
                'MissingUser' { $account.PSObject.Properties.Remove('user') }
            }
            $scenario = New-CliScenario -Account $account
            Assert-Throws { & $scenario.Module { Initialize-AzureCliAuthentication } }
            Assert-Sequence @($scenario.State.Calls | ForEach-Object Operation) @(
                'login', 'account list', 'account show'
            ) 'reject the account before setting context'
            Assert-CliNotPublished $scenario
        }
    }
    $initializationOperations = @('login', 'account list', 'account show', 'account set')
    foreach ($operation in $initializationOperations) {
        Invoke-OfflineTest "Step2 propagates $operation authentication failure without retries" {
            $scenario = New-CliScenario -FailAt $operation
            Assert-Throws { & $scenario.Module { Initialize-AzureCliAuthentication } } -Pattern 'Injected CLI authentication failure'
            $lastIndex = [Array]::IndexOf($initializationOperations, $operation)
            Assert-Sequence @($scenario.State.Calls | ForEach-Object Operation) $initializationOperations[0..$lastIndex] 'stop at the first CLI failure'
            Assert-CliNotPublished $scenario
        }
    }
    Invoke-OfflineTest 'Step2 propagates subscription-not-found instead of switching or retrying login' {
        $scenario = New-CliScenario -FailAt 'account show'
        $scenario.State.FailureMessage = "Subscription '$selectedSubscription' not found."
        Assert-Throws { & $scenario.Module { Initialize-AzureCliAuthentication } } -Pattern 'Subscription .* not found'
        Assert-Sequence @($scenario.State.Calls | ForEach-Object Operation) @(
            'login', 'account list', 'account show'
        ) 'do not retry or set a different subscription'
        Assert-CliNotPublished $scenario
    }
    foreach ($case in @('Resource', 'ExplicitSubscription', 'Directory')) {
        Invoke-OfflineTest "Step2 Invoke-AzResult preserves explicit subscription and directory rules ($case)" {
            $scenario = New-CliScenario
            & $scenario.Module { $script:AzureCliContext = $script:TestState.Account }
            $arguments = switch ($case) {
                'Resource' { @('resource', 'list', '--output', 'json') }
                'ExplicitSubscription' { @('resource', 'list', '--subscription', $firstSubscription, '--only-show-errors') }
                'Directory' { @('ad', 'signed-in-user', 'show', '--output', 'json') }
            }
            & $scenario.Module { param($Arguments) Invoke-AzResult -Arguments $Arguments } $arguments | Out-Null
            Assert-Equal $scenario.State.Calls.Count 1 'forward each resource/directory operation once'
            $actual = $scenario.State.Calls[0].Arguments
            Assert-Equal @($actual | Where-Object { $_ -eq '--only-show-errors' }).Count 1 'add error-only output without duplicates'
            $subscriptionFlags = @($actual | Where-Object { $_ -eq '--subscription' }).Count
            if ($case -eq 'Directory') {
                Assert-Equal $subscriptionFlags 0 'directory ad commands use initialized tenant context, not a subscription flag'
            }
            else {
                Assert-Equal $subscriptionFlags 1 'resource operations carry exactly one subscription flag'
                $expected = if ($case -eq 'ExplicitSubscription') { $firstSubscription } else { $selectedSubscription }
                Assert-Equal (Get-CliOption $actual @('--subscription')) $expected 'preserve or supply the explicit subscription'
            }
        }
    }
    Invoke-OfflineTest 'Step2 Invoke-Az surfaces resource failures without hidden authentication' {
        $scenario = New-CliScenario -FailAt 'resource list'
        & $scenario.Module { $script:AzureCliContext = $script:TestState.Account }
        Assert-Throws { & $scenario.Module { Invoke-Az resource list --output json } } -Pattern 'Injected CLI authentication failure'
        Assert-Sequence @($scenario.State.Calls | ForEach-Object Operation) @('resource list') 'do not retry resource failures'
    }

    $invalidContexts = @('Missing', 'WrongTenant', 'WrongEnvironment', 'AppOnly', 'MissingScope', 'ManualToken')
    foreach ($scriptName in @($step1, $step2, $step3)) {
        $label = $scriptName.Split('-')[0]
        $scope = if ($scriptName -eq $step3) { 'Policy.ReadWrite.AuthenticationMethod' } else { 'Application.ReadWrite.All' }
        Invoke-OfflineTest "$label Graph scope parameter remains string[]" {
            $functionAst = Get-FunctionAst $scriptName 'Connect-EndpointGraph'
            $scopeParameter = @($functionAst.Body.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Scopes' })
            Assert-Equal $scopeParameter.Count 1 'keep an explicit Scopes parameter'
            Assert-Equal $scopeParameter[0].StaticType ([string[]]) 'Scopes must accept a string array'
        }
        foreach ($nonInteractive in @($false, $true)) {
            Invoke-OfflineTest "$label reuses an eligible delegated Graph context (noninteractive=$nonInteractive)" {
                $scenario = New-GraphScenario $scriptName (New-GraphContext @($scope)) $null -NonInteractive $nonInteractive
                & $scenario.Module { Connect-EndpointGraph }
                Assert-Equal $scenario.State.Connections.Count 0 'reuse an eligible refreshable delegated context'
                Assert-Equal $scenario.State.Reads 1 'reuse requires one context check'
                Assert-Equal (& $scenario.Module { $script:GraphTenantId }) $customerTenant 'keep the explicitly selected tenant'
            }
        }
        foreach ($variant in $invalidContexts) {
            Invoke-OfflineTest "$label rejects noninteractive Graph context $variant without sign-in" {
                $scenario = New-GraphScenario $scriptName (New-GraphContext @($scope) $variant) $null -NonInteractive $true
                Assert-Throws { & $scenario.Module { Connect-EndpointGraph } } -Pattern 'Connect-MgGraph.*TenantId'
                Assert-Equal $scenario.State.Connections.Count 0 'noninteractive mode must never connect'
                Assert-Equal $scenario.State.Reads 1 'inspect the existing context without retries'
            }
            Invoke-OfflineTest "$label replaces Graph context $variant with one pinned sign-in" {
                $scenario = New-GraphScenario $scriptName (New-GraphContext @($scope) $variant) (New-GraphContext @($scope))
                & $scenario.Module { Connect-EndpointGraph }
                Assert-GraphConnection $scenario @($scope)
            }
            Invoke-OfflineTest "$label revalidates returned Graph context $variant" {
                $scenario = New-GraphScenario $scriptName $null (New-GraphContext @($scope) $variant)
                Assert-Throws { & $scenario.Module { Connect-EndpointGraph } } -Pattern 'refreshable delegated session'
                Assert-GraphConnection $scenario @($scope)
            }
        }
        foreach ($tenant in @($null, 'invalid', [Guid]::Empty.ToString())) {
            Invoke-OfflineTest "$label rejects invalid customer tenant <$tenant> before Graph context discovery" {
                $scenario = New-GraphScenario $scriptName (New-GraphContext @($scope)) $null -Tenant $tenant -NonInteractive $true
                Assert-Throws { & $scenario.Module { Connect-EndpointGraph } } -Pattern 'TenantId.*(required|nonempty GUID)'
                Assert-Equal $scenario.State.Reads 0 'never infer a customer tenant from a cached Graph session'
                Assert-Equal $scenario.State.Connections.Count 0 'invalid tenants cannot trigger sign-in'
            }
        }
        foreach ($invalidScopes in @(@(), @(''), @($scope, ' '))) {
            Invoke-OfflineTest "$label rejects empty Graph scopes <$($invalidScopes -join ',')>" {
                $scenario = New-GraphScenario $scriptName (New-GraphContext @($scope)) $null
                Assert-Throws {
                    & $scenario.Module { param($Scopes) Connect-EndpointGraph -Scopes $Scopes } $invalidScopes
                } -Pattern 'nonempty scope'
                Assert-Equal $scenario.State.Reads 0 'validate scopes before inspecting context'
                Assert-Equal $scenario.State.Connections.Count 0 'invalid scopes cannot trigger sign-in'
            }
        }
        Invoke-OfflineTest "$label forwards and checks every explicitly requested Graph scope" {
            $scopes = @($scope, 'Directory.Read.All')
            $scenario = New-GraphScenario $scriptName (New-GraphContext @($scope)) (New-GraphContext $scopes)
            & $scenario.Module { param($Scopes) Connect-EndpointGraph -Scopes $Scopes } $scopes
            Assert-GraphConnection $scenario $scopes
        }
        Invoke-OfflineTest "$label rejects an incomplete returned Graph scope set" {
            $scopes = @($scope, 'Directory.Read.All')
            $scenario = New-GraphScenario $scriptName $null (New-GraphContext @($scope))
            Assert-Throws {
                & $scenario.Module { param($Scopes) Connect-EndpointGraph -Scopes $Scopes } $scopes
            } -Pattern 'refreshable delegated session'
            Assert-GraphConnection $scenario $scopes
        }
        Invoke-OfflineTest "$label propagates Graph sign-in failure without retry/fallback" {
            $scenario = New-GraphScenario $scriptName $null $null -ConnectError 'Injected Graph sign-in failure: AADSTS50076'
            Assert-Throws { & $scenario.Module { Connect-EndpointGraph } } -Pattern 'Injected Graph sign-in failure'
            Assert-Equal $scenario.State.Connections.Count 1 'only one Graph sign-in attempt'
            Assert-Equal $scenario.State.Connections[0].TenantId $customerTenant 'the only sign-in targets the selected tenant'
            Assert-Equal $scenario.State.Reads 1 'do not replay failed sign-in or request extra tokens'
        }
        Invoke-OfflineTest "$label propagates Graph context failure without hidden sign-in" {
            $scenario = New-GraphScenario $scriptName $null $null -ContextError 'Injected Graph context failure'
            Assert-Throws { & $scenario.Module { Connect-EndpointGraph } } -Pattern 'Injected Graph context failure'
            Assert-Equal $scenario.State.Connections.Count 0 'do not turn a context error into another login'
            Assert-Equal $scenario.State.Reads 1 'do not retry failed context discovery'
        }
    }

    . (Join-Path $PSScriptRoot 'Test-CyotArm.ps1')

    Invoke-OfflineTest 'Step3 explicit false remains a required Boolean value, not a missing input' {
        $module = New-OfflineModule $step3 @('Read-SetupValue')
        $value = & $module { Read-SetupValue -Name Migrated -DefaultValue $false -Required -ValueType Boolean }
        Assert-True ($value -is [bool]) 'return a Boolean rather than a string'
        Assert-Equal $value $false 'preserve the explicit new-CYOT-only migration choice'
        Assert-Throws {
            & $module { Read-SetupValue -Name Migrated -DefaultValue $null -Required -ValueType Boolean }
        } -Pattern 'Migrated.*required'
    }
    Invoke-OfflineTest 'Step3 unsupported schema stops before inputs, sign-in, approvals, backup or policy I/O' {
        $module = New-OfflineModule $step3 @('Invoke-CyotPolicyUpdate') -Variables @{ NonInteractive = $false }
        $snapshot = Join-Path $script:fixtureDirectory 'must-not-create-policy-backup.json'
        $filesBefore = @(Get-ChildItem -LiteralPath $script:fixtureDirectory -Recurse -Force | ForEach-Object FullName | Sort-Object)
        Assert-Throws {
            & $module {
                param($Snapshot)
                Invoke-CyotPolicyUpdate -SchemaStatus ([pscustomobject]@{
                    Supported = $false; Reason = 'Synthetic unsupported CYOT schema'
                    PolicyUri = 'https://graph.example.invalid/beta/policies/authenticationMethodsPolicy'
                }) -SnapshotPath $Snapshot
            } $snapshot
        } -Pattern 'Synthetic unsupported CYOT schema.*No policy change was attempted'
        Assert-True (-not (Test-Path -LiteralPath $snapshot)) 'unsupported schema must not create a backup'
        Assert-Sequence @(Get-ChildItem -LiteralPath $script:fixtureDirectory -Recurse -Force | ForEach-Object FullName | Sort-Object) $filesBefore 'unsupported schema has no file side effects'
    }
    Invoke-OfflineTest 'Step3 refuses to normalize away unknown existing policy fields' {
        $module = New-OfflineModule $step3 @('Get-CyotPolicyState')
        Assert-Throws {
            & $module {
                Get-CyotPolicyState -Policy ([pscustomobject]@{ cyot = [pscustomobject]@{
                    endpoint = 'https://delivery.example.invalid/api/SendOtp'
                    appId = '33333333-3333-4333-8333-333333333333'; migrated = $false
                    unexpected = 'must not be overwritten'
                } })
            }
        } -Pattern 'unsupported fields'
    }
}
finally {
    foreach ($entry in $savedEnvironment.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process')
    }
    if ($script:fixtureDirectory -and (Test-Path -LiteralPath $script:fixtureDirectory)) {
        Remove-Item -LiteralPath $script:fixtureDirectory -Recurse -Force
    }
    Pop-Location
}

Write-Host "`nOffline behavioral checks: $script:passed passed; $($script:failures.Count) failed."
if ($script:failures.Count) {
    throw "CYOT offline regressions failed:`n$($script:failures -join "`n")"
}
