#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$module = Import-Module (Join-Path $PSScriptRoot '..\support\Epp.Setup.psm1') -Force -PassThru
$directory = Join-Path ([IO.Path]::GetTempPath()) "epp-maintenance-tests-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $directory | Out-Null
try {
    & $module {
        param($Directory, $Assets)
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
        $script:Directory = $Directory
        $script:Subscription = '11111111-1111-1111-1111-111111111111'
        $script:Tenant = '22222222-2222-2222-2222-222222222222'
        $script:AppId = '33333333-3333-3333-3333-333333333333'
        $script:KeyId = '44444444-4444-4444-4444-444444444444'
        $script:Names = Get-EppResourceNames -SubscriptionId $script:Subscription -ApplicationId $script:AppId -ResourcePrefix test
        $script:Root = "/subscriptions/$script:Subscription/resourceGroups/$($script:Names.resourceGroup)/providers"
        $script:SiteId = "$script:Root/Microsoft.Web/sites/$($script:Names.functionApp)"
        $script:IdentityId = "$script:Root/Microsoft.ManagedIdentity/userAssignedIdentities/$($script:Names.outboundIdentity)"
        $script:Provider = Get-EppProvider -AssetDirectory $Assets -Provider infobip -EndpointRegion global -NonInteractive
        $rsa = [Security.Cryptography.RSA]::Create(2048)
        $request = [Security.Cryptography.X509Certificates.CertificateRequest]::new(
            'CN=Maintenance test', $rsa, [Security.Cryptography.HashAlgorithmName]::SHA256,
            [Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $certificate = $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddMonths(6))
        try {
            $script:Application = [pscustomobject]@{
                Id = '55555555-5555-5555-5555-555555555555'; AppId = $script:AppId
                Api = [pscustomobject]@{ RequestedAccessTokenVersion = 2 }
                KeyCredentials = @([pscustomobject]@{
                    Usage = 'Encrypt'; Type = 'AsymmetricX509Cert'; KeyId = $script:KeyId
                    Key = $certificate.RawData; StartDateTime = $certificate.NotBefore; EndDateTime = $certificate.NotAfter
                    DisplayName = 'maintenance test'; CustomKeyIdentifier = $certificate.GetCertHash()
                })
            }
            $script:Summary = @{
                tenantId = $script:Tenant; subscriptionId = $script:Subscription; applicationId = $script:AppId
                encryptionKeyId = $script:KeyId; certificateThumbprint = $certificate.Thumbprint
                certificateId = "https://$($script:Names.keyVault).vault.azure.net/certificates/encryption/$('d' * 32)"
                certificateSecretId = "https://$($script:Names.keyVault).vault.azure.net/secrets/encryption/$('d' * 32)"
                resources = $script:Names; resourcePrefix = 'test'; servicePlan = 'FC1'; language = 'javascript'
                endpointRegion = 'global'; provider = 'infobip'; providerAuthentication = 'oauth'
                providerTenantId = $script:Provider.TenantId; accessTokenScopeTenant = $script:Provider.AccessTokenScopeTenant
                allowedProviderTenantIds = @($script:Provider.TenantId)
                identifierUri = "api://$($script:Names.functionApp).azurewebsites.net/$script:AppId"
                endpointUrl = "https://$($script:Names.functionApp).azurewebsites.net/api/SendOtp"
                packageSha256 = 'b' * 64
            }
            $script:SummaryPath = Join-Path $Directory 'original.json'
            function script:Reset-State {
                $script:Summary.servicePlan = 'FC1'
                $script:Summary | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $script:SummaryPath
                $script:Settings = @{} + $script:Provider.Settings
                $script:Settings.EPP_ENCRYPTION_KEY_ID = $script:KeyId
                $script:Settings.EPP_DECRYPTION_KEY_PEM = "@Microsoft.KeyVault(SecretUri=$($script:Summary.certificateSecretId))"
                $script:Settings.EPP_TENANT_ID = $script:Tenant
                $script:Settings.EPP_OUTBOUND_CLIENT_ID = $script:AppId
                $script:Settings.EPP_OUTBOUND_MI_CLIENT_ID = '66666666-6666-6666-6666-666666666666'
                $script:Settings.EPP_EXPECTED_AUDIENCE = $script:AppId
                $script:Settings.EPP_EXPECTED_ISSUER = "https://login.microsoftonline.com/$script:Tenant/v2.0"
                $script:Settings.EPP_EXPECTED_CLIENT_ID = $script:MicrosoftPhoneProviderAppId
                $script:Settings.EPP_PROVIDER_VOICE_ENDPOINT = 'https://api.infobip.com/tts/3/advanced'
                $script:Settings.CUSTOM_SETTING = 'preserve-private-value'
                $script:Web = @{ minTlsVersion = '1.0'; scmMinTlsVersion = '1.0'; ftpsState = 'AllAllowed'; linuxFxVersion = 'NODE|22' }
                $script:Site = @{
                    id = $script:SiteId; location = 'westus2'; kind = 'functionapp,linux'
                    tags = @{ managedBy = 'EPP-Setup'; eppApplicationId = $script:AppId; eppLanguage = 'javascript'; eppServicePlan = 'FC1' }
                    identity = @{ type = 'SystemAssigned, UserAssigned'; userAssignedIdentities = @{ $script:IdentityId = @{} } }
                    properties = @{
                        serverFarmId = "$script:Root/Microsoft.Web/serverfarms/$($script:Names.hostingPlan)"
                        httpsOnly = $false; state = 'Running'; publicNetworkAccess = 'Enabled'
                        functionAppConfig = @{ runtime = @{ name = 'node'; version = '22' } }
                    }
                }
                $script:Writes = [Collections.Generic.List[string]]::new()
                $script:PublishCalls = 0; $script:Reads = 0; $script:ReferenceStatus = 'Resolved'
                $script:FailPublish = $false; $script:FailTrust = $false; $script:Drift = $false; $script:FailReadback = $false
                $script:MissingTrust = $false; $script:Registered = $true; $script:MountedAfterUpload = $false
                $script:FailMarker = $false
                $script:Answers = [Collections.Generic.Queue[string]]::new()
                $script:Calls = [Collections.Generic.List[string]]::new()
                $script:SignedIn = $true
                $script:Ambiguous = $false
                $script:VaultDenied = $false
                $script:GroupTags = @{ managedBy = 'EPP-Setup' }
                $script:Bundle = @{
                    id = $script:Summary.certificateId; sid = $script:Summary.certificateSecretId
                    cer = [Convert]::ToBase64String($certificate.RawData); attributes = @{ enabled = $true }
                    policy = @{ keyProperties = @{ keyType = 'RSA'; exportable = $true }; secretProperties = @{ contentType = 'application/x-pem-file' } }
                }
            }
            function script:Read-Host {
                param($Prompt)
                Assert ($script:Answers.Count -gt 0) "Unexpected prompt: $Prompt"
                return $script:Answers.Dequeue()
            }
            function script:Get-EppAzureSubscriptions {
                param([switch] $Refresh)
                if ($script:SignedIn) {
                    [pscustomobject]@{
                        Id = $script:Subscription; TenantId = $script:Tenant; Name = 'Test subscription'
                        TenantDisplayName = 'Test tenant'; UserName = 'test user'; IsDefault = $true
                    }
                }
            }
            function script:Get-EppSignInAudienceRestrictions {
                param($Inputs, $ApplicationObjectId)
                return @{
                    '@odata.type' = '#microsoft.graph.allowedTenantsAudience'
                    isHomeTenantAllowed = $true; allowedTenantIds = @($script:Provider.TenantId)
                }
            }
            function script:Assert-EppCliDirectoryContext { param($Inputs) }
            function script:Get-EppApplication { param($Inputs, $ClientId); return $script:Application }
            function script:Assert-EppAuthentication {
                param($SiteId, $Inputs, $Context, $IdentifierUri)
                if ($script:FailTrust) { throw 'authentication-rejected' }
            }
            function script:Assert-EppGraphAccess { param($Inputs, $Certificate, $KeyId, $IdentifierUri, $CertificatePlan) }
            function script:Invoke-EppDirectoryCommand {
                param($Inputs, $Arguments)
                Assert (($Arguments[0..3] -join ' ') -ceq 'ad app federated-credential list') 'Maintenance must only list federated credentials.'
                if ($script:MissingTrust) { return @() }
                return @(@{ issuer = "https://login.microsoftonline.com/$script:Tenant/v2.0"; subject = '77777777-7777-7777-7777-777777777777'; audiences = @('api://AzureADTokenExchange') })
            }
            function script:Get-EppLanguage {
                param($AssetDirectory, $Language, $SourceRepository, $PackageReleaseTag, [switch] $NonInteractive)
                return [pscustomobject]@{ ReleaseTag = 'epp-packages-1-1-javascript'; Url = 'https://github.com/unit/repo/releases/download/epp-packages-1-1-javascript/released-package.zip' }
            }
            function script:Get-EppPackage {
                param($Selection, $Directory)
                return [pscustomobject]@{ Sha256 = 'a' * 64; SourceSha256 = 'a' * 64; RequiresRemoteBuild = $false; Path = 'unused.zip' }
            }
            function script:Publish-EppFunction {
                param($Inputs, $Names, $Context, $Outputs, $SiteId, $Package, $Directory, [switch] $MountAfterUpload)
                $script:PublishCalls++
                Assert ($script:Settings.EPP_PACKAGE_SHA256 -ceq '') 'Invalidate success markers before publishing.'
                if ($script:FailPublish) { throw 'publication-rejected' }
                if ($Inputs.ServicePlan -eq 'EP1') {
                    Assert $MountAfterUpload 'Premium updates must mount the new package after uploading.'
                    $script:MountedAfterUpload = $true
                    $script:Settings.WEBSITE_RUN_FROM_PACKAGE = "$($Outputs.packageContainerUrl.value)$($Package.Sha256).zip"
                }
                if ($script:FailReadback) { $script:Settings.EPP_PROVIDER_VOICE_ENDPOINT = 'https://api.infobip.com/incorrect' }
                return $Package.Sha256
            }
            function script:Invoke-EppAz {
                param([Parameter(ValueFromRemainingArguments)][string[]] $Arguments)
                $command = $Arguments -join ' '
                $script:Calls.Add($command)
                $result = switch -Regex ($command) {
                    '^login ' { $script:SignedIn = $true; return '' }
                    '^account set ' { return '' }
                    '^account show ' {
                        @{ id = $script:Subscription; tenantId = $script:Tenant; state = 'Enabled'; environmentName = 'AzureCloud'; user = @{ type = 'user' } }; break
                    }
                    '^functionapp (list|show) ' {
                        $candidate = @{
                            id = $script:SiteId; name = $script:Names.functionApp; resourceGroup = $script:Names.resourceGroup
                            location = 'westus2'; tags = $script:Site.tags
                        }
                        if ($Arguments[1] -eq 'list') {
                            $sites = @($candidate, @{
                                id = '/unrelated'; name = 'not-epp'; resourceGroup = 'not-epp'; location = 'westus2'; tags = @{}
                            })
                            if ($script:Ambiguous) {
                                $sites += @{
                                    id = "/subscriptions/$script:Subscription/resourceGroups/other/providers/Microsoft.Web/sites/$($script:Names.functionApp)"
                                    name = $script:Names.functionApp; resourceGroup = 'other'; location = 'westus2'; tags = $script:Site.tags
                                }
                            }
                            ,$sites
                        } else { $candidate }
                        break
                    }
                    '^group (list|show) ' {
                        $group = @{ name = $script:Names.resourceGroup; tags = $script:GroupTags }
                        if ($Arguments[1] -eq 'list') { ,@($group) } else { $group }
                        break
                    }
                    '^keyvault show ' {
                        @{
                            id = "/subscriptions/$script:Subscription/resourceGroups/$($script:Names.resourceGroup)/providers/Microsoft.KeyVault/vaults/$($script:Names.keyVault)"
                            properties = @{ tenantId = $script:Tenant; vaultUri = "https://$($script:Names.keyVault).vault.azure.net/" }
                        }; break
                    }
                    '^keyvault certificate list-versions ' {
                        if ($script:VaultDenied) { throw 'Forbidden: certificate metadata access denied' }
                        ,@(@{ id = $script:Bundle.id }); break
                    }
                    '^keyvault certificate show ' { $script:Bundle; break }
                    '^keyvault secret list-versions ' {
                        ,@(@{ id = $script:Summary.certificateSecretId; managed = $true; contentType = 'application/x-pem-file'; attributes = @{ enabled = $true } }); break
                    }
                    '^appservice plan show ' {
                        @{ id = $script:Site.properties.serverFarmId; sku = @{ name = $script:Summary.servicePlan }; location = 'westus2' }; break
                    }
                    '^identity show ' {
                        @{ id = $script:IdentityId; principalId = '77777777-7777-7777-7777-777777777777'; clientId = $script:Settings.EPP_OUTBOUND_MI_CLIENT_ID }; break
                    }
                    '^functionapp function list ' {
                        if ($script:Registered) { @(@{ name = 'site/SendOtp' }) } else { @() }
                        break
                    }
                    '^functionapp config appsettings set ' {
                        $script:Writes.Add('settings')
                        $index = [Array]::IndexOf($Arguments, '--settings')
                        $updates = Read-EppJson $Arguments[$index + 1].Substring(1)
                        foreach ($name in $updates.Keys) { $script:Settings[$name] = $updates[$name] }
                        if ($script:FailMarker -and $updates['EPP_PACKAGE_SHA256'] -ceq ('a' * 64)) {
                            $script:ReferenceStatus = 'AccessToKeyVaultDenied'
                        }
                        return ''
                    }
                    '^rest --method (get|post|patch) ' {
                        $method = $Arguments[2]
                        $index = [Array]::IndexOf($Arguments, '--url')
                        $url = $Arguments[$index + 1]
                        if ($method -eq 'patch') {
                            $index = [Array]::IndexOf($Arguments, '--body')
                            $updates = (Read-EppJson $Arguments[$index + 1].Substring(1)).properties
                            $target = if ($url -match '/config/web\?') { $script:Web } else { $script:Site.properties }
                            foreach ($name in $updates.Keys) { $target[$name] = $updates[$name] }
                            $script:Writes.Add('infrastructure')
                            return ''
                        }
                        if ($url -match '/config/appsettings/list\?') {
                            Assert ($method -eq 'post') 'Appsettings list is a read-only POST.'
                            @{ properties = $script:Settings }; break
                        }
                        Assert ($method -eq 'get') 'Verification must not refresh references or make other POST calls.'
                        if ($url -match '/config/configreferences/') {
                            @{ properties = @{
                                status = $script:ReferenceStatus; reference = $script:Settings.EPP_DECRYPTION_KEY_PEM
                                vaultName = $script:Names.keyVault; secretName = 'encryption'; secretVersion = 'd' * 32; activeVersion = 'd' * 32
                            } }; break
                        }
                        if ($url -match '/config/web\?') { @{ properties = $script:Web }; break }
                        if ($url -ceq "https://management.azure.com$script:SiteId`?api-version=2024-04-01") {
                            $script:Reads++
                            if ($script:Drift -and $script:Reads -eq 2) { $script:Settings.CUSTOM_SETTING = 'concurrently-changed' }
                            $script:Site; break
                        }
                        throw "Unexpected metadata request: $url"
                    }
                    default { throw "Unexpected Azure command: $command" }
                }
                return ConvertTo-Json -InputObject $result -Depth 30 -Compress
            }
            $arguments = @{
                DeploymentSummaryPath = $script:SummaryPath; OutputDirectory = (Join-Path $Directory 'output')
                AssetDirectory = $Assets; SourceRepository = 'unit/repo'
                SourceBaseUri = "https://raw.githubusercontent.com/unit/repo/$('c' * 40)/setup"
                PassThru = $true
            }
            Reset-State
            $original = Get-Content -LiteralPath $script:SummaryPath -Raw
            $result = Invoke-EppMaintenance @arguments -Operation Verify
            Assert (-not $result.applied -and $script:Writes.Count -eq 0 -and $script:PublishCalls -eq 0) 'Verification must not write to Azure or publish code.'
            Assert ($result.changes.Count -eq 6) 'Preview must report two configuration, three infrastructure, and one code delta.'
            Assert ((Get-Content -LiteralPath $script:SummaryPath -Raw) -ceq $original) 'Do not modify the input summary.'
            Assert (($result | ConvertTo-Json -Depth 10) -notmatch 'preserve-private-value') 'Reports must not include existing setting values.'
            Assert-Throws { Invoke-EppMaintenance @arguments -Operation Verify -Apply } 'Verification cannot apply'
            $null = Invoke-EppMaintenance @arguments -Operation Update
            Assert ($script:Writes.Count -eq 0) 'Update without Apply is also read-only.'
            $keyReference = $script:Settings.EPP_DECRYPTION_KEY_PEM
            $result = Invoke-EppMaintenance @arguments -Operation Update -Apply
            Assert ($result.applied -and $script:PublishCalls -eq 1) 'Apply the reviewed package once.'
            Assert ($script:Settings.INFOBIP_VOICE_SENDER_ID -ceq 'Microsoft') 'Supply a newly introduced default sender.'
            Assert ($script:Settings.CUSTOM_SETTING -ceq 'preserve-private-value' -and
                $script:Settings.EPP_DECRYPTION_KEY_PEM -ceq $keyReference -and $script:Settings.EPP_ENCRYPTION_KEY_ID -ceq $script:KeyId) 'Preserve customer settings and encryption identity.'
            $null = Invoke-EppMaintenance @arguments -Operation Update -Apply
            Assert ($script:PublishCalls -eq 1) 'Do not republish a package with a matching success marker.'
            $saved = @(Get-ChildItem -LiteralPath $arguments.OutputDirectory -Filter 'deployment-*.json')
            Assert ($saved.Count -eq 1) 'Save a new deployment summary only after successful changes.'
            $updated = Read-EppJson $saved[0].FullName
            Assert ($updated.certificateId -ceq $script:Summary.certificateId -and $updated.packageSha256 -ceq ('a' * 64)) 'Persist package metadata without changing certificate metadata.'

            foreach ($scope in @('Configuration', 'Infrastructure', 'Code')) {
                Reset-State
                $result = Invoke-EppMaintenance @arguments -Operation Update -Apply -UpdateScope $scope
                Assert (@($result.changes | Where-Object { $_.scope -ne $scope }).Count -eq 0) 'Limit changes to the chosen scope.'
                Assert (($script:PublishCalls -eq 1) -eq ($scope -eq 'Code')) 'Publish only in the code scope.'
            }
            Reset-State
            $script:Settings.INFOBIP_VOICE_SENDER_ID = 'Approved sender'
            $script:Web.minTlsVersion = '1.3'
            $result = Invoke-EppMaintenance @arguments -Operation Update -Apply -UpdateScope Configuration
            Assert ($script:Settings.INFOBIP_VOICE_SENDER_ID -ceq 'Approved sender' -and $script:Web.minTlsVersion -ceq '1.3') 'Preserve a configured sender and stronger TLS.'
            $null = Invoke-EppMaintenance @arguments -Operation Update -Apply -UpdateScope Infrastructure
            Assert ($script:Web.minTlsVersion -ceq '1.3') 'Infrastructure updates must not downgrade TLS 1.3.'
            $null = Invoke-EppMaintenance @arguments -Operation Update -Apply -UpdateScope Configuration -ProviderEnvironment @{ INFOBIP_VOICE_SENDER_ID = 'New approved sender' }
            Assert ($script:Settings.INFOBIP_VOICE_SENDER_ID -ceq 'New approved sender') 'Apply explicit provider input.'
            Assert-Throws {
                Invoke-EppMaintenance @arguments -Operation Update -ProviderEnvironment @{ EPP_ENCRYPTION_KEY_ID = 'unsafe' }
            } 'Unknown or fixed'
            Reset-State
            $script:Summary.servicePlan = 'EP1'
            $script:Summary | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $script:SummaryPath
            $script:Settings.FUNCTIONS_WORKER_RUNTIME = 'node'
            $null = Invoke-EppMaintenance @arguments -Operation Update -Apply
            Assert ($script:MountedAfterUpload -and $script:Web.ftpsState -ceq 'Disabled') 'Mount ready Premium packages and disable FTP.'

            foreach ($failure in @('certificate', 'reference', 'trust', 'federation', 'runtime', 'registration', 'tls', 'drift', 'publish', 'readback', 'marker')) {
                Reset-State
                $savedCount = @(Get-ChildItem -LiteralPath $arguments.OutputDirectory -Filter 'deployment-*.json').Count
                $pattern = switch ($failure) {
                    certificate { $script:Settings.EPP_ENCRYPTION_KEY_ID = [Guid]::NewGuid().ToString(); 'certificate or application identity'; break }
                    reference { $script:ReferenceStatus = 'AccessToKeyVaultDenied'; 'not resolved'; break }
                    trust { $script:FailTrust = $true; 'authentication-rejected'; break }
                    federation { $script:MissingTrust = $true; 'federated trust'; break }
                    runtime { $script:Site.properties.functionAppConfig.runtime.version = '20'; 'runtime requires migration'; break }
                    registration { $script:Registered = $false; 'registered exactly one'; break }
                    tls { $script:Web.minTlsVersion = '1.4'; 'Unsupported TLS value'; break }
                    drift { $script:Drift = $true; 'changed during preflight'; break }
                    publish { $script:FailPublish = $true; 'publication-rejected'; break }
                    readback { $script:FailReadback = $true; 'readback does not match'; break }
                    marker { $script:FailMarker = $true; 'not resolved'; break }
                }
                Assert-Throws { Invoke-EppMaintenance @arguments -Operation Update -Apply } $pattern
                Assert (@(Get-ChildItem -LiteralPath $arguments.OutputDirectory -Filter 'deployment-*.json').Count -eq $savedCount) 'Failed updates must not save a successful deployment summary.'
                if ($failure -notin @('publish', 'readback', 'marker')) { Assert ($script:Writes.Count -eq 0) 'Reject unsafe state before any writes.' }
                else { Assert ($script:Settings.EPP_PACKAGE_SHA256 -ceq '') 'A failed update must not leave a success marker.' }
            }
            Reset-State
            $script:Summary.resources.functionApp = 'different-app'
            $script:Summary | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $script:SummaryPath
            Assert-Throws { Invoke-EppMaintenance @arguments -Operation Verify } 'resource names do not match'
            $script:Summary.resources.functionApp = $script:SiteId.Split('/')[-1]

            $discovery = @{} + $arguments
            $discovery.Remove('DeploymentSummaryPath')
            $discovery.OutputDirectory = Join-Path $Directory 'discovery-output'
            Reset-State
            $script:SignedIn = $false
            foreach ($answer in @('signin', $script:Tenant, $script:Subscription, '1')) { $script:Answers.Enqueue($answer) }
            $result = Invoke-EppMaintenance @discovery -Operation Verify
            Assert ($result.discovered -and $script:Writes.Count -eq 0 -and $script:PublishCalls -eq 0) 'Discover and verify without resource writes.'
            Assert (($script:Calls -join "`n") -match 'login --use-device-code' -and
                ($script:Calls -join "`n") -match 'account set --subscription') 'Guide sign-in and select the CLI context for Graph.'
            Assert ($script:Answers.Count -eq 0) 'Select tenant, subscription, and the tagged Function without unrelated candidates.'
            $recovered = Read-EppMaintenanceSummary $result.deploymentSummaryPath
            Assert ($recovered.certificateId -ceq $script:Summary.certificateId -and
                $recovered.recoveredFromAzure -and $recovered.applicationId -ceq $script:AppId) 'Recover a validated maintenance summary from metadata.'
            $null = Invoke-EppMaintenance @discovery -Operation Update -DeploymentSummaryPath $result.deploymentSummaryPath
            Assert ($script:Writes.Count -eq 0) 'Allow update preview against the recovered summary.'

            Reset-State
            foreach ($answer in @($script:Tenant, $script:Subscription, 'manual', $script:Names.resourceGroup, $script:Names.functionApp)) {
                $script:Answers.Enqueue($answer)
            }
            $null = Invoke-EppMaintenance @discovery -Operation Verify
            Assert ($script:Answers.Count -eq 0 -and ($script:Calls -join "`n") -match 'functionapp show') 'Allow manual Function and resource-group entry.'

            Reset-State
            $script:Site.tags.Remove('managedBy')
            foreach ($answer in @($script:Tenant, $script:Subscription, '1')) { $script:Answers.Enqueue($answer) }
            $null = Invoke-EppMaintenance @discovery -Operation Verify
            Assert ($script:Answers.Count -eq 0) 'Discover Functions through their resource-group EPP tag.'

            Reset-State
            $script:Answers.Enqueue('1')
            $null = Invoke-EppMaintenance @discovery -Operation Verify -TenantId $script:Tenant -SubscriptionId $script:Subscription `
                -ResourceGroupName $script:Names.resourceGroup
            Assert (($script:Calls -join "`n") -notmatch 'group list' -and
                ($script:Calls -join "`n") -match 'functionapp list .*--resource-group') 'Keep resource-group discovery scoped to that group.'

            Reset-State
            $script:Ambiguous = $true
            Assert-Throws {
                Invoke-EppMaintenance @discovery -Operation Verify -TenantId $script:Tenant -SubscriptionId $script:Subscription `
                    -FunctionAppName $script:Names.functionApp -NonInteractive
            } 'ambiguous'
            Assert-Throws {
                Invoke-EppMaintenance @discovery -Operation Verify -TenantId $script:Tenant -SubscriptionId $script:Subscription `
                    -ResourceGroupName $script:Names.resourceGroup -FunctionAppName 'different-function' -NonInteractive
            } 'different Function'

            Reset-State
            $originalCertificateId = $script:Summary.certificateId
            $script:Bundle.id = $originalCertificateId -replace ('d' * 32), ('e' * 32)
            $result = Invoke-EppMaintenance @discovery -Operation Verify -TenantId $script:Tenant -SubscriptionId $script:Subscription `
                -ResourceGroupName $script:Names.resourceGroup -FunctionAppName $script:Names.functionApp -NonInteractive
            $recovered = Read-EppMaintenanceSummary $result.deploymentSummaryPath
            Assert ($recovered.certificateId -ceq $script:Bundle.id -and
                $recovered.certificateSecretId -ceq $script:Summary.certificateSecretId) 'Resolve actual certificate-to-secret binding, not assumed equal versions.'

            Reset-State
            $script:Site.tags.Remove('managedBy')
            $null = Invoke-EppMaintenance @discovery -Operation Verify -TenantId $script:Tenant -SubscriptionId $script:Subscription `
                -ResourceGroupName $script:Names.resourceGroup -FunctionAppName $script:Names.functionApp -NonInteractive
            Assert ($script:Writes.Count -eq 0) 'Accept resource-group tagging without requiring a Function managedBy tag.'
            Assert-Throws {
                Invoke-EppMaintenance @discovery -Operation Verify -TenantId $script:Tenant -SubscriptionId $script:Subscription -NonInteractive
            } 'FunctionAppName is required'
            Assert-Throws { Invoke-EppMaintenance @discovery -Operation Update } 'Update requires'
            Assert-Throws { Invoke-EppMaintenance @arguments -Operation Verify -FunctionAppName 'conflict' } 'not both'

            foreach ($failure in @('untagged', 'secret', 'certificate', 'trust', 'access', 'cancel')) {
                Reset-State
                $savedCount = @(Get-ChildItem -LiteralPath $discovery.OutputDirectory -Filter 'deployment-*.json').Count
                $target = @{ TenantId = $script:Tenant; SubscriptionId = $script:Subscription
                    ResourceGroupName = $script:Names.resourceGroup; FunctionAppName = $script:Names.functionApp; NonInteractive = $true }
                $pattern = switch ($failure) {
                    untagged { $script:Site.tags.Remove('managedBy'); $script:GroupTags.Clear(); 'Neither the Function'; break }
                    secret { $script:Bundle.sid = $script:Summary.certificateSecretId -replace ('d' * 32), ('e' * 32); 'Cannot uniquely bind'; break }
                    certificate {
                        $otherRequest = [Security.Cryptography.X509Certificates.CertificateRequest]::new(
                            'CN=Different certificate', $rsa, [Security.Cryptography.HashAlgorithmName]::SHA256,
                            [Security.Cryptography.RSASignaturePadding]::Pkcs1)
                        $other = $otherRequest.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddMonths(6))
                        try { $script:Bundle.cer = [Convert]::ToBase64String($other.RawData) }
                        finally { $other.Dispose() }
                        'registered public certificate does not match'; break
                    }
                    trust { $script:FailTrust = $true; 'authentication-rejected'; break }
                    access { $script:VaultDenied = $true; 'metadata access denied'; break }
                    cancel { $target = @{}; $script:Answers.Enqueue('0'); 'cancelled'; break }
                }
                Assert-Throws { Invoke-EppMaintenance @discovery -Operation Verify @target } $pattern
                Assert ($script:Writes.Count -eq 0 -and
                    @(Get-ChildItem -LiteralPath $discovery.OutputDirectory -Filter 'deployment-*.json').Count -eq $savedCount) 'Failed discovery must not write resources or save a successful summary.'
            }
        }
        finally {
            $certificate.Dispose()
            $rsa.Dispose()
        }
    } $directory (Join-Path $PSScriptRoot '..')
    Write-Host 'Interactive discovery, recovered summaries, certificate binding, read-only verification, delta updates, and failure guards passed.'
}
finally {
    Remove-Module -ModuleInfo $module -Force
    Remove-Item -LiteralPath $directory -Recurse -Force
}
