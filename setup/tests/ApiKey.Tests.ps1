#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$setupDirectory = Split-Path -Parent $PSScriptRoot
$module = Import-Module (Join-Path $setupDirectory 'support/Epp.Setup.psm1') -Force -PassThru
$directory = Join-Path ([IO.Path]::GetTempPath()) "epp-apikey-tests-$([Guid]::NewGuid().ToString('N'))"
try {
    New-Item -ItemType Directory -Path (Join-Path $directory 'providers') -Force | Out-Null
    Copy-Item (Join-Path $PSScriptRoot 'fixtures/sample-provider.json') (Join-Path $directory 'providers/sample.json')
    @{ schemaVersion = 1; providers = @(@{ id = 'sample'; displayName = 'Sample'; file = 'sample.json' }) } |
        ConvertTo-Json -Depth 4 | Set-Content (Join-Path $directory 'providers/catalog.json')
    & $module {
        param($SetupDirectory, $AssetDirectory)
        function script:Assert($Condition, [string] $Message) { if (-not $Condition) { throw $Message } }
        function script:Assert-Throws([scriptblock] $Action, [string] $Pattern) {
            try { $null = & $Action }
            catch { Assert ($_.Exception.Message -match $Pattern) "Unexpected failure: $($_.Exception.Message)"; return }
            throw "Expected failure matching '$Pattern'."
        }
        $definition = Get-EppProviderDefinition -AssetDirectory $AssetDirectory -Provider Sample
        $provider = Get-EppProvider -AssetDirectory $AssetDirectory -Provider Sample -EndpointRegion global -NonInteractive
        Assert ($null -eq $definition.TenantId -and $null -eq $provider.TenantId) 'API-key providers must not invent a Security Store tenant.'
        Assert (-not $provider.Settings.ContainsKey('EPP_PROVIDER_TENANT_ID') -and $provider.Languages -ceq 'javascript') 'Metadata can restrict runtimes without requiring an outbound OAuth authority.'
        Assert-Throws { Get-EppProvider -AssetDirectory $AssetDirectory -Provider Sample -EndpointRegion eu -NonInteractive } "does not support.*eu"
        $cyot = @(Get-EppProviderCatalog -AssetDirectory $SetupDirectory)
        Assert (($cyot.id | Sort-Object) -join ',' -ceq 'infobip,soprano,telesign,twilio') 'Keep the CYOT onboarding providers and add Twilio.'
        $sid = 'svc-1234'
        $values = @{ SAMPLE_SERVICE_ID = $sid }
        $resolved = Get-EppProviderEnvironment -ProviderConfiguration $provider -Values $values -NonInteractive
        Assert ($resolved.SAMPLE_SERVICE_ID -ceq $sid) 'Resolve declared non-secret input.'
        Assert-Throws { Get-EppProviderEnvironment -ProviderConfiguration $provider -NonInteractive } 'required in noninteractive'
        Assert-Throws { Get-EppProviderEnvironment -ProviderConfiguration $provider -Values @{ OTHER = 'x' } -NonInteractive } 'Unknown or fixed'
        foreach ($invalid in @('svc-123', 123, "svc-1234`n", 'SAMPLE_SERVICE_ID=svc-1234')) {
            Assert-Throws { Get-EppProviderEnvironment -ProviderConfiguration $provider -Values @{ SAMPLE_SERVICE_ID = $invalid } -NonInteractive } 'Invalid provider environment'
        }
        $retained = Get-EppProviderEnvironment -ProviderConfiguration $provider -Existing $values -NonInteractive
        Assert ($retained.SAMPLE_SERVICE_ID -ceq $sid) 'Reuse valid existing input on a rerun without another prompt.'
        $replacement = 'svc-5678'
        $updated = Get-EppProviderEnvironment -ProviderConfiguration $provider -Existing $values -Values @{ SAMPLE_SERVICE_ID = $replacement } -NonInteractive
        Assert ($updated.SAMPLE_SERVICE_ID -ceq $replacement) 'Explicit input overrides the current setting.'

        $generic = @{ environmentVariables = @{
            SAMPLE_SENDER = @{ displayName = 'Sender'; source = 'input'; required = $true; validation = @{ type = 'e164' } }
            SAMPLE_OPTION = @{ displayName = 'Option'; source = 'input'; required = $false }
            SAMPLE_FIXED = @{ displayName = 'Fixed'; source = 'fixed'; required = $true; value = 'constant' }
        } }
        $genericProvider = @{ EnvironmentVariables = Get-EppEnvironmentDefinitions -Deployment $generic -Id sample }
        $settings = Get-EppProviderEnvironment -ProviderConfiguration $genericProvider -Values @{ SAMPLE_SENDER = '+15551234567' } -NonInteractive
        Assert ($settings.SAMPLE_FIXED -ceq 'constant' -and -not $settings.Contains('SAMPLE_OPTION')) 'Resolve fixed fields and omit optional fields without inventing defaults.'
        Assert-Throws { Get-EppProviderEnvironment -ProviderConfiguration $genericProvider -Values @{ SAMPLE_FIXED = 'override' } } 'Unknown or fixed'
        foreach ($badName in @('EPP_PROVIDER_NAME', 'WEBSITE_RUN_FROM_PACKAGE', 'AZURE_CLIENT_ID', 'SAMPLE_bad')) {
            $bad = @{ environmentVariables = @{ $badName = @{ displayName = 'Bad'; source = 'input'; required = $false } } }
            Assert-Throws { Get-EppEnvironmentDefinitions -Deployment $bad -Id sample } 'Invalid environmentVariables'
        }
        Assert-Throws { Get-EppEnvironmentDefinitions -Deployment @{ environmentVariables = @{} } -Id epp } 'reserved platform prefix'
        Assert-Throws { Get-EppEnvironmentDefinitions -Deployment @{ environmentVariables = @() } -Id sample } 'must be a dictionary'
        $generic.environmentVariables.SAMPLE_OPTION['default'] = 'default-option'
        $genericProvider.EnvironmentVariables = Get-EppEnvironmentDefinitions -Deployment $generic -Id sample
        $settings = Get-EppProviderEnvironment -ProviderConfiguration $genericProvider -Values @{ SAMPLE_SENDER = '+15551234567' } -NonInteractive
        Assert ($settings.SAMPLE_OPTION -ceq 'default-option') 'Use a declared optional default without prompting.'
        foreach ($invalidDefault in @(123, $null, "bad`nvalue")) {
            $generic.environmentVariables.SAMPLE_OPTION['default'] = $invalidDefault
            Assert-Throws { Get-EppEnvironmentDefinitions -Deployment $generic -Id sample } 'Invalid provider environment'
        }
        $generic.environmentVariables.SAMPLE_OPTION.Remove('default')
        $generic.environmentVariables.SAMPLE_FIXED['default'] = 'other'
        Assert-Throws { Get-EppEnvironmentDefinitions -Deployment $generic -Id sample } 'Only input.*default'
        $generic.environmentVariables.SAMPLE_FIXED.Remove('default')
        $generic.environmentVariables.SAMPLE_SENDER['default'] = 'not-a-phone-number'
        Assert-Throws { Get-EppEnvironmentDefinitions -Deployment $generic -Id sample } 'does not match'
        $generic.environmentVariables.SAMPLE_SENDER.Remove('default')
        $generic.environmentVariables.SAMPLE_SENDER.validation = @{ type = 'pattern'; pattern = '[' }
        Assert-Throws { Get-EppEnvironmentDefinitions -Deployment $generic -Id sample } 'bounded, anchored'

        $script:Messages = [Collections.Generic.List[string]]::new()
        $script:Answers = [Collections.Generic.Queue[string]]::new()
        function script:Write-Host { param([Parameter(ValueFromPipeline)] $Object, $ForegroundColor, [switch] $NoNewline); process { $script:Messages.Add([string]$Object) } }
        function script:Write-Warning { param($Message); $script:Messages.Add([string]$Message) }
        function script:Read-Host { param($Prompt); return $script:Answers.Dequeue() }
        $script:Answers.Enqueue('invalid'); $script:Answers.Enqueue($sid)
        $prompted = Get-EppProviderEnvironment -ProviderConfiguration $provider
        Assert ($prompted.SAMPLE_SERVICE_ID -ceq $sid -and $script:Answers.Count -eq 0) 'Reprompt invalid input with no credential questions.'

        $script:Calls = [Collections.Generic.List[string]]::new()
        $script:ExistingSecrets = @()
        $script:SecretError = ''
        $script:ListResponse = ''
        $script:GroupExists = $true
        $script:Sites = @('unit-function')
        $script:AppSettings = @(@{ name = 'SAMPLE_SERVICE_ID'; value = $sid })
        function script:Invoke-EppAz {
            [CmdletBinding(PositionalBinding = $false)]
            param([Parameter(Position = 0, ValueFromRemainingArguments)][string[]] $Arguments, [string] $Activity)
            $command = $Arguments -join ' '
            $script:Calls.Add($command)
            switch -Regex ($command) {
                '^keyvault secret list ' {
                    if ($script:ListResponse) { return $script:ListResponse }
                    return ConvertTo-Json -InputObject @($script:ExistingSecrets)
                }
                '^keyvault secret set ' {
                    if ($script:SecretError) { throw $script:SecretError }
                    Assert ($Arguments -contains '--disabled' -and $command.Contains('--disabled true') -and $command.Contains('--output none')) 'Create disabled versions atomically without returning values.'
                    $script:ExistingSecrets += $Arguments[[Array]::IndexOf($Arguments, '--name') + 1]
                    return ''
                }
                '^group exists ' { return ConvertTo-Json -InputObject $script:GroupExists }
                '^resource list ' { return ConvertTo-Json -InputObject $script:Sites }
                '^functionapp config appsettings list ' { return ConvertTo-Json -InputObject $script:AppSettings }
                '^bicep build ' { return '' }
                default { throw "Unexpected Azure operation (no network): $command" }
            }
        }
        $inputs = @{ SubscriptionId = '11111111-1111-1111-1111-111111111111'; ApplicationId = '22222222-2222-2222-2222-222222222222' }
        $names = Get-EppResourceNames -SubscriptionId $inputs.SubscriptionId -ApplicationId $inputs.ApplicationId -ResourcePrefix unit
        $script:Sites = @($names.functionApp)
        $existing = Get-EppExistingAppSettings -Inputs $inputs -Names $names
        Assert ($existing.SAMPLE_SERVICE_ID -ceq $sid) 'Read existing settings for declared-field preservation.'
        $inputs.ExistingProviderEnvironment = $values
        $script:AppSettings = @(@{ name = 'SAMPLE_SERVICE_ID'; value = $replacement })
        Assert-Throws { Invoke-EppDeployment -Inputs $inputs -Names $names -ProviderConfiguration $provider -Context @{} } 'environment settings changed after approval'
        $inputs.Remove('ExistingProviderEnvironment')
        $script:GroupExists = $false; $script:Calls.Clear()
        Assert ((Get-EppExistingAppSettings -Inputs $inputs -Names $names).Count -eq 0 -and $script:Calls.Count -eq 1) 'A new deployment must not query a missing resource group.'
        $script:GroupExists = $true
        Initialize-EppProviderSecrets -Inputs $inputs -Names $names -ProviderConfiguration $provider
        Assert ($script:ExistingSecrets.Count -eq 2) 'Create both missing disabled placeholders.'
        $script:Calls.Clear()
        Initialize-EppProviderSecrets -Inputs $inputs -Names $names -ProviderConfiguration $provider
        Assert ($script:Calls.Count -eq 1 -and $script:Calls[0].StartsWith('keyvault secret list ')) 'Reruns must neither read values nor add secret versions.'
        $script:ExistingSecrets = @('sample-api-key-id'); $script:Calls.Clear()
        Initialize-EppProviderSecrets -Inputs $inputs -Names $names -ProviderConfiguration $provider
        Assert (@($script:Calls | Where-Object { $_ -like 'keyvault secret set *' }).Count -eq 1 -and
            $script:Calls[-1].Contains('--name sample-api-key-secret')) 'Partial reruns must create only the missing secret.'
        $script:ExistingSecrets = @(); $script:SecretError = 'ObjectIsDeletedButRecoverable'
        Assert-Throws { Initialize-EppProviderSecrets -Inputs $inputs -Names $names -ProviderConfiguration $provider } 'ObjectIsDeletedButRecoverable'
        $script:SecretError = ''; $script:ListResponse = '"invalid"'; $script:Calls.Clear()
        Assert-Throws { Initialize-EppProviderSecrets -Inputs $inputs -Names $names -ProviderConfiguration $provider } 'invalid secret metadata'
        Assert ($script:Calls.Count -eq 1) 'Never create placeholders if existing-secret metadata could not be established.'
        $script:ListResponse = ''; $script:Calls.Clear()
        $singleProfile = Read-EppJson (Join-Path $AssetDirectory 'providers/sample.json')
        $singleProfile.deployment.authentication.Remove('identityKeyVaultSecretName')
        $singleProvider = ConvertTo-EppProviderSettings -Profile $singleProfile -Id sample -DisplayName Sample -EndpointRegion global -NonInteractive
        Initialize-EppProviderSecrets -Inputs $inputs -Names $names -ProviderConfiguration $singleProvider
        Assert (@($script:Calls | Where-Object { $_ -like 'keyvault secret set *' }).Count -eq 1 -and
            $script:ExistingSecrets -ceq 'sample-api-key-secret') 'Support API-key providers with one secret and no separate account/key identity.'
        $script:Calls.Clear()
        Initialize-EppProviderSecrets -Inputs $inputs -Names $names -ProviderConfiguration @{ AuthenticationMode = 'oauth' }
        Assert ($script:Calls.Count -eq 0) 'OAuth provisioning must not collect or create API-key secrets.'

        $inputs.ServicePlan = 'FC1'; $inputs.ResourcePrefix = 'unit'; $inputs.TenantId = $inputs.SubscriptionId
        $inputs.ProviderAuthentication = 'apiKey'
        $inputs.Location = 'westus2'; $inputs.Platform = 'Node.js'; $inputs.ProviderEnvironment = $values
        $inputs.PackageUrl = 'https://github.com/unit/repo/releases/download/epp-packages-42-1-javascript/released-package.zip'
        $inputs.PackageReleaseTag = 'epp-packages-42-1-javascript'; $inputs.SourcePackageSha256 = 'a' * 64
        $inputs.SourceBaseUri = "https://raw.githubusercontent.com/unit/repo/$('a' * 40)/setup"
        $context = @{
            ResourceProviders = @(); Application = @{ SignInAudience = 'AzureADMyOrg' }
            InvokeRoleExists = $true; ProviderTenantRestricted = $false
            CertificatePlan = @{ Action = 'Create'; KeyId = $inputs.ApplicationId; CertificateName = 'encryption'; VaultName = $names.keyVault; RemoveKeyIds = @() }
        }
        $script:Messages.Clear()
        Show-EppPlan -Inputs $inputs -Names $names -ProviderConfiguration $provider -Context $context
        $text = $script:Messages -join "`n"
        Assert ($text.Contains("SAMPLE_SERVICE_ID: $sid") -and $text.Contains('DISABLED placeholders') -and
            $text.Contains('no outbound OAuth identity') -and $text.Contains('Easy Auth')) 'Show non-secret inputs, pending credentials, and retained endpoint security before approval.'
        Assert ($text.Contains('single-tenant (AzureADMyOrg)') -and
            -not $text.Contains('Change the endpoint application') -and
            -not $text.Contains('Configure the multi-tenant application')) 'API-key plans must not promise a multi-tenant audience or provider-tenant restriction.'
        $inputs.SourcePackageSha256 = $null; $inputs.PackageSha256 = 'a' * 64; $inputs.PackageReleaseTag = $null
        $script:Messages.Clear()
        Show-EppPlan -Inputs $inputs -Names $names -ProviderConfiguration $provider -Context $context
        $text = $script:Messages -join "`n"
        Assert ($text.Contains('Direct ZIP (no release lookup)') -and $text.Contains('recorded only; no expected SHA-256') -and
            -not $text.Contains('verified automatically')) 'The approval plan must not claim checksum verification for direct packages.'
        $script:Messages.Clear()
        Show-EppDeploymentResult -Inputs $inputs -Names $names -ProviderConfiguration $provider -EndpointUrl 'https://unit.azurewebsites.net/api/SendOtp' -ResultPath 'deployment.json'
        $text = $script:Messages -join "`n"
        Assert ($text.Contains('Customer action required') -and $text.Contains('sample-api-key-id') -and $text.Contains('sample-api-key-secret') -and
            $text.Contains('Live provider delivery has not been validated') -and -not $text.Contains('authorize application')) 'Disclose credential handoff and validation limits, not OAuth authorization.'
        Assert (@(Get-EppResourceRows -Names $names -ServicePlan FC1 -OAuth:$false | Where-Object Resource -eq 'Outbound identity').Count -eq 0) 'Do not plan an OAuth identity for API-key providers.'
        Assert (@(Get-EppResourceProviderRequirements -OAuth:$false | Where-Object Namespace -eq 'Microsoft.ManagedIdentity').Count -eq 0) 'API-key provisioning must not register an unused OAuth resource provider.'

        $script:SetupContext = $context
        $script:AppSettings = @(@{ name = 'SAMPLE_SERVICE_ID'; value = $sid })
        $script:Deployments = 0
        $script:DirectPackage = $false
        function script:Select-EppAzureContext { return @{ TenantId = '11111111-1111-1111-1111-111111111111'; SubscriptionId = '11111111-1111-1111-1111-111111111111' } }
        function script:Select-EppApplication { return '22222222-2222-2222-2222-222222222222' }
        function script:Get-EppTenantRegionScope { return 'NA' }
        function script:Select-EppLocation { return 'westus2' }
        function script:Connect-EppContext { return $script:SetupContext }
        function script:Get-EppCertificatePlan { return $script:SetupContext.CertificatePlan }
        function script:Get-EppLanguage {
            param($Language, $PackagePath)
            Assert ($Language -in @('javascript', 'node.js')) 'Reject unsupported runtimes before package lookup.'
            if ($script:DirectPackage) {
                Assert ($PackagePath -ceq '.\provider.zip') 'Forward PackagePath to package selection.'
                return @{
                    Id = 'javascript'; DisplayName = 'JavaScript'; BuildStrategy = 'ready'
                    Url = 'https://downloads.contoso.com/provider.zip'; ReleaseTag = $null
                }
            }
            return @{
                Id = 'javascript'; DisplayName = 'JavaScript'; BuildStrategy = 'ready'
                Url = 'https://github.com/unit/repo/releases/download/epp-packages-42-1-javascript/released-package.zip'
                ReleaseTag = 'epp-packages-42-1-javascript'
            }
        }
        function script:Get-EppPackage {
            return @{ Sha256 = 'a' * 64; SourceSha256 = $(if ($script:DirectPackage) { $null } else { 'a' * 64 }) }
        }
        function script:Invoke-EppDeployment {
            param($Inputs, $Names, $ProviderConfiguration, $Context, $AssetDirectory, $WorkingDirectory, $Package, $OutputDirectory)
            $script:Deployments++
            Assert ($Inputs.ProviderAuthentication -ceq 'apiKey' -and $null -eq $Inputs.ProviderTenantId) 'Forward API-key mode without an invented tenant.'
            if ($script:DirectPackage) {
                Assert ($Inputs.PackageFile -ceq 'provider.zip' -and -not $Inputs.PackageReleaseTag -and
                    -not $Inputs.SourcePackageSha256 -and $Inputs.PackageSha256 -ceq ('a' * 64)) 'Carry the direct source and recorded hash through approval and deployment.'
            }
            Assert ($Inputs.ProviderEnvironment.SAMPLE_SERVICE_ID -ceq 'svc-1234' -and
                $Inputs.ExistingProviderEnvironment.SAMPLE_SERVICE_ID -ceq 'svc-1234' -and
                $ProviderConfiguration.Settings.SAMPLE_SERVICE_ID -ceq 'svc-1234') 'Wire retained declared input through approval, stale-state snapshot, and Bicep settings.'
            return @{ marker = 'completed' }
        }
        $setup = @{
            AssetDirectory = $AssetDirectory; SourceRepository = 'unit/repo'
            SourceBaseUri = "https://raw.githubusercontent.com/unit/repo/$('a' * 40)/setup"
            ApplicationId = $inputs.ApplicationId; ResourcePrefix = 'unit'; Location = 'westus2'
            Provider = 'sample'; ServicePlan = 'FC1'; NonInteractive = $true
        }
        Assert-Throws { Invoke-EppSetup @setup } 'requires -ApproveDeployment'
        Assert ($script:Deployments -eq 0) 'Missing final approval must prevent provisioning even with valid metadata.'
        Assert-Throws { Invoke-EppSetup @setup -Language python -ApproveDeployment } 'supports only'
        Assert-Throws { Invoke-EppSetup @setup -ApproveDeployment -ProviderEnvironment @{ UNKNOWN = 'x' } } 'Unknown or fixed'
        Assert ($script:Deployments -eq 0) 'Invalid runtime and environment inputs must stop before any provisioning.'
        $completed = Invoke-EppSetup @setup -Language node.js -ApproveDeployment -PassThru
        Assert ($completed.marker -ceq 'completed' -and $script:Deployments -eq 1) 'The generic entry point supports metadata-only onboarding and existing runtime aliases after explicit approval.'
        $script:DirectPackage = $true
        Assert-Throws { Invoke-EppSetup @setup -PackagePath '.\provider.zip' } 'requires -ApproveDeployment'
        Assert ($script:Deployments -eq 1) 'Direct packages must not bypass deployment approval.'
        $null = Invoke-EppSetup @setup -PackagePath '.\provider.zip' -ApproveDeployment
        Assert ($script:Deployments -eq 2) 'Direct package selection reaches the same approved deployment flow.'

    } $setupDirectory $directory
    Write-Host 'Generic API-key metadata, non-secret input, rerun preservation, disabled placeholders, and handoff checks passed.'
}
finally {
    Remove-Module -ModuleInfo $module -Force
    if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force }
}
