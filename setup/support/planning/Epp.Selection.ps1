function Get-EppServicePlan {
    param([string] $ServicePlan, [switch] $NonInteractive)

    Write-Host "`nService plan selection" -ForegroundColor Cyan
    Write-Host 'Review estimated Azure hosting and provider costs:'
    Write-Host 'https://github.com/Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample/blob/main/docs/COST-CALCULATOR.md'
    Write-Host 'Flex Consumption has a free usage grant, not a zero-cost guarantee. Additional usage, Key Vault, storage, and telemetry can incur charges.'
    return Select-EppOption -Entries @(
        @{ id = 'FC1'; displayName = 'Flex Consumption FC1 (free grant, cold starts)' }
        @{ id = 'EP1'; displayName = 'Premium EP1 (warm instance)' }
    ) -Name ServicePlan -PromptName 'Service plan' -Value $ServicePlan -DefaultValue FC1 -NonInteractive:$NonInteractive
}

function Get-EppResourceNames {
    param([string] $SubscriptionId, [string] $ApplicationId, [string] $ResourcePrefix, [switch] $PendingApplication)

    if ($ResourcePrefix -cnotmatch '^[a-z][a-z0-9]{1,7}$') { throw 'ResourcePrefix must be 2-8 lowercase letters/digits, starting with a letter.' }
    $SubscriptionId = ConvertTo-EppGuid $SubscriptionId
    if ($PendingApplication) {
        if ($ApplicationId) { throw 'Pending application names cannot include an application client ID.' }
        $suffix = '<app-id-hash>'
    }
    else {
        $seed = "$SubscriptionId|$(ConvertTo-EppGuid $ApplicationId)|$ResourcePrefix"
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $suffix = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($seed))) -replace '-', '').Substring(0, 8).ToLowerInvariant() }
        finally { $sha.Dispose() }
    }
    return [ordered]@{
        resourceGroup = "$ResourcePrefix-epp-rg-$suffix"
        functionApp = "$ResourcePrefix-epp-func-$suffix"
        storageAccount = "${ResourcePrefix}eppsa$suffix"
        keyVault = "$ResourcePrefix-epp-kv-$suffix"
        hostingPlan = "$ResourcePrefix-epp-plan-$suffix"
        logAnalytics = "$ResourcePrefix-epp-logs-$suffix"
        applicationInsights = "$ResourcePrefix-epp-insights-$suffix"
        outboundIdentity = "$ResourcePrefix-epp-outbound-$suffix"
    }
}

function Get-EppApplicationOptions {
    param([hashtable] $Inputs, [string] $SearchPrefix)

    $query = @{
        '$top' = '50'
        '$select' = 'appId,displayName,signInAudience'
    }
    if ($SearchPrefix) {
        $query['$filter'] = "startswith(displayName,'$($SearchPrefix.Replace("'", "''"))')"
    }
    $response = Invoke-EppGraphRequest -Inputs $Inputs -Path '/v1.0/applications' -Query $query
    if ($response -isnot [Collections.IDictionary] -or $response['value'] -isnot [Array]) {
        throw 'Microsoft Graph returned an invalid application selection response.'
    }
    $applications = @($response.value | ForEach-Object { [pscustomobject]$_ })
    if ($applications.Count -gt 50) { throw 'Graph returned more applications than the requested selection limit.' }
    $seen = @{}
    foreach ($application in ($applications | Sort-Object DisplayName, AppId)) {
        if (-not $application) { throw 'Graph returned an invalid application entry.' }
        # The applications endpoint can also return agent identity blueprints.
        $type = $application.PSObject.Properties['OdataType']
        $typeName = if ($type) { [string]$type.Value } else { '' }
        if (-not $typeName -and $application.PSObject.Properties['@odata.type']) { $typeName = [string]$application.'@odata.type' }
        $additional = $application.PSObject.Properties['AdditionalProperties']
        if (-not $typeName -and $additional -and $additional.Value -is [Collections.IDictionary]) {
            $typeName = [string]$additional.Value['@odata.type']
        }
        if ($typeName -and $typeName.TrimStart('#') -cne 'microsoft.graph.application') { continue }
        if ($application.SignInAudience -notin @('AzureADMyOrg', 'AzureADMultipleOrgs')) { continue }
        $id = ConvertTo-EppGuid ([string]$application.AppId)
        $name = [string]$application.DisplayName
        if ($name -match '[\x00-\x1f\x7f-\x9f]') { throw 'Graph returned an invalid application display name.' }
        if ([string]::IsNullOrWhiteSpace($name)) { $name = '(unnamed application)' }
        if ($seen.ContainsKey($id)) { throw 'Graph returned duplicate application client IDs. Refresh or specify the reviewed client ID.' }
        $seen[$id] = $true
        @{ id = $id; displayName = "$name [$id]" }
    }
}

