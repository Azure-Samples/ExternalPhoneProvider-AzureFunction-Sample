#Requires -Version 7.0
param([string] $TemplatePath, [string] $FrontDoorTemplatePath)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$module = Import-Module (Join-Path $PSScriptRoot '../support/Epp.Setup.psm1') -Force -PassThru
$directory = Join-Path ([IO.Path]::GetTempPath()) "epp-plan-tests-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $directory | Out-Null
try {
    & $module {
        param($Directory, $TemplatePath, $FrontDoorTemplatePath)

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
        $script:Messages = [Collections.Generic.List[string]]::new()
        $script:Calls = [Collections.Generic.List[string]]::new()
        $script:Answers = [Collections.Generic.Queue[string]]::new()
        $script:Regions = '[{"name":"West US 2"}]'
        $script:ExistingPlans = '[]'
        $script:PublicationError = ''
        $script:AuthError = ''
        $script:StartupError = ''
        $script:CloseError = ''
        $script:CliVersion = '2.60.0'
        function script:Write-Host {
            param([Parameter(ValueFromPipeline)] $Object, $ForegroundColor, [switch] $NoNewline)
            process { $script:Messages.Add([string]$Object) }
        }
        function script:Read-Host { param($Prompt); return $script:Answers.Dequeue() }
        function script:Invoke-EppAz {
            param([Parameter(ValueFromRemainingArguments)][string[]] $Arguments)
            $command = $Arguments -join ' '
            $script:Calls.Add($command)
            switch -Regex ($command) {
                '^version ' { return @{ 'azure-cli' = $script:CliVersion } | ConvertTo-Json }
                '^functionapp list-flexconsumption-locations ' { return $script:Regions }
                '^appservice plan list ' { return $script:ExistingPlans }
                '^rest --method get .*Microsoft.Web/geoRegions ' {
                    $path = $Arguments[[Array]::IndexOf($Arguments, '--url-parameters') + 1].Substring(1)
                    $query = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
                    Assert ($query.sku -ceq 'ElasticPremium' -and $query.linuxWorkersEnabled -ceq 'true') 'EP1 must keep the Premium/Linux regional filter.'
                    return '{"value":[{"name":"West US 2"}]}'
                }
                '^(functionapp deployment source config-zip|storage blob upload) ' {
                    if ($script:PublicationError) { throw $script:PublicationError }
                    return ''
                }
                '^functionapp restart ' { return '' }
                '^deployment sub create ' {
                    $path = $Arguments[[Array]::IndexOf($Arguments, '--parameters') + 1].Substring(1)
                    $script:DeploymentParameters = (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable).parameters
                    throw 'stop-after-parameters'
                }
                default { throw "Unexpected Azure call (no network allowed): $command" }
            }
        }

        foreach ($id in @('FC1', 'EP1')) {
            $selected = Get-EppServicePlan -ServicePlan $id.ToLowerInvariant() -NonInteractive
            Assert ($selected.id -ceq $id) 'Explicit plan IDs must normalize to their canonical SKU.'
        }
        Assert-Throws { Get-EppServicePlan -NonInteractive } '\-ServicePlan is required'
        Assert-Throws { Get-EppServicePlan -ServicePlan Y1 -NonInteractive } 'Unknown ServicePlan'
        $script:Answers.Enqueue('1')
        Assert ((Get-EppServicePlan).id -ceq 'FC1') 'Option 1 must select Flex Consumption.'
        $script:Answers.Enqueue('2')
        Assert ((Get-EppServicePlan).id -ceq 'EP1') 'Option 2 must select Premium.'
        Assert (($script:Messages -join "`n") -match 'Service plan selection') 'The selection section must have its requested heading.'
        Assert ($script:Calls.Count -eq 0) 'Selecting a plan must not contact Azure.'

        $inputs = @{
            TenantId = '11111111-1111-1111-1111-111111111111'
            ApplicationId = '22222222-2222-2222-2222-222222222222'
            SubscriptionId = '33333333-3333-3333-3333-333333333333'
            Location = 'westus2'; ResourcePrefix = 'unit'; Platform = 'Node.js'; Language = 'javascript'
            ProviderAuthentication = 'apiKey'; ServicePlan = 'FC1'; BuildStrategy = 'ready'
            PackageUrl = 'https://github.com/Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample/releases/download/epp-packages-1-1/epp-javascript.zip'
            PackageSha256 = ('a' * 64); SourcePackageSha256 = ('a' * 64)
        }
        $names = Get-EppResourceNames -SubscriptionId $inputs.SubscriptionId -ApplicationId $inputs.ApplicationId -ResourcePrefix unit
        $provider = @{
            DisplayName = 'Telesign'; Channel = 'sms'; EndpointRegion = 'global'; AuthenticationMode = 'apiKey'
            Settings = @{
                EPP_PROVIDER_TENANT_ID = '44444444-4444-4444-4444-444444444444'
                EPP_PROVIDER_ENDPOINT = 'https://provider.contoso.com/send'
                EPP_PROVIDER_TIMEOUT_MS = '1500'; EPP_PROVIDER_RETRY_INTERVAL_MS = '100'
            }
            Manifest = @{ deployment = @{ authentication = @{ keyVaultSecretName = 'key'; identityKeyVaultSecretName = 'id' } } }
        }
        $context = @{
            Application = @{ SignInAudience = 'AzureADMultipleOrgs' }
            InvokeRoleExists = $true; ProviderTenantRestricted = $true
            ResourceProviders = @(@{ Namespace = 'Microsoft.Web'; RegistrationState = 'Registered' })
            OperatorId = '55555555-5555-5555-5555-555555555555'; GraphOperatorId = 'operator'; TokenVersion = 2
        }
        foreach ($id in @('FC1', 'EP1')) {
            $inputs.ServicePlan = $id
            $script:Messages.Clear()
            Show-EppPlan -Inputs $inputs -Names $names -ProviderConfiguration $provider -Context $context -SourceBaseUri 'https://source.contoso.com/setup'
            $plan = $script:Messages -join "`n"
            $enabled = ($id -eq 'EP1').ToString().ToLowerInvariant()
            Assert ($plan.Contains("Service plan: $id")) 'The approval must name the selected plan.'
            foreach ($setting in @('EPP_KEY_VAULT_CACHE_ENABLED', 'EPP_ACCESS_TOKEN_CACHE_ENABLED')) {
                Assert ($plan.Contains("$setting=$enabled")) 'The approval must disclose both cache settings.'
            }
            $script:Calls.Clear()
            Assert-EppServicePlanLocation -Inputs $inputs
            Assert ($script:Calls.Count -eq 1) 'Availability must check only the selected plan.'
            if ($id -eq 'FC1') {
                Assert ($script:Calls[0] -like 'functionapp list-flexconsumption-locations *') 'FC1 must use Flex availability.'
                Assert ($plan.Contains('zero always-ready instances') -and $plan.Contains('free usage grant')) 'Disclose FC1 scale-to-zero and billing.'
            }
            else { Assert ($script:Calls[0] -like '*geoRegions*') 'EP1 must keep its ARM availability check.' }
        }
        $inputs.ServicePlan = 'FC1'
        $script:Regions = '[{"name":"East US"}]'
        Assert-Throws { Assert-EppServicePlanLocation -Inputs $inputs } 'FC1 is unavailable'
        $script:Regions = '{}'
        Assert-Throws { Assert-EppServicePlanLocation -Inputs $inputs } 'invalid Flex Consumption'
        $script:Regions = '[{"name":"West US 2"}]'

        foreach ($existing in @('FC1', 'EP1')) {
            $script:ExistingPlans = @(@{ name = $names.hostingPlan; sku = @{ name = $existing } }) | ConvertTo-Json -AsArray
            $inputs.ServicePlan = $existing
            Assert-EppExistingServicePlan -Inputs $inputs -Names $names -Tags @{}
            $inputs.ServicePlan = if ($existing -eq 'FC1') { 'EP1' } else { 'FC1' }
            Assert-Throws { Assert-EppExistingServicePlan -Inputs $inputs -Names $names -Tags @{} } 'in-place plan migration is not supported'
            $script:Calls.Clear()
            Assert-Throws { Assert-EppExistingServicePlan -Inputs $inputs -Names $names -Tags @{ eppServicePlan = $existing } } 'different prefix'
            Assert ($script:Calls.Count -eq 0) 'A tagged plan mismatch must fail before further Azure calls.'
        }
        $script:ExistingPlans = '[]'
        Assert-EppExistingServicePlan -Inputs $inputs -Names $names -Tags @{}
        foreach ($invalid in @('{}', 'null')) {
            $script:ExistingPlans = $invalid
            Assert-Throws { Assert-EppExistingServicePlan -Inputs $inputs -Names $names -Tags @{} } 'invalid hosting-plan list'
        }
        $script:ExistingPlans = '[]'

        function script:Get-Command { param($Name, $ErrorAction); return @{ Name = $Name } }
        function script:Initialize-EppBicep { param([switch] $NonInteractive, [switch] $InstallPrerequisites); throw 'passed-version-check' }
        foreach ($id in @('FC1', 'EP1')) {
            $inputs.ServicePlan = $id
            $script:CliVersion = if ($id -eq 'FC1') { '2.59.0' } else { '2.48.0' }
            Assert-Throws { Connect-EppContext -Inputs $inputs -Names $names -NonInteractive } 'Azure CLI .* or newer is required'
            $script:CliVersion = if ($id -eq 'FC1') { '2.60.0' } else { '2.48.1' }
            Assert-Throws { Connect-EppContext -Inputs $inputs -Names $names -NonInteractive } 'passed-version-check'
        }

        function script:Assert-EppAuthentication {
            param($SiteId, $Inputs, $Context, $IdentifierUri)
            $script:Calls.Add('authentication')
            if ($script:AuthError) { throw $script:AuthError }
        }
        function script:Set-EppPublicAccess {
            param($SiteId, $SubscriptionId, $Access)
            $script:Calls.Add("ingress:$Access")
            if ($Access -eq 'Disabled' -and $script:CloseError) { throw $script:CloseError }
        }
        function script:Sync-EppFunctionTriggers { param($SiteId, $SubscriptionId); $script:Calls.Add('triggers') }
        function script:Assert-EppFunctionPublished {
            param($Inputs, $Names)
            $script:Calls.Add('published')
            if ($script:StartupError) { throw $script:StartupError }
        }
        function script:Invoke-EppDataOperation { param([scriptblock] $Operation); & $Operation }
        function script:Build-EppPythonPackage {
            param($Inputs, $Names, $SiteId, $SourcePath, $Directory)
            $script:Calls.Add('python-build')
            return Join-Path $Directory 'python-built.zip'
        }
        function script:Set-EppPackageSettings {
            param($SiteId, $SubscriptionId, $PackageUrl, $Directory)
            $script:Calls.Add("package-settings:$PackageUrl")
        }
        Set-Content -LiteralPath (Join-Path $Directory 'python-built.zip') -Value 'synthetic built payload'
        $builtHash = (Get-FileHash -LiteralPath (Join-Path $Directory 'python-built.zip') -Algorithm SHA256).Hash.ToLowerInvariant()
        $publish = @{
            Inputs = $inputs; Names = $names; Context = $context; SiteId = '/subscriptions/unit/resourceGroups/unit/providers/Microsoft.Web/sites/unit'
            Outputs = @{ identifierUri = @{ value = 'api://unit' }; packageContainerUrl = @{ value = "https://$($names.storageAccount).blob.core.windows.net/packages/" } }
            Package = @{ Path = (Join-Path $Directory 'source.zip'); RequiresRemoteBuild = $false }
            Directory = $Directory
        }
        foreach ($id in @('FC1', 'EP1')) {
            foreach ($language in @('javascript', 'dotnet', 'python')) {
                $inputs.ServicePlan = $id; $inputs.Language = $language
                $publish.Package.RequiresRemoteBuild = $language -eq 'python'
                $script:Calls.Clear()
                $hash = Publish-EppFunction @publish
                $trace = $script:Calls -join "`n"
                Assert ($script:Calls[0] -ceq 'authentication') 'Authentication must be verified before any publication or ingress change.'
                Assert ($script:Calls[-1] -ceq 'published') 'Publication must finish with Function metadata readback.'
                if ($id -eq 'FC1') {
                    $remoteBuild = ($language -eq 'python').ToString().ToLowerInvariant()
                    Assert ($script:Calls[1] -ceq 'ingress:Enabled') 'Flex must open its authenticated deployment endpoint before One Deploy.'
                    Assert ($trace.Contains("functionapp deployment source config-zip") -and $trace.Contains("--build-remote $remoteBuild")) 'Flex must use One Deploy with the correct remote-build flag.'
                    Assert ($trace -notmatch 'storage blob upload|package-settings|python-build|functionapp restart|triggers') 'Flex must not use Premium publishing or run-from-package.'
                    if ($language -eq 'python') { Assert ($null -eq $hash) 'Do not label a Python source hash as the Azure-built output hash.' }
                    else { Assert ($hash -ceq $inputs.PackageSha256) 'Ready Flex packages must retain the verified hash.' }
                }
                else {
                    Assert ($trace -match 'storage blob upload' -and $trace -match 'functionapp restart' -and $trace -match 'triggers') 'EP1 must retain managed-identity package publication and trigger synchronization.'
                    Assert ($trace -notmatch 'deployment source config-zip') 'EP1 must not use the Flex publishing branch.'
                    if ($language -eq 'python') {
                        Assert ($hash -ceq $builtHash -and $trace.Contains("$builtHash.zip")) 'EP1 Python must upload and mount the built, hashed output.'
                    }
                    else { Assert ($hash -ceq $inputs.PackageSha256) 'Ready EP1 packages must retain the verified hash.' }
                }
            }
        }
        foreach ($id in @('FC1', 'EP1')) {
            $inputs.ServicePlan = $id; $publish.Package.RequiresRemoteBuild = $false
            $script:Calls.Clear(); $script:AuthError = 'authentication-rejected'
            Assert-Throws { Publish-EppFunction @publish } 'authentication-rejected'
            Assert ($script:Calls.Count -eq 1) 'Failed authentication must not open ingress or publish.'
            $script:AuthError = ''; $script:PublicationError = 'publication-rejected'; $script:Calls.Clear()
            Assert-Throws { Publish-EppFunction @publish } 'publication-rejected'
            if ($id -eq 'FC1') { Assert ($script:Calls[-1] -ceq 'ingress:Disabled') 'Failed One Deploy must close ingress.' }
            $script:PublicationError = ''; $script:StartupError = 'startup-rejected'; $script:Calls.Clear()
            Assert-Throws { Publish-EppFunction @publish } 'startup-rejected'
            Assert ($script:Calls[-1] -ceq 'ingress:Disabled') 'Failed startup must close ingress for either plan.'
            $script:CloseError = 'close-rejected'
            Assert-Throws { Publish-EppFunction @publish } 'public ingress could not be disabled'
            $script:StartupError = ''; $script:CloseError = ''
        }

        function script:Get-MgContext { return @{} }
        function script:Test-EppGraphContext { param($Context, $TenantId); return $true }
        function script:Get-EppGraphOperator { return @{ Id = 'operator' } }
        function script:Initialize-EppGraphAccess { param($Inputs, $Context); return @{} }
        function script:Initialize-EppResourceProviders { param($Inputs) }
        foreach ($id in @('FC1', 'EP1')) {
            $inputs.ServicePlan = $id
            Assert-Throws {
                Invoke-EppDeployment -Inputs $inputs -Names $names -ProviderConfiguration $provider -Context $context `
                    -AssetDirectory $Directory -Package $publish.Package -OutputDirectory $Directory -SourceBaseUri 'https://source.contoso.com/setup'
            } 'stop-after-parameters'
            Assert ($script:DeploymentParameters.servicePlan.value -ceq $id) 'The approved plan must be passed to Bicep.'
        }

        if ($TemplatePath) {
            $template = Get-Content -LiteralPath $TemplatePath -Raw | ConvertFrom-Json -AsHashtable
            $resources = if ($template.resources -is [Collections.IDictionary]) { $template.resources.Values } else { $template.resources }
            $inner = ($resources | Where-Object type -eq 'Microsoft.Resources/deployments').properties.template
            $symbolic = $inner.resources -is [Collections.IDictionary]
            $resources = if ($symbolic) { $inner.resources.Values } else { $inner.resources }
            Assert (($inner.parameters.servicePlan.allowedValues -join ',') -ceq 'FC1,EP1') 'Bicep must restrict service plans to the two offered SKUs.'
            Assert ($inner.variables.isFlexConsumption -ceq "[equals(parameters('servicePlan'), 'FC1')]") 'The Flex condition must use the selected SKU.'
            $plan = $resources | Where-Object type -eq 'Microsoft.Web/serverfarms'
            Assert ($plan.sku -ceq "[if(variables('isFlexConsumption'), createObject('name', 'FC1', 'tier', 'FlexConsumption'), createObject('name', 'EP1', 'tier', 'ElasticPremium', 'capacity', 1))]") 'Bicep must deploy the selected SKU, tier, and Premium capacity.'
            $settings = ($resources | Where-Object { $_.type -eq 'Microsoft.Web/sites/config' -and $_.name -like '*appsettings*' }).properties
            foreach ($setting in @('EPP_KEY_VAULT_CACHE_ENABLED', 'EPP_ACCESS_TOKEN_CACHE_ENABLED')) {
                Assert ($settings.Contains("'$setting', if(variables('isFlexConsumption'), 'false', 'true')")) 'Both cache app settings must follow the selected plan.'
            }
            $site = ($resources | Where-Object type -eq 'Microsoft.Web/sites').properties
            Assert ($site -is [Collections.IDictionary]) 'Function App properties must remain a literal object so serverFarmId is visible during provider preflight.'
            Assert ($site.serverFarmId -ceq "[resourceId('Microsoft.Web/serverfarms', parameters('resourceNames').hostingPlan)]") 'The hosting-plan ID must be explicit without a runtime reference.'
            Assert ($site.httpsOnly -eq $true -and $site.publicNetworkAccess -ceq 'Disabled') 'The Function must retain HTTPS-only access and initially disabled public ingress.'
            $functionAppConfig = $site.functionAppConfig
            Assert ($functionAppConfig -is [string] -and $functionAppConfig.StartsWith("[if(variables('isFlexConsumption'), ") -and $functionAppConfig.EndsWith(', null())]')) 'Only functionAppConfig must be conditional on FC1, with no Flex configuration for EP1.'
            $storageEndpoint = if ($symbolic) { "reference('storage').primaryEndpoints.blob" }
                else { "reference(resourceId('Microsoft.Storage/storageAccounts', parameters('resourceNames').storageAccount), '2023-05-01').primaryEndpoints.blob" }
            Assert ($functionAppConfig.Contains("'deployment', createObject('storage', createObject('type', 'blobContainer'") -and $functionAppConfig.Contains($storageEndpoint)) 'Flex must retain its deployment container and storage endpoint lookup.'
            Assert ($functionAppConfig.Contains("'instanceMemoryMB', 2048, 'maximumInstanceCount', 40, 'alwaysReady', createArray()") -and $functionAppConfig.Contains("'type', 'SystemAssignedIdentity'")) 'Flex must retain 2048 MB, up to 40 on-demand instances, zero always-ready instances, and managed-identity deployment storage.'
        }
        if ($FrontDoorTemplatePath) {
            $template = Get-Content -LiteralPath $FrontDoorTemplatePath -Raw | ConvertFrom-Json -AsHashtable
            $resources = if ($template.resources -is [Collections.IDictionary]) { $template.resources.Values } else { $template.resources }
            $regional = @($resources | Where-Object type -eq 'Microsoft.Resources/deployments')
            Assert ($regional.Count -eq 1) 'Front Door must reuse one regional module in a deployment loop.'
            Assert ($regional[0].properties.parameters.servicePlan.value -ceq 'EP1') 'Front Door origins must explicitly stay on the supported EP1 plan.'
            Assert ($regional[0].properties.parameters.frontDoor.value.id -ceq "[parameters('frontDoorId')]") 'Regional ingress must remain pinned to the Front Door profile.'
        }
    } $directory $TemplatePath $FrontDoorTemplatePath
    Write-Host 'Service plan selection, approval, availability, migration guards, CLI versions, and publication checks passed.'
}
finally {
    Remove-Module -ModuleInfo $module -Force
    Remove-Item -LiteralPath $directory -Recurse -Force
}
