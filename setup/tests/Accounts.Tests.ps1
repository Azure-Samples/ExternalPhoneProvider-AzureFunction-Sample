#Requires -Version 7.0
param([string] $ModulePath = (Split-Path -Parent $PSScriptRoot))

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$module = Import-Module (Join-Path $ModulePath 'support\Epp.Setup.psm1') -Force -PassThru
$directory = Join-Path ([IO.Path]::GetTempPath()) "epp-account-tests-$([Guid]::NewGuid().ToString('N'))"
try {
    & $module {
        param($Directory, $ModulePath)

        function script:Assert($Condition, [string] $Message) {
            if (-not $Condition) { throw $Message }
        }
        function script:Assert-Throws([scriptblock] $Action, [string] $Pattern) {
            try { $null = & $Action }
            catch {
                Assert ($_.Exception.Message -match $Pattern) "Unexpected failure: $($_.Exception.Message)"
                return
            }
            throw "Expected failure matching '$Pattern'."
        }
        function script:New-TestAccount([string] $Id, [string] $Tenant, [string] $Name, [string] $TenantName = 'Contoso') {
            return @{
                id = $Id; tenantId = $Tenant; name = $Name; tenantDisplayName = $TenantName
                state = 'Enabled'; cloudName = 'AzureCloud'; isDefault = $false
                user = @{ type = 'user'; name = 'operator@contoso.test' }
            }
        }
        function script:ConvertTo-TestAccountShow([hashtable] $Account) {
            $shown = @{} + $Account
            $shown.environmentName = $shown.cloudName
            $shown.Remove('cloudName')
            return $shown | ConvertTo-Json -Depth 8
        }
        $script:Calls = [Collections.Generic.List[string]]::new()
        $script:Messages = [Collections.Generic.List[string]]::new()
        $script:Warnings = [Collections.Generic.List[string]]::new()
        $script:Prompts = [Collections.Generic.List[string]]::new()
        $script:Answers = [Collections.Generic.Queue[string]]::new()
        $script:LoginAcknowledgement = $null
        function script:Reset-TestState([object[]] $Accounts = @(), [string[]] $Answers = @()) {
            $script:Calls.Clear(); $script:Messages.Clear(); $script:Warnings.Clear(); $script:Prompts.Clear(); $script:Answers.Clear()
            foreach ($answer in $Answers) { $script:Answers.Enqueue($answer) }
            $script:AccountsJson = ConvertTo-Json -InputObject @($Accounts) -Depth 8
            $script:RefreshJson = $null; $script:LoginJson = $null; $script:ShowJson = $null
            $script:CliAvailable = $true; $script:RefreshError = ''; $script:LoginError = ''
            $script:ContextCalls = 0; $script:ContextInputs = $null; $script:ForceAuthentication = $false
        }
        function script:Write-Host {
            param([Parameter(ValueFromPipeline)] $Object, $ForegroundColor, [switch] $NoNewline)
            process {
                $script:Messages.Add([string]$Object)
                if ($script:LoginAcknowledgement -and [string]$Object -ceq 'EPP test device-code prompt') {
                    [IO.File]::WriteAllText($script:LoginAcknowledgement, 'displayed')
                }
            }
        }
        function script:Write-Warning {
            [CmdletBinding()]
            param([string] $Message)
            $script:Warnings.Add($Message)
        }
        function script:Read-Host {
            param($Prompt)
            $script:Prompts.Add($Prompt)
            Assert ($script:Answers.Count -gt 0) "Unexpected prompt: $Prompt"
            return $script:Answers.Dequeue()
        }
        function script:Get-Command {
            param($Name, $ErrorAction)
            Assert ($Name -eq 'az') "Unexpected command lookup: $Name"
            if ($script:CliAvailable) { return @{ Name = 'az' } }
        }

        Reset-TestState
        New-Item -ItemType Directory -Path $Directory | Out-Null
        $script:LoginFixture = Join-Path $Directory 'login.ps1'
        $script:LoginAcknowledgement = Join-Path $Directory 'prompt-displayed'
        $script:PowerShellPath = (Get-Process -Id $PID).Path
        @'
param([string] $AcknowledgementPath, [int] $ExitCode)
[Console]::Error.WriteLine('EPP test device-code prompt')
$deadline = [DateTime]::UtcNow.AddSeconds(5)
while (-not [IO.File]::Exists($AcknowledgementPath)) {
    if ([DateTime]::UtcNow -ge $deadline) {
        [Console]::Error.WriteLine('Device-code instructions were buffered until after sign-in.')
        exit 97
    }
    Start-Sleep -Milliseconds 20
}
[Console]::Out.WriteLine('EPP test sign-in finished')
exit $ExitCode
'@ | Set-Content -LiteralPath $script:LoginFixture -Encoding utf8NoBOM
        function script:az {
            param([Parameter(ValueFromRemainingArguments)][string[]] $Arguments)
            Assert (($Arguments -join ' ') -ceq 'login --use-device-code --output none --only-show-errors') 'Only the expected offline login fixture may run.'
            & $script:PowerShellPath -NoLogo -NoProfile -NonInteractive -File $script:LoginFixture `
                -AcknowledgementPath $script:LoginAcknowledgement -ExitCode $script:LoginExitCode
        }
        try {
            $script:LoginExitCode = 0
            $result = Invoke-EppAz login --use-device-code --output none
            Assert ($null -eq $result) 'Interactive login must not emit success-pipeline data.'
            Assert ($script:Messages.Contains('EPP test sign-in finished')) 'Display stdout as well as device-code instructions.'
            Remove-Item -LiteralPath $script:LoginAcknowledgement
            $script:LoginExitCode = 3
            Assert-Throws { Invoke-EppAz login --use-device-code --output none } 'login.*failed.*exit 3'
            Assert (Test-Path -LiteralPath $script:LoginAcknowledgement) 'Display the prompt even when sign-in later fails.'
            # The verified native failure must not become the Actions PowerShell step's exit status.
            $global:LASTEXITCODE = 0
        }
        finally {
            $script:LoginAcknowledgement = $null
            Remove-Item -LiteralPath Function:\script:az
            Remove-Item -LiteralPath $Directory -Recurse -Force
        }

        function script:Invoke-EppAz {
            param([Parameter(ValueFromRemainingArguments)][string[]] $Arguments)
            $command = $Arguments -join ' '
            $script:Calls.Add($command)
            switch -Regex ($command) {
                '^account list --all --output json(?: --refresh)?$' {
                    if ($Arguments -contains '--refresh') {
                        if ($script:RefreshError) { throw $script:RefreshError }
                        if ($null -ne $script:RefreshJson) { $script:AccountsJson = $script:RefreshJson }
                    }
                    return $script:AccountsJson
                }
                '^login ' {
                    Assert ($Arguments -contains '--use-device-code') 'Selection sign-in and forced authentication must use device code.'
                    if ($script:LoginError) { throw $script:LoginError }
                    if ($null -ne $script:LoginJson) { $script:AccountsJson = $script:LoginJson }
                    return ''
                }
                '^account show --subscription ' { return $script:ShowJson }
                default { throw "Unexpected Azure call (no network allowed): $command" }
            }
        }
        function script:Invoke-WebRequest { throw 'Unexpected web request (no network allowed).' }
        function script:Invoke-RestMethod { throw 'Unexpected REST request (no network allowed).' }

        $tenantA = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        $tenantB = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
        $tenantMissing = 'cccccccc-cccc-cccc-cccc-cccccccccccc'
        $subA = '11111111-1111-1111-1111-111111111111'
        $subB = '22222222-2222-2222-2222-222222222222'
        $subC = '33333333-3333-3333-3333-333333333333'
        $subMissing = '44444444-4444-4444-4444-444444444444'
        $a = New-TestAccount $subA $tenantA 'A-primary'; $a.isDefault = $true
        $b = New-TestAccount $subB $tenantA 'B-secondary'
        $c = New-TestAccount $subC $tenantB 'C-other' 'Fabrikam'; $c.user.name = 'other@fabrikam.test'

        Reset-TestState @($a, $b, $c)
        Assert ($a.ContainsKey('cloudName') -and -not $a.ContainsKey('environmentName')) 'Model account list, not the different account show response.'
        $accounts = @(Get-EppAzureSubscriptions)
        Assert ($accounts.Count -eq 3 -and $accounts[0].IsDefault) 'Preserve enabled user subscriptions and default metadata.'
        Assert ($script:Calls[0] -ceq 'account list --all --output json') 'Initial discovery must read the cache without refreshing or signing in.'
        $disabled = New-TestAccount $subMissing $tenantA 'disabled'; $disabled.state = 'Disabled'
        $principal = New-TestAccount $subMissing $tenantA 'principal'; $principal.user.type = 'servicePrincipal'
        $government = New-TestAccount $subMissing $tenantA 'government'; $government.cloudName = 'AzureUSGovernment'
        $tenantOnly = New-TestAccount $tenantA $tenantA 'N/A(tenant level account)'
        Reset-TestState @($a, $disabled, $principal, $government, $tenantOnly)
        Assert (@(Get-EppAzureSubscriptions).Count -eq 1) 'Exclude disabled, non-user, non-public-cloud, and tenant-only records.'
        Reset-TestState
        Assert (@(Get-EppAzureSubscriptions).Count -eq 0) 'An empty cache is not a selected subscription.'
        foreach ($response in @('{}', 'null', '[null]', '[{"user":null}]')) {
            Reset-TestState
            $script:AccountsJson = $response
            Assert-Throws { Get-EppAzureSubscriptions } 'invalid subscription'
        }
        Reset-TestState @($a, $a)
        Assert-Throws { Get-EppAzureSubscriptions } 'duplicate entries'
        foreach ($case in @('id', 'tenantId', 'name', 'user', 'tenantName', 'tenantNameType', 'default', 'state', 'cloud', 'showSchema', 'userType')) {
            $invalid = New-TestAccount $subA $tenantA 'valid'
            switch ($case) {
                id { $invalid.id = 'not-a-guid' }
                tenantId { $invalid.tenantId = 'not-a-guid' }
                name { $invalid.name = "unsafe`nname" }
                user { $invalid.user.name = '' }
                tenantName { $invalid.tenantDisplayName = "unsafe`nname" }
                tenantNameType { $invalid.tenantDisplayName = @{} }
                default { $invalid.isDefault = 'true' }
                state { $invalid.state = $null }
                cloud { $invalid.cloudName = $null }
                showSchema { $invalid.Remove('cloudName'); $invalid.environmentName = 'AzureCloud' }
                userType { $invalid.user.type = $null }
            }
            Reset-TestState @($invalid)
            Assert-Throws { Get-EppAzureSubscriptions } 'nonempty GUID|invalid .*metadata|invalid .*display name'
        }
        Reset-TestState @($a)
        $script:CliAvailable = $false
        Assert-Throws { Select-EppAzureContext } 'Azure CLI is not installed'
        Assert ($script:Calls.Count -eq 0 -and $script:Prompts.Count -eq 0) 'Missing CLI must fail before selection.'

        Reset-TestState @($a, $b, $c) @('1', '2')
        $selected = Select-EppAzureContext
        Assert ($selected.TenantId -ceq $tenantA -and $selected.SubscriptionId -ceq $subB) 'Select a tenant, then its nondefault subscription.'
        Assert (($script:Prompts -join ',') -ceq 'Azure tenant number or name,Azure subscription number or name') 'Ask for tenant and subscription before other settings.'
        $messages = $script:Messages -join "`n"
        foreach ($text in @("Contoso [$tenantA]", $subA, $subB, 'current CLI default', 'operator@contoso.test')) {
            Assert ($messages.Contains($text)) "Selection must show '$text'."
        }
        Assert (-not $messages.Contains($subC)) 'Do not offer subscriptions from another tenant.'
        Assert ($script:Calls.Count -eq 1) 'Selecting a cached account must not refresh, sign in, or change the CLI default.'

        Reset-TestState @($a) @('1', '1')
        $selected = Select-EppAzureContext
        Assert ($selected.SubscriptionId -ceq $subA -and $script:Prompts.Count -eq 2) 'Even a single cached subscription requires an explicit interactive choice.'
        $unnamed = New-TestAccount $subA $tenantA 'unnamed'; $unnamed.Remove('tenantDisplayName')
        Reset-TestState @($unnamed) @($tenantA, $subA)
        $selected = Select-EppAzureContext
        Assert ($selected.TenantId -ceq $tenantA -and ($script:Messages -join "`n").Contains('tenant name unavailable')) 'Tenant names are optional; selection must still show its ID.'
        Reset-TestState @($a, $b, $c) @($subB)
        $selected = Select-EppAzureContext -TenantId " $($tenantA.ToUpperInvariant()) "
        Assert ($selected.TenantId -ceq $tenantA -and $selected.SubscriptionId -ceq $subB) 'Normalize and preserve an explicitly supplied tenant.'
        Assert ($script:Prompts.Count -eq 1 -and $script:Prompts[0] -like 'Azure subscription *') 'Only prompt for the missing subscription.'
        Reset-TestState @($a, $b, $c)
        $selected = Select-EppAzureContext -SubscriptionId $subC
        Assert ($selected.TenantId -ceq $tenantB -and $selected.SubscriptionId -ceq $subC) 'Resolve the tenant from an explicitly chosen eligible subscription.'
        Assert ($script:Prompts.Count -eq 0) 'Do not ask users to select a different subscription when one was supplied.'

        foreach ($noninteractive in @($false, $true)) {
            Reset-TestState
            $script:AccountsJson = 'invalid'; $script:CliAvailable = $false
            $selected = Select-EppAzureContext -TenantId $tenantA -SubscriptionId $subC -NonInteractive:$noninteractive
            Assert ($selected.TenantId -ceq $tenantA -and $selected.SubscriptionId -ceq $subC) 'Explicit IDs must not be replaced using cached defaults.'
            Assert ($script:Calls.Count -eq 0 -and $script:Prompts.Count -eq 0) 'Complete explicit IDs skip discovery; existing preflight validates them later.'
        }
        foreach ($parameters in @(@{}, @{ TenantId = $tenantA }, @{ SubscriptionId = $subA })) {
            Reset-TestState @($a)
            Assert-Throws { Select-EppAzureContext @parameters -NonInteractive } 'is required in noninteractive mode'
            Assert ($script:Calls.Count -eq 0 -and $script:Prompts.Count -eq 0) 'Unattended mode must never infer missing IDs or sign in.'
        }
        foreach ($parameters in @(@{ TenantId = 'invalid' }, @{ SubscriptionId = 'invalid' })) {
            Reset-TestState @($a)
            Assert-Throws { Select-EppAzureContext @parameters } 'Invalid -'
            Assert ($script:Calls.Count -eq 0 -and $script:Prompts.Count -eq 0) 'Reject malformed supplied IDs before account discovery.'
        }
        Reset-TestState @($a, $c) @($subC, '0')
        $selected = Select-EppAzureContext -TenantId $tenantMissing
        Assert ($null -eq $selected -and $script:Warnings.Count -gt 0) 'An unavailable explicit tenant must not fall back to another tenant.'
        Reset-TestState @($a, $c) @('0')
        $selected = Select-EppAzureContext -SubscriptionId $subMissing
        Assert ($null -eq $selected -and ($script:Warnings -join "`n").Contains('will not be replaced')) 'An unavailable explicit subscription must remain authoritative.'

        Reset-TestState @($a) @('refresh', $tenantB, $subC)
        $script:RefreshJson = ConvertTo-Json -InputObject @($a, $c) -Depth 8
        $selected = Select-EppAzureContext
        Assert ($selected.SubscriptionId -ceq $subC -and $script:Calls.Count -eq 2 -and $script:Calls[1].EndsWith('--refresh')) 'Refresh must rediscover server-side subscriptions only after opt-in.'
        Reset-TestState @($a) @('refresh', $subB)
        $script:RefreshJson = ConvertTo-Json -InputObject @($a, $b) -Depth 8
        $selected = Select-EppAzureContext -TenantId $tenantA
        Assert ($selected.SubscriptionId -ceq $subB -and $script:Prompts.Count -eq 2) 'Refresh the subscription menu while preserving an explicit tenant.'

        Reset-TestState @() @('signin', $tenantA, $subA)
        $script:LoginJson = ConvertTo-Json -InputObject @($a) -Depth 8
        $selected = Select-EppAzureContext
        Assert ($selected.SubscriptionId -ceq $subA -and $script:Calls.Count -eq 3) 'An empty cache can be populated through an explicit sign-in choice.'
        Assert ($script:Calls[1] -ceq 'login --use-device-code --output none') 'Do not guess a tenant before the user can select one.'
        Reset-TestState @($a) @('signin', $subC)
        $script:LoginJson = ConvertTo-Json -InputObject @($a, $c) -Depth 8
        $selected = Select-EppAzureContext -TenantId $tenantB
        Assert ($selected.TenantId -ceq $tenantB -and $script:Calls[1].EndsWith("--tenant $tenantB")) 'Sign in specifically to a supplied tenant.'
        Reset-TestState @($a) @($tenantA, 'signin', $tenantA, $subA)
        $selected = Select-EppAzureContext
        Assert ($selected.SubscriptionId -ceq $subA -and $script:Calls[1].EndsWith("--tenant $tenantA")) 'Subscription-menu sign-in must target the selected tenant.'
        foreach ($action in @('signin', 'refresh')) {
            Reset-TestState @() @($action)
            $script:LoginError = 'sign-in rejected'; $script:RefreshError = 'refresh denied'
            Assert-Throws { Select-EppAzureContext } 'sign-in rejected|refresh denied'
            Assert ($script:Answers.Count -eq 0) 'A failed account operation must surface its error, not silently choose another context.'
        }
        foreach ($cancel in @('', '0', 'Cancel')) {
            Reset-TestState @($a) @($cancel)
            Assert ($null -eq (Select-EppAzureContext)) 'Tenant cancellation must return no selection.'
            Reset-TestState @($a) @($tenantA, $cancel)
            Assert ($null -eq (Select-EppAzureContext)) 'Subscription cancellation must return no selection.'
        }

        Reset-TestState @($a)
        $script:ShowJson = ConvertTo-TestAccountShow $c
        Assert-Throws {
            Connect-EppAzureAccount -Inputs @{ TenantId = $tenantA; SubscriptionId = $subC } -NonInteractive
        } 'requested enabled subscription and tenant'
        Assert ($script:Calls.Count -eq 1) 'Existing preflight must still reject a mismatched explicit tenant without silently signing in.'
        Reset-TestState @($a)
        $script:ShowJson = ConvertTo-TestAccountShow $a
        $shown = $script:ShowJson | ConvertFrom-Json -AsHashtable
        Assert ($shown.environmentName -ceq 'AzureCloud' -and -not $shown.ContainsKey('cloudName')) 'Account show must retain its own environmentName schema.'
        $null = Connect-EppAzureAccount -Inputs @{ TenantId = $tenantA; SubscriptionId = $subA } -ForceAuthentication
        Assert ($script:Calls[0] -ceq "login --tenant $tenantA --use-device-code --output none") 'ForceAuthentication must still reauthenticate to the final selected tenant.'

        function script:Get-EppTenantRegionScope { param($TenantId); return 'NA' }
        function script:Get-EppLanguage {
            param($AssetDirectory, $Language, $SourceRepository, $PackageReleaseTag, [switch] $NonInteractive)
            return @{
                Id = 'javascript'; DisplayName = 'Node.js'; BuildStrategy = 'ready'
                Url = 'https://github.com/Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample/releases/download/epp-packages-1-1/epp-javascript.zip'
                ReleaseTag = 'epp-packages-1-1'
            }
        }
        function script:Connect-EppContext {
            param($Inputs, $Names, [switch] $NonInteractive, [switch] $InstallPrerequisites, [switch] $ForceAuthentication)
            $script:ContextCalls++; $script:ContextInputs = $Inputs; $script:ForceAuthentication = [bool]$ForceAuthentication
            throw 'preflight-boundary'
        }
        $setup = @{
            Location = 'westus2'; ResourcePrefix = 'unit'; Language = 'javascript'; ServicePlan = 'FC1'
            Provider = 'telesign'; EndpointRegion = 'global'; OutputDirectory = $Directory
            AssetDirectory = $ModulePath
            SourceBaseUri = "https://raw.githubusercontent.com/Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample/$('a' * 40)/setup"
        }
        $applicationId = 'dddddddd-dddd-dddd-dddd-dddddddddddd'
        $setup.ApplicationId = $applicationId
        Reset-TestState @($a, $b) @($tenantA, $subB)
        Assert-Throws { Invoke-EppSetup @setup -ForceAuthentication } '^preflight-boundary$'
        Assert (($script:Prompts -join ',') -ceq 'Azure tenant number or name,Azure subscription number or name') 'Account selection must run while explicit application and region inputs skip their pickers.'
        Assert ($script:ContextInputs.TenantId -ceq $tenantA -and $script:ContextInputs.SubscriptionId -ceq $subB -and
            $script:ContextInputs.ApplicationId -ceq $applicationId -and $script:ForceAuthentication) 'Forward the selected IDs and authentication choice to existing preflight.'
        Reset-TestState @($a) @('')
        $result = Invoke-EppSetup @setup
        Assert ($null -eq $result -and $script:ContextCalls -eq 0 -and $script:Prompts.Count -eq 1) 'Cancellation must stop before remaining inputs, Graph sign-in, or deployment.'
        Reset-TestState @($a)
        Assert-Throws { Invoke-EppSetup @setup -NonInteractive -ApproveDeployment } 'TenantId is required'
        Assert ($script:Calls.Count -eq 0 -and $script:ContextCalls -eq 0) 'ApproveDeployment must not authorize automatic account selection.'
        Assert (-not (Test-Path -LiteralPath $Directory)) 'Account discovery must not create deployment output.'
    } $directory $ModulePath
    Write-Host 'Azure account discovery, tenant/subscription selection, refresh, sign-in, cancellation, explicit IDs, unattended behavior, and preflight ordering checks passed.'
}
finally {
    Remove-Module -ModuleInfo $module -Force
    if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force }
}
