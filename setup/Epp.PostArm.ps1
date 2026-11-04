function Complete-EppConfiguration {
    param(
        [hashtable] $Inputs, $ArmState, $ProviderConfiguration, $Context,
        [string] $AssetDirectory, [string] $WorkingDirectory, [string] $OutputDirectory
    )

    $Names = $ArmState.Names
    $outputs = $ArmState.Outputs
    $issued = $ArmState.Issued
    $certificate = $issued.Certificate
    $certificatePlan = $Context.CertificatePlan
    $keyId = $certificatePlan.KeyId
    $ingressMayBeOpen = $false
    try {
        Assert-EppEncryptionReference -Inputs $Inputs -Names $Names -SecretId $issued.SecretId -KeyId $keyId
        Set-EppApplicationEndpoint -Inputs $Inputs -Context $Context -Outputs $outputs -Certificate $certificate -KeyId $keyId `
            -ConfigureFederation:($Inputs.ProviderAuthentication -eq 'oauth')
        $graphAccess = Assert-EppGraphAccess -Inputs $Inputs -Certificate $certificate -KeyId $keyId `
            -IdentifierUri $outputs.identifierUri.value -CertificatePlan $certificatePlan
        if ($Inputs.ProviderAuthentication -eq 'oauth') {
            Assert-EppOutboundFederation -Inputs $Inputs -ApplicationObjectId $Context.Application.Id `
                -OutboundPrincipalId $outputs.outboundPrincipalId.value
        }
        Assert-EppAuthentication -SiteId $ArmState.SiteId -Inputs $Inputs -Context $Context -IdentifierUri $outputs.identifierUri.value
        $ingressMayBeOpen = $true
        Set-EppPublicAccess -SiteId $ArmState.SiteId -SubscriptionId $Inputs.SubscriptionId -Access Enabled `
            -AssetDirectory $AssetDirectory -Directory $WorkingDirectory
        Assert-EppFunctionPublished -Inputs $Inputs -Names $Names
        $Inputs.PackageSha256 = $ArmState.PackageSha256
        $result = [ordered]@{
            tenantId = $Inputs.TenantId; subscriptionId = $Inputs.SubscriptionId; applicationId = $Inputs.ApplicationId
            tenantRegionScope = $Inputs['TenantRegionScope']
            provider = $ProviderConfiguration.Id
            endpointRegion = $ProviderConfiguration.EndpointRegion; providerAuthentication = $Inputs.ProviderAuthentication
            providerTenantId = $Inputs.ProviderTenantId
            accessTokenScopeTenant = if ($Inputs.ProviderAuthentication -eq 'oauth') { $Inputs['AccessTokenScopeTenant'] } else { $null }
            allowedProviderTenantIds = @($Inputs.ProviderAllowedTenantIds)
            providerSmsEndpoint = $ProviderConfiguration.Settings.EPP_PROVIDER_SMS_ENDPOINT
            providerVoiceEndpoint = $ProviderConfiguration.Settings.EPP_PROVIDER_VOICE_ENDPOINT
            resourcePrefix = $Inputs.ResourcePrefix; resources = $Names
            language = $(if ($Inputs.Language -eq 'dotnet') { 'csharp' } else { $Inputs.Language }); servicePlan = $Inputs.ServicePlan
            endpointUrl = $outputs.endpointUrl.value; identifierUri = $outputs.identifierUri.value
            encryptionKeyId = $keyId; certificateThumbprint = $certificate.Thumbprint
            certificateId = $issued.CertificateId; certificateSecretId = $issued.SecretId
            certificateExpiresUtc = $certificate.NotAfter.ToUniversalTime().ToString('o')
            certificateRenewal = 'manual'; certificateAction = $certificatePlan.Action
            certificateVaultSubscriptionId = $certificatePlan.VaultSubscriptionId
            removedEncryptionKeyIds = @($certificatePlan.RemoveKeyIds)
            certificateReferenceResolved = $true
            endpointServicePrincipalId = $graphAccess.EndpointPrincipalId
            microsoftPhoneProviderServicePrincipalId = $graphAccess.CallerPrincipalId
            eppInvokeAppRoleId = $script:EppInvokeAppRoleId
            microsoftGraphApplicationReadAll = $true
            source = $Inputs.SourceBaseUri; sourceRevision = $Inputs.SourceRevision
            packageFile = $Inputs.PackageFile; packageUrl = $Inputs.PackageUrl
            packageReleaseTag = $Inputs.PackageReleaseTag; sourcePackageSha256 = $Inputs.SourcePackageSha256
            packageSha256 = $Inputs.PackageSha256
            policyChanged = $false
        }
        $resultPath = Join-Path $OutputDirectory "deployment-$([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))-$([Guid]::NewGuid().ToString('N').Substring(0, 8)).json"
        $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resultPath -Encoding utf8NoBOM
        Show-EppDeploymentResult -Inputs $Inputs -Names $Names -ProviderConfiguration $ProviderConfiguration `
            -EndpointUrl $outputs.endpointUrl.value -ResultPath $resultPath
        return [pscustomobject]$result
    }
    catch {
        $configurationError = $_
        if ($ingressMayBeOpen) {
            try {
                Set-EppPublicAccess -SiteId $ArmState.SiteId -SubscriptionId $Inputs.SubscriptionId -Access Disabled `
                    -AssetDirectory $AssetDirectory -Directory $WorkingDirectory
            }
            catch {
                throw [AggregateException]::new('Configuration failed and public ingress could not be disabled. Inspect the Function App immediately.',
                    [Exception[]]@($configurationError.Exception, $_.Exception))
            }
        }
        throw $configurationError
    }
}

