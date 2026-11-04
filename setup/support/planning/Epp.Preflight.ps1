function Confirm-EppPrerequisiteInstall {
    param([string] $Description, [switch] $NonInteractive, [switch] $InstallPrerequisites)

    if ($InstallPrerequisites) { return }
    if ($NonInteractive) { throw "$Description is missing. Rerun with -InstallPrerequisites or install it manually." }
    while ($true) {
        $answer = ([string](Read-Host "Install $Description now? Enter Yes or Y to install, or No or N to cancel [No]")).Trim()
        if ($answer -in @('Yes', 'Y')) { return }
        if (-not $answer -or $answer -in @('No', 'N')) { throw "$Description is required. No Azure or tenant resources were changed." }
        Write-Warning 'Enter Yes or Y to install the prerequisite, or No or N to cancel. Press Enter to cancel.'
    }
}

function Initialize-EppBicep {
    param([switch] $NonInteractive, [switch] $InstallPrerequisites)

    try {
        Invoke-EppAz bicep version --output none | Out-Null
        return
    }
    catch {
        if ($_.Exception.Message -notmatch 'Bicep.*(?:not found|not installed)|az bicep install') { throw }
    }
    Confirm-EppPrerequisiteInstall -Description 'the Azure CLI Bicep component' `
        -NonInteractive:$NonInteractive -InstallPrerequisites:$InstallPrerequisites
    Write-Host 'Installing the Azure CLI Bicep component...' -ForegroundColor Cyan
    Invoke-EppAz bicep install --output none | Out-Null
    Invoke-EppAz bicep version --output none | Out-Null
}

function Get-EppResourceProviderRequirements {
    @(
        @{ Namespace = 'Microsoft.Web'; Type = 'sites' }
        @{ Namespace = 'Microsoft.Storage'; Type = 'storageAccounts' }
        @{ Namespace = 'Microsoft.KeyVault'; Type = 'vaults' }
        @{ Namespace = 'Microsoft.OperationalInsights'; Type = 'workspaces' }
        @{ Namespace = 'Microsoft.Insights'; Type = 'components' }
        @{ Namespace = 'Microsoft.ManagedIdentity'; Type = 'userAssignedIdentities' }
        @{ Namespace = 'Microsoft.ContainerInstance'; Type = 'containerGroups' }
        @{ Namespace = 'Microsoft.Resources'; Type = 'deploymentScripts' }
    )
}

function Get-EppResourceProviders {
    param([string] $SubscriptionId)

    foreach ($provider in Get-EppResourceProviderRequirements) {
        $registration = Invoke-EppAz provider show --namespace $provider.Namespace --subscription $SubscriptionId --output json |
            ConvertFrom-Json
        if (-not $registration -or -not $registration.PSObject.Properties['registrationState'] -or
            $registration.registrationState -notin @('Registered', 'Registering', 'NotRegistered', 'Unregistering')) {
            throw "Azure returned an unsupported registration state for '$($provider.Namespace)'."
        }
        if ($registration.registrationState -eq 'Unregistering') {
            throw "Resource provider '$($provider.Namespace)' is being unregistered. Let that operation finish before rerunning setup; it will not be reversed automatically."
        }
        $locations = @()
        if ($registration.PSObject.Properties['resourceTypes'] -and $registration.resourceTypes) {
            $locations = @($registration.resourceTypes | Where-Object { $_ -and $_.resourceType -eq $provider.Type } | ForEach-Object locations)
        }
        [pscustomobject]@{
            Namespace = $provider.Namespace; Type = $provider.Type
            RegistrationState = $registration.registrationState; Locations = $locations
        }
    }
}

function Test-EppProviderLocation {
    param($Provider, [string] $Location)

    return @($Provider.Locations | Where-Object { ($_ -replace '[^a-zA-Z0-9]', '') -ieq $Location }).Count -gt 0
}

function Assert-EppProviderLocations {
    param([object[]] $Providers, [string] $Location)

    foreach ($provider in $Providers) {
        if ($provider.RegistrationState -eq 'Registered' -and -not (Test-EppProviderLocation $provider $Location)) {
            throw "'$($provider.Namespace)/$($provider.Type)' is unavailable in '$Location'. Choose another location."
        }
    }
}

function Assert-EppPremiumLocation {
    param([hashtable] $Inputs)

    $endpoint = "https://management.azure.com/subscriptions/$($Inputs.SubscriptionId)/providers/Microsoft.Web/geoRegions"
    $required = @{ 'api-version' = '2024-04-01'; sku = 'ElasticPremium'; linuxWorkersEnabled = 'true' }
    $parameters = @{} + $required
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $queryPath = Join-Path ([IO.Path]::GetTempPath()) "epp-regions-$([Guid]::NewGuid().ToString('N')).json"
    try {
        for ($pageNumber = 1; $pageNumber -le 20; $pageNumber++) {
            # A query file keeps ampersands and continuation tokens away from Windows az.cmd parsing.
            $parameters | ConvertTo-Json | Set-Content -LiteralPath $queryPath -Encoding utf8NoBOM
            $page = Invoke-EppAz rest --method get --url $endpoint --url-parameters "@$queryPath" `
                --subscription $Inputs.SubscriptionId --output json | ConvertFrom-Json -AsHashtable
            if ($page -isnot [Collections.IDictionary] -or $page['value'] -isnot [Array]) {
                throw 'Azure returned an invalid Elastic Premium region response.'
            }
            if (@($page['value'] | Where-Object {
                $_ -and $_['name'] -is [string] -and ($_['name'] -replace '[^a-zA-Z0-9]', '') -ieq $Inputs.Location
            }).Count) { return }
            if (-not $page['nextLink']) { throw "Linux Premium EP1 is unavailable in '$($Inputs.Location)'." }
            $next = $null
            if (-not [Uri]::TryCreate([string]$page['nextLink'], [UriKind]::Absolute, [ref]$next) -or
                $next.Scheme -ne 'https' -or $next.Port -ne 443 -or $next.UserInfo -or $next.Fragment -or
                $next.GetLeftPart([UriPartial]::Path) -ine $endpoint -or -not $seen.Add($next.AbsoluteUri)) {
                throw 'Azure returned an invalid or repeated Elastic Premium region continuation link.'
            }
            $parameters = @{} + $required
            foreach ($pair in $next.Query.TrimStart('?').Split('&', [StringSplitOptions]::RemoveEmptyEntries)) {
                $parts = $pair.Split('=', 2)
                if ($parts.Count -ne 2) { throw 'Azure returned an invalid region continuation parameter.' }
                $name = [Uri]::UnescapeDataString($parts[0].Replace('+', ' '))
                $value = [Uri]::UnescapeDataString($parts[1].Replace('+', ' '))
                if ($required.ContainsKey($name) -and $required[$name] -cne $value) {
                    throw 'Azure region pagination changed the approved Elastic Premium/Linux filter.'
                }
                $parameters[$name] = $value
            }
        }
        throw 'Azure region pagination exceeded the supported page limit.'
    }
    finally {
        if (Test-Path -LiteralPath $queryPath) { Remove-Item -LiteralPath $queryPath -Force }
    }
}