function Select-EppApplication {
    param(
        [hashtable] $Inputs, [string] $ApplicationId,
        [switch] $NonInteractive, [switch] $InstallPrerequisites, [switch] $ForceAuthentication
    )

    if (-not [string]::IsNullOrWhiteSpace($ApplicationId) -or $NonInteractive) {
        return Read-EppInput -Name ApplicationId -Value $ApplicationId -Kind Guid -NonInteractive
    }
    $null = Connect-EppGraphAccount -Inputs $Inputs -ForceAuthentication:$ForceAuthentication
    Write-Host "`nSelect a dedicated EPP app registration, or create a new application. Do not use a shared application." -ForegroundColor Yellow
    Write-Host 'Application (client) IDs are shown below, not application object IDs. New applications are created only after deployment approval.'
    $search = ''
    while ($true) {
        $entries = @(Get-EppApplicationOptions -Inputs $Inputs -SearchPrefix $search)
        Write-Host "Selected tenant: $($Inputs.TenantId). Showing organizational apps from up to 50 registrations."
        Write-Host 'Use Search by name if your application is not shown; newly registered apps may take time to appear.'
        if (-not $entries.Count) { Write-Warning 'No matching organizational app registrations were returned.' }
        $entries += @(
            @{ id = 'search'; displayName = 'Search by application name prefix' }
            @{ id = 'refresh'; displayName = 'Refresh application list' }
            @{ id = 'manual'; displayName = 'Enter an application (client) ID manually' }
            @{ id = 'create'; displayName = 'Create a new application' }
        )
        $selection = Select-EppOption -Entries $entries -Name ApplicationId -PromptName 'Application' -DefaultValue create -AllowCancel
        if (-not $selection) { return $null }
        switch ($selection.id) {
            'search' {
                $search = Read-EppInput -Name ApplicationSearch -Kind Text -DefaultValue $search `
                    -Hint 'Beginning of the display name; type Cancel to cancel' -AllowCancel
                if ($null -eq $search) { return $null }
            }
            'refresh' { continue }
            'manual' {
                while ($true) {
                    $clientId = Read-EppInput -Name ApplicationId -DefaultValue 'Create a new application' `
                        -Hint 'Application (client) ID, not Object ID; type Cancel to cancel' -AllowCancel
                    if ($null -eq $clientId) { return $null }
                    if ($clientId -ieq 'Create a new application') { return 'create' }
                    try { return ConvertTo-EppGuid $clientId }
                    catch { Write-Warning "ApplicationId : $($_.Exception.Message)" }
                }
            }
            default { return $selection.id }
        }
    }
}

function Get-EppTenantRegionScope {
    param([string] $TenantId)

    $tenantId = ConvertTo-EppGuid $TenantId
    $authority = "https://login.microsoftonline.com/$tenantId/v2.0"
    $metadata = Invoke-RestMethod -Uri "$authority/.well-known/openid-configuration" -TimeoutSec 60 -MaximumRedirection 0
    if ($null -eq $metadata -or $metadata -is [Array]) {
        throw 'Microsoft Entra returned invalid tenant discovery metadata. Setup cannot determine the tenant replication scope.'
    }
    $issuer = $metadata.PSObject.Properties['issuer']
    if (-not $issuer -or $issuer.Value -isnot [string] -or $issuer.Value -ine $authority) {
        throw 'Tenant discovery did not return the selected tenant in the Azure public cloud. Verify the tenant ID; this setup supports Azure public cloud only.'
    }
    $scope = $metadata.PSObject.Properties['tenant_region_scope']
    if (-not $scope -or $scope.Value -isnot [string] -or $scope.Value -notmatch '\A[A-Za-z][A-Za-z0-9]{1,15}\z') {
        throw 'Microsoft Entra did not return a valid tenant replication scope. Setup cannot determine provider routing; verify the tenant ID and retry.'
    }
    return $scope.Value.ToUpperInvariant()
}

