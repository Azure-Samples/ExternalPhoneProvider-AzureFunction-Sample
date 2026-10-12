#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$setupDirectory = Split-Path -Parent $PSScriptRoot
$module = Import-Module (Join-Path $setupDirectory 'support' 'Epp.Setup.psm1') -Force -PassThru
$directory = Join-Path ([IO.Path]::GetTempPath()) "epp-provider-tests-$([Guid]::NewGuid().ToString('N'))"
try {
    New-Item -ItemType Directory -Path (Join-Path $directory 'providers') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $setupDirectory 'providers' 'catalog.json') -Destination (Join-Path $directory 'providers' 'catalog.json')
    & $module {
        param($SetupDirectory, $Directory)

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
        $script:SetupDirectory = $SetupDirectory
        $script:SourceBaseUri = "https://raw.githubusercontent.com/Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample/$('a' * 40)/setup"
        $script:Messages = [Collections.Generic.List[string]]::new()
        $script:Prompts = [Collections.Generic.List[string]]::new()
        $script:Answers = [Collections.Generic.Queue[string]]::new()
        function script:Write-Host {
            param([Parameter(ValueFromPipeline)] $Object, $ForegroundColor, [switch] $NoNewline)
            process { $script:Messages.Add([string]$Object) }
        }
        function script:Read-Host {
            param($Prompt)
            $script:Prompts.Add($Prompt)
            Assert ($script:Answers.Count -gt 0) "Unexpected prompt: $Prompt"
            return $script:Answers.Dequeue()
        }
        function script:Invoke-WebRequest {
            param($Uri, $OutFile, $TimeoutSec, $MaximumRedirection)
            $file = ([Uri]$Uri).Segments[-1]
            Assert ($file -in @('telesign.json', 'soprano.json')) 'Only catalog provider files may be downloaded.'
            Assert ($Uri -ceq "$script:SourceBaseUri/providers/$file") 'Profiles must remain commit-pinned.'
            Copy-Item -LiteralPath (Join-Path $script:SetupDirectory 'providers' $file) -Destination $OutFile
        }
        function script:Invoke-EppAz { throw 'Unexpected Azure call (no network allowed).' }

        foreach ($id in @('telesign', 'soprano')) {
            foreach ($region in @('global', 'eu')) {
                $configuration = Get-EppProvider -AssetDirectory $Directory -SourceBaseUri $script:SourceBaseUri `
                    -Provider $id -EndpointRegion $region -NonInteractive
                $route = $configuration.Manifest.deployment.routes[$region]
                $settings = $configuration.Settings
                Assert ($configuration.Id -ceq $id -and $configuration.EndpointRegion -ceq $region) 'Provider and region selection must be preserved.'
                Assert ($configuration.PSObject.Properties.Name -notcontains 'Channel') 'Provider metadata must not select a channel.'
                Assert (-not $settings.ContainsKey('EPP_PROVIDER_CHANNEL')) 'Setup must not emit a channel app setting.'
                Assert (-not $settings.ContainsKey('EPP_PROVIDER_ENDPOINT')) 'Setup must not emit a shared endpoint setting.'
                Assert ($settings.EPP_PROVIDER_SMS_ENDPOINT -ceq $route.smsEndpoint) 'Use the complete regional SMS endpoint.'
                Assert ($settings.EPP_PROVIDER_VOICE_ENDPOINT -ceq $route.voiceEndpoint) 'Use the complete regional voice endpoint.'
                Assert ($settings.EPP_PROVIDER_TIMEOUT_MS -ceq [string]$route.timeoutMilliseconds) 'Preserve the provider timeout.'
                Assert ($settings.EPP_PROVIDER_RETRY_INTERVAL_MS -ceq [string]([long]$route.retryIntervalSeconds * 1000)) 'Preserve retry interval metadata.'
                Assert ($settings.EPP_PROVIDER_AUTH_MODE -ceq $configuration.Manifest.deployment.authentication.mode) 'Preserve provider authentication.'
                if ($id -eq 'soprano') {
                    Assert ($settings.EPP_PROVIDER_APP_ID -ceq $route.appId -and $settings.EPP_PROVIDER_SCOPE -ceq $route.scope) 'Preserve regional OAuth settings.'
                }
            }
        }
        Assert ($script:Prompts.Count -eq 0) 'Complete provider inputs must not prompt for a channel.'

        $profile = Read-EppJson (Join-Path $SetupDirectory 'providers' 'soprano.json')
        $profile.deployment.routes.eu.smsEndpoint = 'https://sms.eu.provider.contoso.com/send'
        $profile.deployment.routes.eu.voiceEndpoint = 'https://voice.eu.provider.contoso.com/send'
        $configuration = ConvertTo-EppProviderSettings -Profile $profile -Id soprano -DisplayName Soprano -EndpointRegion eu -NonInteractive
        Assert ($configuration.Settings.EPP_PROVIDER_SMS_ENDPOINT -ceq $profile.deployment.routes.eu.smsEndpoint) 'EU selection must preserve its distinct SMS endpoint.'
        Assert ($configuration.Settings.EPP_PROVIDER_VOICE_ENDPOINT -ceq $profile.deployment.routes.eu.voiceEndpoint) 'EU selection must preserve its distinct voice endpoint.'
        Assert-Throws { ConvertTo-EppProviderSettings -Profile $profile -Id soprano -DisplayName Soprano -NonInteractive } '\-EndpointRegion is required'
        Assert-Throws { ConvertTo-EppProviderSettings -Profile $profile -Id soprano -DisplayName Soprano -EndpointRegion invalid -NonInteractive } 'Unknown EndpointRegion'

        foreach ($region in @('global', 'eu')) {
            $profile = Read-EppJson (Join-Path $SetupDirectory 'providers' 'soprano.json')
            $profile.deployment.routes.Remove($region)
            Assert-Throws {
                ConvertTo-EppProviderSettings -Profile $profile -Id soprano -DisplayName Soprano -EndpointRegion global -NonInteractive
            } "deployment\.routes\.$region is missing"
            foreach ($case in @(
                @{ Field = 'smsEndpoint'; Value = 'http://provider.contoso.com/send' }
                @{ Field = 'voiceEndpoint'; Value = 'http://provider.contoso.com/send' }
                @{ Field = 'smsEndpoint'; Value = $null }
                @{ Field = 'voiceEndpoint'; Value = $null }
                @{ Field = 'timeoutMilliseconds'; Value = 2501 }
                @{ Field = 'retryIntervalSeconds'; Value = -1 }
                @{ Field = 'appId'; Value = 'invalid' }
                @{ Field = 'scope'; Value = 'api://provider/not-default' }
            )) {
                $profile = Read-EppJson (Join-Path $SetupDirectory 'providers' 'soprano.json')
                $profile.deployment.routes[$region][$case.Field] = $case.Value
                Assert-Throws {
                    ConvertTo-EppProviderSettings -Profile $profile -Id soprano -DisplayName Soprano -EndpointRegion global -NonInteractive
                } "deployment\.routes\.$region\.$($case.Field)"
            }
        }

        $tokens = $null
        $parseErrors = $null
        $launcher = [Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $SetupDirectory 'Setup-Epp.ps1'), [ref]$tokens, [ref]$parseErrors)
        Assert ($parseErrors.Count -eq 0) 'The launcher must parse successfully.'
        Assert ($launcher.ParamBlock.Parameters.Name.VariablePath.UserPath -notcontains 'Channel') 'The launcher must not expose a Channel parameter.'
        foreach ($name in @('Invoke-EppSetup', 'Get-EppProvider', 'ConvertTo-EppProviderSettings')) {
            Assert (-not (Get-Command $name).Parameters.ContainsKey('Channel')) "$name must not expose a Channel parameter."
        }

        function script:Get-EppLanguage {
            param($AssetDirectory, $Language, $SourceRepository, $PackageReleaseTag, [switch] $NonInteractive)
            return @{ Id = 'javascript'; DisplayName = 'Node.js'; Url = 'https://github.com/unit/package.zip'; BuildStrategy = 'ready' }
        }
        function script:Connect-EppContext {
            param($Inputs, $Names, [switch] $NonInteractive, [switch] $InstallPrerequisites, [switch] $ForceAuthentication)
            throw 'preflight-reached'
        }
        $inputs = @{
            TenantId = '11111111-1111-1111-1111-111111111111'
            SubscriptionId = '22222222-2222-2222-2222-222222222222'
            ApplicationId = '33333333-3333-3333-3333-333333333333'
            Location = 'westus2'; ResourcePrefix = 'unit'; Language = 'javascript'; ServicePlan = 'FC1'
        }
        foreach ($id in @('telesign', 'soprano')) {
            foreach ($region in @('global', 'eu')) {
                Assert-Throws {
                    Invoke-EppSetup @inputs -Provider $id -EndpointRegion $region -AssetDirectory $Directory `
                        -SourceBaseUri $script:SourceBaseUri -OutputDirectory $Directory -NonInteractive
                } '^preflight-reached$'
            }
        }
        Assert ($script:Prompts.Count -eq 0) 'Unattended setup must reach preflight without any channel input.'
        $script:Answers.Enqueue('2')
        $script:Answers.Enqueue('2')
        Assert-Throws {
            Invoke-EppSetup @inputs -AssetDirectory $Directory -SourceBaseUri $script:SourceBaseUri -OutputDirectory $Directory
        } '^preflight-reached$'
        Assert (($script:Prompts -join ',') -ceq 'Tenant scope number or name,Provider number or name') 'Interactive setup must only ask for missing region and provider selections.'
        Assert ($script:Answers.Count -eq 0) 'All expected prompt answers must be consumed.'

        $names = Get-EppResourceNames -SubscriptionId $inputs.SubscriptionId -ApplicationId $inputs.ApplicationId -ResourcePrefix $inputs.ResourcePrefix
        $configuration = Get-EppProvider -AssetDirectory $Directory -SourceBaseUri $script:SourceBaseUri -Provider telesign -EndpointRegion global -NonInteractive
        $script:Messages.Clear()
        Show-EppDeploymentResult -Inputs $inputs -Names $names -ProviderConfiguration $configuration `
            -EndpointUrl 'https://unit.azurewebsites.net/api/SendOtp' -ResultPath (Join-Path $Directory 'deployment.json')
        $result = $script:Messages -join "`n"
        foreach ($method in @('Sms', 'Voice')) {
            Assert ($result.Contains("https://graph.microsoft.com/beta/policies/authenticationMethodsPolicy/authenticationMethodConfigurations/$method")) 'The handoff must show both policy targets.'
        }
        Assert ($result.Contains('each channel you intend to enable')) 'Policy activation must remain an explicit per-channel choice.'
        Assert ($result.Contains('did not change the External Phone Provider policy')) 'Setup must not claim policy activation.'
    } $setupDirectory $directory
    Write-Host 'Provider profiles, channel-independent setup, prompts, and policy handoff checks passed.'
}
finally {
    Remove-Module -ModuleInfo $module -Force
    if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force }
}