function Assert-EppServicePlanLocation {
    param([hashtable] $Inputs)

    if ($Inputs.ServicePlan -eq 'EP1') {
        Assert-EppPremiumLocation -Inputs $Inputs
        return
    }
    if ($Inputs.ServicePlan -ne 'FC1') { throw "Unknown service plan '$($Inputs.ServicePlan)'." }
    $regions = Invoke-EppAz functionapp list-flexconsumption-locations --subscription $Inputs.SubscriptionId --output json |
        ConvertFrom-Json -AsHashtable -NoEnumerate
    if ($regions -isnot [Array]) { throw 'Azure returned an invalid Flex Consumption region response.' }
    if (-not @($regions | Where-Object {
        $_ -and $_['name'] -is [string] -and ($_['name'] -replace '[^a-zA-Z0-9]', '') -ieq $Inputs.Location
    }).Count) {
        throw "Linux Flex Consumption FC1 is unavailable in '$($Inputs.Location)'. Choose another location or EP1."
    }
}

function Assert-EppExistingServicePlan {
    param([hashtable] $Inputs, [Collections.IDictionary] $Names, [Collections.IDictionary] $Tags)

    if ($Tags['eppServicePlan'] -and $Tags['eppServicePlan'] -ne $Inputs.ServicePlan) {
        throw "This prefix already uses '$($Tags['eppServicePlan'])'. Use a different prefix for '$($Inputs.ServicePlan)'; in-place plan migration is not supported."
    }
    # Older EP1 deployments have no plan tag; verify the actual SKU before any writes.
    $allPlans = Invoke-EppAz appservice plan list --resource-group $Names.resourceGroup --subscription $Inputs.SubscriptionId --output json |
        ConvertFrom-Json -AsHashtable -NoEnumerate
    if ($allPlans -isnot [Array]) { throw 'Azure returned an invalid hosting-plan list.' }
    $plans = @($allPlans | Where-Object name -eq $Names.hostingPlan)
    if ($plans.Count -gt 1) { throw 'Azure returned multiple hosting plans with the approved name.' }
    if ($plans.Count -eq 1 -and $plans[0].sku.name -ne $Inputs.ServicePlan) {
        throw "The existing hosting plan uses '$($plans[0].sku.name)'. Use a different prefix for '$($Inputs.ServicePlan)'; in-place plan migration is not supported."
    }
}

