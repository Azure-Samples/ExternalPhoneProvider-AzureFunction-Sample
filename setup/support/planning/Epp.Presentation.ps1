function Get-EppResourceRows {
    param([Collections.IDictionary] $Names, [ValidateSet('FC1', 'EP1')][string] $ServicePlan)

    $planDescription = if ($ServicePlan -eq 'FC1') {
        'Linux Flex Consumption FC1, 2048 MB, up to 40 on-demand instances, zero always-ready instances.'
    } else { 'Linux Premium EP1 compute with one warm instance for the Function App.' }

    return @(
        [pscustomobject]@{ Resource = 'Resource group'; Name = $Names.resourceGroup; Description = 'Contains all Azure resources created by this deployment.' }
        [pscustomobject]@{ Resource = 'Function App'; Name = $Names.functionApp; Description = 'Hosts the External Phone Provider endpoint.' }
        [pscustomobject]@{ Resource = 'Hosting plan'; Name = $Names.hostingPlan; Description = $planDescription }
        [pscustomobject]@{ Resource = 'Storage account'; Name = $Names.storageAccount; Description = 'Provides Function host storage and private package storage.' }
        [pscustomobject]@{ Resource = 'Blob container'; Name = 'packages'; Description = 'Private deployment storage for Flex Consumption.' }
        [pscustomobject]@{ Resource = 'Key Vault'; Name = $Names.keyVault; Description = 'Stores provider credentials and newly issued encryption certificates.' }
        [pscustomobject]@{ Resource = 'Function App identity'; Name = 'System-assigned'; Description = 'Accesses package storage, host storage, Key Vault, and monitoring.' }
        [pscustomobject]@{ Resource = 'Outbound identity'; Name = $Names.outboundIdentity; Description = 'Supports outbound provider authentication when required.' }
        [pscustomobject]@{ Resource = 'Setup identity'; Name = "$($Names.outboundIdentity)-setup"; Description = 'Runs ARM-hosted certificate operations without private-key retrieval.' }
        [pscustomobject]@{ Resource = 'Log Analytics'; Name = $Names.logAnalytics; Description = 'Stores platform and application diagnostic logs.' }
        [pscustomobject]@{ Resource = 'Application Insights'; Name = $Names.applicationInsights; Description = 'Collects Function App telemetry.' }
        [pscustomobject]@{ Resource = 'Diagnostic settings'; Name = 'Configured'; Description = 'Routes supported resource logs and metrics to Log Analytics.' }
    )
}

