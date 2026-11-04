function Initialize-EppApplication {
    param(
        [hashtable] $Inputs, [Collections.IDictionary] $Names, $ProviderConfiguration, $Context,
        [string] $OutputDirectory
    )

    $graphOperator = Get-EppGraphOperator -Inputs $Inputs
    if ($graphOperator.Id -ne $Context.GraphOperatorId -or
        (Get-EppArmOperatorObjectId -Inputs $Inputs) -ne $Context.OperatorId) {
        throw 'The Azure CLI user changed after the plan was reviewed. Rerun setup.'
    }
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    if ($Inputs['NewApplicationDisplayName'] -and -not $Inputs['ApplicationId']) {
        $application = New-EppApplication -Inputs $Inputs -DisplayName $Inputs.NewApplicationDisplayName
        $Inputs.ApplicationId = $application.AppId
        $Context.Application = $application
        Write-Host "`nCreated app registration: $($application.DisplayName)" -ForegroundColor Cyan
        Write-Host "Application (client) ID: $($Inputs.ApplicationId)"
        Write-Host "For reruns, use -ApplicationId '$($Inputs.ApplicationId)' -ResourcePrefix '$($Inputs.ResourcePrefix)' instead of creating another application." -ForegroundColor Yellow

        $Names = Get-EppResourceNames -SubscriptionId $Inputs.SubscriptionId -ApplicationId $Inputs.ApplicationId -ResourcePrefix $Inputs.ResourcePrefix
        $Context.CertificatePlan.VaultName = $Names.keyVault
        $Context.CertificatePlan.VaultResourceId = "/subscriptions/$($Inputs.SubscriptionId)/resourceGroups/$($Names.resourceGroup)/providers/Microsoft.KeyVault/vaults/$($Names.keyVault)"
        $applicationPath = Join-Path $OutputDirectory "application-$($Inputs.ApplicationId).json"
        [ordered]@{
            tenantId = $Inputs.TenantId; subscriptionId = $Inputs.SubscriptionId
            applicationId = $Inputs.ApplicationId; applicationObjectId = $application.Id
            displayName = $application.DisplayName; provider = $ProviderConfiguration.Id
            resourcePrefix = $Inputs.ResourcePrefix; resources = $Names
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $applicationPath -Encoding utf8NoBOM
        Write-Host "Application registration details saved to: $applicationPath"
        Assert-EppResourceGroup -Inputs $Inputs -Names $Names
        Write-Host "`nResolved Azure resource names" -ForegroundColor Cyan
        Get-EppResourceRows -Names $Names -ServicePlan $Inputs.ServicePlan |
            Format-Table Resource, Name, Description -AutoSize | Out-String -Width 240 | Write-Host
    }
    $graphAccess = Initialize-EppGraphAccess -Inputs $Inputs -Context $Context
    return [pscustomobject]@{ Names = $Names; GraphAccess = $graphAccess }
}

function Get-EppSignInAudienceRestrictions {
    param([hashtable] $Inputs, [string] $ApplicationObjectId)

    $result = Invoke-EppGraphRequest -Inputs $Inputs -Path "/beta/applications/$ApplicationObjectId" `
        -Query @{ '$select' = 'id,signInAudience,signInAudienceRestrictions' }
    return $result.signInAudienceRestrictions
}

function Get-EppProviderRestrictionState {
    param($Restriction)

    if ($null -eq $Restriction) { return $null }
    $unsupported = 'The application has an unsupported provider-tenant restriction. Review it before running setup.'
    if ($Restriction -isnot [Collections.IDictionary]) { throw $unsupported }
    $kind = $Restriction['kind']
    $odataType = $Restriction['@odata.type']
    if (($null -ne $kind -and $kind -isnot [string]) -or
        ($null -ne $odataType -and $odataType -isnot [string])) { throw $unsupported }
    if ($null -ne $odataType) {
        $typeKind = switch -CaseSensitive ($odataType) {
            '#microsoft.graph.unrestrictedAudience' { 'unrestricted' }
            '#microsoft.graph.allowedTenantsAudience' { 'allowedTenants' }
            default { throw $unsupported }
        }
        if ($null -ne $kind -and $kind -cne $typeKind) { throw $unsupported }
        $kind = $typeKind
    }
    if ($kind -ceq 'unrestricted') {
        if ($Restriction.Contains('allowedTenantIds') -or $Restriction.Contains('isHomeTenantAllowed')) { throw $unsupported }
        # The pre-creation plan uses null for this same unconfigured state.
        return $null
    }
    if ($kind -cne 'allowedTenants' -or
        $Restriction['isHomeTenantAllowed'] -isnot [bool] -or $Restriction['allowedTenantIds'] -isnot [Array]) {
        throw $unsupported
    }
    $ids = @($Restriction.allowedTenantIds | ForEach-Object { ConvertTo-EppGuid ([string]$_) })
    $unique = @($ids | Sort-Object -Unique)
    if ($unique.Count -ne $ids.Count) { throw 'The application contains duplicate allowed provider tenants.' }
    return @{
        kind = 'allowedTenants'; isHomeTenantAllowed = $Restriction.isHomeTenantAllowed
        allowedTenantIds = $unique
    }
}

function Test-EppProviderTenantRestriction {
    param($Restriction, [string] $ProviderTenantId, [string[]] $ExpectedAllowedTenantIds)

    $state = Get-EppProviderRestrictionState -Restriction $Restriction
    if (-not $state -or -not $state.isHomeTenantAllowed -or $state.allowedTenantIds -notcontains $ProviderTenantId) { return $false }
    if ($ExpectedAllowedTenantIds) {
        return ($state.allowedTenantIds -join ',') -ceq (@($ExpectedAllowedTenantIds | Sort-Object -Unique) -join ',')
    }
    return $true
}

function Set-EppProviderTenantRestriction {
    param([hashtable] $Inputs, [string] $ApplicationObjectId, [string] $ProviderTenantId, [string[]] $AllowedTenantIds)

    $ids = if ($AllowedTenantIds) { @($AllowedTenantIds | ForEach-Object { ConvertTo-EppGuid $_ } | Sort-Object -Unique) } else { @(ConvertTo-EppGuid $ProviderTenantId) }
    if ($ids -notcontains $ProviderTenantId) { throw 'The approved tenant allowlist does not contain the selected provider.' }

    Invoke-EppGraphRequest -Inputs $Inputs -Method PATCH -Path "/beta/applications/$ApplicationObjectId" `
        -Body @{
            signInAudience = 'AzureADMultipleOrgs'
            signInAudienceRestrictions = @{
                '@odata.type' = '#microsoft.graph.allowedTenantsAudience'
                kind = 'allowedTenants'
                isHomeTenantAllowed = $true
                allowedTenantIds = @($ids)
            }
        } | Out-Null
}

function Get-EppServicePrincipal {
    param([hashtable] $Inputs, [string] $AppId, [string] $Description)

    $AppId = ConvertTo-EppGuid $AppId
    $principals = Invoke-EppDirectoryCommand -Inputs $Inputs -Arguments @('ad', 'sp', 'list', '--filter', "appId eq '$AppId'")
    if ($principals -isnot [Array]) { throw 'Azure CLI returned an invalid service-principal list.' }
    if ($principals.Count -gt 1) { throw "Multiple $Description service principals match app ID '$AppId'." }
    if ($principals.Count -and ($principals[0]['appId'] -ine $AppId -or -not $principals[0]['id'])) {
        throw "The $Description service principal does not match its requested app ID."
    }
    if ($principals.Count) {
        return ConvertFrom-EppGraphServicePrincipal -Principal $principals[0]
    }
}

function Ensure-EppServicePrincipal {
    param([hashtable] $Inputs, [string] $AppId, [string] $Description)

    $principal = Get-EppServicePrincipal -Inputs $Inputs -AppId $AppId -Description $Description
    if (-not $principal) {
        $created = Invoke-EppDirectoryCommand -Inputs $Inputs -Arguments @('ad', 'sp', 'create', '--id', $AppId)
        $principal = ConvertFrom-EppGraphServicePrincipal -Principal $created
    }
    if (-not $principal -or $principal.AppId -ne $AppId -or -not $principal.Id -or $principal.AccountEnabled -eq $false) {
        throw "The $Description service principal is missing, disabled, or does not match app ID '$AppId'."
    }
    return $principal
}

function Ensure-EppAppRoleAssignment {
    param([hashtable] $Inputs, $Principal, $Resource, [string] $AppRoleId, [string] $Description)

    $assignments = @(Get-EppAppRoleAssignments -Inputs $Inputs -PrincipalId $Principal.Id)
    $matching = @($assignments | Where-Object { $_.ResourceId -eq $Resource.Id -and $_.AppRoleId -eq $AppRoleId })
    if ($matching.Count -gt 1) { throw "Multiple $Description app-role assignments exist for the Microsoft phone-provider service principal." }
    if (-not $matching.Count) {
        for ($attempt = 1; $attempt -le 12; $attempt++) {
            try {
                Invoke-EppGraphRequest -Inputs $Inputs -Method POST -Path "/v1.0/servicePrincipals/$($Principal.Id)/appRoleAssignments" -Body @{
                    principalId = $Principal.Id
                    resourceId = $Resource.Id
                    appRoleId = $AppRoleId
                } | Out-Null
                break
            }
            catch {
                $transient = $_.Exception.Message -match 'Request_ResourceNotFound|Permission being assigned was not found|does not reference a valid application role'
                if ($attempt -eq 12 -or -not $transient) { throw }
                Write-Warning "Waiting for the new $Description application role to propagate ($attempt/12)."
                Start-Sleep -Seconds 5
            }
        }
    }
}

function Initialize-EppGraphAccess {
    param([hashtable] $Inputs, $Context)

    for ($attempt = 1; $attempt -le 12; $attempt++) {
        try {
            $application = Get-EppApplication -Inputs $Inputs -ObjectId $Context.Application.Id
            break
        }
        catch {
            if (-not $Inputs['NewApplicationDisplayName'] -or $attempt -eq 12 -or
                $_.Exception.Message -notmatch 'Request_ResourceNotFound|ResourceNotFound') { throw }
            Write-Warning "Waiting for the new app registration to propagate ($attempt/12)."
            Start-Sleep -Seconds 5
        }
    }
    if ($application.AppId -ne $Inputs.ApplicationId -or
        $application.SignInAudience -notin @('AzureADMyOrg', 'AzureADMultipleOrgs') -or
        $application.SignInAudience -cne $Context.Application.SignInAudience -or
        $application.TokenEncryptionKeyId) {
        throw 'The dedicated endpoint application changed after preflight or has unsupported token encryption enabled.'
    }
    Assert-EppCertificatePlanUnchanged -Application $application -Plan $Context.CertificatePlan
    $restriction = Get-EppSignInAudienceRestrictions -Inputs $Inputs -ApplicationObjectId $application.Id
    $currentProviderState = Get-EppProviderRestrictionState -Restriction $restriction
    if (-not (Test-EppJsonEqual $currentProviderState $Context.ProviderRestrictionState)) {
        throw 'The application provider configuration changed after the plan was reviewed. Rerun setup; no provider tenants will be removed.'
    }
    if (-not $Inputs['ProviderAllowedTenantIds']) { throw 'The approved provider-tenant allowlist is missing. Rerun preflight.' }
    $roles = @($application.AppRoles | Where-Object { $null -ne $_ })
    $invokeRoles = @($roles | Where-Object { $_.Id -eq $script:EppInvokeAppRoleId -or $_.Value -eq $script:EppInvokeAppRoleValue })
    if ($invokeRoles.Count -gt 1 -or
        ($invokeRoles.Count -eq 1 -and ($invokeRoles[0].Id -ne $script:EppInvokeAppRoleId -or
            $invokeRoles[0].Value -ne $script:EppInvokeAppRoleValue -or -not $invokeRoles[0].IsEnabled -or
            $invokeRoles[0].AllowedMemberTypes -notcontains 'Application'))) {
        throw "The endpoint application has a conflicting '$script:EppInvokeAppRoleValue' role."
    }
    if (-not $invokeRoles.Count) {
        $roles += @{
            allowedMemberTypes = @('Application')
            description = 'Allows the Microsoft phone-provider application to invoke this EPP endpoint.'
            displayName = 'Invoke EPP endpoint'
            id = $script:EppInvokeAppRoleId
            isEnabled = $true
            value = $script:EppInvokeAppRoleValue
        }
    }
    if (-not $invokeRoles.Count) {
        Invoke-EppGraphRequest -Inputs $Inputs -Method PATCH -Path "/v1.0/applications/$($application.Id)" -Body @{ appRoles = $roles } | Out-Null
    }
    if ($application.SignInAudience -ne 'AzureADMultipleOrgs' -or
        -not (Test-EppProviderTenantRestriction -Restriction $restriction -ProviderTenantId $Inputs.ProviderTenantId -ExpectedAllowedTenantIds $Inputs.ProviderAllowedTenantIds)) {
        Set-EppProviderTenantRestriction -Inputs $Inputs -ApplicationObjectId $application.Id -ProviderTenantId $Inputs.ProviderTenantId `
            -AllowedTenantIds $Inputs.ProviderAllowedTenantIds
    }

    $endpointPrincipal = Ensure-EppServicePrincipal -Inputs $Inputs -AppId $Inputs.ApplicationId -Description 'endpoint'
    if (-not $endpointPrincipal.AppRoleAssignmentRequired) {
        Invoke-EppGraphRequest -Inputs $Inputs -Method PATCH -Path "/v1.0/servicePrincipals/$($endpointPrincipal.Id)" `
            -Body @{ appRoleAssignmentRequired = $true } | Out-Null
        $endpointPrincipal = Get-EppServicePrincipal -Inputs $Inputs -AppId $Inputs.ApplicationId -Description 'endpoint'
    }
    if (-not $endpointPrincipal.AppRoleAssignmentRequired) {
        throw 'The endpoint service principal did not enable app-role assignment requirements.'
    }

    $callerPrincipal = Ensure-EppServicePrincipal -Inputs $Inputs -AppId $script:MicrosoftPhoneProviderAppId -Description 'Microsoft phone-provider'
    $graphPrincipal = Get-EppServicePrincipal -Inputs $Inputs -AppId $script:MicrosoftGraphAppId -Description 'Microsoft Graph'
    if (-not $graphPrincipal) { throw 'Microsoft Graph service principal is missing from the tenant.' }
    $graphReadRoles = @($graphPrincipal.AppRoles | Where-Object {
        $_.Id -eq $script:MicrosoftGraphApplicationReadAllRoleId -and $_.Value -eq 'Application.Read.All' -and
        $_.IsEnabled -and $_.AllowedMemberTypes -contains 'Application'
    })
    if ($graphReadRoles.Count -ne 1) { throw 'Microsoft Graph Application.Read.All does not match its expected application role.' }

    Ensure-EppAppRoleAssignment -Inputs $Inputs -Principal $callerPrincipal -Resource $endpointPrincipal `
        -AppRoleId $script:EppInvokeAppRoleId -Description $script:EppInvokeAppRoleValue
    try {
        Ensure-EppAppRoleAssignment -Inputs $Inputs -Principal $callerPrincipal -Resource $graphPrincipal `
            -AppRoleId $script:MicrosoftGraphApplicationReadAllRoleId -Description 'Microsoft Graph Application.Read.All'
    }
    catch {
        if ($_.Exception.Message -match 'Authorization_RequestDenied|Insufficient privileges|Forbidden') {
            throw 'The current Azure CLI Graph session is not authorized to grant Application.Read.All. Its effective Graph permissions must allow app-role assignment, and the signed-in user normally needs an active Privileged Role Administrator role. Azure subscription roles alone are insufficient.'
        }
        throw
    }

    return [pscustomobject]@{
        EndpointPrincipalId = [string]$endpointPrincipal.Id
        CallerPrincipalId = [string]$callerPrincipal.Id
        GraphPrincipalId = [string]$graphPrincipal.Id
    }
}