function Assert-EppGraphAccess {
    param(
        [hashtable] $Inputs, $Certificate, [string] $KeyId, [string] $IdentifierUri,
        [Collections.IDictionary] $CertificatePlan
    )

    $application = Get-EppApplication -Inputs $Inputs -ClientId $Inputs.ApplicationId
    $tenantRestriction = Get-EppSignInAudienceRestrictions -Inputs $Inputs -ApplicationObjectId $application.Id
    $invokeRoles = @($application.AppRoles | Where-Object {
        $_.Id -eq $script:EppInvokeAppRoleId -and $_.Value -eq $script:EppInvokeAppRoleValue -and
        $_.IsEnabled -and $_.AllowedMemberTypes -contains 'Application'
    })
    Assert-EppApplicationEncryption -Application $application -Certificate $Certificate -KeyId $KeyId -Plan $CertificatePlan
    if ($application.SignInAudience -ne 'AzureADMultipleOrgs' -or $application.TokenEncryptionKeyId -or
        $application.IdentifierUris -notcontains $IdentifierUri -or $invokeRoles.Count -ne 1) {
        throw 'Endpoint application readback is missing its multi-tenant setting, identifier URI, Epp.Invoke role, or encryption certificate.'
    }
    if (-not (Test-EppProviderTenantRestriction -Restriction $tenantRestriction -ProviderTenantId $Inputs.ProviderTenantId -ExpectedAllowedTenantIds $Inputs.ProviderAllowedTenantIds)) {
        throw 'Endpoint application readback does not restrict the multi-tenant app to the selected provider tenant.'
    }

    $endpointPrincipal = Get-EppServicePrincipal -Inputs $Inputs -AppId $Inputs.ApplicationId -Description 'endpoint'
    $callerPrincipal = Get-EppServicePrincipal -Inputs $Inputs -AppId $script:MicrosoftPhoneProviderAppId -Description 'Microsoft phone-provider'
    $graphPrincipal = Get-EppServicePrincipal -Inputs $Inputs -AppId $script:MicrosoftGraphAppId -Description 'Microsoft Graph'
    if (-not $endpointPrincipal -or -not $endpointPrincipal.AppRoleAssignmentRequired -or
        -not $callerPrincipal -or $callerPrincipal.AccountEnabled -eq $false -or -not $graphPrincipal) {
        throw 'Service-principal readback is incomplete or the endpoint does not require app-role assignment.'
    }
    $assignments = @(Get-EppAppRoleAssignments -Inputs $Inputs -PrincipalId $callerPrincipal.Id)
    $endpointAssignments = @($assignments | Where-Object {
        $_.ResourceId -eq $endpointPrincipal.Id -and $_.AppRoleId -eq $script:EppInvokeAppRoleId
    })
    $graphAssignments = @($assignments | Where-Object {
        $_.ResourceId -eq $graphPrincipal.Id -and $_.AppRoleId -eq $script:MicrosoftGraphApplicationReadAllRoleId
    })
    if ($endpointAssignments.Count -ne 1 -or $graphAssignments.Count -ne 1) {
        throw 'Microsoft phone-provider readback is missing Epp.Invoke or Microsoft Graph Application.Read.All.'
    }
    return [pscustomobject]@{
        EndpointPrincipalId = [string]$endpointPrincipal.Id
        CallerPrincipalId = [string]$callerPrincipal.Id
        GraphPrincipalId = [string]$graphPrincipal.Id
    }
}

