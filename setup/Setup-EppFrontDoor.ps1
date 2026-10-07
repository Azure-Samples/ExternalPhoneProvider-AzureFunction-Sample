#Requires -Version 7.4
<#
.SYNOPSIS
    Create new JavaScript EP1 origins behind Front Door using an existing EPP deployment as the source.
.DESCRIPTION
    Run from a reviewed repository checkout. The source Function, app registration, and authentication
    policy are not changed. Review the plan before approval. Use -Verify to test an existing expansion
    without deploying resources. Policy activation remains manual.
.EXAMPLE
    .\Setup-EppFrontDoor.ps1 -Verify -AccessToken $token
#>
[CmdletBinding(DefaultParameterSetName = 'Deploy')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Deploy')][guid]$SubscriptionId,
    [Parameter(Mandatory, ParameterSetName = 'Deploy')][guid]$TenantId,
    [Parameter(Mandatory, ParameterSetName = 'Deploy')][ValidatePattern('^[A-Za-z0-9_.()-]+$')][string]$SourceResourceGroup,
    [Parameter(Mandatory, ParameterSetName = 'Deploy')][ValidatePattern('^[a-zA-Z0-9-]+$')][string]$SourceFunctionApp,
    [Parameter(Mandatory, ParameterSetName = 'Deploy')][ValidatePattern('^[a-z][a-z0-9]{2,9}$')][string]$ResourcePrefix,
    [Parameter(Mandatory, ParameterSetName = 'Deploy')][ValidateCount(2, 3)][string[]]$Locations,
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '../artifacts/frontdoor'),
    [Parameter(ParameterSetName = 'Deploy')][switch]$EvaluationOnly,
    [Parameter(ParameterSetName = 'Deploy')][switch]$ApproveDeployment,
    [Parameter(ParameterSetName = 'Deploy')][switch]$NonInteractive,
    [Parameter(Mandatory, ParameterSetName = 'Verify')][switch]$Verify,
    [Parameter(Mandatory, ParameterSetName = 'Verify')][Security.SecureString]$AccessToken
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-FdState {
    param([string]$Path, [hashtable]$State)
    $temporaryPath = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $State | ConvertTo-Json -Depth 25 | Set-Content -LiteralPath $temporaryPath -Encoding utf8NoBOM
        $null = Get-Content -LiteralPath $temporaryPath -Raw | ConvertFrom-Json -AsHashtable
        if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temporaryPath, $Path, "$Path.previous") }
        else { [IO.File]::Move($temporaryPath, $Path) }
    } finally {
        if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force }
    }
}

function Assert-FdGeography {
    param($SourceVault, $RegionCatalog, [string[]]$Locations, [string]$Subscription)
    if ($SourceVault.id -notmatch "^/subscriptions/$([regex]::Escape($Subscription))/") {
        throw 'Source vault must be in the selected subscription for encrypted backup/restore.'
    }
    $sourceRegion = @($RegionCatalog | Where-Object { $_.name -eq $SourceVault.location })
    if ($sourceRegion.Count -ne 1 -or -not $sourceRegion[0].metadata.geography) { throw 'Cannot determine source vault geography.' }
    foreach ($location in $Locations) {
        $region = @($RegionCatalog | Where-Object { $_.name -eq $location })
        if ($region.Count -ne 1 -or $region[0].metadata.geography -cne $sourceRegion[0].metadata.geography) {
            throw "Region $location is outside the source vault geography or could not be resolved. Key Vault backup/restore cannot cross geographies."
        }
    }
}

function Assert-FdRegions {
    param($Regions, [string]$Prefix, [string[]]$Locations)
    if (@($Regions).Count -ne $Locations.Count) { throw 'Checkpoint has an unexpected number of regions.' }
    for ($i = 0; $i -lt $Locations.Count; $i++) {
        $region = $Regions[$i]
        if ($region.location -cne $Locations[$i] -or
            $region.names.resourceGroup -cne "$Prefix-$i-rg" -or
            $region.names.functionApp -cne "$Prefix-$i-func" -or
            $region.names.keyVault -cne "$Prefix-$i-kv" -or
            $region.names.storageAccount -cnotmatch '^eppfd[a-z0-9]{13}$' -or
            $region.hostname -cne "$Prefix-$i-func.azurewebsites.net") {
            throw 'Checkpoint region names do not match this expansion; refusing unrelated resource changes.'
        }
    }
}

