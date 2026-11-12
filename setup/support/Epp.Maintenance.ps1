function Read-EppMaintenanceSummary {
    param([string] $Path)

    $summary = Read-EppJson $Path
    return Assert-EppMaintenanceSummary -Summary $summary
}

function Assert-EppMaintenanceSummary {
    param([Collections.IDictionary] $Summary)

    foreach ($name in @('tenantId', 'subscriptionId', 'applicationId', 'encryptionKeyId')) {
        $summary[$name] = ConvertTo-EppGuid ([string]$summary[$name])
    }
    if (($summary.Contains('maintenanceSchemaVersion') -and $summary['maintenanceSchemaVersion'] -ne 1) -or
        $summary['servicePlan'] -cnotin @('FC1', 'EP1') -or
        $summary['language'] -cnotin @('javascript', 'csharp', 'dotnet', 'python') -or
        $summary['endpointRegion'] -cnotin @('eu', 'global') -or
        $summary['providerAuthentication'] -cne 'oauth') {
        throw 'Unsupported deployment summary or migration. Maintenance supports existing OAuth FC1/EP1 endpoints only.'
    }
    $names = Get-EppResourceNames -SubscriptionId $summary.subscriptionId -ApplicationId $summary.applicationId `
        -ResourcePrefix $summary.resourcePrefix
    if ($summary['resources'] -isnot [Collections.IDictionary]) { throw 'The summary has no resource names.' }
    foreach ($name in $names.Keys) {
        if ($summary.resources[$name] -cne $names[$name]) { throw 'Summary resource names do not match the deployment identity. Migration requires a separate plan.' }
    }
    $certificate = ConvertTo-EppKeyVaultObjectId $summary['certificateId'] certificates
    $secret = ConvertTo-EppKeyVaultObjectId $summary['certificateSecretId'] secrets
    if ($certificate.VaultName -ine $secret.VaultName -or $certificate.Name -ine $secret.Name) {
        throw 'Certificate and secret metadata refer to different vaults or names.'
    }
    if ($summary['certificateThumbprint'] -cnotmatch '^[0-9a-fA-F]{40}$') { throw 'The summary has no valid certificate thumbprint.' }
    $expectedIdentifier = "api://$($names.functionApp).azurewebsites.net/$($summary.applicationId)"
    if ($summary['identifierUri'] -cne $expectedIdentifier -or
        $summary['endpointUrl'] -cne "https://$($names.functionApp).azurewebsites.net/api/SendOtp") {
        throw 'Summary endpoint identity is unsupported. Review migration separately.'
    }
    return $summary
}

function Select-EppMaintenanceEndpoint {
    param(
        [string] $TenantId, [string] $SubscriptionId, [string] $ResourceGroupName,
        [string] $FunctionAppName, [switch] $NonInteractive
    )

    $requestedGroup = $ResourceGroupName
    $requestedFunction = $FunctionAppName
    $context = Select-EppAzureContext -TenantId $TenantId -SubscriptionId $SubscriptionId -NonInteractive:$NonInteractive
    if (-not $context) { throw 'Verification cancelled. No Azure resources were changed.' }
    $null = Connect-EppAzureAccount -Inputs $context -NonInteractive:$NonInteractive
    Write-Host "Using tenant $($context.TenantId), subscription $($context.SubscriptionId)." -ForegroundColor Cyan
    Invoke-EppAz account set --subscription $context.SubscriptionId --output none | Out-Null
    if ($NonInteractive -and -not $FunctionAppName) {
        throw '-FunctionAppName is required for discovery in noninteractive mode.'
    }

    if ($FunctionAppName -and $ResourceGroupName) {
        $site = Invoke-EppAz functionapp show --subscription $context.SubscriptionId --resource-group $ResourceGroupName `
            --name $FunctionAppName --output json | ConvertFrom-Json -AsHashtable
    }
    else {
        $arguments = @('functionapp', 'list', '--subscription', $context.SubscriptionId, '--output', 'json')
        if ($ResourceGroupName) { $arguments += @('--resource-group', $ResourceGroupName) }
        $sites = Invoke-EppAz @arguments | ConvertFrom-Json -AsHashtable -NoEnumerate
        $groups = if ($ResourceGroupName) {
            ,@(Invoke-EppAz group show --subscription $context.SubscriptionId --name $ResourceGroupName --output json |
                ConvertFrom-Json -AsHashtable)
        }
        else {
            Invoke-EppAz group list --subscription $context.SubscriptionId --output json |
                ConvertFrom-Json -AsHashtable -NoEnumerate
        }
        if ($sites -isnot [array] -or $groups -isnot [array]) { throw 'Azure returned an invalid discovery inventory.' }
        $taggedGroups = @($groups | Where-Object { $_['tags'] -and $_['tags']['managedBy'] -ceq 'EPP-Setup' } |
            ForEach-Object { $_['name'] })
        $candidates = @($sites | Where-Object {
            if ($ResourceGroupName -and $_['resourceGroup'] -ine $ResourceGroupName) { $false }
            elseif ($FunctionAppName) { $_['name'] -ieq $FunctionAppName }
            else {
                ($ResourceGroupName -or ($_['tags'] -and $_['tags']['managedBy'] -ceq 'EPP-Setup') -or
                    $_['resourceGroup'] -in $taggedGroups)
            }
        } | Sort-Object { $_['name'] }, { $_['resourceGroup'] })
        if ($FunctionAppName -and -not $candidates.Count) { throw 'The requested Function was not found in the selected subscription/resource group.' }
        if ($FunctionAppName -and $candidates.Count -gt 1 -and $NonInteractive) {
            throw 'The Function name is ambiguous. Supply -ResourceGroupName to select one endpoint.'
        }
        if ($FunctionAppName -and $candidates.Count -eq 1) { $site = $candidates[0] }
        else {
            if (-not $candidates.Count) { Write-Warning 'No tagged EPP Functions were found. Enter a known Function and resource group, or cancel.' }
            $options = @($candidates | ForEach-Object {
                @{ id = $_['id']; displayName = "$($_['name']) | $($_['resourceGroup']) | $($_['location'])" }
            })
            $selection = Select-EppOption -Entries ($options + @(@{ id = 'manual'; displayName = 'Enter a Function name and resource group' })) `
                -Name FunctionAppName -PromptName 'existing EPP endpoint' -NonInteractive:$NonInteractive -AllowCancel
            if (-not $selection) { throw 'Verification cancelled. No Azure resources were changed.' }
            if ($selection.id -eq 'manual') {
                $group = Read-EppInput -Name ResourceGroupName -Value $ResourceGroupName
                $name = Read-EppInput -Name FunctionAppName
                $requestedGroup = $group
                $requestedFunction = $name
                $site = Invoke-EppAz functionapp show --subscription $context.SubscriptionId --resource-group $group `
                    --name $name --output json | ConvertFrom-Json -AsHashtable
            }
            else { $site = $candidates | Where-Object { $_['id'] -ieq $selection.id } | Select-Object -First 1 }
        }
    }
    $idPattern = '^/subscriptions/' + [regex]::Escape($context.SubscriptionId) +
        '/resourceGroups/(?<group>[^/]+)/providers/Microsoft.Web/sites/(?<name>[^/]+)$'
    if ($site -isnot [Collections.IDictionary] -or $site['id'] -notmatch $idPattern) {
        throw 'Azure returned a Function outside the selected subscription or an invalid resource ID.'
    }
    if (($requestedGroup -and $Matches.group -ine $requestedGroup) -or
        ($requestedFunction -and $Matches.name -ine $requestedFunction)) {
        throw 'Azure returned a different Function than requested.'
    }
    Write-Host "Selected Function: $($Matches.name), resource group $($Matches.group)." -ForegroundColor Cyan
    return @{ Context = $context; SiteId = $site['id'] }
}

