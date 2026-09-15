#Requires -Version 7.0
# Dot-sourced only by the offline runner: assertions, ASTs, isolated modules and scratch scope are shared.

function New-ArmTestInput {
    param($Document, [string] $Leaf = "$([Guid]::NewGuid()).json")
    $directory = Join-Path $script:fixtureDirectory 'inputs'
    $null = [IO.Directory]::CreateDirectory($directory)
    $path = Join-Path $directory $Leaf
    $text = if ($Document -is [string]) { $Document } else { ConvertTo-Json -InputObject $Document -Depth 100 }
    [IO.File]::WriteAllText($path, $text, [Text.UTF8Encoding]::new($false))
    return $path
}

function Assert-NoArmScratch {
    Assert-Equal @(Get-ChildItem -LiteralPath $script:fixtureDirectory -File -Force).Count 0 'all generated request/secret snapshots must be removed'
}

function Assert-Utf8File {
    param([byte[]] $Bytes)
    Assert-True ($Bytes.Length -gt 0) 'the captured request file must not be empty'
    Assert-True (-not ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF)) 'use UTF-8 without BOM'
    $null = [Text.UTF8Encoding]::new($false, $true).GetString($Bytes)
}

function Assert-NoParameterLeak {
    param($Scenario, $Failure = $null)
    $text = ($Scenario.State.Messages -join "`n") + ($Scenario.State.Prompts -join "`n")
    if ($Failure) { $text += $Failure.Exception.Message }
    foreach ($marker in $Scenario.State.Markers) {
        Assert-True (-not $text.Contains($marker)) 'logs, prompts and errors must not expose parameter or secret values'
        foreach ($call in $Scenario.State.Calls) {
            Assert-True (-not (($call.Arguments -join ' ').Contains($marker))) 'send values via the file, never the command line'
        }
    }
}

function New-ArmDeploymentScenario {
    param([string] $ChangeType = 'Modify', [bool] $NonInteractive = $false, [string] $FailAt = '')
    $template = @{
        '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
        contentVersion = '1.0.0.0'; resources = @()
        parameters = @{
            location = @{ type = 'string' }; tags = @{ type = 'object' }
            enabled = @{ type = 'bool' }; count = @{ type = 'int' }; names = @{ type = 'array' }
            existingAppSettings = @{ type = 'secureObject' }
        }
        outputs = @{ functionAppResourceId = @{ type = 'string'; value = 'synthetic-resource-id' } }
    }
    $state = @{
        TemplatePath = New-ArmTestInput $template
        DeploymentName = 'cyot-offline-infrastructure'
        Parameters = @{
            location = 'synthetic-location-value'; tags = @{ Purpose = 'Entra - external = offline' }
            enabled = $true; count = 7; names = @('alpha', 'beta')
            existingAppSettings = @{ USER_KEEP = 'CYOT_SYNTHETIC_PARAMETER_DO_NOT_PRINT' }
        }
        Preview = @{ status = 'Succeeded'; changes = @(@{
            changeType = $ChangeType; resourceId = "/subscriptions/$selectedSubscription/resourceGroups/cyot-offline-rg/providers/Microsoft.Web/sites/cyot-offline"
            before = @{ hidden = 'CYOT_SYNTHETIC_BEFORE_DO_NOT_PRINT' }
            after = @{ hidden = 'CYOT_SYNTHETIC_AFTER_DO_NOT_PRINT' }
            delta = @(@{ path = 'properties.secret'; after = 'CYOT_SYNTHETIC_DELTA_DO_NOT_PRINT' })
        }) }
        Deployment = @{ properties = @{ provisioningState = 'Succeeded'; outputs = @{
            functionAppResourceId = @{ type = 'String'; value = 'synthetic-resource-id' }
        } } }
        Calls = [Collections.Generic.List[object]]::new(); Prompts = [Collections.Generic.List[string]]::new()
        Markers = @('synthetic-location-value', 'Entra - external = offline', 'CYOT_SYNTHETIC_PARAMETER_DO_NOT_PRINT',
            'CYOT_SYNTHETIC_BEFORE_DO_NOT_PRINT', 'CYOT_SYNTHETIC_AFTER_DO_NOT_PRINT', 'CYOT_SYNTHETIC_DELTA_DO_NOT_PRINT')
        Answer = 'Yes'; FailAt = $FailAt; MutateDuringApproval = $false; RawResults = @{}
    }
    $module = New-OfflineModule $step2 @(
        'Invoke-ArmTemplateDeployment', 'Invoke-AzResult', 'Assert-AzCommandSucceeded', 'Confirm-SetupAction'
    ) -State $state -Variables @{
        ResourceGroup = 'cyot-offline-rg'; AzureCliContext = (New-Subscription $selectedSubscription)
        GraphTenantId = $customerTenant; NonInteractive = $NonInteractive
    } -Mocks @{
        'Read-Host' = {
            param([string] $Prompt)
            if ($script:TestState.Prompts.Count) { Stop-UnmockedCall 'Repeated ARM approval' }
            $script:TestState.Prompts.Add($Prompt)
            if ($script:TestState.MutateDuringApproval) {
                [IO.File]::WriteAllText($script:TestState.TemplatePath, '{"changedAfterPreview":true}')
                $script:TestState.Parameters.location = 'changed-after-preview'
            }
            $script:TestState.Answer
        }
        'Invoke-AzCommand' = {
            param([string[]] $Arguments, [switch] $Interactive)
            $operation = $Arguments[0..2] -join ' '
            if ($Interactive -or $operation -notin @('deployment group what-if', 'deployment group create') -or
                $script:TestState.Calls.Count -ge 2) { Stop-UnmockedCall "Unexpected ARM command: $operation" }
            $parameterIndex = [Array]::IndexOf($Arguments, '--parameters')
            $templateIndex = [Array]::IndexOf($Arguments, '--template-file')
            if ($parameterIndex -lt 0 -or $templateIndex -lt 0 -or $Arguments[$parameterIndex + 1] -notlike '@*') {
                throw 'ARM calls must use external --template-file and --parameters @file.'
            }
            $parameterPath = [IO.Path]::GetFullPath($Arguments[$parameterIndex + 1].Substring(1))
            $templatePath = [IO.Path]::GetFullPath($Arguments[$templateIndex + 1])
            if ([IO.Path]::GetDirectoryName($parameterPath) -ne $script:FixtureDirectory) {
                Stop-UnmockedCall 'ARM parameters outside the test scratch directory'
            }
            $bytes = [IO.File]::ReadAllBytes($parameterPath)
            $script:TestState.Calls.Add([pscustomobject]@{
                Operation = $operation; Arguments = $Arguments; ParameterPath = $parameterPath
                ParameterBytes = $bytes; Parameters = [Text.UTF8Encoding]::new($false, $true).GetString($bytes) | ConvertFrom-Json -AsHashtable
                TemplatePath = $templatePath; TemplateText = [IO.File]::ReadAllText($templatePath)
            })
            if ($operation -eq $script:TestState.FailAt) {
                return [pscustomobject]@{ ExitCode = 73; Lines = @('Injected ARM failure: CYOT_SYNTHETIC_PARAMETER_DO_NOT_PRINT') }
            }
            if ($script:TestState.RawResults.ContainsKey($operation)) {
                return [pscustomobject]@{ ExitCode = 0; Lines = @($script:TestState.RawResults[$operation]) }
            }
            $body = if ($operation -eq 'deployment group what-if') { $script:TestState.Preview } else { $script:TestState.Deployment }
            [pscustomobject]@{ ExitCode = 0; Lines = @(ConvertTo-Json -InputObject $body -Depth 100 -Compress) }
        }
    }
    return @{ Module = $module; State = $state }
}