function Test-EppRegistrationDelay {
    param([string] $Message)

    if ($Message -notmatch '\b(MissingSubscriptionRegistration|SubscriptionNotRegistered)\b') { return $false }
    foreach ($provider in Get-EppResourceProviderRequirements) {
        if ($Message -match ('(?<![A-Za-z0-9_.])' + [regex]::Escape($provider.Namespace) + '(?![A-Za-z0-9_.])')) { return $true }
    }
    return $false
}

function Invoke-EppRegistrationRetry {
    param([scriptblock] $Operation, [ValidateRange(1, 60)][int] $MaxAttempts = 12)

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try { return & $Operation }
        catch {
            if ($attempt -eq $MaxAttempts -or -not (Test-EppRegistrationDelay $_.Exception.Message)) { throw }
            Write-Warning "Waiting for required Azure resource-provider registration to reach this region ($attempt/$MaxAttempts)."
            Start-Sleep -Seconds 10
        }
    }
}

function Initialize-EppResourceProviders {
    param([hashtable] $Inputs, [ValidateRange(1, 120)][int] $MaxAttempts = 60)

    $requested = @{}
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $providers = @(Get-EppResourceProviders -SubscriptionId $Inputs.SubscriptionId)
        Assert-EppProviderLocations -Providers $providers -Location $Inputs.Location
        foreach ($provider in $providers) {
            if ($provider.RegistrationState -eq 'NotRegistered' -and -not $requested.ContainsKey($provider.Namespace)) {
                Write-Host "Registering Azure resource provider '$($provider.Namespace)' in subscription '$($Inputs.SubscriptionId)'..." -ForegroundColor Cyan
                try {
                    Invoke-EppAz provider register --namespace $provider.Namespace --subscription $Inputs.SubscriptionId --output none | Out-Null
                }
                catch {
                    throw [InvalidOperationException]::new(
                        "Could not register '$($provider.Namespace)' in subscription '$($Inputs.SubscriptionId)'. Resource-provider /register/action permission is required at subscription scope; setup will not grant it. $($_.Exception.Message)",
                        $_.Exception)
                }
                $requested[$provider.Namespace] = $true
            }
        }
        # Azure registers region by region. Do not wait for global Registered when this region is usable.
        $pending = @($providers | Where-Object {
            $_.RegistrationState -eq 'NotRegistered' -or -not (Test-EppProviderLocation $_ $Inputs.Location)
        })
        if (-not $pending.Count) {
            Invoke-EppRegistrationRetry -Operation { Assert-EppServicePlanLocation -Inputs $Inputs } | Out-Null
            return
        }
        if ($attempt -eq $MaxAttempts) {
            $states = $pending | ForEach-Object { "$($_.Namespace)=$($_.RegistrationState)" }
            throw "Required Azure resource providers did not become available for '$($Inputs.Location)' after $MaxAttempts checks: $($states -join ', '). Registrations already requested are left in place; no deployment resources were created."
        }
        Write-Host "Waiting for Azure resource providers ($attempt/$MaxAttempts): $($pending.Namespace -join ', ')" -ForegroundColor DarkGray
        Start-Sleep -Seconds 10
    }
}