function Resolve-EppEndpointRegion {
    param([string] $TenantRegionScope, [string] $EndpointRegion)

    if ([string]::IsNullOrWhiteSpace($TenantRegionScope)) { throw 'The tenant replication scope must be determined before selecting provider routing.' }
    $expected = if ($TenantRegionScope -eq 'EU') { 'eu' } else { 'global' }
    if ($EndpointRegion) {
        if ($EndpointRegion -notin @('eu', 'global')) { throw "Unknown EndpointRegion '$EndpointRegion'. Use eu or global, or omit the parameter for automatic detection." }
        if ($EndpointRegion -ine $expected) {
            throw "-EndpointRegion '$EndpointRegion' is incompatible with tenant replication scope '$TenantRegionScope'. Omit the parameter or use '$expected'."
        }
    }
    return $expected
}

function Test-EppEuDataBoundaryGeography {
    param([string] $Geography)

    if ([string]::IsNullOrWhiteSpace($Geography)) { return $null }
    # EU/EFTA membership: https://learn.microsoft.com/privacy/eudb/eu-data-boundary-learn
    # Azure's Europe geography is Ireland/Netherlands, not the Europe geographyGroup (which includes the UK).
    return $Geography -in @(
        'Europe', 'Austria', 'Belgium', 'Bulgaria', 'Croatia', 'Cyprus', 'Czechia', 'Czech Republic',
        'Denmark', 'Estonia', 'Finland', 'France', 'Germany', 'Greece', 'Hungary', 'Ireland', 'Italy',
        'Latvia', 'Lithuania', 'Luxembourg', 'Malta', 'Netherlands', 'Poland', 'Portugal', 'Romania',
        'Slovakia', 'Slovenia', 'Spain', 'Sweden', 'Iceland', 'Liechtenstein', 'Norway', 'Switzerland'
    )
}

function Get-EppRegionOptions {
    param([hashtable] $Inputs)

    $subscriptionId = ConvertTo-EppGuid $Inputs.SubscriptionId
    # account list-locations cannot target a subscription without changing the CLI default.
    $url = "https://management.azure.com/subscriptions/$subscriptionId/locations?api-version=2022-12-01"
    $response = Invoke-EppAz rest --method get --url $url --subscription $subscriptionId --output json |
        ConvertFrom-Json -AsHashtable
    if ($response -isnot [Collections.IDictionary] -or $response['value'] -isnot [Array]) {
        throw 'Azure returned an invalid subscription location response.'
    }
    $seen = @{}
    foreach ($region in $response.value) {
        if ($region -isnot [Collections.IDictionary] -or $region['metadata'] -isnot [Collections.IDictionary]) {
            throw 'Azure returned invalid region metadata.'
        }
        if ($region.metadata['regionType'] -isnot [string] -or [string]::IsNullOrWhiteSpace($region.metadata['regionType']) -or
            ($null -ne $region.metadata['regionCategory'] -and $region.metadata['regionCategory'] -isnot [string]) -or
            ($null -ne $region.metadata['geography'] -and $region.metadata['geography'] -isnot [string])) {
            throw 'Azure returned invalid region classification metadata.'
        }
        if ($region.metadata['regionType'] -ne 'Physical') { continue }
        $id = [string]$region['name']
        $name = [string]$region['displayName']
        if ($id -cnotmatch '^[a-z][a-z0-9]+$' -or [string]::IsNullOrWhiteSpace($name) -or
            $name -match '[\x00-\x1f\x7f-\x9f]' -or $seen.ContainsKey($id)) {
            throw 'Azure returned an invalid or duplicate region.'
        }
        $seen[$id] = $true
        $recommended = $region.metadata['regionCategory'] -eq 'Recommended'
        $label = if ($recommended) { "$name ($id) - Azure recommended" } else { "$name ($id)" }
        @{
            id = $id; name = $name; displayName = $label; recommended = $recommended
            euDataBoundary = Test-EppEuDataBoundaryGeography -Geography $region.metadata['geography']
        }
    }
}

