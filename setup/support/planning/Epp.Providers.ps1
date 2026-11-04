function Get-EppProviderCatalog {
    param([string] $AssetDirectory)

    $catalog = Read-EppJson (Join-Path $AssetDirectory 'providers/catalog.json')
    if ($catalog['schemaVersion'] -ne 1 -or -not $catalog['providers']) { throw 'Unsupported or empty provider catalog.' }
    $entries = @($catalog['providers'])
    $ids = @{}
    foreach ($entry in $entries) {
        if ($entry -isnot [Collections.IDictionary] -or $entry['id'] -cnotmatch '^[a-z][a-z0-9-]{1,31}$' -or
            $entry['file'] -cnotmatch '^[a-z][a-z0-9-]{1,31}\.json$' -or
            -not $entry['displayName'] -or $entry['displayName'] -match '[\x00-\x1f]' -or $ids.ContainsKey($entry['id'])) {
            throw 'Provider catalog contains an invalid or duplicate entry.'
        }
        $ids[$entry['id']] = $true
    }
    return $entries
}

function Read-EppProviderName {
    param([object[]] $Entries, [string] $Provider, [switch] $NonInteractive)

    $supplied = -not [string]::IsNullOrWhiteSpace($Provider)
    if (-not $supplied -and $NonInteractive) { throw '-Provider is required in noninteractive mode.' }
    while ($true) {
        if (-not $supplied) {
            Write-Host "Provider names: $(($Entries | ForEach-Object { $_['displayName'] } | Sort-Object) -join ', ')"
            $Provider = [string](Read-Host 'Provider name')
        }
        $Provider = $Provider.Trim()
        if (-not $Provider) {
            Write-Warning 'A provider name is required. Choose one of the listed providers.'
            continue
        }
        $selected = @($Entries | Where-Object { $_['id'] -ieq $Provider -or $_['displayName'] -ieq $Provider })
        if ($selected.Count -eq 1) { return [string]$selected[0]['id'] }
        $message = "Unknown provider '$Provider'. Supply a provider name, not a selection number."
        if ($supplied) { throw $message }
        Write-Warning $message
    }
}

function Get-EppProviderDefinition {
    param([string] $AssetDirectory, [string] $Provider)

    $entries = @(Get-EppProviderCatalog -AssetDirectory $AssetDirectory)
    $id = Read-EppProviderName -Entries $entries -Provider $Provider -NonInteractive
    $entry = $entries | Where-Object { $_['id'] -ceq $id } | Select-Object -First 1
    $profile = Read-EppJson (Join-Path $AssetDirectory "providers/$($entry['file'])")
    $deployment = $profile['deployment']
    if ($deployment -isnot [Collections.IDictionary] -or $deployment['enabled'] -isnot [bool] -or -not $deployment['enabled'] -or
        $deployment['providerName'] -ine $id) {
        throw "Provider '$id' is not enabled or has inconsistent deployment metadata."
    }
    return [pscustomobject]@{
        Id = $id; DisplayName = $entry['displayName']
        TenantId = ConvertTo-EppGuid ([string]$deployment['tenantId'])
        Profile = $profile
    }
}