function Assert-EppResourceGroup {
    param([hashtable] $Inputs, [Collections.IDictionary] $Names)

    $null = ConvertTo-EppGuid $Inputs.ApplicationId
    $groupExists = Invoke-EppAz group exists --name $Names.resourceGroup --subscription $Inputs.SubscriptionId --output tsv
    if ($groupExists -eq 'true') {
        $tags = Invoke-EppAz group show --name $Names.resourceGroup --subscription $Inputs.SubscriptionId --query tags --output json |
            ConvertFrom-Json -AsHashtable
        if (-not $tags -or $tags['eppApplicationId'] -ne $Inputs.ApplicationId -or $tags['managedBy'] -ne 'EPP-Setup') {
            throw "Resource group '$($Names.resourceGroup)' is not owned by this EPP application. Choose another prefix; existing resources will not be adopted."
        }
        if ($tags['eppLanguage'] -and $tags['eppLanguage'] -ne $Inputs.Language) {
            throw "This prefix already hosts '$($tags['eppLanguage'])'. Use a different prefix for '$($Inputs.Language)' instead of switching a running app's runtime."
        }
        Assert-EppExistingServicePlan -Inputs $Inputs -Names $Names -Tags $tags
    }
    elseif ($groupExists -ne 'false') { throw 'Azure returned an invalid resource-group existence result.' }
}