function Get-EppDiscoveredSummary {
    param($Endpoint, [string] $AssetDirectory, [string] $KeyVaultSubscriptionId, [switch] $NonInteractive)

    $inputs = $Endpoint.Context
    $site = Get-EppMaintenanceResource -Inputs $inputs -ResourceId $Endpoint.SiteId
    if ($site['id'] -ine $Endpoint.SiteId -or $site['kind'] -notmatch 'functionapp' -or
        $site['tags'] -isnot [Collections.IDictionary]) { throw 'The selected resource is not a tagged EPP Function.' }
    $idPattern = '^/subscriptions/' + [regex]::Escape($inputs.SubscriptionId) +
        '/resourceGroups/(?<group>[^/]+)/providers/Microsoft.Web/sites/(?<prefix>[a-z][a-z0-9]{1,7})-epp-func-[0-9a-f]{8}$'
    if ($site['id'] -notmatch $idPattern) { throw 'The selected Function does not use supported EPP resource names.' }
    $groupName = $Matches.group
    $prefix = $Matches.prefix
    $group = Invoke-EppAz group show --subscription $inputs.SubscriptionId --name $groupName --output json |
        ConvertFrom-Json -AsHashtable
    if ($group -isnot [Collections.IDictionary] -or $group['name'] -ine $groupName) {
        throw 'Azure returned a different resource group than requested.'
    }
    if ($site['tags']['managedBy'] -cne 'EPP-Setup' -and
        ($group['tags'] -isnot [Collections.IDictionary] -or $group['tags']['managedBy'] -cne 'EPP-Setup')) {
        throw 'Neither the Function nor its resource group has the managedBy=EPP-Setup tag.'
    }
    $applicationId = ConvertTo-EppGuid $site.tags['eppApplicationId']
    $functionName = $site['id'].Split('/')[-1]
    $settings = (Get-EppMaintenanceResource -Inputs $inputs -ResourceId "$($Endpoint.SiteId)/config/appsettings/list" -ListSettings).properties
    $provider = Get-EppProvider -AssetDirectory $AssetDirectory -Provider $settings['EPP_PROVIDER_NAME'] `
        -EndpointRegion $settings['EPP_PROVIDER_ENDPOINT_REGION'] -NonInteractive
    $summary = @{
        maintenanceSchemaVersion = 1; recoveredFromAzure = $true
        tenantId = $inputs.TenantId; subscriptionId = $inputs.SubscriptionId; applicationId = $applicationId
        resourcePrefix = $prefix
        resources = Get-EppResourceNames -SubscriptionId $inputs.SubscriptionId -ApplicationId $applicationId -ResourcePrefix $prefix
        language = $site.tags['eppLanguage']; servicePlan = $site.tags['eppServicePlan']; location = $site['location']
        provider = $provider.Id; endpointRegion = $provider.EndpointRegion
        providerAuthentication = $settings['EPP_PROVIDER_AUTH_MODE']; providerTenantId = $provider.TenantId
        accessTokenScopeTenant = $provider.AccessTokenScopeTenant
        identifierUri = "api://$functionName.azurewebsites.net/$applicationId"
        endpointUrl = "https://$functionName.azurewebsites.net/api/SendOtp"
        encryptionKeyId = ConvertTo-EppGuid $settings['EPP_ENCRYPTION_KEY_ID']
    }
    if ($summary.resources.resourceGroup -ine $groupName -or
        $summary.resources.functionApp -ine $site['id'].Split('/')[-1] -or
        $summary.servicePlan -cnotin @('FC1', 'EP1') -or $summary.providerAuthentication -cne 'oauth') {
        throw 'The selected endpoint has unsupported names, hosting tags, or authentication mode.'
    }
    if ($settings['EPP_DECRYPTION_KEY_PEM'] -notmatch '^@Microsoft\.KeyVault\(SecretUri=(?<secret>https://[^)]+)\)$') {
        throw 'The Function must use a versioned Key Vault SecretUri for its encryption certificate.'
    }
    $summary.certificateSecretId = $Matches.secret
    $secret = ConvertTo-EppKeyVaultObjectId $summary.certificateSecretId secrets
    $vaultSubscription = if ($KeyVaultSubscriptionId) { ConvertTo-EppGuid $KeyVaultSubscriptionId }
        elseif ($secret.VaultName -ine $summary.resources.keyVault) {
            Read-EppInput -Name KeyVaultSubscriptionId -Kind Guid -DefaultValue $inputs.SubscriptionId -NonInteractive:$NonInteractive
        }
        else { $inputs.SubscriptionId }
    $null = Get-EppCertificateVault -Inputs $inputs -VaultName $secret.VaultName -SubscriptionId $vaultSubscription
    $versions = Invoke-EppAz keyvault certificate list-versions --vault-name $secret.VaultName --name $secret.Name `
        --subscription $vaultSubscription --output json | ConvertFrom-Json -AsHashtable -NoEnumerate
    if ($versions -isnot [array]) { throw 'Key Vault returned an invalid certificate-version list.' }
    $matching = @()
    foreach ($version in $versions) {
        $id = ConvertTo-EppKeyVaultObjectId $version['id'] certificates
        if ($id.VaultName -ine $secret.VaultName -or $id.Name -ine $secret.Name) { throw 'Key Vault returned an unrelated certificate version.' }
        $bundle = Invoke-EppAz keyvault certificate show --id $version['id'] --subscription $vaultSubscription --output json |
            ConvertFrom-Json -AsHashtable
        if ($bundle['id'] -ine $version['id']) { throw 'Key Vault returned a different certificate version.' }
        if ($bundle['sid'] -ieq $summary.certificateSecretId) { $matching += $bundle }
    }
    if ($matching.Count -ne 1) { throw 'Cannot uniquely bind the configured secret version to an existing Key Vault certificate.' }
    $issued = ConvertFrom-EppCertificateBundle -Bundle $matching[0]
    try {
        Assert-EppCertificateSecret -SecretId $issued.SecretId -SubscriptionId $vaultSubscription
        $summary.certificateId = $issued.CertificateId
        $summary.certificateThumbprint = $issued.Certificate.Thumbprint
        $summary.certificateExpiresUtc = $issued.Certificate.NotAfter.ToUniversalTime().ToString('o')
    }
    finally { $issued.Certificate.Dispose() }
    $summary.certificateVaultSubscriptionId = $vaultSubscription
    $application = Get-EppApplication -Inputs $inputs -ClientId $applicationId
    $restriction = Get-EppProviderRestrictionState (Get-EppSignInAudienceRestrictions -Inputs $inputs -ApplicationObjectId $application.Id)
    if (-not $restriction -or -not $restriction.isHomeTenantAllowed -or $restriction.allowedTenantIds -notcontains $provider.TenantId) {
        throw 'The discovered application does not restrict sign-in to the home tenant and an allowlist containing the provider.'
    }
    $summary.allowedProviderTenantIds = @($restriction.allowedTenantIds)
    Write-Warning 'Discovery verifies current live state, not the original deployment or historical code integrity.'
    Write-Host "Observed provider tenant allowlist: $($summary.allowedProviderTenantIds -join ', '). Review these tenants."
    return Assert-EppMaintenanceSummary -Summary $summary
}