function Invoke-ArmDeploymentScenario {
    param($Scenario)
    & $Scenario.Module {
        Invoke-ArmTemplateDeployment -TemplatePath $script:TestState.TemplatePath `
            -DeploymentName $script:TestState.DeploymentName -Parameters $script:TestState.Parameters
    }
}

function Assert-ArmCalls {
    param($Scenario, [int] $Count = 2)
    $calls = $Scenario.State.Calls
    Assert-Equal $calls.Count $Count 'bounded what-if/deployment calls without hidden retries'
    foreach ($call in $calls) {
        Assert-Equal (Get-CliOption $call.Arguments @('--resource-group', '-g')) 'cyot-offline-rg' 'explicit resource group'
        Assert-Equal (Get-CliOption $call.Arguments @('--subscription')) $selectedSubscription 'explicit subscription'
        Assert-Equal (Get-CliOption $call.Arguments @('--output', '-o')) 'json' 'parse structured CLI results'
        Assert-Utf8File $call.ParameterBytes
        Assert-Sequence @($call.Parameters.Keys | Sort-Object) @('$schema', 'contentVersion', 'parameters') 'standard ARM parameter document'
        Assert-Equal $call.Parameters.'$schema' 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#' 'ARM parameter schema'
        Assert-Equal $call.Parameters.contentVersion '1.0.0.0' 'ARM parameter document version'
        Assert-Equal $call.Parameters.parameters.location.value 'synthetic-location-value' 'serialize string parameters'
        Assert-Equal $call.Parameters.parameters.tags.value.Purpose 'Entra - external = offline' 'preserve spaces and equals signs in JSON tags'
        Assert-True ($call.Parameters.parameters.enabled.value -is [bool] -and $call.Parameters.parameters.enabled.value) 'preserve Boolean types'
        Assert-Equal $call.Parameters.parameters.count.value 7 'preserve integer parameters'
        Assert-Sequence $call.Parameters.parameters.names.value @('alpha', 'beta') 'preserve array parameters'
        Assert-True ($call.Parameters.parameters.existingAppSettings.value -is [Collections.IDictionary]) 'preserve secure-object shape'
        Assert-True ($call.Parameters.parameters.existingAppSettings.value.USER_KEEP -ceq 'CYOT_SYNTHETIC_PARAMETER_DO_NOT_PRINT') 'preserve secure-object values in the file without printing them'
        Assert-True (-not (Test-Path -LiteralPath $call.ParameterPath)) 'delete parameter files on every outcome'
    }
    if ($Count -gt 0) {
        Assert-True ($calls[0].Arguments -contains '--no-pretty-print') 'what-if must not render parameter values'
        Assert-Equal (Get-CliOption $calls[0].Arguments @('--result-format')) 'ResourceIdOnly' 'request only resource change IDs/types'
    }
    if ($Count -eq 2) {
        Assert-Equal $calls[1].Operation 'deployment group create' 'deploy only after preview'
        Assert-Equal (Get-CliOption $calls[1].Arguments @('--mode')) 'Incremental' 'never use complete/deletion mode'
        Assert-True ($calls[1].Arguments -notcontains '--no-wait') 'wait for deployment completion'
        Assert-Equal $calls[1].ParameterPath $calls[0].ParameterPath 'deploy the approved parameter snapshot'
        Assert-Equal $calls[1].TemplatePath $calls[0].TemplatePath 'deploy the approved template snapshot'
        Assert-Equal $calls[1].TemplateText $calls[0].TemplateText 'template contents cannot change after preview'
        Assert-True (-not (Test-Path -LiteralPath $calls[1].TemplatePath)) 'delete the template snapshot'
    }
    Assert-NoArmScratch
}

Invoke-OfflineTest 'ARM deployment uses typed parameter files, safe preview, approval and unwrapped outputs' {
    $scenario = New-ArmDeploymentScenario
    $output = @(Invoke-ArmDeploymentScenario $scenario)
    Assert-Equal $output.Count 1 'return one outputs dictionary'
    Assert-True ($output[0] -is [Collections.IDictionary]) 'do not return the whole deployment or SDK objects'
    Assert-Sequence @($output[0].Keys) @('functionAppResourceId') 'do not return parameters, properties or secure inputs'
    Assert-Equal $output[0].functionAppResourceId 'synthetic-resource-id' 'unwrap each output value'
    Assert-Equal $scenario.State.Prompts.Count 1 'changed resources require approval'
    Assert-True (($scenario.State.Messages -join "`n").Contains('Modify: /subscriptions/')) 'display resource IDs and change types'
    Assert-ArmCalls $scenario
    Assert-NoParameterLeak $scenario
}
Invoke-OfflineTest 'ARM deployment snapshots approved files against concurrent template/parameter changes' {
    $scenario = New-ArmDeploymentScenario
    $scenario.State.MutateDuringApproval = $true
    Invoke-ArmDeploymentScenario $scenario | Out-Null
    Assert-ArmCalls $scenario
    Assert-True (-not $scenario.State.Calls[1].TemplateText.Contains('changedAfterPreview')) 'do not deploy later edits to the source JSON'
}
foreach ($change in @('Create', 'Modify', 'Ignore', 'Deploy', 'Unsupported')) {
    Invoke-OfflineTest "ARM noninteractive $change preview refuses deployment" {
        $scenario = New-ArmDeploymentScenario -ChangeType $change -NonInteractive $true
        $failure = Assert-Throws { Invoke-ArmDeploymentScenario $scenario } -Pattern 'Approval required' -PassThru
        Assert-Equal $scenario.State.Prompts.Count 0 'noninteractive mode must not prompt'
        Assert-ArmCalls $scenario 1
        Assert-NoParameterLeak $scenario $failure
    }
}
foreach ($empty in @($false, $true)) {
    Invoke-OfflineTest "ARM noninteractive no-change state is reusable (empty=$empty)" {
        $scenario = New-ArmDeploymentScenario -ChangeType 'NoChange' -NonInteractive $true
        if ($empty) { $scenario.State.Preview.changes = @() }
        Invoke-ArmDeploymentScenario $scenario | Out-Null
        Assert-Equal $scenario.State.Prompts.Count 0 'no-change preview needs no approval'
        Assert-ArmCalls $scenario
    }
}
foreach ($case in @('PreviewCli', 'DeployCli', 'Declined', 'FailedPreview', 'MissingStatus', 'NullPreview', 'ScalarPreview',
        'EmptyPreviewBody', 'WhitespacePreviewBody', 'MalformedPreviewJson', 'MissingChanges', 'NullChanges', 'InvalidChanges',
        'NullChange', 'ScalarChange', 'MissingResourceId', 'Delete', 'UnknownChange', 'PreviewError',
        'PendingDeployment', 'EmptyDeploymentBody', 'MalformedDeploymentJson', 'MissingOutputs', 'NullOutputs', 'OutputArray',
        'MissingDeclaredOutput', 'MissingOutputValue', 'NullOutput', 'SecureOutput', 'MalformedOutput')) {
    Invoke-OfflineTest "ARM fails closed and cleans snapshots ($case)" {
        $scenario = New-ArmDeploymentScenario
        $expectedCalls = 1
        switch ($case) {
            'PreviewCli' { $scenario.State.FailAt = 'deployment group what-if' }
            'DeployCli' { $scenario.State.FailAt = 'deployment group create'; $expectedCalls = 2 }
            'Declined' { $scenario.State.Answer = 'No' }
            'FailedPreview' { $scenario.State.Preview.status = 'Failed' }
            'MissingStatus' { $scenario.State.Preview.Remove('status') }
            'NullPreview' { $scenario.State.Preview = $null }
            'ScalarPreview' { $scenario.State.Preview = 'Succeeded' }
            'EmptyPreviewBody' { $scenario.State.RawResults['deployment group what-if'] = @() }
            'WhitespacePreviewBody' { $scenario.State.RawResults['deployment group what-if'] = @('   ') }
            'MalformedPreviewJson' { $scenario.State.RawResults['deployment group what-if'] = @('{"status":') }
            'MissingChanges' { $scenario.State.Preview.Remove('changes') }
            'NullChanges' { $scenario.State.Preview.changes = $null }
            'InvalidChanges' { $scenario.State.Preview.changes = @{ unexpected = 'not an array' } }
            'NullChange' { $scenario.State.Preview.changes = @($null) }
            'ScalarChange' { $scenario.State.Preview.changes = @('not a change object') }
            'MissingResourceId' { $scenario.State.Preview.changes[0].Remove('resourceId') }
            'Delete' { $scenario.State.Preview.changes[0].changeType = 'Delete' }
            'UnknownChange' { $scenario.State.Preview.changes[0].changeType = 'FutureUnknownChange' }
            'PreviewError' { $scenario.State.Preview.error = @{ code = 'InvalidTemplate' } }
            'PendingDeployment' { $scenario.State.Deployment.properties.provisioningState = 'Running'; $expectedCalls = 2 }
            'EmptyDeploymentBody' { $scenario.State.RawResults['deployment group create'] = @(); $expectedCalls = 2 }
            'MalformedDeploymentJson' { $scenario.State.RawResults['deployment group create'] = @('{"properties":'); $expectedCalls = 2 }
            'MissingOutputs' { $scenario.State.Deployment.properties.Remove('outputs'); $expectedCalls = 2 }
            'NullOutputs' { $scenario.State.Deployment.properties.outputs = $null; $expectedCalls = 2 }
            'OutputArray' { $scenario.State.Deployment.properties.outputs = @(); $expectedCalls = 2 }
            'MissingDeclaredOutput' { $scenario.State.Deployment.properties.outputs = @{}; $expectedCalls = 2 }
            'MissingOutputValue' { $scenario.State.Deployment.properties.outputs.functionAppResourceId.Remove('value'); $expectedCalls = 2 }
            'NullOutput' { $scenario.State.Deployment.properties.outputs.functionAppResourceId = $null; $expectedCalls = 2 }
            'SecureOutput' { $scenario.State.Deployment.properties.outputs.functionAppResourceId.type = 'secureString'; $expectedCalls = 2 }
            'MalformedOutput' { $scenario.State.Deployment.properties.outputs.functionAppResourceId = 'not an output object'; $expectedCalls = 2 }
        }
        $failure = Assert-Throws { Invoke-ArmDeploymentScenario $scenario } -PassThru
        Assert-ArmCalls $scenario $expectedCalls
        Assert-NoParameterLeak $scenario $failure
    }
}
foreach ($case in @('Missing', 'Unknown')) {
    Invoke-OfflineTest "ARM rejects $case parameters before CLI calls" {
        $scenario = New-ArmDeploymentScenario
        if ($case -eq 'Missing') { $scenario.State.Parameters.Remove('location') }
        else { $scenario.State.Parameters.undeclared = 'not accepted' }
        Assert-Throws { Invoke-ArmDeploymentScenario $scenario } -Pattern "$case ARM parameter"
        Assert-Equal $scenario.State.Calls.Count 0 'reject invalid parameter sets before preview'
        Assert-NoArmScratch
    }
}

foreach ($missing in @('', 'infrastructure.json', 'function-config.json')) {
    Invoke-OfflineTest "ARM template paths resolve from SetupDirectory, not cwd (missing=$missing)" {
        $packageDirectory = Join-Path $script:fixtureDirectory "inputs\package-$([Guid]::NewGuid())"
        $armDirectory = Join-Path $packageDirectory 'arm'
        $null = [IO.Directory]::CreateDirectory($armDirectory)
        foreach ($leaf in @('infrastructure.json', 'function-config.json')) {
            if ($leaf -ne $missing) { [IO.File]::WriteAllText((Join-Path $armDirectory $leaf), '{"parameters":{},"resources":[]}') }
        }
        $module = New-OfflineModule $step2 @('Get-ArmTemplatePaths') -Variables @{ SetupDirectory = $packageDirectory }
        if ($missing) { Assert-Throws { & $module { Get-ArmTemplatePaths } } -Pattern 'Missing ARM template' }
        else {
            $paths = & $module { Get-ArmTemplatePaths }
            foreach ($entry in @{ Infrastructure = 'infrastructure.json'; Configuration = 'function-config.json' }.GetEnumerator()) {
                Assert-Equal $paths[$entry.Key] (Join-Path $armDirectory $entry.Value) 'load the separate companion JSON file'
                Assert-True ([IO.Path]::IsPathFullyQualified($paths[$entry.Key])) 'template paths must be absolute'
            }
        }
    }
}

foreach ($case in @(
    @{ Phase = 'infrastructure'; Limit = 64 }
    @{ Phase = 'configuration'; Limit = 64 }
    @{ Phase = 'plan'; Limit = 40 }
)) {
    Invoke-OfflineTest "Deployment names hash the full Function name within the $($case.Limit)-character limit ($($case.Phase))" {
        $module = New-OfflineModule $step2 @('Get-DeploymentName')
        $first = 'cyot-' + ('a' * 54) + 'x'
        $second = 'cyot-' + ('a' * 54) + 'y'
        $names = @(& $module {
            param($First, $Second, $Phase, $Limit)
            Get-DeploymentName -FunctionName $First -Phase $Phase -MaximumLength $Limit
            Get-DeploymentName -FunctionName $Second -Phase $Phase -MaximumLength $Limit
            Get-DeploymentName -FunctionName $First -Phase $Phase -MaximumLength $Limit
        } $first $second $case.Phase $case.Limit)
        Assert-Equal $first.Length 60 'exercise the maximum Function name length'
        Assert-Equal $names.Count 3 'return one deployment-name string per call'
        foreach ($name in $names) {
            Assert-True ($name -is [string] -and $name.Length -le $case.Limit) 'do not exceed the exact ARM name limit'
            Assert-True ($name -cmatch '^[A-Za-z0-9-]+$') 'generate valid deployment-name characters'
            Assert-True $name.EndsWith("-$($case.Phase)") 'retain the phase identifier'
        }
        Assert-True ($names[0] -cne $names[1]) 'names sharing the truncated prefix must remain distinct'
        Assert-Equal $names[0] $names[2] 'the same input must produce a stable name on rerun'
    }
}
Invoke-OfflineTest 'Deployment naming rejects an impossible length limit' {
    $module = New-OfflineModule $step2 @('Get-DeploymentName')
    Assert-Throws { & $module { Get-DeploymentName -FunctionName 'cyot-offline' -Phase infrastructure -MaximumLength 5 } } -Pattern 'length limit'
}

function New-SecretScenario {
    param([bool] $NonInteractive = $false, [string] $Case = 'Success')
    $state = @{
        Value = "CYOT_SYNTHETIC_SECRET_DO_NOT_PRINT`nsecond line = caf$([char]0x00E9)"
        Markers = @('CYOT_SYNTHETIC_SECRET_DO_NOT_PRINT'); Case = $Case
        Calls = [Collections.Generic.List[object]]::new(); Prompts = [Collections.Generic.List[string]]::new()
        Sleeps = 0
    }
    $module = New-OfflineModule $step2 @(
        'Set-EndpointSecret', 'Invoke-AzResult', 'Assert-AzCommandSucceeded', 'Confirm-SetupAction'
    ) -Variables @{
        NonInteractive = $NonInteractive; AzureCliContext = (New-Subscription $selectedSubscription); GraphTenantId = $customerTenant
    } -State $state -Mocks @{
        'Read-Host' = { param([string] $Prompt) $script:TestState.Prompts.Add($Prompt); if ($script:TestState.Case -eq 'Declined') { 'No' } else { 'Yes' } }
        'Start-Sleep' = { param([int] $Seconds) $script:TestState.Sleeps++; if ($script:TestState.Sleeps -gt 5) { Stop-UnmockedCall 'Unbounded secret retry' } }
        'Invoke-AzCommand' = {
            param([string[]] $Arguments, [switch] $Interactive)
            if ($Interactive -or ($Arguments[0..2] -join ' ') -ne 'keyvault secret set' -or $script:TestState.Calls.Count -ge 6) {
                Stop-UnmockedCall 'Unexpected secret operation'
            }
            $index = [Array]::IndexOf($Arguments, '--file')
            if ($index -lt 0) { throw 'Secret upload must use --file, never --value.' }
            $path = [IO.Path]::GetFullPath($Arguments[$index + 1])
            if ([IO.Path]::GetDirectoryName($path) -ne $script:FixtureDirectory) { Stop-UnmockedCall 'Secret file outside test scratch' }
            $script:TestState.Calls.Add([pscustomobject]@{ Arguments = $Arguments; Path = $path; Bytes = [IO.File]::ReadAllBytes($path) })
            $case = $script:TestState.Case
            if ($case -eq 'CliError') { return [pscustomobject]@{ ExitCode = 74; Lines = @("Injected secret failure: $($script:TestState.Value)") } }
            if ($case -eq 'RbacExhausted' -or ($case -eq 'RbacRetry' -and $script:TestState.Calls.Count -eq 1)) {
                return [pscustomobject]@{ ExitCode = 75; Lines = @('ForbiddenByRbac') }
            }
            $uri = switch ($case) {
                'MissingUri' { '' }
                'WrongUri' { 'https://another-vault.vault.azure.net/secrets/phone-provider-decryption-key/synthetic-version' }
                default { 'https://cyot-offline-vault.vault.azure.net/secrets/phone-provider-decryption-key/synthetic-version' }
            }
            [pscustomobject]@{ ExitCode = 0; Lines = @($uri) }
        }
    }
    return @{ Module = $module; State = $state }
}
foreach ($case in @('Success', 'CliError', 'WrongUri', 'MissingUri', 'Declined', 'NonInteractive', 'RbacRetry', 'RbacExhausted')) {
    Invoke-OfflineTest "Key Vault secret upload uses a UTF-8 file and cleans it ($case)" {
        $scenario = New-SecretScenario -Case $case -NonInteractive ($case -eq 'NonInteractive')
        $action = { & $scenario.Module {
            Set-EndpointSecret -VaultName 'cyot-offline-vault' -SecretName 'phone-provider-decryption-key' -Value $script:TestState.Value
        } }
        $failure = $null
        if ($case -in @('Success', 'RbacRetry')) {
            Assert-Equal (& $action) 'https://cyot-offline-vault.vault.azure.net/secrets/phone-provider-decryption-key' 'return the validated versionless secret URI'
        }
        else { $failure = Assert-Throws $action -PassThru }
        $expectedCount = switch ($case) { 'Declined' { 0 }; 'NonInteractive' { 0 }; 'RbacRetry' { 2 }; 'RbacExhausted' { 6 }; default { 1 } }
        Assert-Equal $scenario.State.Calls.Count $expectedCount 'only bounded RBAC-propagation retries are allowed'
        foreach ($call in $scenario.State.Calls) {
            Assert-True ($call.Arguments -notcontains '--value') 'never put a secret in argv'
            Assert-Equal (Get-CliOption $call.Arguments @('--encoding')) 'utf-8' 'tell CLI how to read the secret file'
            Assert-Equal (Get-CliOption $call.Arguments @('--subscription')) $selectedSubscription 'pin secret writes to the selected subscription'
            Assert-Utf8File $call.Bytes
            Assert-True ([Text.Encoding]::UTF8.GetString($call.Bytes) -ceq $scenario.State.Value) 'preserve the complete multiline secret'
            Assert-True (-not (Test-Path -LiteralPath $call.Path)) 'remove secret files after success or failure'
        }
        Assert-NoParameterLeak $scenario $failure
        Assert-NoArmScratch
    }
}

$commonObsolete = @('AzureWebJobsStorage', 'DEPLOYMENT_STORAGE_CONNECTION_STRING', 'AzureWebJobsStorage__clientId')
$flexObsolete = @('FUNCTIONS_WORKER_RUNTIME', 'FUNCTIONS_EXTENSION_VERSION', 'WEBSITE_NODE_DEFAULT_VERSION',
    'WEBSITE_RUN_FROM_PACKAGE', 'WEBSITE_CONTENTAZUREFILECONNECTIONSTRING', 'WEBSITE_CONTENTSHARE', 'WEBSITE_SKIP_CONTENTSHARE_VALIDATION')
foreach ($plan in @('FlexConsumption', 'Premium')) {
    Invoke-OfflineTest "Appsetting adoption removes only obsolete owned settings ($plan)" {
        $settings = @{ UNRELATED_CUSTOM_SETTING = 'preserve me'; EPP_PROVIDER_NAME = 'retained until managed merge' }
        foreach ($name in $commonObsolete + $flexObsolete) { $settings[$name] = 'old-owned-value' }
        $module = New-OfflineModule $step2 @('Remove-ObsoleteAppSettings')
        $result = & $module { param($Settings, $Plan) Remove-ObsoleteAppSettings -Settings $Settings -PlanType $Plan } $settings $plan
        $removed = $commonObsolete + $(if ($plan -eq 'FlexConsumption') { $flexObsolete } else { @() })
        foreach ($name in $removed) { Assert-True (-not $result.ContainsKey($name)) "remove obsolete $name" }
        foreach ($name in $settings.Keys | Where-Object { $_ -notin $removed }) {
            Assert-Equal $result[$name] $settings[$name] "preserve unrelated/remaining setting $name"
        }
        Assert-Equal $settings.Count ($commonObsolete.Count + $flexObsolete.Count + 2) 'do not mutate the caller snapshot'
        Assert-True (-not [object]::ReferenceEquals($settings, $result)) 'return a separate settings dictionary'
    }
}

foreach ($case in @('Adopt', 'None', 'Ambiguous', 'CliError')) {
    Invoke-OfflineTest "RBAC adoption matches exact principal, scope and role across pages ($case)" {
        $scope = "/subscriptions/$selectedSubscription/resourceGroups/cyot-offline-rg/providers/Microsoft.Storage/storageAccounts/cyotoffline"
        $principal = '66666666-6666-4666-8666-666666666666'
        $role = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
        $oldName = '77777777-7777-4777-8777-777777777777'
        $match = @{ name = $oldName; properties = @{ principalId = $principal; scope = $scope; roleDefinitionId = "/subscriptions/$selectedSubscription/providers/Microsoft.Authorization/roleDefinitions/$role" } }
        $decoys = foreach ($field in @('principalId', 'scope', 'roleDefinitionId')) {
            $copy = $match | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable
            $copy.properties[$field] = 'does-not-match'
            $copy
        }
        $state = @{
            Pages = @(
                @{ value = @($decoys) + $(if ($case -eq 'Ambiguous') { @($match) } else { @() }); nextLink = "https://management.azure.com$scope/providers/Microsoft.Authorization/roleAssignments?offlinePage=2" }
                @{ value = @($(if ($case -ne 'None') { $match })); nextLink = $null }
            )
            Calls = [Collections.Generic.List[object]]::new(); Case = $case
        }
        $module = New-OfflineModule $step2 @('Get-ExistingRoleAssignmentName', 'Get-AzJson', 'Invoke-Az', 'Invoke-AzResult', 'Assert-AzCommandSucceeded') `
            -Variables @{ AzureCliContext = (New-Subscription $selectedSubscription) } -State $state -Mocks @{
                'Invoke-AzCommand' = {
                    param([string[]] $Arguments)
                    if (($Arguments[0..2] -join ' ') -ne 'rest --method get' -or $script:TestState.Calls.Count -ge 2) { Stop-UnmockedCall 'Unexpected RBAC operation' }
                    $index = $script:TestState.Calls.Count
                    $script:TestState.Calls.Add($Arguments)
                    if ($script:TestState.Case -eq 'CliError') { return [pscustomobject]@{ ExitCode = 76; Lines = @('Injected role inventory error') } }
                    [pscustomobject]@{ ExitCode = 0; Lines = @(ConvertTo-Json -InputObject $script:TestState.Pages[$index] -Depth 20 -Compress) }
                }
            }
        $action = { & $module { param($Scope, $Principal, $Role) Get-ExistingRoleAssignmentName -Scope $Scope -PrincipalId $Principal -RoleId $Role } $scope $principal $role }
        if ($case -in @('Ambiguous', 'CliError')) { Assert-Throws $action }
        else { Assert-Equal (& $action) $(if ($case -eq 'Adopt') { $oldName } else { '' }) 'adopt the existing assignment name rather than inventing another ID' }
        Assert-Equal $state.Calls.Count $(if ($case -eq 'CliError') { 1 } else { 2 }) 'follow pagination once and stop on errors'
        foreach ($arguments in $state.Calls) {
            Assert-Equal (Get-CliOption $arguments @('--subscription')) $selectedSubscription 'scope role inventory explicitly'
        }
    }
}

foreach ($case in @('Resolved', 'ResolvedFlex', 'Pagination', 'RetryThenResolved', 'MissingDecryption', 'MissingContent',
        'Empty', 'Malformed', 'InvalidSyntax', 'VaultNotFound', 'SecretNotFound', 'SecretVersionNotFound',
        'UnauthorizedClient', 'Pending', 'UnknownStatus', 'RefreshError', 'ReadError')) {
    Invoke-OfflineTest "Key Vault reference readiness is bounded, fail-closed and does not expose values ($case)" {
        $state = @{
            Case = $case; Attempts = 0; Reads = 0; Page = 0
            ResourceId = "/subscriptions/$selectedSubscription/resourceGroups/cyot-offline-rg/providers/Microsoft.Web/sites/cyot-offline"
            Names = @('EPP_DECRYPTION_KEY_PEM') + $(if ($case -ne 'ResolvedFlex') { @('WEBSITE_CONTENTAZUREFILECONNECTIONSTRING') } else { @() })
            Calls = [Collections.Generic.List[object]]::new(); Sleeps = [Collections.Generic.List[int]]::new()
            Prompts = [Collections.Generic.List[string]]::new()
            Markers = @('CYOT_REFERENCE_VALUE_DO_NOT_PRINT', 'CYOT_REFERENCE_DETAILS_DO_NOT_PRINT')
        }
        $module = New-OfflineModule $step2 @('Wait-EndpointConfiguration', 'Get-AzJson', 'Invoke-Az',
            'Invoke-AzResult', 'Assert-AzCommandSucceeded') -Variables @{
                AzureCliContext = (New-Subscription $selectedSubscription)
            } -State $state -Mocks @{
                'Start-Sleep' = {
                    param([int] $Seconds)
                    $script:TestState.Sleeps.Add($Seconds)
                    if ($script:TestState.Sleeps.Count -gt 5) { Stop-UnmockedCall 'Unbounded readiness wait' }
                }
                'Invoke-AzCommand' = {
                    param([string[]] $Arguments, [switch] $Interactive)
                    if ($Interactive -or $Arguments[0] -ne 'rest') { Stop-UnmockedCall 'Unexpected readiness operation' }
                    $method = $Arguments[[Array]::IndexOf($Arguments, '--method') + 1]
                    $url = $Arguments[[Array]::IndexOf($Arguments, '--url') + 1]
                    $base = "https://management.azure.com$($script:TestState.ResourceId)/config/configreferences/appsettings"
                    $firstPage = "${base}?api-version=2024-04-01"
                    $nextPage = $firstPage + '&$skiptoken=synthetic-page-two'
                    $script:TestState.Calls.Add([pscustomobject]@{ Arguments = $Arguments; Method = $method; Url = $url })
                    if ($method -eq 'post' -and $url -eq "$base/refresh?api-version=2024-04-01") {
                        $script:TestState.Attempts++; $script:TestState.Page = 0
                        if ($script:TestState.Attempts -gt 6) { Stop-UnmockedCall 'Unbounded reference refresh' }
                        $code = if ($script:TestState.Case -eq 'RefreshError') { 77 } else { 0 }
                        return [pscustomobject]@{ ExitCode = $code; Lines = @('Injected reference refresh response') }
                    }
                    if ($method -ne 'get' -or $script:TestState.Attempts -eq 0 -or
                        ($script:TestState.Page -eq 0 -and $url -ne $firstPage) -or
                        ($script:TestState.Page -eq 1 -and ($url -ne $nextPage -or $script:TestState.Case -ne 'Pagination')) -or
                        $script:TestState.Page -gt 1) { Stop-UnmockedCall 'Invalid reference status endpoint/pagination/order' }
                    $script:TestState.Reads++; $script:TestState.Page++
                    if ($script:TestState.Case -eq 'ReadError') {
                        return [pscustomobject]@{ ExitCode = 78; Lines = @('Injected reference read error') }
                    }
                    $records = [Collections.Generic.List[object]]::new()
                    foreach ($name in $script:TestState.Names) {
                        if (($script:TestState.Case -eq 'MissingDecryption' -and $name -eq 'EPP_DECRYPTION_KEY_PEM') -or
                            ($script:TestState.Case -eq 'MissingContent' -and $name -eq 'WEBSITE_CONTENTAZUREFILECONNECTIONSTRING') -or
                            $script:TestState.Case -eq 'Empty') { continue }
                        if ($script:TestState.Case -eq 'Pagination' -and (
                            ($script:TestState.Page -eq 1 -and $name -ne 'EPP_DECRYPTION_KEY_PEM') -or
                            ($script:TestState.Page -eq 2 -and $name -eq 'EPP_DECRYPTION_KEY_PEM'))) { continue }
                        $status = switch ($script:TestState.Case) {
                            { $_ -in @('InvalidSyntax', 'VaultNotFound', 'SecretNotFound', 'SecretVersionNotFound', 'UnauthorizedClient') } { $_ }
                            'Pending' { 'AccessToKeyVaultDenied' }
                            'UnknownStatus' { 'FutureUnresolvedStatus' }
                            'RetryThenResolved' { if ($script:TestState.Attempts -eq 1) { 'AccessToKeyVaultDenied' } else { 'Resolved' } }
                            default { 'Resolved' }
                        }
                        $records.Add(@{ id = "$base/$($name.Replace('_', '%5F'))"; properties = @{
                            status = $status; value = 'CYOT_REFERENCE_VALUE_DO_NOT_PRINT'; details = 'CYOT_REFERENCE_DETAILS_DO_NOT_PRINT'
                        } })
                    }
                    $records.Add(@{ id = "$base/UNRELATED_SETTING"; properties = @{ status = 'UnauthorizedClient' } })
                    $page = @{ value = $records.ToArray(); nextLink = $null }
                    if ($script:TestState.Case -eq 'Empty') { $page.value = @() }
                    if ($script:TestState.Case -eq 'Malformed') { $page.value = @{ unexpected = 'not a collection' } }
                    if ($script:TestState.Case -eq 'Pagination' -and $script:TestState.Page -eq 1) { $page.nextLink = $nextPage }
                    [pscustomobject]@{ ExitCode = 0; Lines = @(ConvertTo-Json -InputObject $page -Depth 15 -Compress) }
                }
            }
        $action = { & $module { Wait-EndpointConfiguration -FunctionResourceId $script:TestState.ResourceId -SettingNames $script:TestState.Names } }
        $failure = $null
        if ($case -in @('Resolved', 'ResolvedFlex', 'Pagination', 'RetryThenResolved')) {
            Assert-Equal @(& $action).Count 0 'readiness success emits no SDK/status objects'
        }
        else { $failure = Assert-Throws $action -PassThru }
        $attempts = if ($case -eq 'RetryThenResolved') { 2 }
            elseif ($case -in @('MissingDecryption', 'MissingContent', 'Empty', 'Pending', 'UnknownStatus')) { 6 }
            else { 1 }
        Assert-Equal $state.Attempts $attempts 'six attempts maximum; fatal syntax/vault/secret/client errors fail immediately'
        Assert-Equal $state.Sleeps.Count ($attempts - 1) 'no sleep after the final attempt or a fatal error'
        foreach ($seconds in $state.Sleeps) { Assert-Equal $seconds 15 'exact bounded readiness retry interval' }
        Assert-Equal $state.Reads $(if ($case -eq 'RefreshError') { 0 } elseif ($case -eq 'Pagination') { 2 } else { $attempts }) 'follow nextLink and refresh before each new attempt'
        foreach ($call in $state.Calls) {
            Assert-Equal (Get-CliOption $call.Arguments @('--subscription')) $selectedSubscription 'readiness requests retain explicit scope'
        }
        Assert-NoParameterLeak @{ State = $state } $failure
    }
}

function New-Step2PhaseScenario {
    param([string] $Plan = 'FlexConsumption', [string] $FailAt = '', [switch] $ExistingEndpoint)
    $group = 'cyot-offline-rg'
    $prefix = "/subscriptions/$selectedSubscription/resourceGroups/$group/providers"
    $state = @{
        Plan = $Plan; FailAt = $FailAt; ExistingEndpoint = [bool]$ExistingEndpoint
        Events = [Collections.Generic.List[string]]::new(); ArmCalls = [Collections.Generic.List[object]]::new()
        SecretValues = [Collections.Generic.List[string]]::new(); Certificate = $null
        Templates = @{
            Infrastructure = New-ArmTestInput @{ parameters = @{}; resources = @() } "$([Guid]::NewGuid())-infrastructure.json"
            Configuration = New-ArmTestInput @{ parameters = @{}; resources = @() } "$([Guid]::NewGuid())-function-config.json"
        }
        Application = [pscustomobject]@{
            Id = '44444444-4444-4444-8444-444444444444'; AppId = '33333333-3333-4333-8333-333333333333'
            Api = [pscustomobject]@{ RequestedAccessTokenVersion = 1 }
        }
        Infrastructure = @{
            functionAppResourceId = "$prefix/Microsoft.Web/sites/cyot-offline"
            defaultHostName = 'actual-arm-host.example.invalid'
            systemAssignedPrincipalId = '66666666-6666-4666-8666-666666666666'
            outboundIdentityResourceId = "$prefix/Microsoft.ManagedIdentity/userAssignedIdentities/cyot-outbound"
            outboundIdentityClientId = '88888888-8888-4888-8888-888888888888'
            outboundIdentityPrincipalId = '99999999-9999-4999-8999-999999999999'
            storageAccountResourceId = "$prefix/Microsoft.Storage/storageAccounts/cyotoffline"
            keyVaultResourceId = "$prefix/Microsoft.KeyVault/vaults/cyot-offline-vault"
            keyVaultUri = 'https://cyot-offline-vault.vault.azure.net/'
            applicationInsightsResourceId = "$prefix/Microsoft.Insights/components/cyot-offline"
            deploymentContainerName = 'old-releases'; contentShareName = $(if ($Plan -eq 'Premium') { 'old-content' } else { '' })
            contentStorageSecretName = $(if ($Plan -eq 'Premium') { 'phone-provider-content-storage' } else { '' }); planType = $Plan
        }
        Existing = @{ tags = @{ function = @{ KEEP = 'existing tag' } }; userAssignedIdentities = @{ unrelated = @{} }
            roleAssignmentNames = @{ storageBlob = '77777777-7777-4777-8777-777777777777' } }
        Settings = @{ USER_KEEP = 'synthetic preserved appsetting'; AzureWebJobsStorage = 'obsolete'; WEBSITE_RUN_FROM_PACKAGE = 'obsolete' }
        Configuration = @{ functionAppResourceId = "$prefix/Microsoft.Web/sites/cyot-offline" }
    }
    $variables = @{
        TenantId = $customerTenant; ApplicationId = $state.Application.AppId; FunctionAppName = 'cyot-offline'
        EndpointUrl = $(if ($ExistingEndpoint) { 'https://existing-endpoint.example.invalid/api/SendOtp' } else { '' })
        NonInteractive = $true; SubscriptionId = $selectedSubscription; ResourceGroup = $group; Location = 'westus2'; PlanType = $Plan
        StorageAccountName = 'cyotoffline'; KeyVaultName = 'cyot-offline-vault'; OutboundIdentityName = 'cyot-outbound'
        CertificatePath = ''; ZipPath = 'synthetic-package.zip'; ZipUrl = ''; FunctionRoute = '/api/SendOtp'
        ProviderName = 'synthetic-provider'; ProviderEndpoint = 'https://provider.example.invalid'
        ProviderTimeoutMs = 1500; ProviderRetryIntervalMs = 0; ProviderAccountName = 'synthetic-account'
        ProviderTenantId = $otherTenant; ProviderScope = 'api://provider.example.invalid/.default'
        ResourceTagName = 'Purpose'; ResourceTagValue = 'Entra - External = Phone Provider'; NoEasyAuth = $false
        ProvidedParameters = @{ ProviderTimeoutMs = 1500; ProviderRetryIntervalMs = 0 }
        MicrosoftPhoneProviderAppId = '25ec60fa-f18d-41a4-b398-50044c90ce13'; SetupDirectory = $script:fixtureDirectory
    }
    $module = New-OfflineModule $step2 @('Invoke-Step2Setup', 'Read-SetupValue', 'Get-ProviderAppSettings',
        'Get-ProviderEntraSettings', 'Get-RequiredArmOutput', 'Get-ResourceId', 'Get-DeploymentName',
        'Remove-ObsoleteAppSettings', 'Write-Step') -State $state -Variables $variables -Mocks @{
        'Trace-Phase' = {
            param([string] $Name)
            $script:TestState.Events.Add($Name)
            if ($script:TestState.FailAt -eq $Name) { throw "Injected phase failure: $Name" }
        }
        'Get-Command' = {
            param([string] $Name)
            if ($Name -ne 'az' -or $script:TestState.ExistingEndpoint) { Stop-UnmockedCall 'Unexpected Azure CLI discovery' }
            [pscustomobject]@{ Name = 'az' }
        }
        'Get-ArmTemplatePaths' = { Trace-Phase 'templates'; $script:TestState.Templates }
        'Resolve-FunctionPackage' = { param($Path, $Url) Trace-Phase 'package'; @{ Path = 'synthetic-package.zip'; Temporary = $false } }
        'Initialize-AzureCliAuthentication' = { Trace-Phase 'azure-auth'; $script:AzureCliContext = [pscustomobject]@{ id = $SubscriptionId } }
        'Connect-EndpointGraph' = { param([string[]] $Scopes) Trace-Phase 'graph' }
        'Get-CyotApplication' = {
            param([string] $ApplicationId, [switch] $RequireMultiTenant)
            if ($ApplicationId -ne $script:TestState.Application.AppId -or -not $RequireMultiTenant) { Stop-UnmockedCall 'Unpinned application lookup' }
            Trace-Phase 'application'; $script:TestState.Application
        }
        'Get-ExistingDeploymentState' = {
            param([string] $DeployerObjectId)
            Trace-Phase 'inventory'
            @{ hostingPlanName = 'old-plan'; workspaceName = 'old-workspace'; deploymentContainerName = 'old-releases'; contentShareName = 'old-content'; existing = $script:TestState.Existing }
        }
        'Invoke-ArmTemplateDeployment' = {
            param([string] $TemplatePath, [string] $DeploymentName, [hashtable] $Parameters)
            $phase = if ($TemplatePath -eq $script:TestState.Templates.Infrastructure) { 'infrastructure' }
                elseif ($TemplatePath -eq $script:TestState.Templates.Configuration) { 'configuration' }
                else { Stop-UnmockedCall 'Deployment did not use one of the two separate template paths' }
            Trace-Phase $phase
            $script:TestState.ArmCalls.Add([pscustomobject]@{ Phase = $phase; TemplatePath = $TemplatePath; DeploymentName = $DeploymentName; Parameters = $Parameters })
            if ($phase -eq 'infrastructure') { $script:TestState.Infrastructure } else { $script:TestState.Configuration }
        }
        'Get-EndpointCertificate' = {
            param([string] $EndpointHost, [string] $Path)
            Trace-Phase 'certificate'
            $rsa = [Security.Cryptography.RSA]::Create(2048)
            try {
                $request = [Security.Cryptography.X509Certificates.CertificateRequest]::new("CN=$EndpointHost", $rsa,
                    [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
                $script:TestState.Certificate = $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-1), [DateTimeOffset]::UtcNow.AddDays(1))
            }
            finally { $rsa.Dispose() }
            $script:TestState.Certificate
        }
        'Publish-EndpointRegistration' = {
            param($Application, $Certificate, [string] $EndpointHost)
            Trace-Phase 'registration'
            @{ IdentifierUri = "api://$EndpointHost/$($Application.AppId)"; EncryptionKeyId = 'abcdefab-1234-4123-8123-abcdefabcdef' }
        }
        'Ensure-ProviderFederation' = {
            param($Application, [string] $PrincipalId)
            Trace-Phase 'federation'
            if ($PrincipalId -ne $script:TestState.Infrastructure.outboundIdentityPrincipalId) { Stop-UnmockedCall 'Federation did not use the actual ARM principal' }
        }
        'Set-EndpointSecret' = {
            param([string] $VaultName, [string] $SecretName, [string] $Value)
            Trace-Phase "secret:$SecretName"
            $script:TestState.SecretValues.Add($Value)
            "https://$VaultName.vault.azure.net/secrets/$SecretName"
        }
        'Get-ExistingAppSettings' = { Trace-Phase 'settings'; $script:TestState.Settings }
        'Wait-EndpointConfiguration' = {
            param([string] $FunctionResourceId, [string[]] $SettingNames)
            Trace-Phase 'references'
            $expectedNames = @('EPP_DECRYPTION_KEY_PEM')
            if ($script:TestState.Plan -eq 'Premium') { $expectedNames += 'WEBSITE_CONTENTAZUREFILECONNECTIONSTRING' }
            if ($FunctionResourceId -ne $script:TestState.Infrastructure.functionAppResourceId -or
                $SettingNames.Count -ne $expectedNames.Count -or
                @($expectedNames | Where-Object { $SettingNames -notcontains $_ }).Count) {
                Stop-UnmockedCall 'Required Key Vault reference readiness was not checked'
            }
        }
        'Confirm-SetupAction' = { param($Action, $Target, $Details) if ($Action -ne 'deploy Function package') { Stop-UnmockedCall "Unexpected approval: $Action" } }
        'Invoke-Az' = {
            if ($script:TestState.ExistingEndpoint) { Stop-UnmockedCall 'Azure CLI in existing-endpoint mode' }
            $operation = ($args | Select-Object -First 3) -join ' '
            switch ($operation) {
                'group exists --name' { 'true' }
                'ad signed-in-user show' { '12121212-1212-4212-8212-121212121212' }
                'storage account keys' { Trace-Phase 'content-key'; 'CYOT_SYNTHETIC_STORAGE_KEY_DO_NOT_PRINT' }
                'functionapp deployment source' {
                    if ($args -notcontains 'config-zip') { Stop-UnmockedCall 'Unexpected publication method' }
                    Trace-Phase 'zip'
                }
                default { Stop-UnmockedCall "Unexpected orchestration CLI operation: $operation" }
            }
        }
    }
    return @{ Module = $module; State = $state }
}

foreach ($plan in @('FlexConsumption', 'Premium')) {
    Invoke-OfflineTest "One Step2 orchestrator deploys two external templates around Graph/secret work ($plan)" {
        $scenario = New-Step2PhaseScenario -Plan $plan
        $result = @(& $scenario.Module { Invoke-Step2Setup })
        Assert-Equal $result.Count 1 'return only the original Stage2 result object'
        Assert-Sequence @($result[0].PSObject.Properties.Name | Sort-Object) @(
            'ApplicationId', 'CertThumbprint', 'EncryptionKeyId', 'EndpointUrl', 'IdentifierUri', 'Stage', 'TenantId'
        ) 'preserve Stage2 output shape'
        Assert-Equal $result[0].Stage 2 'do not activate Stage3'
        Assert-Equal $result[0].TenantId $customerTenant 'preserve the customer tenant'
        Assert-Equal $result[0].EndpointUrl 'https://actual-arm-host.example.invalid/api/SendOtp' 'use the actual ARM hostname'
        $expected = @('templates', 'package', 'azure-auth', 'graph', 'application', 'inventory', 'infrastructure',
            'certificate', 'application', 'registration', 'federation', 'secret:phone-provider-decryption-key')
        if ($plan -eq 'Premium') { $expected += @('content-key', 'secret:phone-provider-content-storage') }
        $expected += @('settings', 'configuration', 'references', 'zip')
        Assert-Sequence $scenario.State.Events.ToArray() $expected 'inputs/auth/app validation -> infra -> Graph/secrets -> configuration -> ZIP'
        Assert-Equal $scenario.State.ArmCalls.Count 2 'automatically deploy both phases from one invocation'
        $infra = $scenario.State.ArmCalls[0].Parameters
        $config = $scenario.State.ArmCalls[1].Parameters
        Assert-Equal $infra.existing.roleAssignmentNames.storageBlob '77777777-7777-4777-8777-777777777777' 'pass adopted RBAC assignment names to ARM'
        Assert-Equal $infra.existing.tags.function.KEEP 'existing tag' 'preserve existing tags in the snapshot'
        Assert-True $infra.existing.userAssignedIdentities.ContainsKey('unrelated') 'preserve unrelated user-assigned identities'
        Assert-Equal $infra.hostingPlanName 'old-plan' 'reuse the actual hosting plan'
        Assert-Equal $infra.workspaceName 'old-workspace' 'reuse the actual workspace'
        Assert-Equal $config.existingAppSettings.USER_KEEP 'synthetic preserved appsetting' 'preserve unrelated appsettings'
        Assert-True (-not $config.existingAppSettings.ContainsKey('AzureWebJobsStorage')) 'remove obsolete connection-string settings before ARM'
        Assert-Equal $config.managedSettings.EPP_OUTBOUND_MI_CLIENT_ID $scenario.State.Infrastructure.outboundIdentityClientId 'use the actual ARM identity client ID'
        Assert-Equal $config.contentStorageSecretUri $(if ($plan -eq 'Premium') { 'https://cyot-offline-vault.vault.azure.net/secrets/phone-provider-content-storage' } else { '' }) 'Premium passes only a Key Vault reference, not a storage key'
        $serialized = ConvertTo-Json -InputObject @($infra, $config, $result[0]) -Depth 100
        foreach ($secret in $scenario.State.SecretValues) { Assert-True (-not $serialized.Contains($secret)) 'private-key and content secrets must never enter ARM parameters or outputs' }
        Assert-True (-not $serialized.Contains('CYOT_SYNTHETIC_STORAGE_KEY_DO_NOT_PRINT')) 'never expose the content-storage key'
    }
}
foreach ($phase in @('package', 'azure-auth', 'graph', 'application', 'inventory', 'infrastructure', 'certificate',
        'registration', 'federation', 'secret:phone-provider-decryption-key', 'secret:phone-provider-content-storage',
        'configuration', 'references')) {
    Invoke-OfflineTest "Step2 stops later phases after $phase fails" {
        $scenario = New-Step2PhaseScenario -Plan Premium -FailAt $phase
        Assert-Throws { & $scenario.Module { Invoke-Step2Setup } } -Pattern "Injected phase failure: $([regex]::Escape($phase))"
        Assert-Equal $scenario.State.Events[-1] $phase 'nothing may run after the failed phase'
        Assert-True (-not $scenario.State.Events.Contains('zip')) 'do not publish code after a failed prerequisite'
        if ($phase -in @('package', 'azure-auth', 'graph', 'application', 'inventory', 'infrastructure')) {
            Assert-True (-not $scenario.State.Events.Contains('certificate')) 'do not configure certificates/Graph after infra/preflight failure'
            Assert-True (-not $scenario.State.Events.Contains('configuration')) 'do not configure the Function after infra/preflight failure'
        }
    }
}
foreach ($field in @('functionAppResourceId', 'storageAccountResourceId', 'keyVaultResourceId', 'keyVaultUri',
        'outboundIdentityResourceId', 'applicationInsightsResourceId', 'planType', 'systemAssignedPrincipalId',
        'outboundIdentityClientId', 'outboundIdentityPrincipalId', 'defaultHostName', 'contentShareName', 'contentStorageSecretName')) {
    Invoke-OfflineTest "Step2 missing infrastructure output $field prevents configuration/publication" {
        $scenario = New-Step2PhaseScenario -Plan Premium
        $scenario.State.Infrastructure.Remove($field)
        Assert-Throws { & $scenario.Module { Invoke-Step2Setup } }
        Assert-True (-not $scenario.State.Events.Contains('certificate')) 'missing outputs must stop before certificate or Graph changes'
        Assert-True (-not $scenario.State.Events.Contains('configuration')) 'missing outputs must stop before configuration'
        Assert-True (-not $scenario.State.Events.Contains('zip')) 'missing outputs must stop before publishing'
    }
}
foreach ($field in @('storageAccountResourceId', 'keyVaultResourceId', 'outboundIdentityResourceId', 'applicationInsightsResourceId',
        'planType', 'systemAssignedPrincipalId', 'outboundIdentityClientId', 'outboundIdentityPrincipalId', 'keyVaultUri',
        'contentShareName', 'contentStorageSecretName')) {
    Invoke-OfflineTest "Step2 rejects nonempty but invalid infrastructure output $field before Graph mutation" {
        $scenario = New-Step2PhaseScenario -Plan Premium
        $scenario.State.Infrastructure[$field] = 'wrong-nonempty-output'
        Assert-Throws { & $scenario.Module { Invoke-Step2Setup } }
        foreach ($phase in @('certificate', 'registration', 'federation', 'configuration', 'zip')) {
            Assert-True (-not $scenario.State.Events.Contains($phase)) "invalid output must prevent $phase"
        }
    }
}
foreach ($subscription in @($null, '  ', 'not-a-guid', [Guid]::Empty.ToString())) {
    Invoke-OfflineTest "Step2 noninteractive subscription <$subscription> fails before package resolution" {
        $scenario = New-Step2PhaseScenario
        & $scenario.Module { param($Value) $script:SubscriptionId = $Value } $subscription
        Assert-Throws { & $scenario.Module { Invoke-Step2Setup } } -Pattern 'SubscriptionId.*(required|GUID)'
        foreach ($phase in @('package', 'azure-auth', 'graph', 'infrastructure', 'configuration', 'zip')) {
            Assert-True (-not $scenario.State.Events.Contains($phase)) "reject an invalid subscription before $phase"
        }
    }
}
foreach ($case in @('WrongInfraTarget', 'WrongPrincipal', 'WrongConfigTarget', 'MissingConfigTarget', 'InvalidProvider', 'MissingProvider', 'UnsupportedTokenVersion')) {
    Invoke-OfflineTest "Step2 refuses invalid phase inputs/results ($case)" {
        $scenario = New-Step2PhaseScenario
        switch ($case) {
            'WrongInfraTarget' { $scenario.State.Infrastructure.functionAppResourceId = '/subscriptions/another-target' }
            'WrongPrincipal' { $scenario.State.Infrastructure.systemAssignedPrincipalId = 'not-a-guid' }
            'WrongConfigTarget' { $scenario.State.Configuration.functionAppResourceId = '/subscriptions/another-target' }
            'MissingConfigTarget' { $scenario.State.Configuration.Clear() }
            'InvalidProvider' { & $scenario.Module { $script:ProviderScope = 'invalid-scope' } }
            'MissingProvider' { & $scenario.Module { $script:ProviderName = '' } }
            'UnsupportedTokenVersion' { $scenario.State.Application.Api.RequestedAccessTokenVersion = 3 }
        }
        Assert-Throws { & $scenario.Module { Invoke-Step2Setup } }
        Assert-True (-not $scenario.State.Events.Contains('zip')) 'invalid inputs/results cannot reach publishing'
        if ($case -in @('InvalidProvider', 'MissingProvider', 'UnsupportedTokenVersion')) {
            Assert-True (-not $scenario.State.Events.Contains('infrastructure')) 'finish input/app preflight before provisioning'
        }
    }
}
Invoke-OfflineTest 'EndpointUrl mode skips template checks, ARM, Azure and package publishing entirely' {
    $scenario = New-Step2PhaseScenario -ExistingEndpoint
    & $scenario.Module { $script:SubscriptionId = $null; $script:ProviderName = ''; $script:ZipPath = '' }
    $result = & $scenario.Module { Invoke-Step2Setup }
    Assert-Sequence $scenario.State.Events.ToArray() @('graph', 'application', 'certificate', 'application', 'registration') 'existing endpoints only need directory/certificate configuration'
    Assert-Equal $scenario.State.ArmCalls.Count 0 'no ARM in existing-endpoint mode'
    Assert-Equal $result.EndpointUrl 'https://existing-endpoint.example.invalid/api/SendOtp' 'preserve the explicitly supplied endpoint'
}
Invoke-OfflineTest 'Step2 keeps a single orchestrator entry point and separate, non-embedded ARM files' {
    $ast = $ScriptAsts[$step2]
    $topCommands = @(foreach ($statement in $ast.EndBlock.Statements) {
        if ($statement -isnot [Management.Automation.Language.FunctionDefinitionAst]) {
            $statement.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true)
        }
    })
    Assert-Equal @($topCommands | Where-Object { $_.GetCommandName() -eq 'Invoke-Step2Setup' }).Count 1 'invoke one orchestrator, not a manual two-script workflow'
    Assert-Equal @($topCommands | Where-Object { $_.GetCommandName() -in @('Invoke-Az', 'Invoke-ArmTemplateDeployment') }).Count 0 'all deployment sequencing belongs inside the orchestrator'
    $embedded = @($ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.StringConstantExpressionAst] -and
        $node.Value -match 'deploymentTemplate\.json|"\$schema"\s*:'
    }, $true))
    Assert-Equal $embedded.Count 0 'do not embed ARM template JSON in PowerShell'
    $flow = Get-FunctionAst $step2 'Invoke-Step2Setup'
    $commands = @($flow.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true))
    $armCalls = @($commands | Where-Object { $_.GetCommandName() -eq 'Invoke-ArmTemplateDeployment' })
    Assert-Equal $armCalls.Count 2 'wire both ARM phases'
    foreach ($name in @('Get-ProviderAppSettings', 'Get-ProviderEntraSettings', 'Resolve-FunctionPackage', 'Initialize-AzureCliAuthentication', 'Get-CyotApplication')) {
        $preflight = @($commands | Where-Object { $_.GetCommandName() -eq $name }) | Select-Object -First 1
        Assert-True ($null -ne $preflight -and $preflight.Extent.EndOffset -lt $armCalls[0].Extent.StartOffset) "$name must precede infrastructure mutation"
    }
}

. (Join-Path $PSScriptRoot 'Test-CyotArmTemplates.ps1')
