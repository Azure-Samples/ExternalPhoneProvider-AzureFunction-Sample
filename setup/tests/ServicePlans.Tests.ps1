#Requires -Version 7.0
param([string] $TemplatePath, [string] $PublishTemplatePath, [string] $IngressTemplatePath)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$module = Import-Module (Join-Path $PSScriptRoot '../support/Epp.Setup.psm1') -Force -PassThru
$directory = Join-Path (Get-Location) ".epp-plan-tests-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $directory | Out-Null
try {
    & $module {
        param($Directory, $TemplatePath, $PublishTemplatePath, $IngressTemplatePath)

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
        $script:Activities = [Collections.Generic.List[string]]::new()
        $script:Answers = [Collections.Generic.Queue[string]]::new()
        $script:Regions = '[{"name":"West US 2"}]'
        $script:ExistingPlans = '[]'
        $script:PublicationError = ''
        $script:AuthError = ''
        $script:StartupError = ''
        $script:CloseError = ''
        $script:OpenError = ''
        $script:InvalidSite = $false
        $script:GroupParameters = @{}
        $script:CliVersion = '2.60.0'
        function script:Write-Host {
            param([Parameter(ValueFromPipeline)] $Object, $ForegroundColor, [switch] $NoNewline)
            process { $script:Messages.Add([string]$Object) }
        }
        function script:Read-Host { param($Prompt); return $script:Answers.Dequeue() }
        function script:Invoke-EppAz {
            [CmdletBinding(PositionalBinding = $false)]
            param([Parameter(Position = 0, ValueFromRemainingArguments)][string[]] $Arguments, [string] $Activity)
            $command = $Arguments -join ' '
            $script:Calls.Add($command)
            if ($Activity) { $script:Activities.Add($Activity) }
            switch -Regex ($command) {
                '^version ' { return @{ 'azure-cli' = $script:CliVersion } | ConvertTo-Json }
                '^bicep version ' { return '' }
                '^functionapp list-flexconsumption-locations ' { return $script:Regions }
                '^appservice plan list ' { return $script:ExistingPlans }
                '^rest --method get .*Microsoft.Web/geoRegions ' {
                    $path = $Arguments[[Array]::IndexOf($Arguments, '--url-parameters') + 1].Substring(1)
                    $query = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
                    Assert ($query.sku -ceq 'ElasticPremium' -and $query.linuxWorkersEnabled -ceq 'true') 'EP1 must keep the Premium/Linux regional filter.'
                    return '{"value":[{"name":"West US 2"}]}'
                }
                '^rest --method get .*Microsoft.Web/sites/' {
                    if ($script:InvalidSite) { return '{"id":"wrong-site","properties":{}}' }
                    return @{
                        id = $script:SiteId; name = 'unit'; location = 'westus2'; kind = 'functionapp,linux'
                        identity = @{
                            type = 'SystemAssigned, UserAssigned'; principalId = 'identity'
                            userAssignedIdentities = @{ '/subscriptions/unit/resourceGroups/unit/providers/Microsoft.ManagedIdentity/userAssignedIdentities/outbound' = @{} }
                        }
                        tags = @{ managedBy = 'EPP-Setup'; customTag = 'preserve-tag' }
                        properties = @{ serverFarmId = 'preserve-plan'; publicNetworkAccess = 'Disabled'; httpsOnly = $true }
                    } | ConvertTo-Json -Depth 6
                }
                '^deployment group create ' {
                    $path = $Arguments[[Array]::IndexOf($Arguments, '--parameters') + 1].Substring(1)
                    $template = $Arguments[[Array]::IndexOf($Arguments, '--template-file') + 1]
                    $parameters = (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable).parameters
                    if ($template -match 'ingress\.json$') {
                        $access = $parameters.access.value
                        $script:GroupParameters["ingress:$access"] = $parameters
                        $script:Calls.Add("ingress:$access")
                        if ($access -eq 'Enabled' -and $script:OpenError) { throw $script:OpenError }
                        if ($access -eq 'Disabled' -and $script:CloseError) { throw $script:CloseError }
                    }
                    elseif ($template -match 'publish\.json$') {
                        $script:GroupParameters.publish = $parameters
                        $script:Calls.Add('publish')
                        if ($script:PublicationError) { throw $script:PublicationError }
                    }
                    else { throw "Unexpected group template: $template" }
                }
                '^deployment sub create ' {
                    $path = $Arguments[[Array]::IndexOf($Arguments, '--parameters') + 1].Substring(1)
                    $template = $Arguments[[Array]::IndexOf($Arguments, '--template-file') + 1]
                    Assert ($template -match 'main\.json$') 'Deploy the compiled JSON, not Bicep.'
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
        foreach ($blank in @('', '  ')) {
            $script:Answers.Enqueue($blank)
            Assert ((Get-EppServicePlan).id -ceq 'FC1') 'Enter must accept the Flex Consumption default.'
        }
        $script:Answers.Enqueue('2')
        Assert ((Get-EppServicePlan).id -ceq 'EP1') 'Option 2 must select Premium.'
        Assert (($script:Messages -join "`n") -match 'Service plan selection') 'The selection section must have its requested heading.'
        Assert (($script:Messages -join "`n").Contains('https://github.com/Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample/blob/main/docs/COST-CALCULATOR.md')) 'Link the repository cost estimator at plan selection.'
        Assert ($script:Calls.Count -eq 0) 'Selecting a plan must not contact Azure.'

        $inputs = @{
            TenantId = '11111111-1111-1111-1111-111111111111'
            ApplicationId = '22222222-2222-2222-2222-222222222222'
            SubscriptionId = '33333333-3333-3333-3333-333333333333'
            Location = 'westus2'; ResourcePrefix = 'unit'; Platform = 'Node.js'; Language = 'javascript'
            ProviderAuthentication = 'oauth'; ServicePlan = 'FC1'; BuildStrategy = 'ready'
            PackageFile = 'released-package.zip'
            PackageReleaseTag = 'epp-packages-1-1-javascript'
            PackageUrl = 'https://github.com/Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample/releases/download/epp-packages-1-1-javascript/released-package.zip'
            SourceRevision = ('a' * 40)
            SourceBaseUri = "https://raw.githubusercontent.com/Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample/$('a' * 40)/setup"
            PackageSha256 = ('a' * 64); SourcePackageSha256 = ('a' * 64)
            ArmAssetDirectory = $Directory
        }
        $names = Get-EppResourceNames -SubscriptionId $inputs.SubscriptionId -ApplicationId $inputs.ApplicationId -ResourcePrefix unit
        $provider = @{
            DisplayName = 'Telesign'; EndpointRegion = 'global'; AuthenticationMode = 'oauth'
            TenantId = '44444444-4444-4444-4444-444444444444'
            AccessTokenScopeTenant = '77777777-7777-7777-7777-777777777777'
            Settings = @{
                EPP_PROVIDER_TENANT_ID = '77777777-7777-7777-7777-777777777777'
                EPP_PROVIDER_APP_ID = '88888888-8888-8888-8888-888888888888'
                EPP_PROVIDER_SCOPE = 'api://88888888-8888-8888-8888-888888888888/.default'
                EPP_PROVIDER_SMS_ENDPOINT = 'https://sms.provider.contoso.com/send'
                EPP_PROVIDER_VOICE_ENDPOINT = 'https://voice.provider.contoso.com/send'
                EPP_PROVIDER_TIMEOUT_MS = '1500'; EPP_PROVIDER_RETRY_INTERVAL_MS = '100'
            }
            Manifest = @{ deployment = @{ authentication = @{ mode = 'oauth' } } }
        }
        $context = @{
            Application = @{ SignInAudience = 'AzureADMultipleOrgs' }
            CertificatePlan = @{
                Action = 'Create'; KeyId = '66666666-6666-6666-6666-666666666666'
                CertificateName = 'phone-provider-encryption'; VaultName = $names.keyVault
                CertificateId = $null; VaultSubscriptionId = $inputs.SubscriptionId
                VaultResourceId = "/subscriptions/$($inputs.SubscriptionId)/resourceGroups/$($names.resourceGroup)/providers/Microsoft.KeyVault/vaults/$($names.keyVault)"
                VaultRbac = $true; VaultAccessPolicies = @()
                RemoveKeyIds = @(); ExistingCertificates = @()
            }
            InvokeRoleExists = $true; ProviderTenantRestricted = $true
            ResourceProviders = @(@{ Namespace = 'Microsoft.Web'; RegistrationState = 'Registered' })
            OperatorId = '55555555-5555-5555-5555-555555555555'; GraphOperatorId = 'operator'; TokenVersion = 2
        }
        foreach ($id in @('FC1', 'EP1')) {
            $inputs.ServicePlan = $id
            $script:Messages.Clear()
            Show-EppPlan -Inputs $inputs -Names $names -ProviderConfiguration $provider -Context $context
            $plan = $script:Messages -join "`n"
            Assert ($plan.Contains("Service plan: $id")) 'The approval must name the selected plan.'
            Assert ($plan.Contains('Language:') -and -not $plan.Contains('Platform:')) 'Use customer-facing language terminology.'
            Assert (-not $plan.Contains('Python')) 'Do not describe Python builds for JavaScript deployments.'
            Assert ($plan.Contains($inputs.SourceBaseUri) -and $plan.Contains($inputs.PackageUrl) -and
                $plan.Contains("Release:      $($inputs.PackageReleaseTag)")) 'The approval must identify the setup source and exact Function release URL.'
            Assert ($plan.Contains('SMS and voice (selected by each request)')) 'The approval must disclose support for both request channels.'
            Assert ($plan.Contains("SMS endpoint: $($provider.Settings.EPP_PROVIDER_SMS_ENDPOINT)")) 'The approval must disclose the SMS endpoint.'
            Assert ($plan.Contains("Voice endpoint: $($provider.Settings.EPP_PROVIDER_VOICE_ENDPOINT)")) 'The approval must disclose the voice endpoint.'
            foreach ($setting in @('EPP_KEY_VAULT_CACHE_ENABLED', 'EPP_ACCESS_TOKEN_CACHE_ENABLED')) {
                Assert (-not $plan.Contains($setting)) 'The approval must not advertise obsolete cache settings.'
            }
            Assert ($plan.Contains('Deploy the verified GitHub release URL through ARM') -and
                $plan.Contains('ARM does not enforce the locally verified hash')) 'Disclose native publication and its second-fetch integrity boundary.'
            $script:Calls.Clear()
            Assert-EppServicePlanLocation -Inputs $inputs
            Assert ($script:Calls.Count -eq 1) 'Availability must check only the selected plan.'
            if ($id -eq 'FC1') {
                Assert ($script:Calls[0] -like 'functionapp list-flexconsumption-locations *') 'FC1 must use Flex availability.'
                Assert ($plan.Contains('zero always-ready instances') -and $plan.Contains('free usage grant')) 'Disclose FC1 scale-to-zero and billing.'
            }
            else { Assert ($script:Calls[0] -like '*geoRegions*') 'EP1 must keep its ARM availability check.' }
        }
        $script:Messages.Clear()
        Show-EppPlan -Inputs $inputs -Names $names -ProviderConfiguration $provider -Context $context
        $plan = $script:Messages -join "`n"
        Assert ($plan.Contains("Security Store tenant: $($provider.TenantId)") -and
            $plan.Contains("Access-token tenant: $($provider.AccessTokenScopeTenant)")) 'Approval must disclose the two distinct provider tenants.'
        Assert ($plan.Contains('Telesign OAuth: add a federated credential') -and
            -not $plan.Contains('Soprano OAuth')) 'Federation guidance must identify the selected OAuth provider.'
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
        function script:Connect-EppAzureAccount { param($Inputs, [switch] $NonInteractive, [switch] $ForceAuthentication); throw 'passed-version-check' }
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
        function script:Assert-EppFunctionPublished {
            param($Inputs, $Names)
            $script:Calls.Add('published')
            if ($script:StartupError) { throw $script:StartupError }
        }
        function script:Invoke-EppDataOperation { param([scriptblock] $Operation); & $Operation }
        $script:SiteId = "/subscriptions/$($inputs.SubscriptionId)/resourceGroups/$($names.resourceGroup)/providers/Microsoft.Web/sites/$($names.functionApp)"
        $publish = @{
            Inputs = $inputs; Names = $names; Context = $context; SiteId = $script:SiteId
            Outputs = @{ identifierUri = @{ value = 'api://unit' }; packageContainerUrl = @{ value = "https://$($names.storageAccount).blob.core.windows.net/packages/" } }
            Package = @{ Path = (Join-Path $Directory 'source.zip'); RequiresRemoteBuild = $false }
            Directory = $Directory
        }
        foreach ($id in @('FC1', 'EP1')) {
            foreach ($language in @('javascript', 'dotnet', 'python')) {
                $inputs.ServicePlan = $id; $inputs.Language = $language
                $inputs.PackageReleaseTag = "epp-packages-1-1-$language"
                $inputs.PackageUrl = "https://github.com/Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample/releases/download/$($inputs.PackageReleaseTag)/released-package.zip"
                $script:Calls.Clear(); $script:Activities.Clear()
                $hash = Publish-EppFunction @publish
                $trace = $script:Calls -join "`n"
                Assert ($script:Calls[0] -ceq 'authentication') 'Authentication must be verified before any publication or ingress change.'
                Assert ($script:Calls[-1] -ceq 'published') 'Publication must finish with Function metadata readback.'
                Assert ($script:Activities.Count -gt 0) 'Every plan/language publication path must provide an activity indicator.'
                Assert ($script:Calls.IndexOf('ingress:Enabled') -lt $script:Calls.IndexOf('publish')) 'Open ingress through ARM only after authentication, before native publication.'
                Assert ($script:GroupParameters.publish.servicePlan.value -ceq $id -and
                    $script:GroupParameters.publish.packageUri.value -ceq $inputs.PackageUrl -and
                    $script:GroupParameters.publish.functionAppName.value -ceq $names.functionApp) 'Publish the exact release ZIP to the approved plan and Function.'
                Assert ($script:GroupParameters['ingress:Enabled'].site.value.properties.serverFarmId -ceq 'preserve-plan') 'The ingress wrapper must pass existing site metadata to ARM.'
                $ingressSite = $script:GroupParameters['ingress:Enabled'].site.value
                Assert ($ingressSite.identity.type -ceq 'SystemAssigned, UserAssigned' -and
                    $ingressSite.identity.userAssignedIdentities.Count -eq 1 -and
                    $ingressSite.tags.customTag -ceq 'preserve-tag') 'Ingress must pass through both Function identities and existing tags.'
                Assert ($trace -notmatch 'config-zip|storage blob upload|functionapp restart|triggers|build-remote') 'All languages must use native ARM publication without remote builds or imperative restart/sync.'
                Assert ($hash -ceq $inputs.PackageSha256) 'All six publication paths must retain the verified release hash.'
                Assert (-not (Test-Path (Join-Path $Directory 'publish.parameters.json')) -and
                    -not (Test-Path (Join-Path $Directory 'ingress.parameters.json'))) 'Remove ARM parameter files after publication.'
            }
        }
        foreach ($id in @('FC1', 'EP1')) {
            $inputs.ServicePlan = $id; $publish.Package.RequiresRemoteBuild = $false
            $script:Calls.Clear(); $script:AuthError = 'authentication-rejected'
            Assert-Throws { Publish-EppFunction @publish } 'authentication-rejected'
            Assert ($script:Calls.Count -eq 1) 'Failed authentication must not open ingress or publish.'
            $script:AuthError = ''; $script:PublicationError = 'publication-rejected'; $script:Calls.Clear()
            Assert-Throws { Publish-EppFunction @publish } 'publication-rejected'
            Assert ($script:Calls[-1] -ceq 'ingress:Disabled') 'Failed native publication must close ingress for either plan.'
            Assert (-not (Test-Path (Join-Path $Directory 'publish.parameters.json'))) 'Failed publication must remove its ARM parameter file.'
            $script:PublicationError = ''; $script:StartupError = 'startup-rejected'; $script:Calls.Clear()
            Assert-Throws { Publish-EppFunction @publish } 'startup-rejected'
            Assert ($script:Calls[-1] -ceq 'ingress:Disabled') 'Failed startup must close ingress for either plan.'
            $script:CloseError = 'close-rejected'
            Assert-Throws { Publish-EppFunction @publish } 'public ingress could not be disabled'
            $script:StartupError = ''; $script:CloseError = ''
            $script:OpenError = 'open-rejected'; $script:Calls.Clear()
            Assert-Throws { Publish-EppFunction @publish } 'open-rejected'
            Assert ($script:Calls[-1] -ceq 'ingress:Disabled' -and -not $script:Calls.Contains('publish')) 'A failed ingress enable must close ingress without publication.'
            $script:OpenError = ''; $script:InvalidSite = $true; $script:Calls.Clear()
            Assert-Throws { Set-EppPublicAccess -SiteId $script:SiteId -SubscriptionId $inputs.SubscriptionId -Access Enabled -AssetDirectory $Directory -Directory $Directory } 'invalid Function metadata'
            Assert (@($script:Calls | Where-Object { $_ -like 'deployment group create *' }).Count -eq 0) 'Invalid site metadata must not be sent to ARM.'
            $script:InvalidSite = $false
            $publish.Package.RequiresRemoteBuild = $true; $script:Calls.Clear()
            Assert-Throws { Publish-EppFunction @publish } 'ready-to-deploy release ZIP'
            Assert ($script:Calls.Count -eq 0) 'Reject source packages before authentication or ingress changes.'
            $publish.Package.RequiresRemoteBuild = $false
        }

        function script:Get-EppGraphOperator { param($Inputs); return @{ Id = 'operator' } }
        $script:ArmOperator = $context.OperatorId
        function script:Get-EppArmOperatorObjectId { param($Inputs); return $script:ArmOperator }
        function script:Initialize-EppGraphAccess { param($Inputs, $Context); return @{} }
        function script:Initialize-EppResourceProviders { param($Inputs) }
        foreach ($id in @('FC1', 'EP1')) {
            $inputs.ServicePlan = $id
            $script:Activities.Clear()
            Assert-Throws {
                Invoke-EppDeployment -Inputs $inputs -Names $names -ProviderConfiguration $provider -Context $context `
                    -AssetDirectory $Directory -WorkingDirectory $Directory -Package $publish.Package -OutputDirectory $Directory
            } 'stop-after-parameters'
            Assert ($script:Activities -contains 'Deploying Azure resources') 'ARM deployment must use the shared activity indicator.'
            Assert ($script:DeploymentParameters.servicePlan.value -ceq $id) 'The approved plan must be passed to Bicep.'
            foreach ($setting in @('EPP_PROVIDER_SMS_ENDPOINT', 'EPP_PROVIDER_VOICE_ENDPOINT', 'EPP_PROVIDER_TENANT_ID', 'EPP_PROVIDER_SCOPE')) {
                Assert ($script:DeploymentParameters.providerSettings.value[$setting] -ceq $provider.Settings[$setting]) 'Approved endpoints and OAuth settings must be passed to Bicep.'
            }
            Assert ($script:DeploymentParameters.providerSettings.value.EPP_PROVIDER_TENANT_ID -ceq $provider.AccessTokenScopeTenant -and
                $script:DeploymentParameters.providerSettings.value.EPP_PROVIDER_TENANT_ID -cne $provider.TenantId) 'Deploy the access-token authority rather than the Security Store tenant.'
            Assert (-not $script:DeploymentParameters.providerSettings.value.ContainsKey('EPP_PROVIDER_CHANNEL')) 'Bicep must not receive a channel restriction.'
        }

        if ($TemplatePath) {
            $template = Get-Content -LiteralPath $TemplatePath -Raw | ConvertFrom-Json -AsHashtable
            $inner = ($template.resources | Where-Object { $_.type -eq 'Microsoft.Resources/deployments' -and $_.name -ceq 'epp-endpoint' }).properties.template
            Assert (($inner.parameters.servicePlan.allowedValues -join ',') -ceq 'FC1,EP1') 'Bicep must restrict service plans to the two offered SKUs.'
            Assert ($inner.variables.isFlexConsumption -ceq "[equals(parameters('servicePlan'), 'FC1')]") 'The Flex condition must use the selected SKU.'
            $plan = $inner.resources | Where-Object type -eq 'Microsoft.Web/serverfarms'
            Assert ($plan.sku -ceq "[if(variables('isFlexConsumption'), createObject('name', 'FC1', 'tier', 'FlexConsumption'), createObject('name', 'EP1', 'tier', 'ElasticPremium', 'capacity', 1))]") 'Bicep must deploy the selected SKU, tier, and Premium capacity.'
            Assert (@($inner.resources | Where-Object { $_.type -eq 'Microsoft.Web/sites/config' -and $_.name -like '*appsettings*' }).Count -eq 0) 'Initial settings reads and writes must not target the same resource in one template.'
            $settingsDeployment = $inner.resources | Where-Object { $_.type -eq 'Microsoft.Resources/deployments' -and $_.name -ceq 'epp-app-settings' }
            $settings = $settingsDeployment.properties.parameters.appSettings.value
            $settingsRead = "list(format('{0}/config/appsettings', resourceId('Microsoft.Web/sites', parameters('resourceNames').functionApp)), '2024-04-01').properties"
            Assert ($settings.StartsWith("[union($settingsRead, ", [StringComparison]::Ordinal) -and
                -not $settings.Contains('listApplicationSettings') -and
                $settings.Contains("'WEBSITE_RUN_FROM_PACKAGE', '1'") -and
                $settings.Contains("'SCM_DO_BUILD_DURING_DEPLOYMENT', 'false'")) 'Initial settings must read the appsettings child through its list action, merge existing values, and configure Premium ZIP mounting without builds.'
            Assert ($settingsDeployment.dependsOn -ccontains "[resourceId('Microsoft.Web/sites', parameters('resourceNames').functionApp)]") 'Read existing settings only after the Function exists.'
            foreach ($setting in @('EPP_KEY_VAULT_CACHE_ENABLED', 'EPP_ACCESS_TOKEN_CACHE_ENABLED')) {
                Assert (-not $settings.Contains($setting)) 'Bicep must not configure removed credential caches.'
            }
            $site = ($inner.resources | Where-Object type -eq 'Microsoft.Web/sites').properties
            Assert ($site -is [Collections.IDictionary]) 'Function App properties must remain a literal object so serverFarmId is visible during provider preflight.'
            Assert ($site.serverFarmId -ceq "[resourceId('Microsoft.Web/serverfarms', parameters('resourceNames').hostingPlan)]") 'The hosting-plan ID must be explicit without a runtime reference.'
            Assert ($site.httpsOnly -eq $true -and $site.publicNetworkAccess -ceq 'Disabled') 'The Function must retain HTTPS-only access and initially disabled public ingress.'
            Assert ($site.keyVaultReferenceIdentity -ceq 'SystemAssigned') 'Certificate references must use the Function system identity, not the outbound identity.'
            $functionAppConfig = $site.functionAppConfig
            Assert ($functionAppConfig -is [string] -and $functionAppConfig.StartsWith("[if(variables('isFlexConsumption'), ") -and $functionAppConfig.EndsWith(', null())]')) 'Only functionAppConfig must be conditional on FC1, with no Flex configuration for EP1.'
            Assert ($functionAppConfig.Contains("'deployment', createObject('storage', createObject('type', 'blobContainer'") -and $functionAppConfig.Contains("reference(resourceId('Microsoft.Storage/storageAccounts', parameters('resourceNames').storageAccount), '2023-05-01').primaryEndpoints.blob")) 'Flex must retain its deployment container and storage endpoint lookup.'
            Assert ($functionAppConfig.Contains("'instanceMemoryMB', 2048, 'maximumInstanceCount', 40, 'alwaysReady', createArray()") -and $functionAppConfig.Contains("'type', 'SystemAssignedIdentity'")) 'Flex must retain 2048 MB, up to 40 on-demand instances, zero always-ready instances, and managed-identity deployment storage.'
            Assert ($template.outputs.certificateBundle.type -ceq 'object' -and
                $template.outputs.certificateSecretVersions.type -ceq 'array') 'ARM must return public certificate metadata and secret-version metadata for local validation.'
            $encryption = ($template.resources | Where-Object name -eq 'epp-encryption-settings').properties.template
            Assert (@($encryption.resources | Where-Object type -eq 'Microsoft.Web/sites/config').Count -eq 0) 'Encryption settings reads and writes must not target the same resource in one template.'
            $encryptionSettingsDeployment = $encryption.resources | Where-Object { $_.type -eq 'Microsoft.Resources/deployments' -and $_.name -ceq 'epp-encryption-app-settings' }
            $encryptionSettings = $encryptionSettingsDeployment.properties.parameters.appSettings.value
            $encryptionSettingsRead = "list(format('{0}/config/appsettings', resourceId('Microsoft.Web/sites', parameters('functionAppName'))), '2024-04-01').properties"
            Assert ($encryptionSettings.StartsWith("[union($encryptionSettingsRead, ", [StringComparison]::Ordinal) -and
                -not $encryptionSettings.Contains('listApplicationSettings') -and
                $encryptionSettings.Contains("'EPP_DECRYPTION_KEY_PEM'") -and
                $encryptionSettings.Contains("'@Microsoft.KeyVault(SecretUri={0})'") -and
                $encryptionSettings.Contains("'EPP_ENCRYPTION_KEY_ID'")) 'Encryption settings must read the appsettings child through its list action, preserve existing values, and pin the approved secret version/key ID.'
            foreach ($deployment in @($settingsDeployment, $encryptionSettingsDeployment)) {
                $writer = $deployment.properties.template
                $writtenSettings = @($writer.resources | Where-Object type -eq 'Microsoft.Web/sites/config')
                Assert ($deployment.properties.expressionEvaluationOptions.scope -ceq 'inner' -and
                    $writer.parameters.appSettings.type -ceq 'secureObject') 'Settings snapshots must cross an inner-scope deployment boundary as secure objects.'
                Assert ($writer.resources.Count -eq 1 -and $writtenSettings.Count -eq 1 -and
                    $writtenSettings[0].name -ceq "[format('{0}/{1}', parameters('functionAppName'), 'appsettings')]" -and
                    $writtenSettings[0].properties -ceq "[parameters('appSettings')]") 'The shared settings writer must apply only the supplied snapshot without reading its own target.'
            }
            $certificateTemplate = ($template.resources | Where-Object name -eq 'epp-certificate').properties.template
            $operation = $certificateTemplate.resources | Where-Object type -eq 'Microsoft.Resources/deploymentScripts'
            Assert ($operation.kind -ceq 'AzurePowerShell' -and
                $operation.identity.type -ceq 'UserAssigned' -and
                $operation.properties.cleanupPreference -ceq 'Always' -and
                $operation.properties.timeout -ceq 'PT15M') 'Certificate operations must run in ARM with a managed identity, bounded timeout, and cleanup.'
            $sourceDeployment = $template.resources | Where-Object name -eq 'epp-certificate-access'
            $access = $sourceDeployment.properties.template
            $validation = $access.resources | Where-Object name -eq 'epp-certificate-policy-validation'
            $allowed = $validation.properties.template.parameters.accessPoliciesValid.allowedValues
            Assert ($allowed.Count -eq 1 -and $allowed[0] -eq $true -and
                $validation.properties.parameters.accessPoliciesValid.value -ceq "[variables('accessPoliciesValid')]") 'A native nested deployment must reject invalid legacy policies before vault access changes.'
            Assert (-not $sourceDeployment.properties.parameters.ContainsKey('accessPoliciesValid')) 'Main must not evaluate identity-dependent policy guards inside reference-bearing lambdas.'
            $policyGuard = $access.variables | ConvertTo-Json -Depth 20 -Compress
            Assert ($policyGuard.Contains('functionPrincipalId') -and $policyGuard.Contains('setupPrincipalId') -and
                $policyGuard.Contains('lessOrEquals(length(') -and -not $policyGuard.Contains('reference(') -and
                $policyGuard.Contains('tenantId') -and $policyGuard.Contains('applicationId')) 'Validate duplicate, tenant, and application restrictions locally using parameter IDs only.'
            $grants = @($access.resources | Where-Object type -eq 'Microsoft.Authorization/roleAssignments')
            Assert ($grants.Count -eq 2 -and
                @($grants | Where-Object { $_.condition.Contains('existingFunctionGrants') -or $_.condition.Contains('existingSetupGrants') }).Count -eq 2) 'Native external-vault grants must skip existing matching RBAC assignments.'
            Assert ($sourceDeployment.subscriptionId -ceq "[parameters('certificatePlan').vaultSubscriptionId]" -and
                $sourceDeployment.resourceGroup.Contains("parameters('certificatePlan').vaultResourceId")) 'Deploy external-vault grants in the approved source subscription and resource group.'
            $endpointGrants = @($inner.resources | Where-Object type -eq 'Microsoft.Authorization/roleAssignments')
            Assert (@($endpointGrants | Where-Object { $_.properties.principalType -ceq 'User' }).Count -eq 0 -and
                -not $inner.parameters.ContainsKey('deployerObjectId')) 'Setup must not grant the local operator vault or package-upload data roles.'
            Assert ($inner.variables.keyVaultReaderRoleId.Contains('21090545-7ca7-4776-b22c-e363652d74d2') -and
                -not $inner.variables.ContainsKey('keyVaultSecretsOfficerRoleId') -and
                $inner.variables.keyVaultCertificatesOfficerRoleId.Contains('a4417e6f-fecd-4de8-b567-7b0420556985')) 'The setup identity receives certificate officer and metadata reader, not secrets officer.'
            $policyResource = $access.resources | Where-Object type -eq 'Microsoft.KeyVault/vaults/accessPolicies'
            Assert (($policyResource.dependsOn -join ',').Contains('epp-certificate-policy-validation')) 'Legacy policy updates must depend on successful native policy validation.'
            $policy = $policyResource.properties.accessPolicies | ConvertTo-Json -Depth 20 -Compress
            Assert ($policy.Contains('functionPermissions') -and $policy.Contains('setupPermissions') -and
                $policy.Contains("'get'") -and $policy.Contains("'list'")) 'Native access-policy grants must preserve existing permissions while adding secret read and metadata access.'
        }
        if ($PublishTemplatePath) {
            $template = Get-Content -LiteralPath $PublishTemplatePath -Raw | ConvertFrom-Json -AsHashtable
            $extension = $template.resources | Where-Object type -eq 'Microsoft.Web/sites/extensions'
            Assert ($extension.name.Contains("'onedeploy'") -and $extension.name.Contains("'ZipDeploy'") -and
                $extension.properties.remoteBuild -eq $false -and
                $extension.properties.packageUri -ceq "[parameters('packageUri')]") 'Publish templates must select the native plan-specific extension and mount the exact release ZIP without building.'
        }
        if ($IngressTemplatePath) {
            $template = Get-Content -LiteralPath $IngressTemplatePath -Raw | ConvertFrom-Json -AsHashtable
            $site = $template.resources | Where-Object type -eq 'Microsoft.Web/sites'
            Assert ($site.identity -ceq "[parameters('site').identity]" -and
                $site.tags.Contains("parameters('site'), 'tags'") -and
                $site.properties.Contains("union(parameters('site').properties") -and
                $site.properties.Contains("'publicNetworkAccess', parameters('access')")) 'Native ingress updates must preserve site properties and identity while changing access only.'
        }
    } $directory $TemplatePath $PublishTemplatePath $IngressTemplatePath
    Write-Host 'Service plan selection, approval, availability, migration guards, CLI versions, and publication checks passed.'
}
finally {
    Remove-Module -ModuleInfo $module -Force
    Remove-Item -LiteralPath $directory -Recurse -Force
}