function Show-EppPlan {
    param([hashtable] $Inputs, [Collections.IDictionary] $Names, $ProviderConfiguration, $Context)

    Write-Host "`nDeployment plan (create or update)" -ForegroundColor Cyan
    Write-Host "Tenant:       $($Inputs.TenantId)"
    Write-Host "Subscription: $($Inputs.SubscriptionId)"
    if ($Inputs['NewApplicationDisplayName'] -and -not $Inputs['ApplicationId']) {
        Write-Host "Application:  Create '$($Inputs.NewApplicationDisplayName)' after approval (client ID not yet assigned)"
    }
    else { Write-Host "Application:  $($Inputs.ApplicationId)" }
    Write-Host "Location:     $($Inputs.Location)"
    Write-Host "Language:     $($Inputs.Platform)"
    Write-Host "Service plan: $($Inputs.ServicePlan)"
    Write-Host "Provider:     $($ProviderConfiguration.DisplayName)"
    Write-Host 'Channels:     SMS and voice (selected by each request)'
    if ($Inputs['TenantRegionScope']) { Write-Host "Tenant replication scope: $($Inputs.TenantRegionScope)" }
    $providerRoute = if ($ProviderConfiguration.EndpointRegion -eq 'eu') { 'EU' } else { 'Global' }
    Write-Host "Provider route: $providerRoute"
    Write-Host "Provider auth: $($ProviderConfiguration.AuthenticationMode)"
    Write-Host "Security Store tenant: $($ProviderConfiguration.TenantId)"
    if ($Inputs['ProviderAllowedTenantIds']) {
        Write-Host "Allowed provider tenants after deployment: $($Inputs.ProviderAllowedTenantIds -join ', ') (home tenant also allowed)"
        Write-Host 'Existing allowed provider tenants are preserved; selecting a provider does not configure multi-provider runtime fallback.'
    }
    Write-Host "SMS endpoint: $($ProviderConfiguration.Settings.EPP_PROVIDER_SMS_ENDPOINT)"
    Write-Host "Voice endpoint: $($ProviderConfiguration.Settings.EPP_PROVIDER_VOICE_ENDPOINT)"
    Write-Host 'Per-channel routing requires a Function package that reads EPP_PROVIDER_SMS_ENDPOINT and EPP_PROVIDER_VOICE_ENDPOINT.' -ForegroundColor Yellow
    if ($ProviderConfiguration.AuthenticationMode -eq 'oauth') {
        Write-Host "Access-token tenant: $($ProviderConfiguration.AccessTokenScopeTenant)"
        Write-Host "Provider API: $($ProviderConfiguration.Settings.EPP_PROVIDER_APP_ID) / $($ProviderConfiguration.Settings.EPP_PROVIDER_SCOPE)"
    }
    else {
        $auth = $ProviderConfiguration.Manifest.deployment.authentication
        Write-Host "Key Vault:    $($auth.keyVaultSecretName), $($auth.identityKeyVaultSecretName)"
    }
    Write-Host "Timeout:      $($ProviderConfiguration.Settings.EPP_PROVIDER_TIMEOUT_MS) ms"
    Write-Host "Retry:        $($ProviderConfiguration.Settings.EPP_PROVIDER_RETRY_INTERVAL_MS) ms (package-dependent; not a retry guarantee)"
    Write-Host "Package:      $($Inputs.PackageUrl)"
    Write-Host "Release:      $($Inputs.PackageReleaseTag)"
    Write-Host "Source hash:  $($Inputs.SourcePackageSha256) (verified automatically)"
    Write-Host "Setup source: $($Inputs.SourceBaseUri)"

    Write-Host "`nAzure resources and configuration" -ForegroundColor Cyan
    Get-EppResourceRows -Names $Names -ServicePlan $Inputs.ServicePlan |
        Format-Table Resource, Name, Description -AutoSize | Out-String -Width 240 | Write-Host
    if ($Inputs['NewApplicationDisplayName'] -and -not $Inputs['ApplicationId']) {
        Write-Host '  - <app-id-hash> is a name placeholder, not an actual resource name. The new client ID determines the eight-character suffix after approval.'
        Write-Host '  - Final resource names and ownership are checked before Azure resource deployment. Reruns use the new client ID and this same prefix.'
    }
    Write-Host '  - Required Azure resource providers are checked before deployment; existing registrations are reused.'
    $Context.ResourceProviders | Select-Object Namespace, RegistrationState | Format-Table -AutoSize | Out-String -Width 200 | Write-Host

    Write-Host "`nAccess and permissions" -ForegroundColor Cyan
    Write-Host '  - Function App managed identity:'
    Write-Host '      Storage Blob Data Owner - access the private deployment package.'
    Write-Host '      Storage Queue Data Contributor and Storage Table Data Contributor - use Azure Functions host storage.'
    Write-Host '      Key Vault Secrets User - read provider credentials and the encryption private key.'
    Write-Host '      Monitoring Metrics Publisher - publish platform metrics.'
    Write-Host '  - Dedicated setup managed identity, scoped to this Key Vault:'
    Write-Host '      Key Vault Certificates Officer - issue and inspect the encryption certificate.'
    Write-Host '      Key Vault Reader - inspect certificate backing-secret metadata, not private keys.'
    Write-Host '      ARM-hosted certificate execution uses temporary Container Instances and supporting storage (additional permissions, quota, and charges).'
    if ($Inputs['NewApplicationDisplayName'] -and -not $Inputs['ApplicationId']) {
        Write-Host "  - Create a dedicated Microsoft Entra app registration named '$($Inputs.NewApplicationDisplayName)' in the selected tenant."
        Write-Host '      No client secret or redirect URI is created. An existing app with the same name is not adopted.'
    }
    if ($Context.Application.SignInAudience -ne 'AzureADMultipleOrgs') {
        Write-Host '  - Change the endpoint application from single-tenant to organizational multi-tenant.'
    }
    if (-not $Context.InvokeRoleExists) {
        Write-Host "  - Add the '$script:EppInvokeAppRoleValue' application permission to the endpoint application."
    }
    Write-Host '  - Create or reuse the Microsoft phone-provider enterprise application:'
    Write-Host "      $script:EppInvokeAppRoleValue - allows Microsoft to obtain an access token and call the Azure Function endpoint."
    Write-Host '      Microsoft Graph Application.Read.All - allows Microsoft to read the public encryption key from the endpoint application and encrypt request payloads.'
    Write-Host '      WARNING: Application.Read.All permits app-only reading of every application and enterprise application in this tenant.' -ForegroundColor Yellow

    Write-Host "`nEndpoint security" -ForegroundColor Cyan
    if (-not $Context.ProviderTenantRestricted) {
        Write-Host '  - Configure the multi-tenant application for its home tenant and the displayed provider-tenant allowlist.'
    }
    Write-Host '  - Configure Easy Auth to require HTTPS authentication and allow only the Microsoft phone-provider enterprise application.'
    Show-EppCertificatePlan -Plan $Context.CertificatePlan -Names $Names
    if ($Inputs.ProviderAuthentication -eq 'oauth') {
        Write-Host "  - $($ProviderConfiguration.DisplayName) OAuth: add a federated credential so the outbound managed identity can authenticate without a client secret."
    }
    else {
        Write-Host "  - $($ProviderConfiguration.DisplayName) API key: store the required provider credentials in Key Vault; no federated credential is created."
    }

    Write-Host "`nDeployment notes" -ForegroundColor Cyan
    Write-Host '  - Deploy the verified GitHub release URL through ARM with ingress closed; enable HTTPS only after Graph trust and Easy Auth are verified.'
    Write-Host '  - Azure fetches the release URL again; use trusted immutable release assets because ARM does not enforce the locally verified hash.'
    Write-Host '  - Azure resource and Function deployment may each take several minutes. Keep this session open until deployment completes.'
    if ($Inputs.ServicePlan -eq 'FC1') {
        Write-Host '  - Flex Consumption: publish through One Deploy. No always-ready instances.'
        Write-Host '  - FC1 includes a free usage grant. Usage beyond the grant, Key Vault, storage, and telemetry can incur charges.' -ForegroundColor Yellow
    }
    if ($Inputs.ServicePlan -eq 'EP1') {
        Write-Host '  - Premium EP1, Key Vault, storage, and telemetry incur Azure charges.' -ForegroundColor Yellow
    }
    Write-Host '  - Rerunning setup can restart the Function App.' -ForegroundColor Yellow
    Write-Host '  - Failed deployments are not automatically rolled back, and resources are not automatically deleted.' -ForegroundColor Yellow

}