function Set-EppApplicationEndpoint {
    param([hashtable] $Inputs, $Context, $Outputs, $Certificate, [string] $KeyId, [bool] $ConfigureFederation = $true)

    $application = Get-EppApplication -Inputs $Inputs -ObjectId $Context.Application.Id
    if ($application.AppId -ne $Inputs.ApplicationId -or $application.SignInAudience -ne 'AzureADMultipleOrgs' -or $application.TokenEncryptionKeyId) {
        throw 'The application changed after preflight. Its identity, audience, and signed-token configuration must still match.'
    }
    $plan = $Context.CertificatePlan
    Assert-EppCertificatePlanUnchanged -Application $application -Plan $plan
    if ($KeyId -ne $plan.KeyId) { throw 'The encryption key ID does not match the approved certificate plan.' }
    $encryptionKeys = @($application.KeyCredentials | Where-Object { $_ -and $_.Usage -eq 'Encrypt' })
    if ($plan.Action -eq 'Reuse') {
        $selected = @($encryptionKeys | Where-Object { [string]$_.KeyId -eq $KeyId })
        if ($selected.Count -ne 1 -or -not $selected[0].Key -or
            [Convert]::ToBase64String([byte[]]$selected[0].Key) -cne [Convert]::ToBase64String($Certificate.RawData)) {
            throw 'The certificate no longer matches the selected encryption credential. No credentials were removed.'
        }
        $key = $selected[0]
    }
    elseif ($plan.Action -in @('Create', 'Replace')) {
        if (@($application.KeyCredentials | Where-Object { $_ -and [string]$_.KeyId -eq $KeyId }).Count) {
            throw 'The new encryption key ID is already registered. Rerun setup and review a new plan.'
        }
        $key = @{
            CustomKeyIdentifier = $Certificate.GetCertHash()
            DisplayName = $Certificate.Subject
            Key = $Certificate.GetRawCertData()
            KeyId = $KeyId
            Type = 'AsymmetricX509Cert'
            Usage = 'Encrypt'
            StartDateTime = $Certificate.NotBefore.ToUniversalTime()
            EndDateTime = $Certificate.NotAfter.ToUniversalTime()
        }
    }
    else { throw 'An approved Create, Reuse, or Replace certificate action is required.' }
    $removedIds = @($encryptionKeys | Where-Object { [string]$_.KeyId -ne $KeyId } | ForEach-Object { [string]$_.KeyId } | Sort-Object)
    if (($removedIds -join ',') -cne (@($plan.RemoveKeyIds | Sort-Object) -join ',')) {
        throw 'The encryption credentials to remove do not match the approved plan. No credentials were removed.'
    }
    $uris = @($application.IdentifierUris | Where-Object { $_ })
    if ($uris -notcontains $Outputs.identifierUri.value) { $uris += $Outputs.identifierUri.value }
    $keys = @($application.KeyCredentials | Where-Object { $_ -and $_.Usage -ne 'Encrypt' })
    if (@($keys | Where-Object { -not $_.Key }).Count) {
        throw 'A non-encryption credential is unreadable and cannot be safely preserved. No credentials were removed.'
    }
    $keys += $key
    # Do not set tokenEncryptionKeyId: JWE payload encryption is separate from bearer-token encryption.
    Invoke-EppGraphRequest -Inputs $Inputs -Method PATCH -Path "/v1.0/applications/$($application.Id)" -Body @{
        identifierUris = $uris
        keyCredentials = @(ConvertTo-EppGraphKeyCredentials -Credentials $keys)
    } | Out-Null
    if (-not $ConfigureFederation) { return }

    $issuer = "https://login.microsoftonline.com/$($Inputs.TenantId)/v2.0"
    $audience = 'api://AzureADTokenExchange'
    $credentialName = "epp-$($Outputs.outboundPrincipalId.value)-outbound"
    $credentials = Invoke-EppDirectoryCommand -Inputs $Inputs -Arguments @('ad', 'app', 'federated-credential', 'list', '--id', $application.Id)
    if ($credentials -isnot [Array]) { throw 'Azure CLI returned an invalid federated-credential list.' }
    $credentials = @($credentials | ForEach-Object { [pscustomobject]$_ })
    $matching = @($credentials | Where-Object {
        $_.Issuer -ceq $issuer -and $_.Subject -ceq $Outputs.outboundPrincipalId.value -and
        @($_.Audiences).Count -eq 1 -and $_.Audiences[0] -ceq $audience
    })
    if (-not $matching.Count) {
        if (@($credentials | Where-Object Name -eq $credentialName).Count) {
            throw "The outbound federated credential '$credentialName' is already used for a different trust. Expected issuer '$issuer', subject '$($Outputs.outboundPrincipalId.value)', and audience '$audience'. It will not be overwritten."
        }
        New-EppFederatedCredential -Inputs $Inputs -ObjectId $application.Id -Credential @{
            name = $credentialName; issuer = $issuer; subject = $Outputs.outboundPrincipalId.value; audiences = @($audience)
        }
    }
}