function Connect-EppContext {
    param(
        [hashtable] $Inputs, [Collections.IDictionary] $Names,
        [switch] $NonInteractive, [switch] $InstallPrerequisites, [switch] $ForceAuthentication
    )

    if ($NonInteractive -and $ForceAuthentication) {
        throw '-ForceAuthentication requires interactive device-code sign-in and cannot be combined with -NonInteractive.'
    }
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw "Azure CLI is not installed or not on PATH. Install Azure CLI, open a new PowerShell 7 window, and rerun setup."
    }
    $cliVersion = Invoke-EppAz version --output json | ConvertFrom-Json
    $minimumCliVersion = if ($Inputs.ServicePlan -eq 'FC1') { [Version]'2.60.0' } else { [Version]'2.48.1' }
    if ([Version]$cliVersion.'azure-cli' -lt $minimumCliVersion) {
        throw "Azure CLI $minimumCliVersion or newer is required for $($Inputs.ServicePlan) deployment with SCM basic authentication disabled."
    }
    Initialize-EppBicep -NonInteractive:$NonInteractive -InstallPrerequisites:$InstallPrerequisites
    $account = Connect-EppAzureAccount -Inputs $Inputs -NonInteractive:$NonInteractive `
        -ForceAuthentication:($ForceAuthentication -and -not $Inputs['AzureSelectionAuthenticated'])
    $Inputs.AzureSelectionAuthenticated = $true
    $operatorId = Get-EppArmOperatorObjectId -Inputs $Inputs
    $graphAccount = Connect-EppGraphAccount -Inputs $Inputs -NonInteractive:$NonInteractive
    $graph = $graphAccount.Context
    $graphOperator = $graphAccount.Operator
    $pendingApplication = $Inputs['NewApplicationDisplayName'] -and -not $Inputs['ApplicationId']
    $application = if ($pendingApplication) {
        [pscustomobject]@{
            Id = $null; AppId = $null; DisplayName = $Inputs.NewApplicationDisplayName
            SignInAudience = 'AzureADMyOrg'; Api = @{ RequestedAccessTokenVersion = $null }
            AppRoles = @(); IdentifierUris = @(); KeyCredentials = @(); TokenEncryptionKeyId = $null
        }
    }
    else { Get-EppApplication -Inputs $Inputs -ClientId $Inputs.ApplicationId }
    if ($application.SignInAudience -notin @('AzureADMyOrg', 'AzureADMultipleOrgs')) {
        throw 'The existing EPP application must be an organizational single- or multi-tenant app. Choose Create a new application or register a dedicated organizational app manually.'
    }
    if ($application.TokenEncryptionKeyId) { throw 'Clear tokenEncryptionKeyId manually on the endpoint app. Easy Auth requires signed, not encrypted, bearer access tokens.' }

    $endpointPrincipals = @(if (-not $pendingApplication) {
        Get-EppServicePrincipal -Inputs $Inputs -AppId $Inputs.ApplicationId -Description endpoint
    })
    $callerPrincipals = @(Get-EppServicePrincipal -Inputs $Inputs -AppId $script:MicrosoftPhoneProviderAppId -Description 'Microsoft phone-provider')
    $graphPrincipals = @(Get-EppServicePrincipal -Inputs $Inputs -AppId $script:MicrosoftGraphAppId -Description 'Microsoft Graph')
    if ($graphPrincipals.Count -ne 1) { throw 'Microsoft Graph has no unique service principal in this tenant.' }
    $graphReadRoles = @($graphPrincipals[0].AppRoles | Where-Object {
        $_.Id -eq $script:MicrosoftGraphApplicationReadAllRoleId -and $_.Value -eq 'Application.Read.All' -and
        $_.IsEnabled -and $_.AllowedMemberTypes -contains 'Application'
    })
    if ($graphReadRoles.Count -ne 1) { throw 'Microsoft Graph Application.Read.All does not match its expected enabled application role.' }

    $invokeRoles = @($application.AppRoles | Where-Object {
        $_.Id -eq $script:EppInvokeAppRoleId -or $_.Value -eq $script:EppInvokeAppRoleValue
    })
    if ($invokeRoles.Count -gt 1 -or
        ($invokeRoles.Count -eq 1 -and ($invokeRoles[0].Id -ne $script:EppInvokeAppRoleId -or
            $invokeRoles[0].Value -ne $script:EppInvokeAppRoleValue -or -not $invokeRoles[0].IsEnabled -or
            $invokeRoles[0].AllowedMemberTypes -notcontains 'Application'))) {
        throw "The endpoint application has a conflicting '$script:EppInvokeAppRoleValue' app role or role ID."
    }
    $tenantRestriction = if (-not $pendingApplication) {
        Get-EppSignInAudienceRestrictions -Inputs $Inputs -ApplicationObjectId $application.Id
    } else { $null }
    $providerRestrictionState = Get-EppProviderRestrictionState -Restriction $tenantRestriction
    $allowedTenants = @(if ($providerRestrictionState) { $providerRestrictionState.allowedTenantIds })
    $providerTenants = @($Inputs.ProviderTenantId)
    if ($Inputs['ProviderAuthentication'] -eq 'oauth') {
        $providerTenants += ConvertTo-EppGuid ([string]$Inputs['AccessTokenScopeTenant'])
    }
    $Inputs.ProviderAllowedTenantIds = @(($allowedTenants + $providerTenants) | Sort-Object -Unique)
    $version = if ($application.Api -and $application.Api.RequestedAccessTokenVersion) { [int]$application.Api.RequestedAccessTokenVersion } else { 1 }
    if ($version -notin @(1, 2)) { throw 'The endpoint application has an unsupported access-token version.' }

    if (-not $pendingApplication) { Assert-EppResourceGroup -Inputs $Inputs -Names $Names }

    $resourceProviders = @(Get-EppResourceProviders -SubscriptionId $Inputs.SubscriptionId)
    Assert-EppProviderLocations -Providers $resourceProviders -Location $Inputs.Location
    $web = $resourceProviders | Where-Object Namespace -eq 'Microsoft.Web'
    if ($web.RegistrationState -eq 'Registered') {
        try { Assert-EppServicePlanLocation -Inputs $Inputs }
        catch {
            if (-not (Test-EppRegistrationDelay $_.Exception.Message)) { throw }
            Write-Warning 'Azure resource-provider registration is still reaching this region. Availability will be checked again after approval.'
        }
    }
    return [pscustomobject]@{
        OperatorId = $operatorId; GraphOperatorId = $graphOperator.Id; GraphAccount = $graphOperator.Account
        Application = $application; TokenVersion = $version; CertificatePlan = $null
        EndpointPrincipal = $endpointPrincipals | Select-Object -First 1
        CallerPrincipal = $callerPrincipals | Select-Object -First 1
        GraphPrincipal = $graphPrincipals[0]
        InvokeRoleExists = $invokeRoles.Count -eq 1
        ProviderTenantRestricted = Test-EppProviderTenantRestriction -Restriction $tenantRestriction `
            -ProviderTenantId $Inputs.ProviderTenantId -ExpectedAllowedTenantIds $Inputs.ProviderAllowedTenantIds
        ProviderRestrictionState = $providerRestrictionState
        ResourceProviders = $resourceProviders
    }
}