function Confirm-EppDeployment {
    param([switch] $NonInteractive, [switch] $ApproveDeployment)

    if ($ApproveDeployment) { return $true }
    if ($NonInteractive) { throw 'Deployment requires -ApproveDeployment in noninteractive mode. No Azure resources were changed.' }
    while ($true) {
        $answer = ([string](Read-Host 'Proceed with deployment? Enter Yes or Y to deploy, or No or N to cancel [No]')).Trim()
        if ($answer -in @('Yes', 'Y')) { return $true }
        if (-not $answer -or $answer -in @('No', 'N')) { return $false }
        Write-Warning 'Enter Yes or Y to deploy, or No or N to cancel. Press Enter to cancel.'
    }
}

function Show-EppCertificatePlan {
    param([Collections.IDictionary] $Plan, [Collections.IDictionary] $Names)

    if (-not $Plan) { throw 'Select an encryption certificate action before reviewing the deployment plan.' }
    Write-Host "`nEncryption certificate: $($Plan.Action)" -ForegroundColor Cyan
    Write-Host "  App-registration key ID to keep/register: $($Plan.KeyId)"
    if ($Plan.Action -eq 'Reuse') {
        Write-Host "  Keep certificate: $($Plan.CertificateId)"
        Write-Host "  Thumbprint: $($Plan.Thumbprint); expires: $($Plan.ExpiresUtc)"
        Write-Host "  Pin decryption to: $($Plan.SecretId)"
        if ($Plan.VaultName -ine $Names.keyVault) {
            if ($Plan.VaultRbac) {
                Write-Host "  Grant the Function system identity Key Vault Secrets User at: $($Plan.VaultResourceId)/secrets/$($Plan.CertificateName)"
            }
            else {
                Write-Host "  Add Secrets/Get for the Function system identity at: $($Plan.VaultResourceId)"
                Write-Host '  WARNING: access-policy vaults grant secret read access vault-wide, not just to this certificate.' -ForegroundColor Yellow
            }
        }
        if ($Plan.VaultName -ine $Names.keyVault) {
            Write-Host '  Grant the setup identity metadata-read access to the source vault; it never retrieves the private key.'
        }
        Write-Host '  Reuse does not change external-vault network rules; both the Function and the hosted setup script must reach the certificate vault.'
        Write-Host '  Existing certificate issuance policies are not changed; endpoint certificate synchronization remains manual.'
    }
    else {
        Write-Host "  Issue or reuse the staged certificate '$($Plan.CertificateName)' in '$($Plan.VaultName)'."
        Write-Host '  New certificates use RSA-2048, 12-month validity, key reuse, and manual renewal (no AutoRenew).'
    }
    if ($Plan.RemoveKeyIds.Count) {
        Write-Host '  Remove ONLY these app-registration encryption credentials after the replacement secret reference resolves:' -ForegroundColor Yellow
        foreach ($entry in $Plan.ExistingCertificates | Where-Object { $_.id -in $Plan.RemoveKeyIds }) {
            Write-Host "    $($entry.displayName)" -ForegroundColor Yellow
        }
        Write-Host '  WARNING: coordinate maintenance for every endpoint sharing this application. Cached/in-flight requests can fail; this is not zero-downtime rotation.' -ForegroundColor Yellow
    }
    else { Write-Host '  No existing app-registration encryption credentials will be removed.' }
    Write-Host '  Preserve non-encryption credentials and all Key Vault certificates, keys, and secrets.'
    Write-Host '  Keep private keys in Key Vault; verify the Function reference before registering exactly one public encryption certificate.'
    Write-Host '  Renewal and the authorized decryption evaluation remain administrator-owned operations.' -ForegroundColor Yellow
}