function Assert-FdSource {
    param($Site, $Settings, $Auth, [string]$Tenant, [bool]$EvaluationOnly)
    if ($Site.kind -notmatch 'functionapp' -or $Site.kind -notmatch 'linux' -or
        $Settings.FUNCTIONS_WORKER_RUNTIME -cne 'node') {
        throw 'This setup supports Linux JavaScript Functions only. Python and .NET are not supported.'
    }
    $aad = $Auth.identityProviders.azureActiveDirectory
    $applicationId = ([guid]$aad.registration.clientId).ToString()
    $issuer = "https://login.microsoftonline.com/$Tenant/v2.0"
    $excluded = @($Auth.globalValidation.excludedPaths | Where-Object { $_ })
    if (-not $Auth.platform.enabled -or -not $Auth.globalValidation.requireAuthentication -or
        $Auth.globalValidation.unauthenticatedClientAction -ne 'Return401' -or
        -not $Auth.httpSettings.requireHttps -or -not $aad.enabled -or
        $aad.registration.openIdIssuer.TrimEnd('/') -cne $issuer -or
        @($aad.validation.allowedAudiences).Count -ne 1 -or $aad.validation.allowedAudiences[0] -cne $applicationId -or
        @($excluded | Where-Object { $_ -cne '/api/health/ready' }).Count -gt 0) {
        throw 'Source must use enforced HTTPS Easy Auth with its v2 application-ID audience and no delivery-path exemptions.'
    }
    $callers = @($aad.validation.defaultAuthorizationPolicy.allowedApplications)
    if (-not $callers.Count) { throw 'Source caller allowlist must not be empty.' }
    foreach ($caller in $callers) { $null = [guid]$caller }
    # Do not silently widen source policies that this first version cannot reproduce.
    $policy = $aad.validation.defaultAuthorizationPolicy
    if (($policy.Contains('allowedPrincipals') -and @($policy.allowedPrincipals.Values | Where-Object { $_ }).Count) -or
        ($aad.validation.Contains('jwtClaimChecks') -and @($aad.validation.jwtClaimChecks.Values | Where-Object { $_ }).Count)) {
        throw 'Additional principal/claim restrictions require manual review; this version does not clone them.'
    }
    $package = [uri]$Settings.WEBSITE_RUN_FROM_PACKAGE
    if ($package.Scheme -cne 'https' -or $package.Host -notmatch '^[a-z0-9]+\.blob\.core\.windows\.net$' -or
        $package.UserInfo -or $package.Query -or $package.Fragment -or -not $package.IsDefaultPort -or
        $package.AbsolutePath -notmatch '^/([^/]+)/(.+)$') {
        throw 'Source must use a private Azure Blob run-from-package URL without SAS, query strings, or credentials.'
    }
    if ($Settings.WEBSITE_RUN_FROM_PACKAGE_BLOB_MI_RESOURCE_ID -cne 'SystemAssigned') {
        throw 'Source package access must use its system-assigned managed identity.'
    }
    if ($Settings.EPP_DECRYPTION_KEY_PEM -notmatch '^@Microsoft.KeyVault\(SecretUri=(https://([a-zA-Z0-9-]+)\.vault\.azure\.net/secrets/phone-provider-encryption/([a-zA-Z0-9]+))/?\)$') {
        throw 'Source must use a version-pinned phone-provider-encryption Key Vault certificate secret.'
    }
    $sourceKey = $Matches[1].TrimEnd('/')
    $sourceVault = $Matches[2]
    if (-not $EvaluationOnly -and -not $Settings.EPP_PROVIDER_NAME) {
        throw 'Source has no provider configured. Use -EvaluationOnly explicitly for non-delivering validation.'
    }
    if (-not $EvaluationOnly -and $Settings.EPP_PROVIDER_AUTH_MODE -cne 'apiKey') {
        throw 'Automatic provider cloning currently supports API-key profiles only. OAuth needs regional federation; use explicit -EvaluationOnly or keep manual onboarding.'
    }
    return @{
        applicationId = $applicationId; issuer = $issuer; callers = $callers
        packageUrl = $package.AbsoluteUri; sourceKey = $sourceKey; sourceVault = $sourceVault
    }
}