function Resolve-EppApplicationProvider {
    param([hashtable] $Inputs, [string] $AssetDirectory, [string] $Provider, [switch] $NonInteractive)

    $entries = @(Get-EppProviderCatalog -AssetDirectory $AssetDirectory)
    if (-not [string]::IsNullOrWhiteSpace($Provider) -or $NonInteractive) {
        return Read-EppProviderName -Entries $entries -Provider $Provider -NonInteractive:$NonInteractive
    }
    if ($Inputs['NewApplicationDisplayName']) {
        Write-Host 'Choose a provider for the new application. The application and its provider configuration will be created only after deployment approval.'
        return Read-EppProviderName -Entries $entries
    }
    $application = Get-EppApplication -Inputs $Inputs -ClientId $Inputs.ApplicationId
    $restriction = Get-EppSignInAudienceRestrictions -Inputs $Inputs -ApplicationObjectId $application.Id
    $state = Get-EppProviderRestrictionState -Restriction $restriction
    $configured = @()
    if ($application.SignInAudience -eq 'AzureADMultipleOrgs' -and $state -and $state.isHomeTenantAllowed) {
        foreach ($entry in $entries) {
            $definition = Get-EppProviderDefinition -AssetDirectory $AssetDirectory -Provider $entry['id']
            if ($state.allowedTenantIds -contains $definition.TenantId) { $configured += $entry }
        }
    }
    if (-not $configured.Count) {
        Write-Host 'No supported provider is configured on this application. Enter a provider name; configuration is included in the deployment approval.'
        return Read-EppProviderName -Entries $entries
    }
    if ($configured.Count -eq 1) {
        $entry = $configured[0]
        while ($true) {
            $answer = ([string](Read-Host "Application is configured for $($entry['displayName']). Use this provider? Enter Yes or Y, or No or N to cancel [No]")).Trim()
            if ($answer -in @('Yes', 'Y')) { return [string]$entry['id'] }
            if (-not $answer -or $answer -in @('No', 'N')) { return $null }
            Write-Warning 'Enter Yes or Y to use the configured provider, or No or N to cancel. Press Enter to cancel.'
        }
    }
    Write-Host 'Multiple providers are configured on this application. Enter the provider name to use for this deployment.'
    return Read-EppProviderName -Entries $configured
}