function Assert-EppOutboundFederation {
    param([hashtable] $Inputs, [string] $ApplicationObjectId, [string] $OutboundPrincipalId)

    $issuer = "https://login.microsoftonline.com/$($Inputs.TenantId)/v2.0"
    for ($attempt = 1; $attempt -le 6; $attempt++) {
        $credentials = Invoke-EppDirectoryCommand -Inputs $Inputs -Arguments @(
            'ad', 'app', 'federated-credential', 'list', '--id', $ApplicationObjectId)
        if ($credentials -isnot [array] -or @($credentials | Where-Object { $_ -isnot [Collections.IDictionary] }).Count) {
            throw 'Azure CLI returned invalid outbound federation metadata. Ingress will not be opened.'
        }
        $matching = @($credentials | Where-Object {
            $_['issuer'] -ceq $issuer -and $_['subject'] -ceq $OutboundPrincipalId -and
            @($_['audiences']).Count -eq 1 -and $_['audiences'][0] -ceq 'api://AzureADTokenExchange'
        })
        if ($matching.Count -eq 1) { return }
        if ($attempt -lt 6) { Start-Sleep -Seconds 10 }
    }
    throw 'Outbound federation readback does not match the approved identity, issuer, and audience. Ingress will not be opened.'
}

function Assert-EppAuthentication {
    param([string] $SiteId, [hashtable] $Inputs, $Context, [string] $IdentifierUri)

    $auth = Invoke-EppAz rest --method get --url "https://management.azure.com$SiteId/config/authsettingsV2?api-version=2024-04-01" `
        --subscription $Inputs.SubscriptionId --output json | ConvertFrom-Json -AsHashtable
    $properties = $auth['properties']
    if ($properties -isnot [Collections.IDictionary]) { throw 'Easy Auth readback is missing. Ingress will not be opened.' }
    foreach ($name in @('platform', 'globalValidation', 'httpSettings', 'identityProviders')) {
        if ($properties[$name] -isnot [Collections.IDictionary]) { throw 'Easy Auth readback is incomplete. Ingress will not be opened.' }
    }
    $aad = $properties['identityProviders']['azureActiveDirectory']
    if ($aad -isnot [Collections.IDictionary] -or $aad['registration'] -isnot [Collections.IDictionary] -or
        $aad['validation'] -isnot [Collections.IDictionary] -or
        $aad['validation']['defaultAuthorizationPolicy'] -isnot [Collections.IDictionary]) {
        throw 'The Entra identity provider is incomplete. Ingress will not be opened.'
    }
    $expectedIssuer = if ($Context.TokenVersion -eq 2) { "https://login.microsoftonline.com/$($Inputs.TenantId)/v2.0" } else { "https://sts.windows.net/$($Inputs.TenantId)/" }
    $expectedAudience = if ($Context.TokenVersion -eq 2) { $Inputs.ApplicationId } else { $IdentifierUri }
    $callers = @($aad['validation']['defaultAuthorizationPolicy']['allowedApplications'])
    $audiences = @($aad['validation']['allowedAudiences'])
    if (-not $properties['platform']['enabled'] -or -not $properties['globalValidation']['requireAuthentication'] -or
        $properties['globalValidation']['unauthenticatedClientAction'] -ne 'Return401' -or
        @($properties['globalValidation']['excludedPaths'] | Where-Object { $_ }).Count -ne 0 -or
        -not $properties['httpSettings']['requireHttps'] -or -not $aad['enabled'] -or
        $aad['registration']['clientId'] -ne $Inputs.ApplicationId -or $aad['registration']['openIdIssuer'] -cne $expectedIssuer -or
        $callers.Count -ne 1 -or $callers[0] -ne $script:MicrosoftPhoneProviderAppId -or
        $audiences.Count -ne 1 -or $audiences[0] -cne $expectedAudience) {
        throw 'Easy Auth readback does not match the approved tenant, audience, and caller restrictions. Ingress will not be opened.'
    }
}

function Assert-EppFunctionPublished {
    param([hashtable] $Inputs, [Collections.IDictionary] $Names)

    for ($attempt = 1; $attempt -le 6; $attempt++) {
        $functions = @(Invoke-EppAz functionapp function list --resource-group $Names.resourceGroup --name $Names.functionApp `
            --subscription $Inputs.SubscriptionId --output json | ConvertFrom-Json)
        if (@($functions | Where-Object { $_ -and $_.name -match '(^|/)SendOtp$' }).Count -eq 1) { return }
        if ($attempt -lt 6) { Start-Sleep -Seconds 10 }
    }
    throw 'The package was published but Azure did not register SendOtp. Inspect the Function runtime/build logs; deployment is not complete.'
}