function Add-FdReadiness {
    param([string]$Package, [string]$Handler)
    $zip = [IO.Compression.ZipFile]::Open($Package, [IO.Compression.ZipArchiveMode]::Update)
    try {
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $total = 0L
        foreach ($entry in $zip.Entries) {
            if (-not $seen.Add($entry.FullName) -or $entry.FullName -match '(^/|\\|(^|/)\.\.(/|$))') {
                throw 'Unsafe or ambiguous source package paths.'
            }
            $total += $entry.Length
        }
        if ($total -gt 500MB) { throw 'Source package exceeds the expanded size limit.' }
        foreach ($required in @('host.json','package.json','node_modules/@azure/functions/package.json',
            'src/functions/SendOtp.js','src/functions/config.js','src/functions/logging.js')) {
            if (-not $zip.GetEntry($required)) { throw "Source package missing $required." }
        }
        $reader = [IO.StreamReader]::new($zip.GetEntry('package.json').Open())
        try { $manifest = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
        if ($manifest.main -cne 'src/functions/*.js') { throw 'Source package must load src/functions/*.js.' }
        $old = $zip.GetEntry('src/functions/health.js')
        if ($old) { $old.Delete() }
        $stream = $zip.CreateEntry('src/functions/health.js').Open()
        try {
            $bytes = [IO.File]::ReadAllBytes($Handler)
            $stream.Write($bytes, 0, $bytes.Length)
        } finally { $stream.Dispose() }
    } finally { $zip.Dispose() }
}

function Restore-FdBackup {
    param([string]$Vault, [ValidateSet('certificates','secrets')][string]$Kind,
        [string]$Path, [Security.SecureString]$Token)
    if ($Vault -cnotmatch '^[a-zA-Z0-9-]+$') { throw 'Invalid vault name.' }
    $value = [Convert]::ToBase64String([IO.File]::ReadAllBytes($Path)).TrimEnd('=').Replace('+','-').Replace('/','_')
    $body = @{ value = $value } | ConvertTo-Json -Compress
    for ($attempt = 1; $attempt -le 12; $attempt++) {
        $response = Invoke-WebRequest -Uri "https://$Vault.vault.azure.net/$Kind/restore?api-version=7.4" `
            -Method Post -Authentication Bearer -Token $Token -ContentType application/json -Body $body `
            -TimeoutSec 120 -MaximumRedirection 0 -SkipHttpErrorCheck
        if ($response.StatusCode -eq 200) { return }
        $errorBody = $response.Content | ConvertFrom-Json -AsHashtable
        $code = [string]$errorBody.error.code
        if ($response.StatusCode -eq 403 -and $attempt -lt 12 -and
            $errorBody.error.Contains('innererror') -and $errorBody.error.innererror.code -eq 'ForbiddenByRbac') {
            Write-Warning "Waiting for regional vault restore permission ($attempt/12)."
            Start-Sleep -Seconds 10
            continue
        }
        throw "Encrypted $Kind restore failed for $Vault (HTTP $($response.StatusCode), $code). No key values were logged."
    }
}

function Invoke-EppFrontDoor {
    [CmdletBinding()]
    param(
        [guid]$SubscriptionId, [guid]$TenantId, [string]$SourceResourceGroup,
        [string]$SourceFunctionApp, [string]$ResourcePrefix, [string[]]$Locations,
        [string]$OutputDirectory, [switch]$EvaluationOnly, [switch]$ApproveDeployment,
        [switch]$NonInteractive, [string]$AssetDirectory
    )
    if ($Locations.Count -notin @(2,3) -or @($Locations | Select-Object -Unique).Count -ne $Locations.Count -or
        @($Locations | Where-Object { $_ -cnotmatch '^[a-z0-9]+$' }).Count) { throw 'Specify two or three distinct Azure region names.' }
    if ($ResourcePrefix -cnotmatch '^[a-z][a-z0-9]{2,9}$') { throw 'Prefix must be 3-10 lowercase letters/digits, starting with a letter.' }
    if (-not $OutputDirectory) { $OutputDirectory = Join-Path $AssetDirectory '../artifacts/frontdoor' }
    $OutputDirectory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
    $sourceId = "/subscriptions/$SubscriptionId/resourceGroups/$SourceResourceGroup/providers/Microsoft.Web/sites/$SourceFunctionApp"
    $globalGroup = "$ResourcePrefix-global-rg"
    $groups = @($globalGroup) + @(0..($Locations.Count-1) | ForEach-Object { "$ResourcePrefix-$_-rg" })
    if ($SourceResourceGroup -in $groups) { throw 'The source must not be inside a target group.' }
    $module = Import-Module (Join-Path $AssetDirectory 'support/Epp.Setup.psm1') -PassThru -Force
    function Az {
        param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
        & $module { param($ArgsList, $Sub) Invoke-EppAz @ArgsList --subscription $Sub --only-show-errors } $Arguments $SubscriptionId.ToString()
    }
    function DataAz {
        param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
        & $module {
            param($ArgsList, $Sub)
            Invoke-EppDataOperation { Invoke-EppAz @ArgsList --subscription $Sub --only-show-errors }
        } $Arguments $SubscriptionId.ToString()
    }
    function Arm {
        param([string]$Id, [string]$Method = 'Get', $Body)
        $token = Az account get-access-token --output json | ConvertFrom-Json
        $arguments = @{
            Uri = "https://management.azure.com${Id}?api-version=2024-04-01"
            Method = $Method; Headers = @{ Authorization = "Bearer $($token.accessToken)" }
            ContentType = 'application/json'; TimeoutSec = 120
        }
        if ($null -ne $Body) { $arguments.Body = $Body | ConvertTo-Json -Depth 40 }
        Invoke-RestMethod @arguments | ConvertTo-Json -Depth 60 | ConvertFrom-Json -AsHashtable
    }
    function StateWrite { Write-FdState -Path $statePath -State $state }
    function ParameterFile {
        param([string]$Name, [hashtable]$Values)
        $parameters = @{}
        foreach ($key in $Values.Keys) { $parameters[$key] = @{ value = $Values[$key] } }
        $path = Join-Path $temporary $Name
        @{ parameters = $parameters } | ConvertTo-Json -Depth 25 | Set-Content -LiteralPath $path -Encoding utf8NoBOM
        return $path
    }
    $temporary = Join-Path ([IO.Path]::GetTempPath()) ('epp-frontdoor-' + [guid]::NewGuid().ToString('N'))
    $state = $null
    $mutating = $false
    try {
        $account = Az account show --output json | ConvertFrom-Json
        if ([guid]$account.tenantId -ne $TenantId) { throw 'Subscription and tenant mismatch.' }
        $operator = & $module {
            param($Sub, $Tenant)
            Get-EppArmOperatorObjectId -Inputs @{ SubscriptionId = $Sub; TenantId = $Tenant }
        } $SubscriptionId.ToString() $TenantId.ToString()
        $site = Arm $sourceId
        $settings = (Arm "$sourceId/config/appsettings/list" 'Post').properties
        $auth = (Arm "$sourceId/config/authsettingsV2/list").properties
        $source = Assert-FdSource $site $settings $auth $TenantId.ToString() $EvaluationOnly.IsPresent
        $vault = Az keyvault show --name $source.sourceVault --output json | ConvertFrom-Json -AsHashtable
        $regionCatalog = Az rest --method get --url "https://management.azure.com/subscriptions/$SubscriptionId/locations?api-version=2022-12-01" --output json | ConvertFrom-Json -AsHashtable
        Assert-FdGeography $vault $regionCatalog.value $Locations $SubscriptionId.ToString()
        $plan = Arm $site.properties.serverFarmId
        if ($plan.sku.name -cne 'EP1') { throw 'Only source EP1 plans are supported. FC1 expansion is not implemented.' }
        $certificate = DataAz keyvault certificate show --vault-name $source.sourceVault --name phone-provider-encryption --output json | ConvertFrom-Json -AsHashtable
        if ($certificate.sid.TrimEnd('/') -cne $source.sourceKey -or -not $certificate.attributes.enabled -or
            $certificate.policy.keyProperties.exportable -ne $true -or $certificate.policy.keyProperties.keyType -cne 'RSA' -or
            $certificate.policy.secretProperties.contentType -cne 'application/x-pem-file') {
            throw 'Source must use the latest enabled exportable RSA PEM certificate version. Coordinate renewal before expansion.'
        }
        $publicCertificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new([Convert]::FromBase64String($certificate.cer))
        try {
            if ($publicCertificate.NotAfter.ToUniversalTime() -le [DateTime]::UtcNow.AddDays(30)) { throw 'Source certificate must have more than 30 days remaining.' }
            $thumbprint = $publicCertificate.Thumbprint
        } finally { $publicCertificate.Dispose() }
        $providerSettings = [ordered]@{}
        $secretNames = @()
        if (-not $EvaluationOnly) {
            $provider = [string]$settings.EPP_PROVIDER_NAME
            if ($provider -cnotmatch '^[a-z0-9-]+$') { throw 'Invalid provider ID.' }
            $profilePath = Join-Path $AssetDirectory "providers/$provider.json"
            if (-not (Test-Path $profilePath)) { throw 'No reviewed setup profile for the source provider.' }
            $profile = (Get-Content $profilePath -Raw | ConvertFrom-Json -AsHashtable).deployment
            if (-not $profile.enabled -or $profile.authentication.mode -cne 'apiKey') { throw 'Source profile is not a supported API-key provider.' }
            foreach ($field in @('keyVaultSecretName','identityKeyVaultSecretName')) {
                if ($profile.authentication.ContainsKey($field) -and $profile.authentication[$field]) { $secretNames += $profile.authentication[$field] }
            }
            if (-not $secretNames.Count -or @($secretNames | Where-Object { $_ -cnotmatch '^[a-zA-Z0-9-]+$' }).Count) { throw 'Provider profile has no valid credential secret names.' }
            if ($settings.KEY_VAULT_URL.TrimEnd('/') -cne "https://$($source.sourceVault).vault.azure.net") { throw 'Provider and certificate must use the same source vault in this version.' }
            foreach ($key in @('EPP_PROVIDER_NAME','EPP_PROVIDER_ENDPOINT','EPP_PROVIDER_CHANNEL','EPP_PROVIDER_ENDPOINT_REGION',
                'EPP_PROVIDER_AUTH_MODE','EPP_PROVIDER_TIMEOUT_MS','EPP_PROVIDER_ACCOUNT_NAME','EPP_PROVIDER_RETRY_INTERVAL_MS')) {
                if ($settings.ContainsKey($key)) { $providerSettings[$key] = [string]$settings[$key] }
            }
            $providerUri = [uri]$providerSettings.EPP_PROVIDER_ENDPOINT
            if ($providerUri.Scheme -ne 'https' -or -not $providerUri.Host -or $providerUri.UserInfo -or $providerUri.Query -or $providerUri.Fragment) {
                throw 'Source provider endpoint must be HTTPS without embedded credentials, query strings, or fragments.'
            }
        }
        $packageUri = [uri]$source.packageUrl
        $storageName = $packageUri.Host.Split('.')[0]
        $segments = $packageUri.AbsolutePath.TrimStart('/').Split('/',2)
        New-Item -ItemType Directory -Path $temporary | Out-Null
        $package = Join-Path $temporary 'origin.zip'
        DataAz storage blob download --account-name $storageName --container-name $segments[0] --name ([uri]::UnescapeDataString($segments[1])) `
            --file $package --auth-mode login --output none | Out-Null
        $sourceHash = (Get-FileHash $package -Algorithm SHA256).Hash
        Add-FdReadiness -Package $package -Handler (Join-Path $AssetDirectory '../javascript/src/functions/health.js')
        $packageHash = (Get-FileHash $package -Algorithm SHA256).Hash
        $identity = [ordered]@{
            source = $sourceId; locations = $Locations; prefix = $ResourcePrefix
            sourcePackageHash = $sourceHash; certificate = $certificate.sid
            readinessHash = (Get-FileHash (Join-Path $AssetDirectory '../javascript/src/functions/health.js') -Algorithm SHA256).Hash
            evaluationOnly = $EvaluationOnly.IsPresent; issuer = $source.issuer; audience = $source.applicationId
            callers = @($source.callers | Sort-Object); providerSettings = $providerSettings
        } | ConvertTo-Json -Depth 10 -Compress
        $fingerprint = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($identity)))
        $statePath = Join-Path $OutputDirectory 'frontdoor-state.json'
        if (Test-Path $statePath) {
            $state = Get-Content $statePath -Raw | ConvertFrom-Json -AsHashtable
            if ($state.fingerprint -cne $fingerprint) { throw 'Source/configuration changed since this expansion. Use a new prefix or review the previous state; refusing to overwrite it.' }
            if ($state.ContainsKey('regions')) { Assert-FdRegions $state.regions $ResourcePrefix $Locations }
        }
        $savedPackage = Join-Path $OutputDirectory 'frontdoor-package.zip'
        if ($state -and $state.ContainsKey('packageHash')) {
            if (-not (Test-Path -LiteralPath $savedPackage) -or (Get-FileHash $savedPackage -Algorithm SHA256).Hash -cne $state.packageHash) {
                throw 'Saved package is missing or changed; restore the approved artifact before resuming.'
            }
        } elseif (Test-Path -LiteralPath $savedPackage) {
            throw 'An untracked package already exists in the output directory; choose a separate output directory.'
        }
        foreach ($group in $groups) {
            if ((Az group exists --name $group --output tsv) -eq 'true') {
                $existing = Az group show --name $group --output json | ConvertFrom-Json -AsHashtable
                if (-not $state -or $existing.tags.managedBy -cne 'EPP-FrontDoor-Setup' -or
                    $existing.tags.sourceResourceId -cne $sourceId) { throw "Refusing to adopt existing resource group $group." }
            }
        }
        Write-Host "Source (unchanged): $sourceId"
        Write-Host "New origins: $($Locations -join ', '); JavaScript on Linux EP1; Front Door Standard."
        Write-Host "Target groups: $($groups -join ', ')"
        Write-Host "Source package SHA256: $sourceHash"
        Write-Host 'The package will gain the reviewed, opt-in readiness handler. Secret replication uses encrypted Key Vault backups.'
        Write-Host "Provider mode: $(if ($EvaluationOnly) {'EVALUATION ONLY; no provider configured'} else {'API-key profile with regional credential copies'})"
        Write-Host 'Charges apply. No app registration, source Function, caller permissions, or authentication policy changes are made.'
        if (-not $ApproveDeployment) {
            if ($NonInteractive) { throw 'Noninteractive deployment requires -ApproveDeployment.' }
            if ((Read-Host 'Type Yes to create/update only this expansion') -cne 'Yes') { throw 'Deployment not approved.' }
        }
        New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
        if (-not $state) {
            $state = @{ fingerprint = $fingerprint; sourceResourceId = $sourceId; phase = 'approved'; prefix = $ResourcePrefix }
            StateWrite
        }
        $mutating = $true
        $state.phase = 'deploying'
        StateWrite
        # Keep the reviewed package stable across reruns rather than rebuilding a ZIP with new timestamps.
        if ($state.ContainsKey('packageHash')) {
            $package = $savedPackage; $packageHash = $state.packageHash
        } else {
            Copy-Item -LiteralPath $package -Destination $savedPackage
            $package = $savedPackage
            $state.packageHash = $packageHash
        }
        $state.sourcePackageHash = $sourceHash
        $state.certificateThumbprint = $thumbprint
        StateWrite
        $publicPath = Join-Path $OutputDirectory 'encryption-public.cer'
        [IO.File]::WriteAllBytes($publicPath, [Convert]::FromBase64String($certificate.cer))
        foreach ($namespace in @('Microsoft.Cdn','Microsoft.Web','Microsoft.Storage','Microsoft.KeyVault','Microsoft.Insights','Microsoft.OperationalInsights','Microsoft.ManagedIdentity')) {
            if ((Az provider show --namespace $namespace --query registrationState --output tsv) -ne 'Registered') {
                Az provider register --namespace $namespace --wait --output none | Out-Null
            }
        }
        Az group create --name $globalGroup --location $Locations[0] --tags managedBy=EPP-FrontDoor-Setup "sourceResourceId=$sourceId" --output none | Out-Null
        if (-not $state.ContainsKey('frontDoorId')) {
            $file = ParameterFile 'profile.json' @{ prefix = $ResourcePrefix }
            $template = Join-Path $AssetDirectory 'infra/frontdoor.bicep'
            Az deployment group what-if --resource-group $globalGroup --name fd-profile --template-file $template --parameters "@$file" --result-format ResourceIdOnly
            Az deployment group create --resource-group $globalGroup --name fd-profile --template-file $template --parameters "@$file" --output none | Out-Null
            $profile = Az rest --method get --url "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$globalGroup/providers/Microsoft.Cdn/profiles/$ResourcePrefix-fd?api-version=2025-04-15" --output json | ConvertFrom-Json
            $state.frontDoorId = ([guid]$profile.properties.frontDoorId).ToString()
            StateWrite
        }
        $values = @{
            prefix = $ResourcePrefix; locations = $Locations; tenantId = $TenantId.ToString()
            applicationId = $source.applicationId; deployerObjectId = $operator
            sourceResourceId = $sourceId; packageBlobName = "$($packageHash.ToLower()).zip"
            providerSettings = $providerSettings; frontDoorId = $state.frontDoorId
            callerApplicationIds = $source.callers
        }
        if (-not $state.ContainsKey('regions')) {
            $file = ParameterFile 'regions.json' $values
            $template = Join-Path $AssetDirectory 'infra/frontdoor-regions.bicep'
            Az deployment sub validate --location $Locations[0] --name "$ResourcePrefix-regions" --template-file $template --parameters "@$file" --output none | Out-Null
            Az deployment sub what-if --location $Locations[0] --name "$ResourcePrefix-regions" --template-file $template --parameters "@$file" --result-format ResourceIdOnly
            $deployment = Az deployment sub create --location $Locations[0] --name "$ResourcePrefix-regions" --template-file $template --parameters "@$file" --output json | ConvertFrom-Json -AsHashtable
            $state.regions = @($deployment.properties.outputs.regions.value)
            StateWrite
        }
        Assert-FdRegions $state.regions $ResourcePrefix $Locations
        $backup = Join-Path $temporary 'certificate.backup'
        DataAz keyvault certificate backup --vault-name $source.sourceVault --name phone-provider-encryption --file $backup --output none | Out-Null
        foreach ($secret in $secretNames) {
            DataAz keyvault secret backup --vault-name $source.sourceVault --name $secret --file (Join-Path $temporary "$secret.backup") --output none | Out-Null
        }
        foreach ($region in $state.regions) {
            $name = $region.names
            $targetStorage = Az storage account show --resource-group $name.resourceGroup --name $name.storageAccount --output json | ConvertFrom-Json
            if ($targetStorage.id -notlike "/subscriptions/$SubscriptionId/resourceGroups/$($name.resourceGroup)/*") { throw 'Target package storage is outside the expansion.' }
            $id = "/subscriptions/$SubscriptionId/resourceGroups/$($name.resourceGroup)/providers/Microsoft.Web/sites/$($name.functionApp)"
            $null = Arm $id 'Patch' @{ properties = @{ publicNetworkAccess = 'Disabled' } }
            $certificates = @(DataAz keyvault certificate list --vault-name $name.keyVault --output json | ConvertFrom-Json)
            if (-not @($certificates | Where-Object { $_.id -match '/phone-provider-encryption$' }).Count) {
                $vaultAccess = Az account get-access-token --resource https://vault.azure.net --output json | ConvertFrom-Json
                $secureToken = ConvertTo-SecureString $vaultAccess.accessToken -AsPlainText -Force
                try { Restore-FdBackup $name.keyVault certificates $backup $secureToken }
                finally { $secureToken.Dispose(); $vaultAccess = $null }
            }
            $regionalCert = DataAz keyvault certificate show --vault-name $name.keyVault --name phone-provider-encryption --output json | ConvertFrom-Json
            if ($regionalCert.cer -cne $certificate.cer) { throw 'Regional certificate mismatch; no existing keys will be overwritten.' }
            foreach ($secret in $secretNames) {
                $secrets = @(DataAz keyvault secret list --vault-name $name.keyVault --output json | ConvertFrom-Json)
                if (@($secrets | Where-Object { $_.id -match "/$([regex]::Escape($secret))$" }).Count) {
                    $sourceMetadata = DataAz keyvault secret list-versions --vault-name $source.sourceVault --name $secret --output json | ConvertFrom-Json
                    $targetMetadata = DataAz keyvault secret list-versions --vault-name $name.keyVault --name $secret --output json | ConvertFrom-Json
                    $sourceVersions = @($sourceMetadata | ForEach-Object { $_.id.Split('/')[-1] } | Sort-Object)
                    $targetVersions = @($targetMetadata | ForEach-Object { $_.id.Split('/')[-1] } | Sort-Object)
                    if (Compare-Object $sourceVersions $targetVersions) { throw 'Credential versions changed. Coordinate rotation manually rather than overwrite regional secrets.' }
                } else {
                    $vaultAccess = Az account get-access-token --resource https://vault.azure.net --output json | ConvertFrom-Json
                    $secureToken = ConvertTo-SecureString $vaultAccess.accessToken -AsPlainText -Force
                    try { Restore-FdBackup $name.keyVault secrets (Join-Path $temporary "$secret.backup") $secureToken }
                    finally { $secureToken.Dispose(); $vaultAccess = $null }
                }
            }
            $blob = $values.packageBlobName
            if ((DataAz storage blob exists --account-name $name.storageAccount --container-name packages --name $blob --auth-mode login --query exists --output tsv) -ne 'true') {
                DataAz storage blob upload --account-name $name.storageAccount --container-name packages --name $blob --file $package --auth-mode login --overwrite false --output none | Out-Null
            }
            $check = Join-Path $temporary 'verify.zip'
            DataAz storage blob download --account-name $name.storageAccount --container-name packages --name $blob --auth-mode login --file $check --overwrite --output none | Out-Null
            if ((Get-FileHash $check -Algorithm SHA256).Hash -cne $packageHash) { throw 'Regional package verification failed.' }
            Remove-Item -LiteralPath $check
            $regionalSettings = (Arm "$id/config/appsettings/list" 'Post').properties
            $regionalSettings.EPP_DECRYPTION_KEY_PEM = "@Microsoft.KeyVault(SecretUri=$($regionalCert.sid))"
            if ($settings.ContainsKey('EPP_ENCRYPTION_KEY_ID')) { $regionalSettings.EPP_ENCRYPTION_KEY_ID = $settings.EPP_ENCRYPTION_KEY_ID }
            $null = Arm "$id/config/appsettings" 'Put' @{ properties = $regionalSettings }
            $readAuth = (Arm "$id/config/authsettingsV2/list").properties
            $validated = Assert-FdSource (Arm $id) $regionalSettings $readAuth $TenantId.ToString() $EvaluationOnly.IsPresent
            if ((($validated.callers | Sort-Object) -join ',') -cne (($source.callers | Sort-Object) -join ',')) { throw 'Regional caller allowlist differs.' }
            $network = (Arm "$id/config/web").properties
            $allow = @($network.ipSecurityRestrictions | Where-Object { $_.action -eq 'Allow' })
            if ($network.ipSecurityRestrictionsDefaultAction -ne 'Deny' -or $allow.Count -ne 1 -or
                $allow[0].ipAddress -ne 'AzureFrontDoor.Backend' -or
                (@($allow[0].headers.'x-azure-fdid') -join ',') -cne $state.frontDoorId) { throw 'Regional ingress restriction verification failed.' }
            $null = Arm $id 'Patch' @{ properties = @{ publicNetworkAccess = 'Enabled' } }
            Az functionapp restart --resource-group $name.resourceGroup --name $name.functionApp --output none | Out-Null
            & $module { param($SiteId, $Sub) Sync-EppFunctionTriggers -SiteId $SiteId -SubscriptionId $Sub } $id $SubscriptionId.ToString()
            $functions = @(Az functionapp function list --resource-group $name.resourceGroup --name $name.functionApp --output json | ConvertFrom-Json)
            foreach ($function in @('SendOtp','FrontDoorHealth')) {
                if (@($functions | Where-Object { $_.name -match "/$function$" }).Count -ne 1) { throw "Missing regional $function function." }
            }
            $references = Arm "$id/config/configreferences/appsettings"
            if (@($references.value | Where-Object { $_.name -eq 'EPP_DECRYPTION_KEY_PEM' -and $_.properties.status -eq 'Resolved' }).Count -ne 1) { throw 'Regional decryption key reference unresolved.' }
        }
        $currentSettings = (Arm "$sourceId/config/appsettings/list" 'Post').properties
        $currentAuth = (Arm "$sourceId/config/authsettingsV2/list").properties
        $currentSource = Assert-FdSource (Arm $sourceId) $currentSettings $currentAuth $TenantId.ToString() $EvaluationOnly.IsPresent
        foreach ($key in @('applicationId','issuer','packageUrl','sourceKey')) {
            if ($currentSource[$key] -cne $source[$key]) { throw 'Source trust, package URL, or key changed during expansion. Review before resuming.' }
        }
        if ((($currentSource.callers | Sort-Object) -join ',') -cne (($source.callers | Sort-Object) -join ',')) {
            throw 'Source caller allowlist changed during expansion.'
        }
        $file = ParameterFile 'routes.json' @{ prefix = $ResourcePrefix; origins = @($state.regions | ForEach-Object { $_.hostname }) }
        $template = Join-Path $AssetDirectory 'infra/frontdoor.bicep'
        Az deployment group what-if --resource-group $globalGroup --name fd-routes --template-file $template --parameters "@$file" --result-format ResourceIdOnly
        Az deployment group create --resource-group $globalGroup --name fd-routes --template-file $template --parameters "@$file" --output none | Out-Null
        $edge = Az rest --method get --url "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$globalGroup/providers/Microsoft.Cdn/profiles/$ResourcePrefix-fd/afdEndpoints/$ResourcePrefix-edge?api-version=2025-04-15" --output json | ConvertFrom-Json
        $state.endpointUrl = "https://$($edge.properties.hostName)/api/SendOtp"
        $state.evaluationOnly = $EvaluationOnly.IsPresent
        $state.phase = 'deployed_requires_authenticated_validation'
        StateWrite
        Write-Host "Deployed: $($state.endpointUrl)"
        Write-Host 'Source endpoint and policy unchanged. Verify authenticated evaluation and provider delivery before manual policy activation.'
    }
    catch {
        $failure = $_
        if ($mutating -and $state) {
            $state.phase = 'failed'
            $state.recovery = 'Review original error; resume with the same unchanged source, inputs and output directory.'
            # ARM may create origins before returning outputs or saving their checkpoint.
            foreach ($i in 0..($Locations.Count-1)) {
                $id = "/subscriptions/$SubscriptionId/resourceGroups/$ResourcePrefix-$i-rg/providers/Microsoft.Web/sites/$ResourcePrefix-$i-func"
                try { $null = Arm $id 'Patch' @{ properties = @{ publicNetworkAccess = 'Disabled' } } }
                catch { Write-Warning "Could not close ingress for $ResourcePrefix-$i-func. Check it manually." }
            }
            try { StateWrite }
            catch { Write-Warning 'Could not save the failure checkpoint. Review Azure state before resuming.' }
        }
        throw $failure
    }
    finally {
        if (Test-Path $temporary) {
            foreach ($file in Get-ChildItem -LiteralPath $temporary -File) { Remove-Item -LiteralPath $file.FullName -Force }
            Remove-Item -LiteralPath $temporary
        }
        Remove-Module -ModuleInfo $module
    }
}

function Test-EppFrontDoor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OutputDirectory,
        [Parameter(Mandatory)][Security.SecureString]$AccessToken
    )
    $state = Get-Content -LiteralPath (Join-Path $OutputDirectory 'frontdoor-state.json') -Raw | ConvertFrom-Json
    $endpoint = [uri]$state.endpointUrl
    if ($endpoint.Scheme -ne 'https' -or $endpoint.Host -notmatch '^[a-z0-9.-]+\.azurefd\.net$' -or
        -not $endpoint.IsDefaultPort -or $endpoint.AbsolutePath -cne '/api/SendOtp' -or
        $endpoint.Query -or $endpoint.Fragment -or $endpoint.UserInfo) {
        throw 'State does not identify an HTTPS Front Door SendOtp endpoint.'
    }
    $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new(
        [IO.File]::ReadAllBytes((Join-Path $OutputDirectory 'encryption-public.cer')))
    $rsa = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey($certificate)
    $records = [Collections.Generic.List[object]]::new()
    $invalidToken = ConvertTo-SecureString 'invalid' -AsPlainText -Force
    function Encode([byte[]]$Bytes) { [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+','-').Replace('/','_') }
    try {
        foreach ($mode in @('missing-token','invalid-token','evaluation-1','evaluation-2','evaluation-3')) {
            $nonce = [guid]::NewGuid().ToString('N')
            $correlation = [guid]::NewGuid().ToString()
            $header = Encode ([Text.Encoding]::UTF8.GetBytes('{"alg":"RSA-OAEP-256","enc":"A256GCM"}'))
            $key = [Security.Cryptography.RandomNumberGenerator]::GetBytes(32)
            $iv = [Security.Cryptography.RandomNumberGenerator]::GetBytes(12)
            $plain = [Text.Encoding]::UTF8.GetBytes((@{ nonce = $nonce; phoneNumber = '+15555550100'; message = 'Synthetic evaluation only' } | ConvertTo-Json -Compress))
            $encrypted = [byte[]]::new($plain.Length)
            $tag = [byte[]]::new(16)
            $aes = [Security.Cryptography.AesGcm]::new($key, 16)
            try {
                $aes.Encrypt($iv, $plain, $encrypted, $tag, [Text.Encoding]::ASCII.GetBytes($header))
                $wrapped = $rsa.Encrypt($key, [Security.Cryptography.RSAEncryptionPadding]::OaepSHA256)
            } finally { $aes.Dispose(); [Array]::Clear($key, 0, $key.Length) }
            $body = @{
                type = 'microsoft.mfa.otpDeliver.v1'; mode = 2; channel = 1; ttlSeconds = 60
                correlationId = $correlation
                encryptedDeliveryContext = (@($header, (Encode $wrapped), (Encode $iv), (Encode $encrypted), (Encode $tag)) -join '.')
            } | ConvertTo-Json -Compress
            $request = @{
                Uri = $endpoint; Method = 'Post'; ContentType = 'application/json'; Body = $body
                MaximumRedirection = 0; TimeoutSec = 30; SkipHttpErrorCheck = $true
            }
            if ($mode -ne 'missing-token') {
                $request.Authentication = 'Bearer'
                $request.Token = if ($mode -eq 'invalid-token') { $invalidToken } else { $AccessToken }
            }
            $response = Invoke-WebRequest @request
            $status = [int]$response.StatusCode
            $passed = $status -in @(401,403)
            if ($mode -like 'evaluation-*') {
                $passed = $false
                if ($status -eq 200) {
                    $result = $response.Content | ConvertFrom-Json
                    $passed = $result.nonce -ceq $nonce -and $result.correlationId -ceq $correlation
                }
            }
            $records.Add(@{ check = $mode; httpStatus = $status; passed = $passed; correlationId = $correlation })
            Write-Host "$mode HTTP $status; passed=$passed"
        }
        $records | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'evaluation-results.json') -Encoding utf8NoBOM
        if (@($records | Where-Object { -not $_.passed }).Count) { throw 'Front Door evaluation/authentication checks failed. No live messages were sent.' }
        Write-Host 'Evaluation passed from this caller. This does not prove every origin, failover timing, or live provider delivery.'
    }
    finally {
        $invalidToken.Dispose()
        $rsa.Dispose()
        $certificate.Dispose()
    }
}

# Dot-sourcing loads the helpers for offline tests without running a deployment.
if ($MyInvocation.InvocationName -ne '.') {
    if ($PSCmdlet.ParameterSetName -eq 'Verify') {
        Test-EppFrontDoor -OutputDirectory $OutputDirectory -AccessToken $AccessToken
    } else {
        Invoke-EppFrontDoor @PSBoundParameters -AssetDirectory $PSScriptRoot
    }
}