function Get-EppProvider {
    param(
        [string] $AssetDirectory, [string] $Provider,
        [string] $EndpointRegion, [switch] $NonInteractive
    )

    $entries = @(Get-EppProviderCatalog -AssetDirectory $AssetDirectory)
    $id = Read-EppProviderName -Entries $entries -Provider $Provider -NonInteractive:$NonInteractive
    if (-not $id) { return $null }
    $definition = Get-EppProviderDefinition -AssetDirectory $AssetDirectory -Provider $id
    return ConvertTo-EppProviderSettings -Profile $definition.Profile -Id $definition.Id -DisplayName $definition.DisplayName `
        -EndpointRegion $EndpointRegion -NonInteractive:$NonInteractive
}

function ConvertTo-EppProviderSettings {
    param(
        [Collections.IDictionary] $Profile, [string] $Id, [string] $DisplayName,
        [string] $EndpointRegion, [switch] $NonInteractive
    )

    $issues = [Collections.Generic.List[string]]::new()
    $deployment = $Profile['deployment']
    if ($deployment -isnot [Collections.IDictionary]) { throw "Provider '$DisplayName' has no deployment configuration." }
    if ($deployment['enabled'] -isnot [bool] -or -not $deployment['enabled']) {
        $issues.Add('the provider owner has not enabled this profile')
    }
    if ($deployment['providerName'] -ine $Id) { $issues.Add('deployment.providerName must match the catalog ID or display name') }
    $providerTenantId = $null
    try { $providerTenantId = ConvertTo-EppGuid $deployment['tenantId'] }
    catch { $issues.Add('deployment.tenantId must identify the provider Security Store tenant') }
    $accessTokenScopeTenant = $providerTenantId
    if ($deployment.Contains('AccessTokenScopeTenant')) {
        try { $accessTokenScopeTenant = ConvertTo-EppGuid $deployment['AccessTokenScopeTenant'] }
        catch { $issues.Add('deployment.AccessTokenScopeTenant must identify the provider access-token tenant') }
    }

    $authentication = $deployment['authentication']
    if ($authentication -isnot [Collections.IDictionary] -or $authentication['mode'] -notin @('apiKey', 'oauth')) {
        $issues.Add('deployment.authentication.mode must be apiKey or oauth')
    }
    $authenticationMode = if ($authentication -is [Collections.IDictionary]) { [string]$authentication['mode'] } else { '' }
    if ($authenticationMode -eq 'apiKey') {
        foreach ($name in @('keyVaultSecretName', 'identityKeyVaultSecretName')) {
            if ($authentication[$name] -cnotmatch '^[a-z0-9][a-z0-9-]{1,126}$') {
                $issues.Add("deployment.authentication.$name must be a Key Vault secret name")
            }
        }
    }

    $routes = $deployment['routes']
    if ($routes -isnot [Collections.IDictionary]) { throw "Provider '$DisplayName' is missing deployment.routes." }
    foreach ($regionId in @('global', 'eu')) {
        $route = $routes[$regionId]
        if ($route -isnot [Collections.IDictionary]) {
            $issues.Add("deployment.routes.$regionId is missing")
            continue
        }
        foreach ($endpointName in @('smsEndpoint', 'voiceEndpoint')) {
            try { Assert-EppHttpsUrl $route[$endpointName] }
            catch { $issues.Add("deployment.routes.$regionId.$endpointName must be a public HTTPS endpoint") }
        }
        $timeout = $route['timeoutMilliseconds']
        $retry = $route['retryIntervalSeconds']
        if (($timeout -isnot [long] -and $timeout -isnot [int]) -or $timeout -lt 1 -or $timeout -gt 2500) {
            $issues.Add("deployment.routes.$regionId.timeoutMilliseconds must be an integer from 1 to 2500")
        }
        if (($retry -isnot [long] -and $retry -isnot [int]) -or $retry -lt 0 -or $retry -gt 2147483) {
            $issues.Add("deployment.routes.$regionId.retryIntervalSeconds must be a nonnegative integer fitting Int32 milliseconds")
        }
        if ($authenticationMode -eq 'oauth') {
            try { $null = ConvertTo-EppGuid $route['appId'] }
            catch { $issues.Add("deployment.routes.$regionId.appId must identify the provider API application") }
            $scope = [string]$route['scope']
            $resource = $scope -replace '/\.default$', ''
            $resourceUri = $null
            $resourceGuid = [Guid]::Empty
            $validResource = ([Guid]::TryParse($resource, [ref] $resourceGuid) -and $resourceGuid -ne [Guid]::Empty) -or
                ([Uri]::TryCreate($resource, [UriKind]::Absolute, [ref] $resourceUri) -and
                    $resourceUri.Scheme -in @('api', 'https') -and $resourceUri.Host -and
                    -not $resourceUri.UserInfo -and -not $resourceUri.Query -and -not $resourceUri.Fragment)
            if (-not $validResource -or $scope -notmatch '/\.default$' -or $scope -match '[\s<>]') {
                $issues.Add("deployment.routes.$regionId.scope must be the provider API resource followed by /.default")
            }
        }
    }
    if ($issues.Count) {
        throw "Provider '$DisplayName' is not deployment-ready:`n - $($issues -join "`n - ")`nAsk the provider owner to complete its GitHub JSON. No Azure resources were changed."
    }

    $regionEntry = Select-EppOption -Entries @(
        @{ id = 'global'; displayName = 'Global endpoint' }
        @{ id = 'eu'; displayName = 'EU endpoint' }
    ) -Name EndpointRegion -Value $EndpointRegion -NonInteractive:$NonInteractive
    $selectedRoute = $routes[$regionEntry['id']]
    $settings = @{
        EPP_PROVIDER_NAME = $Id
        EPP_PROVIDER_SMS_ENDPOINT = [string]$selectedRoute['smsEndpoint']
        EPP_PROVIDER_VOICE_ENDPOINT = [string]$selectedRoute['voiceEndpoint']
        EPP_PROVIDER_ENDPOINT_REGION = [string]$regionEntry['id']
        EPP_PROVIDER_TIMEOUT_MS = [string]$selectedRoute['timeoutMilliseconds']
        EPP_PROVIDER_RETRY_INTERVAL_MS = [string]([long]$selectedRoute['retryIntervalSeconds'] * 1000)
        EPP_PROVIDER_AUTH_MODE = $authenticationMode
        EPP_PROVIDER_TENANT_ID = $accessTokenScopeTenant
    }
    if ($authenticationMode -eq 'oauth') {
        $settings.EPP_PROVIDER_SCOPE = [string]$selectedRoute['scope']
        $settings.EPP_PROVIDER_APP_ID = [string]$selectedRoute['appId']
    }
    return [pscustomobject]@{
        Id = $Id
        DisplayName = $DisplayName
        TenantId = $providerTenantId
        AccessTokenScopeTenant = $accessTokenScopeTenant
        Manifest = $Profile
        EndpointRegion = [string]$regionEntry['id']
        AuthenticationMode = $authenticationMode
        Settings = $settings
    }
}
