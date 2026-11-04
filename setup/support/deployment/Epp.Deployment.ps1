function Get-EppDeploymentParameters {
    param([hashtable] $Inputs, [Collections.IDictionary] $Names, $ProviderConfiguration, $Context, $Package)

    if ($Inputs.ServicePlan -notin @('FC1', 'EP1')) { throw "Unknown service plan '$($Inputs.ServicePlan)'." }
    if ($Package.RequiresRemoteBuild) { throw 'ARM publication requires a packaged release ZIP. Select a current package release.' }
    Assert-EppHttpsUrl $Inputs.PackageUrl
    $settings = @{} + $ProviderConfiguration.Settings
    $settings.EPP_PROVIDER_AUTH_MODE = $Inputs.ProviderAuthentication
    $certificatePlan = $Context.CertificatePlan
    $existingRoleAssignments = @()
    if ($certificatePlan.Action -eq 'Reuse') {
        $vault = Get-EppCertificateVault -Inputs $Inputs -VaultName $certificatePlan.VaultName -SubscriptionId $certificatePlan.VaultSubscriptionId
        if ($vault['id'] -ine $certificatePlan.VaultResourceId -or
            ($vault['properties']['enableRbacAuthorization'] -eq $true) -ne $certificatePlan.VaultRbac -or
            -not (Test-EppJsonEqual @($vault['properties']['accessPolicies'] | Where-Object { $null -ne $_ }) $certificatePlan.VaultAccessPolicies)) {
            throw 'The reused vault or its permission model changed after approval. Rerun setup.'
        }
        if ($certificatePlan.VaultRbac -and $certificatePlan.VaultName -ine $Names.keyVault) {
            foreach ($scope in @($certificatePlan.VaultResourceId, "$($certificatePlan.VaultResourceId)/secrets/$($certificatePlan.CertificateName)")) {
                $assignments = Invoke-EppAz role assignment list --scope $scope --include-inherited `
                    --subscription $certificatePlan.VaultSubscriptionId --output json | ConvertFrom-Json -AsHashtable -NoEnumerate
                if ($assignments -isnot [array]) { throw 'Azure returned an invalid source-vault role-assignment list.' }
                $existingRoleAssignments += $assignments
            }
        }
    }
    return @{
        resourceNames = @{ value = $Names }
        location = @{ value = $Inputs.Location }
        tenantId = @{ value = $Inputs.TenantId }
        applicationId = @{ value = $Inputs.ApplicationId }
        tokenVersion = @{ value = $Context.TokenVersion }
        callerApplicationId = @{ value = $script:MicrosoftPhoneProviderAppId }
        providerSettings = @{ value = $settings }
        language = @{ value = $Inputs.Language }
        servicePlan = @{ value = $Inputs.ServicePlan }
        packageUri = @{ value = $Inputs.PackageUrl }
        certificatePlan = @{ value = @{
            action = $certificatePlan.Action; keyId = $certificatePlan.KeyId
            certificateName = $certificatePlan.CertificateName; certificateId = $certificatePlan.CertificateId
            vaultName = $certificatePlan.VaultName; vaultSubscriptionId = $certificatePlan.VaultSubscriptionId
            vaultResourceId = $certificatePlan.VaultResourceId; vaultRbac = $certificatePlan.VaultRbac
            existingPolicies = $certificatePlan.VaultAccessPolicies
            existingRoleAssignments = $existingRoleAssignments
        } }
        executionId = @{ value = [Guid]::NewGuid().ToString() }
    }
}

function Invoke-EppMainDeployment {
    param([hashtable] $Inputs, [hashtable] $Parameters, [string] $AssetDirectory, [string] $Directory)

    $parameterPath = Join-Path $Directory 'deployment.parameters.json'
    try {
        @{ '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'; contentVersion = '1.0.0.0'; parameters = $Parameters } |
            ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $parameterPath -Encoding utf8NoBOM
        Write-Host 'Deployment may take several minutes. Keep this session open.' -ForegroundColor Cyan
        $deploymentName = "epp-$($Inputs.ResourcePrefix)-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
        return Invoke-EppRegistrationRetry -Operation {
            Invoke-EppAz -Activity 'Deploying Azure resources and Function code' deployment sub create --name $deploymentName `
                --subscription $Inputs.SubscriptionId --location $Inputs.Location --template-file (Join-Path $AssetDirectory 'main.json') `
                --parameters "@$parameterPath" --query properties.outputs --output json
        } | ConvertFrom-Json
    }
    finally { if (Test-Path -LiteralPath $parameterPath) { Remove-Item -LiteralPath $parameterPath -Force } }
}

function Get-EppArmState {
    param([hashtable] $Inputs, [Collections.IDictionary] $Names, $Context, $Outputs, [string] $OutputDirectory)

    foreach ($mapping in @{ functionAppName = 'functionApp'; storageAccountName = 'storageAccount'; keyVaultName = 'keyVault'; resourceGroupName = 'resourceGroup' }.GetEnumerator()) {
        if ($Outputs.($mapping.Key).value -cne $Names[$mapping.Value]) { throw 'Bicep outputs do not match the approved resource names. Stop and inspect the deployment.' }
    }
    $null = ConvertTo-EppGuid $Outputs.outboundPrincipalId.value
    Assert-EppHttpsUrl $Outputs.endpointUrl.value
    if ([Text.Encoding]::UTF8.GetByteCount($Outputs.endpointUrl.value) -gt 100) { throw 'The deployed endpoint URL exceeds the EPP 100-byte limit.' }
    $certificatePlan = $Context.CertificatePlan
    $issued = $null
    try {
        $bundle = $Outputs.certificateBundle.value | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable
        $issued = ConvertFrom-EppCertificateBundle -Bundle $bundle -RequireSetupPolicy:($certificatePlan.Action -ne 'Reuse')
        $location = ConvertTo-EppKeyVaultObjectId $issued.CertificateId certificates
        if ($location.VaultName -ine $certificatePlan.VaultName -or $location.Name -ine $certificatePlan.CertificateName) {
            throw 'ARM returned a certificate outside the approved vault or certificate name.'
        }
        $versions = @($Outputs.certificateSecretVersions.value | ForEach-Object { $_ | ConvertTo-Json -Depth 8 | ConvertFrom-Json -AsHashtable })
        Assert-EppCertificateSecret -SecretId $issued.SecretId -Versions $versions
        if ($certificatePlan.Action -eq 'Reuse' -and
            ($issued.CertificateId -ine $certificatePlan.CertificateId -or $issued.SecretId -ine $certificatePlan.SecretId -or
                $issued.Certificate.Thumbprint -ine $certificatePlan.Thumbprint)) {
            throw 'The selected certificate or backing secret changed after approval. Rerun setup and review a new plan.'
        }
        [IO.File]::WriteAllBytes((Join-Path $OutputDirectory "$($issued.Certificate.Thumbprint).cer"), $issued.Certificate.RawData)
        Write-Host "Selected encryption key ID: $($certificatePlan.KeyId)"
        Write-Host "Key Vault certificate: $($issued.CertificateId)"
        Assert-EppEncryptionReference -Inputs $Inputs -Names $Names -SecretId $issued.SecretId -KeyId $certificatePlan.KeyId
        $siteId = "/subscriptions/$($Inputs.SubscriptionId)/resourceGroups/$($Names.resourceGroup)/providers/Microsoft.Web/sites/$($Names.functionApp)"
        Assert-EppAuthentication -SiteId $siteId -Inputs $Inputs -Context $Context -IdentifierUri $Outputs.identifierUri.value
        $site = Invoke-EppAz rest --method get --url "https://management.azure.com$siteId`?api-version=2024-04-01" `
            --subscription $Inputs.SubscriptionId --output json | ConvertFrom-Json -AsHashtable
        if ($site -isnot [Collections.IDictionary] -or $site['id'] -ine $siteId -or
            $site['properties'] -isnot [Collections.IDictionary] -or $site['properties']['publicNetworkAccess'] -cne 'Disabled') {
            throw 'ARM deployment must leave the approved Function with public ingress disabled.'
        }
        Assert-EppFunctionPublished -Inputs $Inputs -Names $Names
        return [pscustomobject]@{
            Names = $Names; Outputs = $Outputs; Issued = $issued; SiteId = $siteId; PackageSha256 = $Inputs.PackageSha256
        }
    }
    catch {
        if ($issued) { $issued.Certificate.Dispose() }
        throw
    }
}

function Set-EppPublicAccess {
    param(
        [string] $SiteId, [string] $SubscriptionId, [ValidateSet('Enabled', 'Disabled')][string] $Access,
        [string] $AssetDirectory, [string] $Directory
    )

    $site = Invoke-EppAz rest --method get --url "https://management.azure.com$SiteId`?api-version=2024-04-01" `
        --subscription $SubscriptionId --output json | ConvertFrom-Json -AsHashtable
    if ($site -isnot [Collections.IDictionary] -or $site['id'] -ine $SiteId -or
        $site['properties'] -isnot [Collections.IDictionary]) { throw 'Azure returned invalid Function metadata; ingress was not changed.' }
    Invoke-EppIngressDeployment -SubscriptionId $SubscriptionId -ResourceGroup ($SiteId.Split('/')[4]) `
        -AssetDirectory $AssetDirectory -Directory $Directory -Parameters @{ site = $site; access = $Access } | Out-Null
}

function Invoke-EppIngressDeployment {
    param(
        [string] $SubscriptionId, [string] $ResourceGroup, [string] $AssetDirectory,
        [string] $Directory, [hashtable] $Parameters
    )

    $path = Join-Path $Directory 'ingress.parameters.json'
    try {
        $values = @{}
        foreach ($name in $Parameters.Keys) { $values[$name] = @{ value = $Parameters[$name] } }
        @{ parameters = $values } | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $path -Encoding utf8NoBOM
        Invoke-EppAz -Activity 'Deploying Function ingress through ARM' deployment group create `
            --name "epp-ingress-$([Guid]::NewGuid().ToString('N').Substring(0, 8))" `
            --resource-group $ResourceGroup --subscription $SubscriptionId `
            --template-file (Join-Path $AssetDirectory 'ingress.json') --parameters "@$path" --output none | Out-Null
    }
    finally { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force } }
}