function Get-EppMaintenanceResource {
    param([hashtable] $Inputs, [string] $ResourceId, [switch] $ListSettings)

    $method = if ($ListSettings) { 'post' } else { 'get' }
    $value = Invoke-EppAz rest --method $method --url "https://management.azure.com$ResourceId`?api-version=2024-04-01" `
        --subscription $Inputs.SubscriptionId --output json | ConvertFrom-Json -AsHashtable
    if ($value -isnot [Collections.IDictionary] -or $value['properties'] -isnot [Collections.IDictionary]) {
        throw 'Azure returned incomplete maintenance metadata.'
    }
    return $value
}

function Get-EppMaintenanceState {
    param([Collections.IDictionary] $Summary, [hashtable] $Inputs, $Provider, [switch] $WaitForReady)

    Assert-EppCliDirectoryContext -Inputs $Inputs
    $account = Invoke-EppAz account show --subscription $Inputs.SubscriptionId --output json | ConvertFrom-Json -AsHashtable
    if ($account['tenantId'] -ine $Inputs.TenantId -or $account['id'] -ine $Inputs.SubscriptionId -or $account['state'] -cne 'Enabled') {
        throw 'The summary subscription does not match an enabled subscription in the selected tenant.'
    }
    $names = $Summary.resources
    $root = "/subscriptions/$($Inputs.SubscriptionId)/resourceGroups/$($names.resourceGroup)/providers"
    $siteId = "$root/Microsoft.Web/sites/$($names.functionApp)"
    $site = Get-EppMaintenanceResource -Inputs $Inputs -ResourceId $siteId
    $plan = Invoke-EppAz appservice plan show --ids "$root/Microsoft.Web/serverfarms/$($names.hostingPlan)" `
        --subscription $Inputs.SubscriptionId --output json | ConvertFrom-Json -AsHashtable
    $properties = $site.properties
    if ($site['id'] -ine $siteId -or $properties['serverFarmId'] -ine $plan['id'] -or
        $plan['sku']['name'] -cne $Summary.servicePlan -or
        ([string]$site['location'] -replace ' ', '') -ine ([string]$plan['location'] -replace ' ', '') -or
        ($Summary['location'] -and
            ([string]$site['location'] -replace ' ', '') -ine ([string]$Summary['location'] -replace ' ', ''))) {
        throw 'The live endpoint or hosting plan differs from the saved deployment. Migration requires a separate plan.'
    }
    if ($site['kind'] -notmatch 'functionapp' -or $site['kind'] -notmatch 'linux' -or
        $site['tags']['eppApplicationId'] -ine $Inputs.ApplicationId -or
        $site['tags']['eppLanguage'] -cne $Inputs.Language -or
        $properties['publicNetworkAccess'] -cne 'Enabled' -or $properties['state'] -cne 'Running') {
        throw 'The endpoint identity, runtime, running state, or ingress differs from a completed deployment. Inspect it before updating.'
    }
    $settings = (Get-EppMaintenanceResource -Inputs $Inputs -ResourceId "$siteId/config/appsettings/list" -ListSettings).properties
    foreach ($name in @('EPP_PROVIDER_NAME', 'EPP_PROVIDER_AUTH_MODE', 'EPP_PROVIDER_ENDPOINT_REGION',
        'EPP_PROVIDER_TENANT_ID', 'EPP_PROVIDER_SCOPE', 'EPP_PROVIDER_APP_ID')) {
        if ($settings[$name] -cne $Provider.Settings[$name]) { throw "Setting '$name' requires a provider/trust migration, not an in-place update." }
    }
    if ($Summary['providerTenantId'] -ine $Provider.TenantId -or $Summary['accessTokenScopeTenant'] -ine $Provider.AccessTokenScopeTenant) {
        throw 'The provider trust profile changed. Review migration separately.'
    }
    $secretId = $Summary.certificateSecretId
    if ($settings['EPP_ENCRYPTION_KEY_ID'] -ine $Summary.encryptionKeyId -or
        $settings['EPP_DECRYPTION_KEY_PEM'] -ine "@Microsoft.KeyVault(SecretUri=$secretId)" -or
        $settings['EPP_OUTBOUND_CLIENT_ID'] -ine $Inputs.ApplicationId -or
        $settings['EPP_TENANT_ID'] -ine $Inputs.TenantId) {
        throw 'The live certificate or application identity differs from the saved deployment. No credentials will be changed.'
    }
    for ($attempt = 1; $attempt -le 12; $attempt++) {
        $reference = (Get-EppMaintenanceResource -Inputs $Inputs -ResourceId "$siteId/config/configreferences/appsettings/EPP_DECRYPTION_KEY_PEM").properties
        if ($reference['status'] -ceq 'Resolved' -or -not $WaitForReady -or
            $reference['status'] -cnotin @('Initialized', 'FetchTimedOut')) { break }
        if ($attempt -lt 12) {
            Write-Warning "Waiting for certificate reference readback after the update ($attempt/12). No reference refresh is requested."
            Start-Sleep -Seconds 10
        }
    }
    $secret = ConvertTo-EppKeyVaultObjectId $secretId secrets
    if ($reference['status'] -cne 'Resolved' -or $reference['reference'] -ine $settings['EPP_DECRYPTION_KEY_PEM'] -or
        $reference['vaultName'] -ine $secret.VaultName -or $reference['secretName'] -ine $secret.Name -or
        $reference['secretVersion'] -ine $secret.Version -or
        ($reference['activeVersion'] -and $reference['activeVersion'] -ine $secret.Version)) {
        throw 'The existing versioned certificate-secret reference is not resolved as recorded. Maintenance will not refresh or replace it.'
    }
    $application = Get-EppApplication -Inputs $Inputs -ClientId $Inputs.ApplicationId
    $version = if ($application.Api.RequestedAccessTokenVersion -eq 2) { 2 } else { 1 }
    $context = [pscustomobject]@{ TokenVersion = $version }
    Assert-EppAuthentication -SiteId $siteId -Inputs $Inputs -Context $context -IdentifierUri $Summary.identifierUri
    $audience = if ($version -eq 2) { $Inputs.ApplicationId } else { $Summary.identifierUri }
    $issuer = if ($version -eq 2) { "https://login.microsoftonline.com/$($Inputs.TenantId)/v2.0" } else { "https://sts.windows.net/$($Inputs.TenantId)/" }
    if ($settings['EPP_EXPECTED_AUDIENCE'] -cne $audience -or $settings['EPP_EXPECTED_ISSUER'] -cne $issuer -or
        $settings['EPP_EXPECTED_CLIENT_ID'] -ine $script:MicrosoftPhoneProviderAppId) {
        throw 'Runtime authentication settings differ from Easy Auth. Review application trust separately.'
    }
    $key = @($application.KeyCredentials | Where-Object { $_.Usage -eq 'Encrypt' -and $_.KeyId -eq $Summary.encryptionKeyId })
    if ($key.Count -ne 1 -or -not $key[0].Key -or
        -not $key[0].StartDateTime -or -not $key[0].EndDateTime -or
        [DateTimeOffset]$key[0].StartDateTime -gt [DateTimeOffset]::UtcNow -or
        [DateTimeOffset]$key[0].EndDateTime -le [DateTimeOffset]::UtcNow.AddDays(30)) {
        throw 'The registered encryption credential is missing, invalid, or expires within 30 days. Renew it through a separately reviewed certificate procedure.'
    }
    $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new([byte[]]$key[0].Key)
    try {
        if ($certificate.Thumbprint -ine $Summary.certificateThumbprint -or
            $certificate.NotBefore.ToUniversalTime() -gt [DateTime]::UtcNow -or
            $certificate.NotAfter.ToUniversalTime() -le [DateTime]::UtcNow.AddDays(30)) {
            throw 'The registered public certificate does not match the summary or needs renewal.'
        }
        $trustInputs = @{} + $Inputs
        $trustInputs.ProviderTenantId = $Provider.TenantId
        $trustInputs.ProviderAllowedTenantIds = @($Summary.allowedProviderTenantIds)
        $null = Assert-EppGraphAccess -Inputs $trustInputs -Certificate $certificate -KeyId $Summary.encryptionKeyId `
            -IdentifierUri $Summary.identifierUri -CertificatePlan @{
                NonEncryptionSnapshot = Get-EppKeyCredentialSnapshot @($application.KeyCredentials | Where-Object Usage -ne 'Encrypt')
            }
    }
    finally { $certificate.Dispose() }
    $identity = Invoke-EppAz identity show --ids "$root/Microsoft.ManagedIdentity/userAssignedIdentities/$($names.outboundIdentity)" `
        --subscription $Inputs.SubscriptionId --output json | ConvertFrom-Json -AsHashtable
    $null = ConvertTo-EppGuid $identity['principalId']
    if ($settings['EPP_OUTBOUND_MI_CLIENT_ID'] -ine $identity['clientId'] -or
        -not $site['identity']['userAssignedIdentities'].Contains($identity['id'])) {
        throw 'The outbound managed identity differs from the configured identity.'
    }
    $credentials = Invoke-EppDirectoryCommand -Inputs $Inputs -Arguments @('ad', 'app', 'federated-credential', 'list', '--id', $application.Id)
    $matching = @($credentials | Where-Object {
        $_['issuer'] -ceq "https://login.microsoftonline.com/$($Inputs.TenantId)/v2.0" -and
        $_['subject'] -ceq $identity['principalId'] -and @($_['audiences']).Count -eq 1 -and
        $_['audiences'][0] -ceq 'api://AzureADTokenExchange'
    })
    if ($matching.Count -ne 1) { throw 'The outbound federated trust is missing or ambiguous. Maintenance will not change it.' }
    $web = (Get-EppMaintenanceResource -Inputs $Inputs -ResourceId "$siteId/config/web").properties
    $runtime = @{
        javascript = @{ worker = 'node'; version = '22'; stack = 'NODE|22' }
        dotnet = @{ worker = 'dotnet-isolated'; version = '10.0'; stack = 'DOTNET-ISOLATED|10.0' }
        python = @{ worker = 'python'; version = '3.11'; stack = 'PYTHON|3.11' }
    }[$Inputs.Language]
    if ($Inputs.ServicePlan -eq 'FC1') {
        if ($properties['functionAppConfig']['runtime']['name'] -cne $runtime.worker -or
            $properties['functionAppConfig']['runtime']['version'] -cne $runtime.version) {
            throw 'The Flex runtime requires migration. Maintenance does not change runtime versions.'
        }
    }
    elseif ($web['linuxFxVersion'] -ine $runtime.stack -or $settings['FUNCTIONS_WORKER_RUNTIME'] -cne $runtime.worker) {
        throw 'The Premium runtime requires migration. Maintenance does not change runtime versions.'
    }
    $functions = @(Invoke-EppAz functionapp function list --resource-group $names.resourceGroup --name $names.functionApp `
        --subscription $Inputs.SubscriptionId --output json | ConvertFrom-Json)
    if (@($functions | Where-Object { $_ -and $_.name -match '(^|/)SendOtp$' }).Count -ne 1) {
        throw 'Azure has not registered exactly one SendOtp function. Inspect the runtime before updating.'
    }
    return @{
        SiteId = $siteId; Settings = $settings; Web = $web; Context = $context
        Snapshot = @{
            Settings = $settings; Web = $web; HttpsOnly = $properties['httpsOnly']
            Identity = $site['identity']; Plan = $properties['serverFarmId']; TokenVersion = $version
            Keys = Get-EppKeyCredentialSnapshot $application.KeyCredentials
        }
        HttpsOnly = $properties['httpsOnly']
    }
}

function Get-EppMaintenancePlan {
    param($State, $Provider, [Collections.IDictionary] $Summary, $Package, [hashtable] $ProviderEnvironment, [string] $Scope)

    $desired = @{} + $Provider.Settings
    $environment = Get-EppProviderEnvironment -ProviderConfiguration $Provider -Values $ProviderEnvironment -Existing $State.Settings -NonInteractive
    foreach ($name in $environment.Keys) { $desired[$name] = $environment[$name] }
    $settings = @{}
    $changes = [Collections.Generic.List[object]]::new()
    if ($Scope -in @('All', 'Configuration')) {
        foreach ($name in @($desired.Keys | Sort-Object)) {
            if ($State.Settings[$name] -cne $desired[$name]) {
                $settings[$name] = $desired[$name]
                $changes.Add(@{ scope = 'Configuration'; name = $name })
            }
        }
    }
    $site = @{}
    $web = @{}
    if ($Scope -in @('All', 'Infrastructure')) {
        if ($State.HttpsOnly -ne $true) {
            $site.httpsOnly = $true
            $changes.Add(@{ scope = 'Infrastructure'; name = 'httpsOnly' })
        }
        foreach ($name in @('minTlsVersion', 'scmMinTlsVersion')) {
            if ($State.Web[$name] -and $State.Web[$name] -cnotin @('1.0', '1.1', '1.2', '1.3')) {
                throw "Unsupported TLS value for '$name'. Review it separately; maintenance will not downgrade an unknown version."
            }
            if ($State.Web[$name] -cnotin @('1.2', '1.3')) {
                $web[$name] = '1.2'
                $changes.Add(@{ scope = 'Infrastructure'; name = $name })
            }
        }
        if ($Summary.servicePlan -eq 'EP1' -and $State.Web['ftpsState'] -cne 'Disabled') {
            $web.ftpsState = 'Disabled'
            $changes.Add(@{ scope = 'Infrastructure'; name = 'ftpsState' })
        }
    }
    $code = $Scope -in @('All', 'Code') -and $State.Settings['EPP_PACKAGE_SHA256'] -cne $Package.Sha256
    if ($Scope -in @('All', 'Code') -and $Summary.servicePlan -eq 'EP1' -and
        $State.Settings['WEBSITE_RUN_FROM_PACKAGE'] -cne "https://$($Summary.resources.storageAccount).blob.core.windows.net/packages/$($Package.Sha256).zip") {
        $code = $true
    }
    if ($code) { $changes.Add(@{ scope = 'Code'; name = 'Function package' }) }
    return @{
        Settings = $settings; Site = $site; Web = $web; Code = $code
        Environment = $environment; Changes = @($changes)
    }
}

function Set-EppMaintenanceResource {
    param([hashtable] $Inputs, [string] $ResourceId, [hashtable] $Properties, [string] $Directory)

    $path = Join-Path $Directory 'maintenance-body.json'
    try {
        @{ properties = $Properties } | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $path -Encoding utf8NoBOM
        Invoke-EppAz rest --method patch --url "https://management.azure.com$ResourceId`?api-version=2024-04-01" `
            --subscription $Inputs.SubscriptionId --headers 'Content-Type=application/json' --body "@$path" --output none | Out-Null
    }
    finally { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force } }
}