function Select-EppLocation {
    param([hashtable] $Inputs, [string] $Location, [switch] $NonInteractive, [switch] $ForceAuthentication)

    $euTenant = $Inputs['TenantRegionScope'] -eq 'EU'
    if (-not [string]::IsNullOrWhiteSpace($Location) -or $NonInteractive) {
        $Location = Read-EppInput -Name Location -Value $Location -Kind Location -NonInteractive
        if (-not $euTenant) { return $Location }
    }
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw 'Azure CLI is not installed or not on PATH. Install Azure CLI, open a new PowerShell 7 window, and rerun setup.'
    }
    $null = Connect-EppAzureAccount -Inputs $Inputs -NonInteractive:$NonInteractive `
        -ForceAuthentication:($ForceAuthentication -and -not $Inputs['AzureSelectionAuthenticated'])
    $Inputs.AzureSelectionAuthenticated = $true
    $regions = @(Get-EppRegionOptions -Inputs $Inputs)
    $preferred = @('eastus', 'westus2', 'centralus', 'westeurope', 'northeurope', 'southeastasia', 'australiaeast', 'japaneast')
    $recommended = @($regions | Where-Object { $_.recommended -and (-not $euTenant -or $_.euDataBoundary -eq $true) })
    $ordered = @(
        foreach ($id in $preferred) { $recommended | Where-Object { $_.id -ceq $id } }
        $recommended | Where-Object { $_.id -notin $preferred } | Sort-Object { $_.displayName }
    )
    $shortlist = @($ordered | Select-Object -First 8)
    if (-not $Location) {
        if ($euTenant) { Write-Host "`nRecommended Azure regions within the EU Data Boundary:" -ForegroundColor Cyan }
        else { Write-Host "`nChoose a region near your users and consistent with your data-residency requirements." -ForegroundColor Cyan }
        Write-Host 'The shortlist uses Azure Recommended metadata, not a latency/cost ranking or a guarantee of FC1/EP1 availability or quota. Existing preflight and deployment checks still apply.' -ForegroundColor Yellow
    }
    $showAll = $false
    while (-not $Location) {
        $entries = @(if ($showAll) { $regions | Sort-Object { $_.displayName } } else { $shortlist })
        $defaultRegion = if ($entries.Count) { [string]$entries[0].id } else { '' }
        if (-not $entries.Count) {
            $message = if ($euTenant -and -not $showAll) {
                'Azure returned no recommended regions with verified EU Data Boundary geography. Show all regions or enter a region name manually; verify the selection before deployment.'
            }
            else { 'No regions are available in this view. Show all regions or enter a region name manually.' }
            Write-Warning $message
        }
        $entries += if ($showAll) {
            @{ id = 'shortlist'; displayName = 'Back to recommended regions' }
        }
        else {
            @{ id = 'all'; displayName = 'Show all physical regions returned for this subscription' }
        }
        $entries += @{ id = 'manual'; displayName = 'Enter an Azure region name manually' }
        $defaultSelection = if ($defaultRegion) { $defaultRegion } elseif ($showAll) { 'shortlist' } else { 'all' }
        $selection = Select-EppOption -Entries $entries -Name Location -PromptName 'Azure region' -DefaultValue $defaultSelection -AllowCancel
        if (-not $selection) { return $null }
        switch ($selection.id) {
            'all' { $showAll = $true }
            'shortlist' { $showAll = $false }
            'manual' {
                $example = if ($euTenant) { 'westeurope' } else { 'westus2' }
                $Location = Read-EppInput -Name Location -Kind Location -DefaultValue $defaultRegion `
                    -Hint "Programmatic region name, for example $example; type Cancel to cancel" -AllowCancel
                if (-not $Location) { return $null }
            }
            default { $Location = $selection.id }
        }
    }
    $selectedRegion = $regions | Where-Object { $_.id -ceq $Location } | Select-Object -First 1
    $selectedName = if ($selectedRegion) { "$($selectedRegion.name) ($Location)" } else { $Location }
    Write-Host "Selected Azure region: $selectedName"
    if ($euTenant -and (-not $selectedRegion -or $selectedRegion.euDataBoundary -ne $true)) {
        $message = if (-not $selectedRegion -or $null -eq $selectedRegion.euDataBoundary) {
            'The selected region could not be verified as an EU Data Boundary location.'
        }
        else { 'The selected region is outside the EU Data Boundary.' }
        Write-Warning "$message Verify that this selection meets your organization's data-residency requirements. The selected region will be included in the deployment plan for review."
    }
    return $Location
}