function Show-EppDeploymentResult {
    param(
        [hashtable] $Inputs, [Collections.IDictionary] $Names, $ProviderConfiguration,
        [string] $EndpointUrl, [string] $ResultPath
    )

    Write-Host "`nDeployment completed successfully." -ForegroundColor Green
    Write-Host 'IMPORTANT: Save this output. The endpoint URL and Application (client) ID are required for policy updates.' -ForegroundColor Yellow
    Write-Host "`nAzure resources created or updated" -ForegroundColor Cyan
    Get-EppResourceRows -Names $Names -ServicePlan $Inputs.ServicePlan |
        Format-Table Resource, Name -AutoSize | Out-String -Width 160 | Write-Host
    Write-Host "Function endpoint: $EndpointUrl" -ForegroundColor Green
    Write-Host "Service plan: $($Inputs.ServicePlan)"
    Write-Host "Deployment details: $ResultPath"
    Write-Host 'Certificate renewal is manual. Track the expiry in the deployment details and coordinate the Entra certificate update before expiry.' -ForegroundColor Yellow

    if ($ProviderConfiguration.AuthenticationMode -eq 'oauth') {
        Write-Host "`nPending operation" -ForegroundColor Yellow
        Write-Host "Have the $($ProviderConfiguration.DisplayName) administrator authorize application '$($Inputs.ApplicationId)' in access-token tenant '$($ProviderConfiguration.AccessTokenScopeTenant)'."
        Write-Host "   Provider API: $($ProviderConfiguration.Settings.EPP_PROVIDER_APP_ID) / $($ProviderConfiguration.Settings.EPP_PROVIDER_SCOPE)"
        Write-Host '   Provider consent and application-role assignments are not performed by setup. No provider API-key secrets are required.'
    }

    Write-Host "`nNext steps" -ForegroundColor Cyan
    Write-Host 'After validating each channel you intend to enable, update its External Phone Provider policy in Microsoft Graph:'
    foreach ($authenticationMethod in @('Sms', 'Voice')) {
        Write-Host "   ${authenticationMethod}: " -NoNewline
        Write-Host "https://graph.microsoft.com/beta/policies/authenticationMethodsPolicy/authenticationMethodConfigurations/$authenticationMethod" -ForegroundColor Yellow
    }
    Write-Host '   url:   ' -NoNewline
    Write-Host $EndpointUrl -ForegroundColor Yellow
    Write-Host '   appId: ' -NoNewline
    Write-Host $Inputs.ApplicationId -ForegroundColor Yellow
    Write-Host '   The setup script did not change the External Phone Provider policy.'
    Write-Host '   Policy configuration and validation guidance:'
    Write-Host '   https://github.com/Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample/blob/main/docs/GETTING-STARTED.md#4-connect-your-provider-and-test'
}