function Set-EppMaintenanceSettings {
    param([hashtable] $Inputs, [Collections.IDictionary] $Names, [hashtable] $Settings, [string] $Directory)

    $path = Join-Path $Directory 'maintenance-settings.json'
    try {
        $Settings | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding utf8NoBOM
        Invoke-EppAz functionapp config appsettings set --resource-group $Names.resourceGroup --name $Names.functionApp `
            --subscription $Inputs.SubscriptionId --settings "@$path" --output none | Out-Null
    }
    finally { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force } }
}

function Invoke-EppMaintenance {
    [CmdletBinding()]
    param(
        [ValidateSet('Verify', 'Update')][string] $Operation,
        [string] $DeploymentSummaryPath,
        [string] $TenantId, [string] $SubscriptionId, [string] $ResourceGroupName,
        [string] $FunctionAppName, [string] $KeyVaultSubscriptionId, [switch] $NonInteractive,
        [ValidateSet('All', 'Code', 'Configuration', 'Infrastructure')][string] $UpdateScope = 'All',
        [switch] $Apply, [hashtable] $ProviderEnvironment, [string] $PackageReleaseTag,
        [string] $OutputDirectory, [string] $AssetDirectory, [string] $SourceBaseUri,
        [string] $SourceRepository, [switch] $PassThru
    )

    if ($Operation -eq 'Verify' -and ($Apply -or $ProviderEnvironment)) { throw 'Verification cannot apply changes or accept new provider settings.' }
    $pattern = '^https://raw\.githubusercontent\.com/' + [regex]::Escape($SourceRepository) + '/(?<revision>[0-9a-fA-F]{40})/setup$'
    if ($SourceBaseUri -cnotmatch $pattern) { throw 'Maintenance requires commit-pinned assets.' }
    $revision = $Matches.revision
    $discovered = -not $DeploymentSummaryPath
    if ($DeploymentSummaryPath -and ($TenantId -or $SubscriptionId -or $ResourceGroupName -or $FunctionAppName -or $KeyVaultSubscriptionId)) {
        throw 'Choose a saved summary or discovery parameters, not both.'
    }
    if ($discovered) {
        if ($Operation -ne 'Verify') { throw 'Update requires -DeploymentSummaryPath. Run Verify-Epp.ps1 to discover and verify an endpoint first.' }
        $endpoint = Select-EppMaintenanceEndpoint -TenantId $TenantId -SubscriptionId $SubscriptionId `
            -ResourceGroupName $ResourceGroupName -FunctionAppName $FunctionAppName -NonInteractive:$NonInteractive
        $summary = Get-EppDiscoveredSummary -Endpoint $endpoint -AssetDirectory $AssetDirectory `
            -KeyVaultSubscriptionId $KeyVaultSubscriptionId -NonInteractive:$NonInteractive
    }
    else { $summary = Read-EppMaintenanceSummary $DeploymentSummaryPath }
    $inputs = @{
        TenantId = $summary.tenantId; SubscriptionId = $summary.subscriptionId; ApplicationId = $summary.applicationId
        ServicePlan = $summary.servicePlan; Language = $(if ($summary.language -eq 'csharp') { 'dotnet' } else { $summary.language })
    }
    $provider = Get-EppProvider -AssetDirectory $AssetDirectory -Provider $summary.provider -EndpointRegion $summary.endpointRegion -NonInteractive
    if ($inputs.Language -cnotin $provider.Languages) { throw 'The provider no longer supports this runtime. Review migration separately.' }
    $state = Get-EppMaintenanceState -Summary $summary -Inputs $inputs -Provider $provider
    $directory = Join-Path ([IO.Path]::GetTempPath()) "epp-maintenance-$([Guid]::NewGuid().ToString('N'))"
    try {
        New-Item -ItemType Directory -Path $directory | Out-Null
        $selection = $null
        $package = $null
        if ($UpdateScope -in @('All', 'Code')) {
            $selection = Get-EppLanguage -AssetDirectory $AssetDirectory -Language $inputs.Language `
                -SourceRepository $SourceRepository -PackageReleaseTag $PackageReleaseTag -NonInteractive
            $package = Get-EppPackage -Selection $selection -Directory $directory
            if ($package.RequiresRemoteBuild) { throw 'Maintenance requires a ready-to-deploy package. Remote-build migration is not supported.' }
        }
        elseif ($PackageReleaseTag) { throw '-PackageReleaseTag requires the All or Code update scope.' }
        $plan = Get-EppMaintenancePlan -State $state -Provider $provider -Summary $summary -Package $package `
            -ProviderEnvironment $ProviderEnvironment -Scope $UpdateScope
        Write-Host "`nExisting identity, application trust, encryption credential, resolved secret reference, and SendOtp registration verified." -ForegroundColor Cyan
        Write-Host 'Supported infrastructure scope: HTTPS-only, minimum TLS for app/SCM, and disabling EP1 FTP. Other infrastructure is not reconciled.'
        Write-Host 'Package comparison uses the last successful maintenance marker, not a live byte-level code attestation.'
        if ($package) {
            Write-Host "Target package: $($selection.ReleaseTag); SHA-256: $($package.Sha256)"
        }
        Write-Host "Reviewed source: $SourceBaseUri"
        foreach ($change in $plan.Changes) { Write-Host "  $($change.scope): $($change.name)" }
        if (-not $plan.Changes.Count) { Write-Host 'No supported deltas found.' }
        if (-not $Apply) { Write-Host 'Read-only preview. Use Update-Epp.ps1 with -Apply to authorize these supported changes.' }
        $applied = $false
        if ($Apply -and $plan.Changes.Count) {
            $current = Get-EppMaintenanceState -Summary $summary -Inputs $inputs -Provider $provider
            if (-not (Test-EppJsonEqual $state.Snapshot $current.Snapshot)) { throw 'The endpoint changed during preflight. Rerun to review a fresh plan.' }
            Write-Warning 'Applying supported deltas may restart the Function. On failure, partial changes remain; no automatic rollback is attempted.'
            if ($plan.Site.Count) { Set-EppMaintenanceResource -Inputs $inputs -ResourceId $state.SiteId -Properties $plan.Site -Directory $directory }
            if ($plan.Web.Count) { Set-EppMaintenanceResource -Inputs $inputs -ResourceId "$($state.SiteId)/config/web" -Properties $plan.Web -Directory $directory }
            if ($plan.Settings.Count) { Set-EppMaintenanceSettings -Inputs $inputs -Names $summary.resources -Settings $plan.Settings -Directory $directory }
            if ($plan.Code) {
                # Invalidate the previous success marker before publishing, including failure paths.
                Set-EppMaintenanceSettings -Inputs $inputs -Names $summary.resources -Settings @{ EPP_PACKAGE_SHA256 = '' } -Directory $directory
                $inputs.PackageSha256 = $package.Sha256
                $outputs = [pscustomobject]@{
                    identifierUri = [pscustomobject]@{ value = $summary.identifierUri }
                    packageContainerUrl = [pscustomobject]@{ value = "https://$($summary.resources.storageAccount).blob.core.windows.net/packages/" }
                }
                $hash = Publish-EppFunction -Inputs $inputs -Names $summary.resources -Context $state.Context `
                    -Outputs $outputs -SiteId $state.SiteId -Package $package -Directory $directory -MountAfterUpload:($inputs.ServicePlan -eq 'EP1')
                if ($hash -cne $package.Sha256) { throw 'Published package hash differs from the approved package.' }
            }
            $after = Get-EppMaintenanceState -Summary $summary -Inputs $inputs -Provider $provider -WaitForReady
            $remaining = Get-EppMaintenancePlan -State $after -Provider $provider -Summary $summary -Package $package `
                -ProviderEnvironment $ProviderEnvironment -Scope $UpdateScope
            if ($remaining.Settings.Count -or $remaining.Site.Count -or $remaining.Web.Count) { throw 'Update readback does not match the supported delta plan.' }
            if ($plan.Code -and $inputs.ServicePlan -eq 'EP1' -and
                $after.Settings['WEBSITE_RUN_FROM_PACKAGE'] -cne "https://$($summary.resources.storageAccount).blob.core.windows.net/packages/$($package.Sha256).zip") {
                throw 'The Function did not mount the approved package.'
            }
            if ($plan.Code) {
                try {
                    Set-EppMaintenanceSettings -Inputs $inputs -Names $summary.resources -Settings @{ EPP_PACKAGE_SHA256 = $package.Sha256 } -Directory $directory
                    # App-setting writes can restart the host, including this bookkeeping write.
                    Assert-EppFunctionPublished -Inputs $inputs -Names $summary.resources
                    $marked = Get-EppMaintenanceState -Summary $summary -Inputs $inputs -Provider $provider -WaitForReady
                    if ($marked.Settings['EPP_PACKAGE_SHA256'] -cne $package.Sha256) { throw 'Package success marker readback failed.' }
                }
                catch {
                    $markerError = $_
                    try {
                        Set-EppMaintenanceSettings -Inputs $inputs -Names $summary.resources -Settings @{ EPP_PACKAGE_SHA256 = '' } -Directory $directory
                    }
                    catch {
                        throw [AggregateException]::new('Update verification failed and its success marker could not be cleared. Inspect the endpoint before retrying.',
                            [Exception[]]@($markerError.Exception, $_.Exception))
                    }
                    throw $markerError
                }
            }
            $applied = $true
        }
        New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
        $stamp = "$([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
        $report = [ordered]@{
            operation = $Operation; applied = $applied; scope = $UpdateScope; verifiedUtc = [DateTime]::UtcNow.ToString('o')
            subscriptionId = $summary.subscriptionId; applicationId = $summary.applicationId
            source = $SourceBaseUri; sourceRevision = $revision; changes = @($plan.Changes)
            certificateChanged = $false; applicationTrustChanged = $false; liveDeliveryValidated = $false
            packageSha256 = $(if ($package) { $package.Sha256 } else { $null })
            packageReleaseTag = $(if ($selection) { $selection.ReleaseTag } else { $null })
            tenantId = $summary.tenantId; resourceGroup = $summary.resources.resourceGroup
            functionApp = $summary.resources.functionApp; endpointUrl = $summary.endpointUrl
            discovered = $discovered
        }
        if ($discovered) {
            $recoveredPath = Join-Path $OutputDirectory "deployment-discovered-$stamp.json"
            $summary | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $recoveredPath -Encoding utf8NoBOM
            $report.deploymentSummaryPath = $recoveredPath
            Write-Host "Recovered deployment summary: $recoveredPath"
        }
        $reportPath = Join-Path $OutputDirectory "verification-$stamp.json"
        $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reportPath -Encoding utf8NoBOM
        if ($applied) {
            $summary.maintenanceSchemaVersion = 1
            $summary.lastMaintenanceSource = $SourceBaseUri
            $summary.lastMaintenanceUtc = $report.verifiedUtc
            if ($plan.Code) {
                $summary.packageSha256 = $package.Sha256
                $summary.sourcePackageSha256 = $package.SourceSha256
                $summary.packageChecksumVerified = [bool]$package.SourceSha256
                $summary.packageReleaseTag = $selection.ReleaseTag
                $summary.packageUrl = $selection.Url
            }
            if ($UpdateScope -in @('All', 'Configuration')) {
                $summary.providerEnvironment = $plan.Environment
                $summary.providerSmsEndpoint = $provider.Settings.EPP_PROVIDER_SMS_ENDPOINT
                $summary.providerVoiceEndpoint = $provider.Settings.EPP_PROVIDER_VOICE_ENDPOINT
            }
            $summaryPath = Join-Path $OutputDirectory "deployment-$stamp.json"
            $summary | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $summaryPath -Encoding utf8NoBOM
            Write-Host "Updated deployment summary: $summaryPath"
        }
        Write-Host "Verification report: $reportPath"
        if ($PassThru) { return [pscustomobject]$report }
    }
    finally {
        if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force }
    }
}
