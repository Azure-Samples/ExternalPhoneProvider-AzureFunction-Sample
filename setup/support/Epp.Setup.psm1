#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:MicrosoftPhoneProviderAppId = '25ec60fa-f18d-41a4-b398-50044c90ce13'
$script:MicrosoftGraphAppId = '00000003-0000-0000-c000-000000000000'
$script:MicrosoftGraphApplicationReadAllRoleId = '9a5d68dd-52b0-4cc2-bd40-abcf44ac3a30'
$script:EppInvokeAppRoleId = 'ddf32018-9212-41c7-b73c-f5dfe73a2f24'
$script:EppInvokeAppRoleValue = 'Epp.Invoke'
$script:GraphRequiredScopes = @('User.Read', 'Application.ReadWrite.All', 'Application.Read.All', 'AppRoleAssignment.ReadWrite.All')
. (Join-Path $PSScriptRoot 'Epp.Packages.ps1')

function Read-EppJson {
    param([string] $Path)

    $value = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    if ($value -isnot [Collections.IDictionary]) { throw "Expected a JSON object in '$Path'." }
    return $value
}

function ConvertTo-EppGuid {
    param([string] $Value)

    $guid = [Guid]::Empty
    if (-not [Guid]::TryParse($Value, [ref] $guid) -or $guid -eq [Guid]::Empty) {
        throw 'Use a nonempty GUID, not an application name or an all-zero placeholder.'
    }
    return $guid.ToString('D')
}

function Assert-EppHttpsUrl {
    param([string] $Value)

    $uri = $null
    if (-not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref] $uri) -or
        $uri.Scheme -ne 'https' -or $uri.Port -ne 443 -or $uri.IsLoopback -or
        $uri.HostNameType -ne [UriHostNameType]::Dns -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or
        $uri.Host -notmatch '\.' -or
        $uri.Host -match '(?i)((^|\.)example\.(com|net|org)$|\.(invalid|test|example)$)') {
        throw 'Use a public HTTPS hostname on port 443, without credentials, a query string, or placeholders.'
    }
}

function Select-EppOption {
    param(
        [object[]] $Entries, [string] $Name, [string] $Value,
        [string] $PromptName, [switch] $NonInteractive
    )

    $ids = @($Entries | ForEach-Object { $_['id'] })
    $displayName = if ($PromptName) { $PromptName } else { $Name }
    if ($Value) {
        $selected = $Entries | Where-Object { $_['id'] -ieq $Value -or $_['displayName'] -ieq $Value } | Select-Object -First 1
        if (-not $selected) { throw "Unknown $Name '$Value'. Choose: $($ids -join ', ')." }
        return $selected
    }
    if ($NonInteractive) { throw "-$Name is required. Choose: $($ids -join ', ')." }
    Write-Host "`nChoose your $($displayName.ToLowerInvariant()):" -ForegroundColor Cyan
    for ($index = 0; $index -lt $Entries.Count; $index++) { Write-Host "  [$($index + 1)] $($Entries[$index]['displayName'])" }
    while ($true) {
        $answer = ([string](Read-Host "$displayName number or name")).Trim()
        $number = 0
        if ([int]::TryParse($answer, [ref] $number) -and $number -ge 1 -and $number -le $Entries.Count) { return $Entries[$number - 1] }
        $selected = $Entries | Where-Object { $_['id'] -ieq $answer -or $_['displayName'] -ieq $answer } | Select-Object -First 1
        if ($selected) { return $selected }
        Write-Warning "Choose one of the listed $($displayName.ToLowerInvariant()) options."
    }
}

function Read-EppInput {
    param(
        [string] $Name, [string] $Value, [string] $Hint,
        [ValidateSet('Text', 'Guid', 'Location', 'Prefix', 'PackageUrl', 'Hash')]
        [string] $Kind = 'Text',
        [switch] $NonInteractive,
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$')]
        [string] $SourceRepository = 'Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample'
    )

    $supplied = -not [string]::IsNullOrWhiteSpace($Value)
    while ($true) {
        if (-not $supplied) {
            if ($NonInteractive) { throw "-$Name is required in noninteractive mode." }
            $prompt = if ($Hint) { "$Name - $Hint" } else { $Name }
            $Value = [string](Read-Host $prompt)
        }
        $Value = $Value.Trim()
        try {
            if (-not $Value -or $Value -match '[\x00-\x1f<>]') { throw 'A nonempty value without placeholders is required.' }
            switch ($Kind) {
                'Guid' { $Value = ConvertTo-EppGuid $Value }
                'Location' {
                    if ($Value -cnotmatch '^[a-z][a-z0-9]+$') { throw 'Use an Azure region name such as westus2.' }
                }
                'Prefix' {
                    if ($Value -cnotmatch '^[a-z][a-z0-9]{1,7}$') {
                        throw 'Use 2-8 lowercase letters or digits, starting with a letter (for example contoso).'
                    }
                }
                'PackageUrl' {
                    Assert-EppHttpsUrl $Value
                    $repositories = @('Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample', $SourceRepository)
                    $allowed = @($repositories | Where-Object {
                        $Value -cmatch ('^https://github\.com/' + [regex]::Escape($_) + '/releases/download/[^/]+/[^/]+\.zip$')
                    })
                    if (-not $allowed.Count) {
                        throw 'Use a versioned ZIP release URL from the selected source repository or Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample.'
                    }
                }
                'Hash' {
                    if ($Value -notmatch '^[0-9a-fA-F]{64}$') { throw 'Use the package SHA-256 from its release checksums.' }
                    $Value = $Value.ToLowerInvariant()
                }
            }
            return $Value
        }
        catch {
            if ($supplied) { throw "Invalid -${Name}: $($_.Exception.Message)" }
            Write-Warning "$Name : $($_.Exception.Message)"
        }
    }
}

function Get-EppProvider {
    param(
        [string] $AssetDirectory, [string] $SourceBaseUri, [string] $Provider, [string] $Channel,
        [string] $EndpointRegion, [switch] $NonInteractive,
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$')]
        [string] $SourceRepository = 'Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample'
    )

    $sourcePattern = '^https://raw\.githubusercontent\.com/' + [regex]::Escape($SourceRepository) + '/[0-9a-fA-F]{40}/setup$'
    if ($SourceBaseUri -cnotmatch $sourcePattern) {
        throw 'Provider files must come from the same commit-pinned selected repository as the deployment tools.'
    }
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
    $selected = Select-EppOption -Entries $entries -Name Provider -Value $Provider -NonInteractive:$NonInteractive

    $path = Join-Path $AssetDirectory "providers/$($selected['file'])"
    Invoke-WebRequest -Uri "$SourceBaseUri/providers/$($selected['file'])" -OutFile $path -TimeoutSec 60 -MaximumRedirection 0
    $profile = Read-EppJson $path
    return ConvertTo-EppProviderSettings -Profile $profile -Id $selected['id'] -DisplayName $selected['displayName'] `
        -Channel $Channel -EndpointRegion $EndpointRegion -NonInteractive:$NonInteractive
}

function ConvertTo-EppProviderSettings {
    param(
        [Collections.IDictionary] $Profile, [string] $Id, [string] $DisplayName,
        [string] $Channel, [string] $EndpointRegion, [switch] $NonInteractive
    )

    $issues = [Collections.Generic.List[string]]::new()
    $deployment = $Profile['deployment']
    if ($deployment -isnot [Collections.IDictionary]) { throw "Provider '$DisplayName' has no deployment configuration." }
    if ($deployment['enabled'] -isnot [bool] -or -not $deployment['enabled']) {
        $issues.Add('the provider owner has not enabled this profile')
    }
    if ($deployment['providerName'] -ine $Id) { $issues.Add('deployment.providerName must match the catalog ID or display name') }
    try { $providerTenantId = ConvertTo-EppGuid $deployment['tenantId'] }
    catch { $issues.Add('deployment.tenantId must identify the provider tenant') }

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
    foreach ($channelId in @('sms', 'voice')) {
        if ($routes[$channelId] -isnot [Collections.IDictionary]) {
            $issues.Add("deployment.routes.$channelId is missing")
            continue
        }
        foreach ($regionId in @('global', 'eu')) {
            $route = $routes[$channelId][$regionId]
            if ($route -isnot [Collections.IDictionary]) {
                $issues.Add("deployment.routes.$channelId.$regionId is missing")
                continue
            }
            try { Assert-EppHttpsUrl $route['endpoint'] }
            catch { $issues.Add("deployment.routes.$channelId.$regionId.endpoint must be a public HTTPS endpoint") }
            $timeout = $route['timeoutMilliseconds']
            $retry = $route['retryIntervalSeconds']
            if (($timeout -isnot [long] -and $timeout -isnot [int]) -or $timeout -lt 1 -or $timeout -gt 2500) {
                $issues.Add("deployment.routes.$channelId.$regionId.timeoutMilliseconds must be an integer from 1 to 2500")
            }
            if (($retry -isnot [long] -and $retry -isnot [int]) -or $retry -lt 0 -or $retry -gt 2147483) {
                $issues.Add("deployment.routes.$channelId.$regionId.retryIntervalSeconds must be a nonnegative integer fitting Int32 milliseconds")
            }
            if ($authenticationMode -eq 'oauth') {
                try { $null = ConvertTo-EppGuid $route['appId'] }
                catch { $issues.Add("deployment.routes.$channelId.$regionId.appId must identify the provider API application") }
                $scope = [string]$route['scope']
                $resource = $scope -replace '/\.default$', ''
                $resourceUri = $null
                $resourceGuid = [Guid]::Empty
                $validResource = ([Guid]::TryParse($resource, [ref] $resourceGuid) -and $resourceGuid -ne [Guid]::Empty) -or
                    ([Uri]::TryCreate($resource, [UriKind]::Absolute, [ref] $resourceUri) -and
                        $resourceUri.Scheme -in @('api', 'https') -and $resourceUri.Host -and
                        -not $resourceUri.UserInfo -and -not $resourceUri.Query -and -not $resourceUri.Fragment)
                if (-not $validResource -or $scope -notmatch '/\.default$' -or $scope -match '[\s<>]') {
                    $issues.Add("deployment.routes.$channelId.$regionId.scope must be the provider API resource followed by /.default")
                }
            }
        }
    }
    if ($issues.Count) {
        throw "Provider '$DisplayName' is not deployment-ready:`n - $($issues -join "`n - ")`nAsk the provider owner to complete its GitHub JSON. No Azure resources were changed."
    }

    $channelEntry = Select-EppOption -Entries @(
        @{ id = 'sms'; displayName = 'SMS' }
        @{ id = 'voice'; displayName = 'Voice' }
    ) -Name Channel -Value $Channel -NonInteractive:$NonInteractive
    $regionEntry = Select-EppOption -Entries @(
        @{ id = 'global'; displayName = 'Global endpoint' }
        @{ id = 'eu'; displayName = 'EU endpoint' }
    ) -Name EndpointRegion -Value $EndpointRegion -NonInteractive:$NonInteractive
    $selectedRoute = $routes[$channelEntry['id']][$regionEntry['id']]
    $settings = @{
        EPP_PROVIDER_NAME = $Id
        EPP_PROVIDER_ENDPOINT = [string]$selectedRoute['endpoint']
        EPP_PROVIDER_CHANNEL = [string]$channelEntry['id']
        EPP_PROVIDER_ENDPOINT_REGION = [string]$regionEntry['id']
        EPP_PROVIDER_TIMEOUT_MS = [string]$selectedRoute['timeoutMilliseconds']
        EPP_PROVIDER_RETRY_INTERVAL_MS = [string]([long]$selectedRoute['retryIntervalSeconds'] * 1000)
        EPP_PROVIDER_AUTH_MODE = $authenticationMode
        EPP_PROVIDER_TENANT_ID = $providerTenantId
    }
    if ($authenticationMode -eq 'oauth') {
        $settings.EPP_PROVIDER_SCOPE = [string]$selectedRoute['scope']
        $settings.EPP_PROVIDER_APP_ID = [string]$selectedRoute['appId']
    }
    return [pscustomobject]@{
        Id = $Id
        DisplayName = $DisplayName
        Manifest = $Profile
        Channel = [string]$channelEntry['id']
        EndpointRegion = [string]$regionEntry['id']
        AuthenticationMode = $authenticationMode
        Settings = $settings
    }
}

function Get-EppResourceNames {
    param([string] $SubscriptionId, [string] $ApplicationId, [string] $ResourcePrefix)

    if ($ResourcePrefix -cnotmatch '^[a-z][a-z0-9]{1,7}$') { throw 'ResourcePrefix must be 2-8 lowercase letters/digits, starting with a letter.' }
    $seed = "$(ConvertTo-EppGuid $SubscriptionId)|$(ConvertTo-EppGuid $ApplicationId)|$ResourcePrefix"
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $suffix = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($seed))) -replace '-', '').Substring(0, 8).ToLowerInvariant() }
    finally { $sha.Dispose() }
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

function Invoke-EppAz {
    param([Parameter(ValueFromRemainingArguments)][string[]] $Arguments)

    $PSNativeCommandUseErrorActionPreference = $false
    $errorPath = Join-Path ([IO.Path]::GetTempPath()) "epp-az-$([Guid]::NewGuid().ToString('N')).stderr"
    try {
        $output = & az @Arguments --only-show-errors 2> $errorPath
        $exitCode = $LASTEXITCODE
        $errorText = if (Test-Path -LiteralPath $errorPath) { [string](Get-Content -LiteralPath $errorPath -Raw) } else { '' }
        $message = (($output -join "`n") + "`n" + $errorText) -replace '(?i)([?&](?:sig|token|code|client_secret|password)=)[^&\s]+', '$1[REDACTED]'
        $message = $message -replace '(?i)(Bearer\s+)[^\s,;]+', '$1[REDACTED]'
        if ($exitCode -ne 0) {
            throw "Azure CLI operation '$($Arguments[0]) $($Arguments[1])' failed (exit $exitCode): $message"
        }
        if (-not [string]::IsNullOrWhiteSpace($errorText)) {
            $warning = $errorText -replace '(?i)([?&](?:sig|token|code|client_secret|password)=)[^&\s]+', '$1[REDACTED]'
            Write-Warning ($warning -replace '(?i)(Bearer\s+)[^\s,;]+', '$1[REDACTED]')
        }
        return $output -join "`n"
    }
    finally { if (Test-Path -LiteralPath $errorPath) { Remove-Item -LiteralPath $errorPath -Force } }
}

function Invoke-EppDataOperation {
    param([scriptblock] $Operation)

    for ($attempt = 1; $attempt -le 12; $attempt++) {
        try { return & $Operation }
        catch {
            if ($attempt -eq 12 -or $_.Exception.Message -notmatch 'ForbiddenByRbac|AuthorizationPermissionMismatch|Caller is not authorized to perform action on resource') { throw }
            Write-Warning "Waiting for the new data-plane role assignment ($attempt/12)."
            Start-Sleep -Seconds 10
        }
    }
}

function Import-EppGraphModules {
    param([switch] $NonInteractive, [switch] $InstallPrerequisites)

    $requiredModules = @('Microsoft.Graph.Authentication', 'Microsoft.Graph.Applications')
    $missing = @($requiredModules | Where-Object {
        $available = @(Get-Module -ListAvailable -Name $_)
        -not @($available | Where-Object Version -ge ([Version]'2.0.0')).Count
    })
    if ($missing.Count) {
        if (-not $InstallPrerequisites) {
            if ($NonInteractive) {
                throw "Missing Microsoft Graph modules: $($missing -join ', '). Rerun with -InstallPrerequisites or install them for CurrentUser."
            }
            while ($true) {
                $answer = ([string](Read-Host "Install missing Microsoft Graph modules from PSGallery for CurrentUser ($($missing -join ', '))? Type Yes or No [No]")).Trim()
                if ($answer -ieq 'Yes') { break }
                if (-not $answer -or $answer -ieq 'No') {
                    throw "Install the missing Microsoft Graph modules and rerun setup. No Azure or tenant resources were changed."
                }
                Write-Warning 'Type Yes to install the listed modules, or No/Enter to stop.'
            }
        }
        if (-not (Get-Command Install-Module -ErrorAction SilentlyContinue)) {
            throw 'Install-Module is unavailable. Install PowerShellGet, then install the required Microsoft Graph modules.'
        }
        foreach ($name in $missing) {
            Write-Host "Installing $name from PSGallery for CurrentUser..." -ForegroundColor Cyan
            Install-Module -Name $name -Scope CurrentUser -Repository PSGallery -MinimumVersion 2.0.0 `
                -Force -AllowClobber -ErrorAction Stop
        }
    }

    # The SDK and its sign-in context belong to the session, not this temporary helper module.
    foreach ($name in $requiredModules) {
        $module = @(Get-Module -ListAvailable -Name $name) | Where-Object Version -ge ([Version]'2.0.0') |
            Sort-Object Version -Descending | Select-Object -First 1
        if (-not $module) { throw "Microsoft Graph module '$name' was not available after prerequisite setup." }
        $loaded = Get-Module -Name $name | Select-Object -First 1
        Import-Module $module.Path -Global -Force:($loaded -and $loaded.Version -ne $module.Version) -ErrorAction Stop
    }
    foreach ($command in @(
        'Connect-MgGraph', 'Invoke-MgGraphRequest', 'Get-MgApplication', 'Update-MgApplication',
        'Get-MgServicePrincipal', 'New-MgServicePrincipal', 'Update-MgServicePrincipal',
        'Get-MgServicePrincipalAppRoleAssignment', 'New-MgServicePrincipalAppRoleAssignment'
    )) {
        if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
            throw "The installed Microsoft Graph modules do not provide required command '$command'. Update both Graph modules and rerun."
        }
    }
}

function Confirm-EppPrerequisiteInstall {
    param([string] $Description, [switch] $NonInteractive, [switch] $InstallPrerequisites)

    if ($InstallPrerequisites) { return }
    if ($NonInteractive) { throw "$Description is missing. Rerun with -InstallPrerequisites or install it manually." }
    while ($true) {
        $answer = ([string](Read-Host "Install $Description now? Type Yes or No [No]")).Trim()
        if ($answer -ieq 'Yes') { return }
        if (-not $answer -or $answer -ieq 'No') { throw "$Description is required. No Azure or tenant resources were changed." }
        Write-Warning 'Type Yes to install the prerequisite, or No/Enter to stop.'
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

function Connect-EppAzureAccount {
    param([hashtable] $Inputs, [switch] $NonInteractive, [switch] $ForceAuthentication)

    $account = $null
    if ($ForceAuthentication) {
        if ($NonInteractive) { throw '-ForceAuthentication cannot be combined with -NonInteractive.' }
        Write-Host "Reauthenticating Azure CLI to tenant $($Inputs.TenantId) with device code..." -ForegroundColor Cyan
        Invoke-EppAz login --tenant $Inputs.TenantId --use-device-code --output none | Out-Null
        $account = Invoke-EppAz account show --subscription $Inputs.SubscriptionId --output json | ConvertFrom-Json
    }
    else {
        try {
            $account = Invoke-EppAz account show --subscription $Inputs.SubscriptionId --output json | ConvertFrom-Json
        }
        catch {
            if ($NonInteractive) {
                throw "Azure CLI is not signed in to subscription '$($Inputs.SubscriptionId)' in tenant '$($Inputs.TenantId)'. Run az login first."
            }
            Write-Host "Signing in to Azure tenant $($Inputs.TenantId)..." -ForegroundColor Cyan
            Invoke-EppAz login --tenant $Inputs.TenantId --output none | Out-Null
            $account = Invoke-EppAz account show --subscription $Inputs.SubscriptionId --output json | ConvertFrom-Json
        }
    }
    if ($account.id -ne $Inputs.SubscriptionId -or $account.tenantId -ne $Inputs.TenantId -or
        $account.state -ne 'Enabled' -or $account.environmentName -ne 'AzureCloud' -or $account.user.type -ne 'user') {
        throw 'Azure CLI must be signed in as a user to the requested enabled subscription and tenant in the public Azure cloud.'
    }
    return $account
}

function ConvertFrom-EppJwtPayload {
    param([string] $Token)

    $segments = $Token.Split('.')
    if ($segments.Count -ne 3 -or $segments[1].Length -gt 65536) {
        throw 'Azure CLI returned an invalid ARM access token.'
    }
    $payload = $segments[1].Replace('-', '+').Replace('_', '/')
    switch ($payload.Length % 4) {
        2 { $payload += '==' }
        3 { $payload += '=' }
        1 { throw 'Azure CLI returned an invalid ARM access-token payload.' }
    }
    try {
        return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) |
            ConvertFrom-Json -AsHashtable -ErrorAction Stop
    }
    catch {
        throw 'Azure CLI returned an unreadable ARM access-token payload.'
    }
}

function Get-EppArmOperatorObjectId {
    param([hashtable] $Inputs)

    $token = $null
    try {
        $token = Invoke-EppAz account get-access-token --subscription $Inputs.SubscriptionId `
            --resource 'https://management.azure.com/' --query accessToken --output tsv
        if ([string]::IsNullOrWhiteSpace($token)) { throw 'Azure CLI did not return an ARM access token.' }
        $claims = ConvertFrom-EppJwtPayload -Token $token
        if ($claims['tid'] -ne $Inputs.TenantId) {
            throw 'The ARM access token belongs to a different tenant than the approved deployment.'
        }
        return ConvertTo-EppGuid ([string]$claims['oid'])
    }
    finally { $token = $null }
}

function Get-EppGraphOperator {
    $operator = Invoke-MgGraphRequest -Method GET `
        -Uri 'https://graph.microsoft.com/v1.0/me?$select=id,userPrincipalName' `
        -OutputType PSObject -ErrorAction Stop
    $id = ConvertTo-EppGuid ([string]$operator.id)
    $account = if ([string]::IsNullOrWhiteSpace([string]$operator.userPrincipalName)) { $id } else { [string]$operator.userPrincipalName }
    return [pscustomobject]@{ Id = $id; Account = $account }
}

function Connect-EppGraphAccount {
    param([hashtable] $Inputs, [switch] $NonInteractive, [switch] $ForceAuthentication)

    if ($NonInteractive -and $ForceAuthentication) {
        throw '-ForceAuthentication requires interactive Graph device-code sign-in and cannot be combined with -NonInteractive.'
    }
    $graph = if ($ForceAuthentication) { $null } else { Get-EppInitialGraphContext }
    if ($ForceAuthentication -or -not (Test-EppGraphContext -Context $graph -TenantId $Inputs.TenantId)) {
        $scopeList = $script:GraphRequiredScopes -join ', '
        if ($NonInteractive) { throw "Connect-MgGraph to the customer tenant with $scopeList before noninteractive setup." }
        $connectArguments = @{
            TenantId = $Inputs.TenantId
            Scopes = $script:GraphRequiredScopes
            ContextScope = 'Process'
            NoWelcome = $true
            ErrorAction = 'Stop'
        }
        if ($ForceAuthentication) { $connectArguments.UseDeviceAuthentication = $true }
        Connect-MgGraph @connectArguments
        $graph = Get-MgContext -ErrorAction Stop
    }
    if (-not (Test-EppGraphContext -Context $graph -TenantId $Inputs.TenantId)) {
        throw "Microsoft Graph is not connected to the required customer tenant with delegated scopes: $($script:GraphRequiredScopes -join ', ')."
    }
    return [pscustomobject]@{ Context = $graph; Operator = Get-EppGraphOperator }
}

function Get-EppInitialGraphContext {
    try { return Get-MgContext -ErrorAction Stop }
    catch {
        if ($_.Exception.GetBaseException().Message -cne 'SessionNotInitialized') { throw }
    }

    # Graph's failed OnRemove hook can reset its static session while leaving the module loaded.
    $authentication = @(Get-Module -Name Microsoft.Graph.Authentication)
    if ($authentication.Count -ne 1) {
        throw 'The Graph SDK session is uninitialized and its loaded Authentication version is ambiguous. Run setup in a fresh PowerShell process with pwsh -NoProfile.'
    }
    Write-Warning 'An earlier module removal reset the Graph SDK session. Reloading its existing Authentication version once; sign-in may be required.'
    Import-Module Microsoft.Graph.Authentication -RequiredVersion $authentication[0].Version -Global -Force -ErrorAction Stop
    try { return Get-MgContext -ErrorAction Stop }
    catch {
        if ($_.Exception.GetBaseException().Message -cne 'SessionNotInitialized') { throw }
        throw 'The Graph SDK session could not be reinitialized. Run setup in a fresh PowerShell process with pwsh -NoProfile; no Azure resources were changed.'
    }
}

function Test-EppGraphContext {
    param($Context, [string] $TenantId)

    if (-not $Context -or $Context.TenantId -ne $TenantId -or $Context.Environment -ne 'Global' -or
        $Context.AuthType -ne 'Delegated') {
        return $false
    }
    return @($script:GraphRequiredScopes | Where-Object { $Context.Scopes -notcontains $_ }).Count -eq 0
}

function Get-EppSignInAudienceRestrictions {
    param([string] $ApplicationObjectId)

    $result = Invoke-MgGraphRequest -Method GET `
        -Uri "https://graph.microsoft.com/beta/applications/$ApplicationObjectId`?`$select=id,signInAudience,signInAudienceRestrictions" `
        -OutputType PSObject -ErrorAction Stop
    return $result.signInAudienceRestrictions
}

function Test-EppProviderTenantRestriction {
    param($Restriction, [string] $ProviderTenantId)

    return $Restriction -and $Restriction.kind -eq 'allowedTenants' -and
        $Restriction.isHomeTenantAllowed -eq $true -and
        @($Restriction.allowedTenantIds).Count -eq 1 -and
        $Restriction.allowedTenantIds[0] -eq $ProviderTenantId
}

function Set-EppProviderTenantRestriction {
    param([string] $ApplicationObjectId, [string] $ProviderTenantId)

    Invoke-MgGraphRequest -Method PATCH `
        -Uri "https://graph.microsoft.com/beta/applications/$ApplicationObjectId" `
        -Body @{
            signInAudience = 'AzureADMultipleOrgs'
            signInAudienceRestrictions = @{
                '@odata.type' = '#microsoft.graph.allowedTenantsAudience'
                kind = 'allowedTenants'
                isHomeTenantAllowed = $true
                allowedTenantIds = @($ProviderTenantId)
            }
        } -ContentType 'application/json' -ErrorAction Stop | Out-Null
}

function Get-EppResourceProviderRequirements {
    @(
        @{ Namespace = 'Microsoft.Web'; Type = 'sites' }
        @{ Namespace = 'Microsoft.Storage'; Type = 'storageAccounts' }
        @{ Namespace = 'Microsoft.KeyVault'; Type = 'vaults' }
        @{ Namespace = 'Microsoft.OperationalInsights'; Type = 'workspaces' }
        @{ Namespace = 'Microsoft.Insights'; Type = 'components' }
        @{ Namespace = 'Microsoft.ManagedIdentity'; Type = 'userAssignedIdentities' }
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
            Invoke-EppRegistrationRetry -Operation { Assert-EppPremiumLocation -Inputs $Inputs } | Out-Null
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

function Connect-EppContext {
    param(
        [hashtable] $Inputs, [Collections.IDictionary] $Names,
        [switch] $NonInteractive, [switch] $InstallPrerequisites, [switch] $ForceAuthentication
    )

    if ($NonInteractive -and $ForceAuthentication) {
        throw '-ForceAuthentication requires interactive device-code sign-in and cannot be combined with -NonInteractive.'
    }
    foreach ($command in @('az', 'New-SelfSignedCertificate', 'Export-Certificate')) {
        if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
            if ($command -eq 'az') {
                throw "Azure CLI is not installed or not on PATH. Install Azure CLI, open a new PowerShell 7 window, and rerun setup."
            }
            throw "Missing Windows certificate command '$command'. Run setup in PowerShell 7 on Windows."
        }
    }
    $cliVersion = Invoke-EppAz version --output json | ConvertFrom-Json
    if ([Version]$cliVersion.'azure-cli' -lt [Version]'2.48.1') {
        throw 'Azure CLI 2.48.1 or newer is required for deployment with SCM basic authentication disabled.'
    }
    Initialize-EppBicep -NonInteractive:$NonInteractive -InstallPrerequisites:$InstallPrerequisites
    Import-EppGraphModules -NonInteractive:$NonInteractive -InstallPrerequisites:$InstallPrerequisites
    $account = Connect-EppAzureAccount -Inputs $Inputs -NonInteractive:$NonInteractive `
        -ForceAuthentication:$ForceAuthentication
    $operatorId = Get-EppArmOperatorObjectId -Inputs $Inputs
    $graphAccount = Connect-EppGraphAccount -Inputs $Inputs -NonInteractive:$NonInteractive `
        -ForceAuthentication:$ForceAuthentication
    $graph = $graphAccount.Context
    $graphOperator = $graphAccount.Operator
    $applications = @(Get-MgApplication -Filter "appId eq '$($Inputs.ApplicationId)'" -All -ErrorAction Stop)
    if ($applications.Count -ne 1) { throw 'Complete manual Step 1: exactly one existing application with this client ID is required.' }
    $application = Get-MgApplication -ApplicationId $applications[0].Id `
        -Property Id, AppId, DisplayName, SignInAudience, Api, AppRoles, IdentifierUris, KeyCredentials, TokenEncryptionKeyId -ErrorAction Stop
    if ($application.SignInAudience -notin @('AzureADMyOrg', 'AzureADMultipleOrgs')) {
        throw 'The existing EPP application must be an organizational single- or multi-tenant app. Create a dedicated organizational app in manual Step 1.'
    }
    if ($application.TokenEncryptionKeyId) { throw 'Clear tokenEncryptionKeyId manually on the endpoint app. Easy Auth requires signed, not encrypted, bearer access tokens.' }

    $endpointPrincipals = @(Get-MgServicePrincipal -Filter "appId eq '$($Inputs.ApplicationId)'" -All -ErrorAction Stop)
    if ($endpointPrincipals.Count -gt 1) { throw 'Multiple endpoint service principals match the supplied application. Resolve the duplicate tenant objects manually.' }
    $callerPrincipals = @(Get-MgServicePrincipal -Filter "appId eq '$script:MicrosoftPhoneProviderAppId'" -All -ErrorAction Stop)
    if ($callerPrincipals.Count -gt 1) { throw 'Multiple Microsoft phone-provider service principals exist in this tenant. Resolve the duplicate tenant objects manually.' }
    $graphPrincipals = @(Get-MgServicePrincipal -Filter "appId eq '$script:MicrosoftGraphAppId'" -Property Id,AppId,AppRoles -All -ErrorAction Stop)
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
    $tenantRestriction = Get-EppSignInAudienceRestrictions -ApplicationObjectId $application.Id
    $version = if ($application.Api -and $application.Api.RequestedAccessTokenVersion) { [int]$application.Api.RequestedAccessTokenVersion } else { 1 }
    if ($version -notin @(1, 2)) { throw 'The endpoint application has an unsupported access-token version.' }

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
    }
    elseif ($groupExists -ne 'false') { throw 'Azure returned an invalid resource-group existence result.' }

    $resourceProviders = @(Get-EppResourceProviders -SubscriptionId $Inputs.SubscriptionId)
    Assert-EppProviderLocations -Providers $resourceProviders -Location $Inputs.Location
    $web = $resourceProviders | Where-Object Namespace -eq 'Microsoft.Web'
    if ($web.RegistrationState -eq 'Registered') {
        try { Assert-EppPremiumLocation -Inputs $Inputs }
        catch {
            if (-not (Test-EppRegistrationDelay $_.Exception.Message)) { throw }
            Write-Warning 'Azure resource-provider registration is still reaching this region. Availability will be checked again after approval.'
        }
    }
    return [pscustomobject]@{
        OperatorId = $operatorId; GraphOperatorId = $graphOperator.Id; GraphAccount = $graphOperator.Account
        Application = $application; TokenVersion = $version
        EndpointPrincipal = $endpointPrincipals | Select-Object -First 1
        CallerPrincipal = $callerPrincipals | Select-Object -First 1
        GraphPrincipal = $graphPrincipals[0]
        InvokeRoleExists = $invokeRoles.Count -eq 1
        ProviderTenantRestricted = Test-EppProviderTenantRestriction -Restriction $tenantRestriction `
            -ProviderTenantId $Inputs.ProviderTenantId
        ResourceProviders = $resourceProviders
    }
}

function Get-EppResourceRows {
    param([Collections.IDictionary] $Names)

    return @(
        [pscustomobject]@{ Resource = 'Resource group'; Name = $Names.resourceGroup; Description = 'Contains all Azure resources created by this deployment.' }
        [pscustomobject]@{ Resource = 'Function App'; Name = $Names.functionApp; Description = 'Hosts the External Phone Provider endpoint.' }
        [pscustomobject]@{ Resource = 'Hosting plan'; Name = $Names.hostingPlan; Description = 'Linux Premium EP1 compute for the Function App.' }
        [pscustomobject]@{ Resource = 'Storage account'; Name = $Names.storageAccount; Description = 'Provides Function host storage and private package storage.' }
        [pscustomobject]@{ Resource = 'Blob container'; Name = 'packages'; Description = 'Stores the verified deployment package privately.' }
        [pscustomobject]@{ Resource = 'Key Vault'; Name = $Names.keyVault; Description = 'Stores the encryption private key and provider credentials.' }
        [pscustomobject]@{ Resource = 'Function App identity'; Name = 'System-assigned'; Description = 'Accesses package storage, host storage, Key Vault, and monitoring.' }
        [pscustomobject]@{ Resource = 'Outbound identity'; Name = $Names.outboundIdentity; Description = 'Supports outbound provider authentication when required.' }
        [pscustomobject]@{ Resource = 'Log Analytics'; Name = $Names.logAnalytics; Description = 'Stores platform and application diagnostic logs.' }
        [pscustomobject]@{ Resource = 'Application Insights'; Name = $Names.applicationInsights; Description = 'Collects Function App telemetry.' }
        [pscustomobject]@{ Resource = 'Diagnostic settings'; Name = 'Configured'; Description = 'Routes supported resource logs and metrics to Log Analytics.' }
    )
}

function Show-EppPlan {
    param([hashtable] $Inputs, [Collections.IDictionary] $Names, $ProviderConfiguration, $Context, [string] $SourceBaseUri)

    Write-Host "`nDeployment plan (create or update)" -ForegroundColor Cyan
    Write-Host "Tenant:       $($Inputs.TenantId)"
    Write-Host "Subscription: $($Inputs.SubscriptionId)"
    Write-Host "Application:  $($Inputs.ApplicationId)"
    Write-Host "Location:     $($Inputs.Location)"
    Write-Host "Platform:     $($Inputs.Platform)"
    Write-Host "Provider:     $($ProviderConfiguration.DisplayName)"
    Write-Host "Channel:      $($ProviderConfiguration.Channel)"
    $tenantScope = if ($ProviderConfiguration.EndpointRegion -eq 'eu') { 'EU' } else { 'Global' }
    Write-Host "Tenant scope: $tenantScope"
    Write-Host "Provider auth: $($ProviderConfiguration.AuthenticationMode)"
    Write-Host "Provider tenant: $($ProviderConfiguration.Settings.EPP_PROVIDER_TENANT_ID)"
    Write-Host "API endpoint: $($ProviderConfiguration.Settings.EPP_PROVIDER_ENDPOINT)"
    if ($ProviderConfiguration.AuthenticationMode -eq 'oauth') {
        Write-Host "Provider API: $($ProviderConfiguration.Settings.EPP_PROVIDER_APP_ID) / $($ProviderConfiguration.Settings.EPP_PROVIDER_SCOPE)"
    }
    else {
        $auth = $ProviderConfiguration.Manifest.deployment.authentication
        Write-Host "Key Vault:    $($auth.keyVaultSecretName), $($auth.identityKeyVaultSecretName)"
    }
    Write-Host "Timeout:      $($ProviderConfiguration.Settings.EPP_PROVIDER_TIMEOUT_MS) ms"
    Write-Host "Retry:        $($ProviderConfiguration.Settings.EPP_PROVIDER_RETRY_INTERVAL_MS) ms (package-dependent; not a retry guarantee)"
    Write-Host "Package:      $($Inputs.PackageUrl)"
    Write-Host "Source hash:  $($Inputs.SourcePackageSha256) (verified automatically)"
    Write-Host "Source:       $SourceBaseUri"

    Write-Host "`nAzure resources and configuration" -ForegroundColor Cyan
    Get-EppResourceRows -Names $Names |
        Format-Table Resource, Name, Description -AutoSize | Out-String -Width 240 | Write-Host
    Write-Host '  - Required Azure resource providers are checked before deployment; existing registrations are reused.'
    $Context.ResourceProviders | Select-Object Namespace, RegistrationState | Format-Table -AutoSize | Out-String -Width 200 | Write-Host

    Write-Host "`nAccess and permissions" -ForegroundColor Cyan
    Write-Host '  - Function App managed identity:'
    Write-Host '      Storage Blob Data Owner - access the private deployment package.'
    Write-Host '      Storage Queue Data Contributor and Storage Table Data Contributor - use Azure Functions host storage.'
    Write-Host '      Key Vault Secrets User - read provider credentials and the encryption private key.'
    Write-Host '      Monitoring Metrics Publisher - publish platform metrics.'
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
        Write-Host '  - Restrict the multi-tenant endpoint application to the customer tenant and selected provider tenant.'
    }
    Write-Host '  - Configure Easy Auth to require HTTPS authentication and allow only the Microsoft phone-provider enterprise application.'
    Write-Host '  - Create an encryption certificate and store its private key in the new Key Vault.'
    if ($Inputs.ProviderAuthentication -eq 'oauth') {
        Write-Host '  - Soprano OAuth: add a federated credential so the outbound managed identity can authenticate without a client secret.'
    }
    else {
        Write-Host '  - Telesign API key: store the required provider credentials in Key Vault; no federated credential is created.'
    }

    Write-Host "`nDeployment notes" -ForegroundColor Cyan
    Write-Host '  - Deploy the verified package, synchronize Function triggers, and enable HTTPS ingress after Easy Auth is verified.'
    if ($Inputs.BuildStrategy -eq 'remote-build') {
        Write-Host '  - Python: use the Entra-protected SCM endpoint for remote build, then save only the built output in private package storage.'
    }
    Write-Host '  - Premium EP1, storage, and telemetry incur Azure charges.' -ForegroundColor Yellow
    Write-Host '  - Rerunning setup can restart the Function App.' -ForegroundColor Yellow
    Write-Host '  - Failed deployments are not automatically rolled back, and resources are not automatically deleted.' -ForegroundColor Yellow

}

function Confirm-EppDeployment {
    param([switch] $NonInteractive, [switch] $ApproveDeployment)

    if ($ApproveDeployment) { return $true }
    if ($NonInteractive) { throw 'Deployment requires -ApproveDeployment in noninteractive mode. No Azure resources were changed.' }
    while ($true) {
        $answer = ([string](Read-Host 'Deploy this complete plan? Type Yes or No [No]')).Trim()
        if ($answer -ieq 'Yes') { return $true }
        if (-not $answer -or $answer -ieq 'No') { return $false }
        Write-Warning 'Type Yes to deploy, or No/Enter to cancel.'
    }
}

function Show-EppDeploymentResult {
    param(
        [hashtable] $Inputs, [Collections.IDictionary] $Names, $ProviderConfiguration,
        [string] $EndpointUrl, [string] $ResultPath
    )

    Write-Host "`nDeployment completed" -ForegroundColor Green
    Write-Host "`nAzure resources created or updated" -ForegroundColor Cyan
    Get-EppResourceRows -Names $Names |
        Format-Table Resource, Name -AutoSize | Out-String -Width 160 | Write-Host
    Write-Host "Function endpoint: $EndpointUrl" -ForegroundColor Green
    Write-Host "Deployment details: $ResultPath"

    if ($ProviderConfiguration.Id -eq 'telesign') {
        $authentication = $ProviderConfiguration.Manifest.deployment.authentication
        Write-Host "`nPending operation" -ForegroundColor Yellow
        Write-Host "Add the Telesign credentials to Key Vault '$($Names.keyVault)':"
        Write-Host "   - $($authentication.identityKeyVaultSecretName) - your Telesign customer ID."
        Write-Host "   - $($authentication.keyVaultSecretName) - your Telesign API key."
        Write-Host '   Store the values as Key Vault secrets; do not enter them into this setup script or shared logs.'
    }

    Write-Host "`nNext steps" -ForegroundColor Cyan
    $authenticationMethod = if ($ProviderConfiguration.Channel -eq 'voice') { 'Voice' } else { 'Sms' }
    $graphPolicyEndpoint = "https://graph.microsoft.com/beta/policies/authenticationMethodsPolicy/authenticationMethodConfigurations/$authenticationMethod"
    Write-Host 'After validating the endpoint, update the External Phone Provider policy in Microsoft Graph:'
    Write-Host '   Microsoft Graph endpoint: ' -NoNewline
    Write-Host $graphPolicyEndpoint -ForegroundColor Yellow
    Write-Host '   url:   ' -NoNewline
    Write-Host $EndpointUrl -ForegroundColor Yellow
    Write-Host '   appId: ' -NoNewline
    Write-Host $Inputs.ApplicationId -ForegroundColor Yellow
    Write-Host '   The setup script did not change the External Phone Provider policy.'
}

function Get-EppServicePrincipal {
    param([string] $AppId, [string] $Description)

    $principals = @(Get-MgServicePrincipal -Filter "appId eq '$AppId'" `
        -Property Id,AppId,DisplayName,AccountEnabled,AppRoleAssignmentRequired,AppRoles -All -ErrorAction Stop)
    if ($principals.Count -gt 1) { throw "Multiple $Description service principals match app ID '$AppId'." }
    return $principals | Select-Object -First 1
}

function Ensure-EppServicePrincipal {
    param([string] $AppId, [string] $Description)

    $principal = Get-EppServicePrincipal -AppId $AppId -Description $Description
    if (-not $principal) {
        $principal = New-MgServicePrincipal -AppId $AppId -ErrorAction Stop
    }
    if (-not $principal -or $principal.AppId -ne $AppId -or -not $principal.Id -or $principal.AccountEnabled -eq $false) {
        throw "The $Description service principal is missing, disabled, or does not match app ID '$AppId'."
    }
    return $principal
}

function Ensure-EppAppRoleAssignment {
    param($Principal, $Resource, [string] $AppRoleId, [string] $Description)

    $assignments = @(Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $Principal.Id -All -ErrorAction Stop)
    $matching = @($assignments | Where-Object { $_.ResourceId -eq $Resource.Id -and $_.AppRoleId -eq $AppRoleId })
    if ($matching.Count -gt 1) { throw "Multiple $Description app-role assignments exist for the Microsoft phone-provider service principal." }
    if (-not $matching.Count) {
        for ($attempt = 1; $attempt -le 12; $attempt++) {
            try {
                New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $Principal.Id -BodyParameter @{
                    PrincipalId = $Principal.Id
                    ResourceId = $Resource.Id
                    AppRoleId = $AppRoleId
                } -ErrorAction Stop | Out-Null
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

    $application = Get-MgApplication -ApplicationId $Context.Application.Id `
        -Property Id,AppId,SignInAudience,Api,AppRoles,IdentifierUris,KeyCredentials,TokenEncryptionKeyId -ErrorAction Stop
    if ($application.AppId -ne $Inputs.ApplicationId -or
        $application.SignInAudience -notin @('AzureADMyOrg', 'AzureADMultipleOrgs') -or
        $application.TokenEncryptionKeyId) {
        throw 'The dedicated endpoint application changed after preflight or has unsupported token encryption enabled.'
    }
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
            AllowedMemberTypes = @('Application')
            Description = 'Allows the Microsoft phone-provider application to invoke this EPP endpoint.'
            DisplayName = 'Invoke EPP endpoint'
            Id = $script:EppInvokeAppRoleId
            IsEnabled = $true
            Value = $script:EppInvokeAppRoleValue
        }
    }
    if (-not $invokeRoles.Count) {
        Update-MgApplication -ApplicationId $application.Id -AppRoles $roles -ErrorAction Stop
    }
    $restriction = Get-EppSignInAudienceRestrictions -ApplicationObjectId $application.Id
    if ($application.SignInAudience -ne 'AzureADMultipleOrgs' -or
        -not (Test-EppProviderTenantRestriction -Restriction $restriction -ProviderTenantId $Inputs.ProviderTenantId)) {
        Set-EppProviderTenantRestriction -ApplicationObjectId $application.Id -ProviderTenantId $Inputs.ProviderTenantId
    }

    $endpointPrincipal = Ensure-EppServicePrincipal -AppId $Inputs.ApplicationId -Description 'endpoint'
    if (-not $endpointPrincipal.AppRoleAssignmentRequired) {
        Update-MgServicePrincipal -ServicePrincipalId $endpointPrincipal.Id -AppRoleAssignmentRequired:$true -ErrorAction Stop
        $endpointPrincipal = Get-EppServicePrincipal -AppId $Inputs.ApplicationId -Description 'endpoint'
    }
    if (-not $endpointPrincipal.AppRoleAssignmentRequired) {
        throw 'The endpoint service principal did not enable app-role assignment requirements.'
    }

    $callerPrincipal = Ensure-EppServicePrincipal -AppId $script:MicrosoftPhoneProviderAppId -Description 'Microsoft phone-provider'
    $graphPrincipal = Get-EppServicePrincipal -AppId $script:MicrosoftGraphAppId -Description 'Microsoft Graph'
    if (-not $graphPrincipal) { throw 'Microsoft Graph service principal is missing from the tenant.' }
    $graphReadRoles = @($graphPrincipal.AppRoles | Where-Object {
        $_.Id -eq $script:MicrosoftGraphApplicationReadAllRoleId -and $_.Value -eq 'Application.Read.All' -and
        $_.IsEnabled -and $_.AllowedMemberTypes -contains 'Application'
    })
    if ($graphReadRoles.Count -ne 1) { throw 'Microsoft Graph Application.Read.All does not match its expected application role.' }

    Ensure-EppAppRoleAssignment -Principal $callerPrincipal -Resource $endpointPrincipal `
        -AppRoleId $script:EppInvokeAppRoleId -Description $script:EppInvokeAppRoleValue
    try {
        Ensure-EppAppRoleAssignment -Principal $callerPrincipal -Resource $graphPrincipal `
            -AppRoleId $script:MicrosoftGraphApplicationReadAllRoleId -Description 'Microsoft Graph Application.Read.All'
    }
    catch {
        if ($_.Exception.Message -match 'Authorization_RequestDenied|Insufficient privileges|Forbidden') {
            throw 'Granting Microsoft Graph Application.Read.All to the Microsoft phone-provider service principal requires AppRoleAssignment.ReadWrite.All consent and a sufficiently privileged administrator, normally Privileged Role Administrator.'
        }
        throw
    }

    return [pscustomobject]@{
        EndpointPrincipalId = [string]$endpointPrincipal.Id
        CallerPrincipalId = [string]$callerPrincipal.Id
        GraphPrincipalId = [string]$graphPrincipal.Id
    }
}

function Get-EppEncryptionCertificate {
    param([hashtable] $Inputs, [string] $OutputDirectory)

    $subject = "CN=EPP-$($Inputs.ApplicationId)-$($Inputs.ResourcePrefix)"
    $certificate = Get-ChildItem Cert:\CurrentUser\My |
        Where-Object { $_.Subject -eq $subject -and $_.HasPrivateKey -and $_.NotAfter -gt (Get-Date).AddDays(30) } |
        Sort-Object NotAfter -Descending | Select-Object -First 1
    if (-not $certificate) {
        $certificate = New-SelfSignedCertificate -Subject $subject -CertStoreLocation 'Cert:\CurrentUser\My' `
            -KeyAlgorithm RSA -KeyLength 2048 -KeyExportPolicy Exportable -KeyUsage KeyEncipherment, DataEncipherment `
            -NotAfter (Get-Date).AddYears(1)
    }
    $publicPath = Join-Path $OutputDirectory "$($certificate.Thumbprint).cer"
    Export-Certificate -Cert $certificate -FilePath $publicPath -Force | Out-Null
    return $certificate
}

function Assert-EppGraphAccess {
    param([hashtable] $Inputs, $Certificate, [string] $KeyId, [string] $IdentifierUri)

    $applications = @(Get-MgApplication -Filter "appId eq '$($Inputs.ApplicationId)'" -All -ErrorAction Stop)
    if ($applications.Count -ne 1) { throw 'The endpoint application was not uniquely readable after configuration.' }
    $application = Get-MgApplication -ApplicationId $applications[0].Id `
        -Property Id,AppId,SignInAudience,AppRoles,IdentifierUris,KeyCredentials,TokenEncryptionKeyId -ErrorAction Stop
    $tenantRestriction = Get-EppSignInAudienceRestrictions -ApplicationObjectId $application.Id
    $invokeRoles = @($application.AppRoles | Where-Object {
        $_.Id -eq $script:EppInvokeAppRoleId -and $_.Value -eq $script:EppInvokeAppRoleValue -and
        $_.IsEnabled -and $_.AllowedMemberTypes -contains 'Application'
    })
    $keys = @($application.KeyCredentials | Where-Object {
        $_.KeyId -eq $KeyId -and $_.Usage -eq 'Encrypt' -and $_.CustomKeyIdentifier -and
        -not (Compare-Object $_.CustomKeyIdentifier $Certificate.GetCertHash())
    })
    if ($application.SignInAudience -ne 'AzureADMultipleOrgs' -or $application.TokenEncryptionKeyId -or
        $application.IdentifierUris -notcontains $IdentifierUri -or $invokeRoles.Count -ne 1 -or $keys.Count -ne 1) {
        throw 'Endpoint application readback is missing its multi-tenant setting, identifier URI, Epp.Invoke role, or encryption certificate.'
    }
    if (-not (Test-EppProviderTenantRestriction -Restriction $tenantRestriction -ProviderTenantId $Inputs.ProviderTenantId)) {
        throw 'Endpoint application readback does not restrict the multi-tenant app to the selected provider tenant.'
    }

    $endpointPrincipal = Get-EppServicePrincipal -AppId $Inputs.ApplicationId -Description 'endpoint'
    $callerPrincipal = Get-EppServicePrincipal -AppId $script:MicrosoftPhoneProviderAppId -Description 'Microsoft phone-provider'
    $graphPrincipal = Get-EppServicePrincipal -AppId $script:MicrosoftGraphAppId -Description 'Microsoft Graph'
    if (-not $endpointPrincipal -or -not $endpointPrincipal.AppRoleAssignmentRequired -or
        -not $callerPrincipal -or $callerPrincipal.AccountEnabled -eq $false -or -not $graphPrincipal) {
        throw 'Service-principal readback is incomplete or the endpoint does not require app-role assignment.'
    }
    $assignments = @(Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $callerPrincipal.Id -All -ErrorAction Stop)
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

function Set-EppPrivateKey {
    param($Certificate, [string] $KeyId, [string] $VaultName, [string] $SubscriptionId, [string] $Directory)

    $existing = @(Invoke-EppDataOperation {
        Invoke-EppAz keyvault secret list --vault-name $VaultName --subscription $SubscriptionId --output json
    } | ConvertFrom-Json -AsHashtable)
    $match = @($existing | Where-Object { $_['name'] -eq 'phone-provider-decryption-key' })
    if ($match.Count -and $match[0]['tags'] -and
        $match[0]['tags']['certificateThumbprint'] -eq $Certificate.Thumbprint -and
        $match[0]['tags']['encryptionKeyId'] -eq $KeyId) {
        if (-not $match[0]['attributes']['enabled'] -or
            ($match[0]['attributes']['expires'] -and [DateTimeOffset]::Parse($match[0]['attributes']['expires']) -le [DateTimeOffset]::UtcNow)) {
            throw 'The existing decryption secret is disabled or expired. Correct its state before rerunning setup.'
        }
        return
    }

    $rsa = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($Certificate)
    if (-not $rsa) { throw 'The encryption certificate must have an exportable RSA private key.' }
    $privatePath = Join-Path $Directory 'private-key.txt'
    try {
        $pem = "-----BEGIN PRIVATE KEY-----`n$([Convert]::ToBase64String($rsa.ExportPkcs8PrivateKey(), [Base64FormattingOptions]::InsertLineBreaks))`n-----END PRIVATE KEY-----"
        [IO.File]::WriteAllText($privatePath, [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pem)), [Text.UTF8Encoding]::new($false))
        Invoke-EppDataOperation {
            Invoke-EppAz keyvault secret set --vault-name $VaultName --subscription $SubscriptionId `
                --name phone-provider-decryption-key --file $privatePath --encoding utf-8 `
                --tags "certificateThumbprint=$($Certificate.Thumbprint)" "encryptionKeyId=$KeyId" --output none
        } | Out-Null
    }
    finally {
        $rsa.Dispose()
        if (Test-Path -LiteralPath $privatePath) { Remove-Item -LiteralPath $privatePath -Force }
    }
}

function Assert-EppPrivateKey {
    param([string] $VaultName, [string] $SubscriptionId, $Certificate, [string] $KeyId)

    $secret = Invoke-EppDataOperation {
        Invoke-EppAz keyvault secret show --vault-name $VaultName --subscription $SubscriptionId `
            --name phone-provider-decryption-key --output json
    } | ConvertFrom-Json -AsHashtable
    if (-not $secret -or -not $secret['attributes']['enabled'] -or
        $secret['tags']['certificateThumbprint'] -ne $Certificate.Thumbprint -or
        $secret['tags']['encryptionKeyId'] -ne $KeyId) {
        throw 'Key Vault readback does not match the approved encryption certificate and key ID.'
    }
}

function Set-EppApplicationEndpoint {
    param([hashtable] $Inputs, $Context, $Outputs, $Certificate, [string] $KeyId, [bool] $ConfigureFederation = $true)

    $application = Get-MgApplication -ApplicationId $Context.Application.Id `
        -Property Id, AppId, SignInAudience, IdentifierUris, KeyCredentials, TokenEncryptionKeyId -ErrorAction Stop
    if ($application.AppId -ne $Inputs.ApplicationId -or $application.SignInAudience -ne 'AzureADMultipleOrgs' -or $application.TokenEncryptionKeyId) {
        throw 'The application changed after preflight. Its identity, audience, and signed-token configuration must still match.'
    }
    $key = @{
        CustomKeyIdentifier = $Certificate.GetCertHash()
        DisplayName = "EPP encryption $($Certificate.Thumbprint)"
        Key = $Certificate.GetRawCertData()
        KeyId = $KeyId
        Type = 'AsymmetricX509Cert'
        Usage = 'Encrypt'
        StartDateTime = $Certificate.NotBefore.ToUniversalTime()
        EndDateTime = $Certificate.NotAfter.ToUniversalTime()
    }
    $uris = @($application.IdentifierUris | Where-Object { $_ })
    if ($uris -notcontains $Outputs.identifierUri.value) { $uris += $Outputs.identifierUri.value }
    $keys = @($application.KeyCredentials | Where-Object { $null -ne $_ })
    if (-not @($keys | Where-Object { $_.KeyId -eq $KeyId }).Count) { $keys += $key }
    # Do not set tokenEncryptionKeyId: JWE payload encryption is separate from bearer-token encryption.
    Update-MgApplication -ApplicationId $application.Id -IdentifierUris $uris -KeyCredentials $keys -ErrorAction Stop
    if (-not $ConfigureFederation) { return }

    $issuer = "https://login.microsoftonline.com/$($Inputs.TenantId)/v2.0"
    $audience = 'api://AzureADTokenExchange'
    $credentialName = "epp-$($Outputs.functionAppName.value)-outbound"
    $credentials = @(Get-MgApplicationFederatedIdentityCredential -ApplicationId $application.Id -All -ErrorAction Stop)
    $matching = @($credentials | Where-Object {
        $_.Issuer -ceq $issuer -and $_.Subject -ceq $Outputs.outboundPrincipalId.value -and
        @($_.Audiences).Count -eq 1 -and $_.Audiences[0] -ceq $audience
    })
    if (-not $matching.Count) {
        if (@($credentials | Where-Object Name -eq $credentialName).Count) { throw 'The outbound federated credential name is already used for a different trust. It will not be overwritten.' }
        New-MgApplicationFederatedIdentityCredential -ApplicationId $application.Id -BodyParameter @{
            Name = $credentialName; Issuer = $issuer; Subject = $Outputs.outboundPrincipalId.value; Audiences = @($audience)
        } -ErrorAction Stop | Out-Null
    }
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

function Set-EppPublicAccess {
    param([string] $SiteId, [string] $SubscriptionId, [ValidateSet('Enabled', 'Disabled')][string] $Access)

    Invoke-EppAz resource update --ids $SiteId --api-version 2024-04-01 --set "properties.publicNetworkAccess=$Access" `
        --subscription $SubscriptionId --output none | Out-Null
}

function Set-EppPackageSettings {
    param([string] $SiteId, [string] $SubscriptionId, [string] $PackageUrl, [string] $Directory)

    $current = Invoke-EppAz rest --method post `
        --url "https://management.azure.com$SiteId/config/appsettings/list?api-version=2024-04-01" `
        --subscription $SubscriptionId --output json | ConvertFrom-Json -AsHashtable
    if ($current['properties'] -isnot [Collections.IDictionary]) { throw 'Could not read existing Function App settings.' }
    $settings = $current['properties']
    $settings['WEBSITE_RUN_FROM_PACKAGE'] = $PackageUrl
    $settings['WEBSITE_RUN_FROM_PACKAGE_BLOB_MI_RESOURCE_ID'] = 'SystemAssigned'
    $settings['SCM_DO_BUILD_DURING_DEPLOYMENT'] = 'false'
    $settings['ENABLE_ORYX_BUILD'] = 'false'
    $settings.Remove('SCM_RUN_FROM_PACKAGE')
    $path = Join-Path $Directory 'runtime-appsettings.json'
    try {
        @{ properties = $settings } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding utf8NoBOM
        Invoke-EppAz rest --method put --url "https://management.azure.com$SiteId/config/appsettings?api-version=2024-04-01" `
            --body "@$path" --headers 'Content-Type=application/json' --subscription $SubscriptionId --output none | Out-Null
    }
    finally { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force } }
}

function Build-EppPythonPackage {
    param([hashtable] $Inputs, [Collections.IDictionary] $Names, [string] $SiteId, [string] $SourcePath, [string] $Directory)

    Write-Host 'Building Python and its Linux dependencies in Azure automatically...' -ForegroundColor Cyan
    Invoke-EppAz functionapp deployment source config-zip --resource-group $Names.resourceGroup --name $Names.functionApp `
        --subscription $Inputs.SubscriptionId --src $SourcePath --build-remote true --timeout 1800 --output none | Out-Null
    $site = Invoke-EppAz rest --method get --url "https://management.azure.com$SiteId`?api-version=2024-04-01" `
        --subscription $Inputs.SubscriptionId --output json | ConvertFrom-Json -AsHashtable
    $hosts = @($site['properties']['enabledHostNames'] | Where-Object { $_ -match '^[a-zA-Z0-9-]+\.scm\.(?:[a-zA-Z0-9-]+\.)?azurewebsites\.net$' })
    if ($hosts.Count -ne 1) { throw 'Azure did not return exactly one public-cloud SCM hostname for the Function App.' }
    $token = $null
    $secureToken = $null
    $path = Join-Path $Directory 'python-ready.zip'
    try {
        $token = Invoke-EppAz account get-access-token --subscription $Inputs.SubscriptionId `
            --resource 'https://management.azure.com/' --query accessToken --output tsv
        if ([string]::IsNullOrWhiteSpace($token)) { throw 'Azure CLI did not return an SCM access token.' }
        $secureToken = ConvertTo-SecureString $token -AsPlainText -Force
        Invoke-WebRequest -Uri "https://$($hosts[0])/api/zip/site/wwwroot/" -Authentication Bearer -Token $secureToken `
            -OutFile $path -TimeoutSec 300 -MaximumRedirection 0
    }
    finally {
        $token = $null
        if ($secureToken) { $secureToken.Dispose() }
    }
    # The source ZIP must never become the persistent run-from-package artifact.
    Assert-EppArchive -Path $path -Language python -Kind ready
    return $path
}

function Sync-EppFunctionTriggers {
    param([string] $SiteId, [string] $SubscriptionId)

    for ($attempt = 1; $attempt -le 12; $attempt++) {
        try {
            Invoke-EppAz rest --method post --url "https://management.azure.com$SiteId/syncfunctiontriggers?api-version=2024-04-01" `
                --subscription $SubscriptionId --output none | Out-Null
            return
        }
        catch {
            $transientHostError = $_.Exception.Message -match 'BadGateway|ServiceUnavailable|GatewayTimeout|Encountered an error \(InternalServerError\) from host runtime'
            if ($attempt -eq 12 -or -not $transientHostError) { throw }
            Write-Warning "Waiting for the Function host to load the package ($attempt/12). Easy Auth remains enforced."
            Start-Sleep -Seconds 10
        }
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

function Invoke-EppDeployment {
    param(
        [hashtable] $Inputs, [Collections.IDictionary] $Names, $ProviderConfiguration, $Context,
        [string] $AssetDirectory, $Package, [string] $OutputDirectory, [string] $SourceBaseUri
    )

    $graph = Get-MgContext
    $graphOperator = if (Test-EppGraphContext -Context $graph -TenantId $Inputs.TenantId) { Get-EppGraphOperator } else { $null }
    if (-not $graphOperator -or $graphOperator.Id -ne $Context.GraphOperatorId) {
        throw 'The Graph session changed after the plan was reviewed. Rerun setup.'
    }
    # The single setup approval covers these planned writes, including SDK/certificate cmdlets.
    $ConfirmPreference = 'None'
    $graphAccess = Initialize-EppGraphAccess -Inputs $Inputs -Context $Context
    Initialize-EppResourceProviders -Inputs $Inputs
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    $certificate = Get-EppEncryptionCertificate -Inputs $Inputs -OutputDirectory $OutputDirectory
    $existingKeys = @($Context.Application.KeyCredentials | Where-Object {
        $_ -and $_.Usage -eq 'Encrypt' -and $_.CustomKeyIdentifier -and
        -not (Compare-Object $_.CustomKeyIdentifier $certificate.GetCertHash())
    })
    if ($existingKeys.Count -gt 1) { throw 'Multiple encryption credentials match this certificate. Resolve the duplicate credentials manually.' }
    $keyId = if ($existingKeys.Count) { [string]$existingKeys[0].KeyId } else { [Guid]::NewGuid().ToString() }
    $settings = @{} + $ProviderConfiguration.Settings
    $settings.EPP_ENCRYPTION_KEY_ID = $keyId
    $settings.EPP_PROVIDER_AUTH_MODE = $Inputs.ProviderAuthentication
    $parameters = @{
        resourceNames = @{ value = $Names }
        location = @{ value = $Inputs.Location }
        tenantId = @{ value = $Inputs.TenantId }
        applicationId = @{ value = $Inputs.ApplicationId }
        tokenVersion = @{ value = $Context.TokenVersion }
        callerApplicationId = @{ value = $script:MicrosoftPhoneProviderAppId }
        deployerObjectId = @{ value = $Context.OperatorId }
        providerSettings = @{ value = $settings }
        packageBlobName = @{ value = "$($Inputs.PackageSha256).zip" }
        language = @{ value = $Inputs.Language }
        remoteBuild = @{ value = [bool]$Package.RequiresRemoteBuild }
    }
    $parameterPath = Join-Path $AssetDirectory 'deployment.parameters.json'
    @{ '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'; contentVersion = '1.0.0.0'; parameters = $parameters } |
        ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $parameterPath -Encoding utf8NoBOM
    Write-Host 'Deploying Bicep infrastructure...' -ForegroundColor Cyan
    $deploymentName = "epp-$($Inputs.ResourcePrefix)-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
    $outputs = Invoke-EppRegistrationRetry -Operation {
        Invoke-EppAz deployment sub create --name $deploymentName `
            --subscription $Inputs.SubscriptionId --location $Inputs.Location --template-file (Join-Path $AssetDirectory 'infra/main.bicep') `
            --parameters "@$parameterPath" --query properties.outputs --output json
    } | ConvertFrom-Json
    foreach ($mapping in @{ functionAppName = 'functionApp'; storageAccountName = 'storageAccount'; keyVaultName = 'keyVault'; resourceGroupName = 'resourceGroup' }.GetEnumerator()) {
        if ($outputs.($mapping.Key).value -cne $Names[$mapping.Value]) { throw 'Bicep outputs do not match the approved resource names. Stop and inspect the deployment.' }
    }
    $null = ConvertTo-EppGuid $outputs.outboundPrincipalId.value
    Assert-EppHttpsUrl $outputs.endpointUrl.value
    if ([Text.Encoding]::UTF8.GetByteCount($outputs.endpointUrl.value) -gt 100) { throw 'The deployed endpoint URL exceeds the EPP 100-byte limit.' }
    Set-EppPrivateKey -Certificate $certificate -KeyId $keyId -VaultName $Names.keyVault `
        -SubscriptionId $Inputs.SubscriptionId -Directory $AssetDirectory
    Assert-EppPrivateKey -VaultName $Names.keyVault -SubscriptionId $Inputs.SubscriptionId `
        -Certificate $certificate -KeyId $keyId
    Set-EppApplicationEndpoint -Inputs $Inputs -Context $Context -Outputs $outputs -Certificate $certificate -KeyId $keyId `
        -ConfigureFederation:($Inputs.ProviderAuthentication -eq 'oauth')
    $graphAccess = Assert-EppGraphAccess -Inputs $Inputs -Certificate $certificate -KeyId $keyId `
        -IdentifierUri $outputs.identifierUri.value
    $siteId = "/subscriptions/$($Inputs.SubscriptionId)/resourceGroups/$($Names.resourceGroup)/providers/Microsoft.Web/sites/$($Names.functionApp)"
    $ingressOpened = $false
    try {
        Assert-EppAuthentication -SiteId $siteId -Inputs $Inputs -Context $Context -IdentifierUri $outputs.identifierUri.value
        $packagePath = $Package.Path
        if ($Package.RequiresRemoteBuild) {
            $ingressOpened = $true
            Set-EppPublicAccess -SiteId $siteId -SubscriptionId $Inputs.SubscriptionId -Access Enabled
            $packagePath = Build-EppPythonPackage -Inputs $Inputs -Names $Names -SiteId $siteId -SourcePath $Package.Path -Directory $AssetDirectory
            $Inputs.PackageSha256 = (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        Write-Host 'Publishing the ready-to-run Function package...' -ForegroundColor Cyan
        Invoke-EppDataOperation {
            Invoke-EppAz storage blob upload --account-name $Names.storageAccount --container-name packages `
                --name "$($Inputs.PackageSha256).zip" --file $packagePath --auth-mode login --overwrite true `
                --subscription $Inputs.SubscriptionId --output none
        } | Out-Null
        if ($Package.RequiresRemoteBuild) {
            if ($outputs.packageContainerUrl.value -cne "https://$($Names.storageAccount).blob.core.windows.net/packages/") {
                throw 'Azure returned an unexpected package storage URL. The app will not mount it.'
            }
            $packageUrl = "$($outputs.packageContainerUrl.value)$($Inputs.PackageSha256).zip"
            Assert-EppHttpsUrl $packageUrl
            Set-EppPackageSettings -SiteId $siteId -SubscriptionId $Inputs.SubscriptionId -PackageUrl $packageUrl -Directory $AssetDirectory
        }
        if (-not $ingressOpened) {
            $ingressOpened = $true
            Set-EppPublicAccess -SiteId $siteId -SubscriptionId $Inputs.SubscriptionId -Access Enabled
        }
        Invoke-EppAz functionapp restart --resource-group $Names.resourceGroup --name $Names.functionApp `
            --subscription $Inputs.SubscriptionId --output none | Out-Null
        Sync-EppFunctionTriggers -SiteId $siteId -SubscriptionId $Inputs.SubscriptionId
        Assert-EppFunctionPublished -Inputs $Inputs -Names $Names
    }
    catch {
        $deploymentError = $_
        if ($ingressOpened) {
            try { Set-EppPublicAccess -SiteId $siteId -SubscriptionId $Inputs.SubscriptionId -Access Disabled }
            catch { throw [AggregateException]::new('Deployment failed and public ingress could not be disabled. Inspect the Function App immediately.', [Exception[]]@($deploymentError.Exception, $_.Exception)) }
        }
        throw $deploymentError
    }
    $result = [ordered]@{
        tenantId = $Inputs.TenantId; subscriptionId = $Inputs.SubscriptionId; applicationId = $Inputs.ApplicationId
        provider = $ProviderConfiguration.Id; channel = $ProviderConfiguration.Channel
        endpointRegion = $ProviderConfiguration.EndpointRegion; providerAuthentication = $Inputs.ProviderAuthentication
        providerTenantId = $Inputs.ProviderTenantId
        resourcePrefix = $Inputs.ResourcePrefix; resources = $Names
        language = $Inputs.Language
        endpointUrl = $outputs.endpointUrl.value; identifierUri = $outputs.identifierUri.value
        encryptionKeyId = $keyId; certificateThumbprint = $certificate.Thumbprint
        endpointServicePrincipalId = $graphAccess.EndpointPrincipalId
        microsoftPhoneProviderServicePrincipalId = $graphAccess.CallerPrincipalId
        eppInvokeAppRoleId = $script:EppInvokeAppRoleId
        microsoftGraphApplicationReadAll = $true
        packageUrl = $Inputs.PackageUrl; sourcePackageSha256 = $Inputs.SourcePackageSha256
        packageSha256 = $Inputs.PackageSha256; source = $SourceBaseUri
        policyChanged = $false
    }
    $resultPath = Join-Path $OutputDirectory "deployment-$([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))-$([Guid]::NewGuid().ToString('N').Substring(0, 8)).json"
    $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resultPath -Encoding utf8NoBOM

    Show-EppDeploymentResult -Inputs $Inputs -Names $Names -ProviderConfiguration $ProviderConfiguration `
        -EndpointUrl $outputs.endpointUrl.value -ResultPath $resultPath
    return [pscustomobject]$result
}

function Invoke-EppSetup {
    [CmdletBinding()]
    param(
        [string] $TenantId, [string] $SubscriptionId, [string] $ApplicationId, [string] $Location,
        [string] $Provider, [string] $Channel, [string] $EndpointRegion,
        [string] $ResourcePrefix,
        [string] $Language,
        [string] $OutputDirectory, [string] $AssetDirectory, [string] $SourceBaseUri,
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$')]
        [string] $SourceRepository = 'Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample',
        [string] $PackageReleaseTag,
        [switch] $NonInteractive, [switch] $InstallPrerequisites,
        [switch] $ForceAuthentication, [switch] $ApproveDeployment
    )

    Write-Host "`nEnter missing customer settings. Supplied values will not be requested again."
    $inputs = @{}
    foreach ($name in @('TenantId', 'SubscriptionId', 'ApplicationId')) {
        $inputs[$name] = Read-EppInput -Name $name -Value (Get-Variable -Name $name -ValueOnly) -Kind Guid `
            -NonInteractive:$NonInteractive
    }
    $inputs.Location = Read-EppInput Location $Location -Kind Location -Hint 'Azure region, for example westus2' -NonInteractive:$NonInteractive
    $channelSelection = Select-EppOption -Entries @(
        @{ id = 'sms'; displayName = 'SMS' }
        @{ id = 'voice'; displayName = 'Voice' }
    ) -Name Channel -Value $Channel -NonInteractive:$NonInteractive
    $tenantScopeSelection = Select-EppOption -Entries @(
        @{ id = 'global'; displayName = 'Global' }
        @{ id = 'eu'; displayName = 'EU' }
    ) -Name EndpointRegion -PromptName 'Tenant scope' -Value $EndpointRegion -NonInteractive:$NonInteractive

    $providerConfiguration = Get-EppProvider -AssetDirectory $AssetDirectory -SourceBaseUri $SourceBaseUri -Provider $Provider `
        -Channel $channelSelection['id'] -EndpointRegion $tenantScopeSelection['id'] `
        -NonInteractive:$NonInteractive -SourceRepository $SourceRepository
    $inputs.ProviderAuthentication = $providerConfiguration.AuthenticationMode
    $inputs.ProviderTenantId = $providerConfiguration.Settings.EPP_PROVIDER_TENANT_ID
    $selection = Get-EppLanguage -AssetDirectory $AssetDirectory -Language $Language -SourceRepository $SourceRepository `
        -PackageReleaseTag $PackageReleaseTag -NonInteractive:$NonInteractive
    $inputs.Language = $selection.Id
    $inputs.Platform = $selection.DisplayName
    $inputs.PackageUrl = $selection.Url
    $inputs.BuildStrategy = $selection.BuildStrategy
    $inputs.ResourcePrefix = Read-EppInput ResourcePrefix $ResourcePrefix -Kind Prefix `
        -Hint 'All resources created by this script will start with this prefix' -NonInteractive:$NonInteractive
    $names = Get-EppResourceNames -SubscriptionId $inputs.SubscriptionId -ApplicationId $inputs.ApplicationId -ResourcePrefix $inputs.ResourcePrefix

    Write-Host "`nChecking prerequisites and the selected Azure context (no resource changes)..." -ForegroundColor Cyan
    $context = Connect-EppContext -Inputs $inputs -Names $names -NonInteractive:$NonInteractive `
        -InstallPrerequisites:$InstallPrerequisites -ForceAuthentication:$ForceAuthentication
    $package = Get-EppPackage -Selection $selection -Directory $AssetDirectory
    $inputs.PackageSha256 = $package.Sha256
    $inputs.SourcePackageSha256 = $package.SourceSha256
    Invoke-EppAz bicep build --file (Join-Path $AssetDirectory 'infra/main.bicep') `
        --outfile (Join-Path $AssetDirectory 'main.json') | Out-Null
    Show-EppPlan -Inputs $inputs -Names $names -ProviderConfiguration $providerConfiguration -Context $context -SourceBaseUri $SourceBaseUri
    if (-not (Confirm-EppDeployment -NonInteractive:$NonInteractive -ApproveDeployment:$ApproveDeployment)) {
        Write-Host 'Cancelled. No Azure resources were changed.' -ForegroundColor Yellow
        return
    }
    try {
        $null = Invoke-EppDeployment -Inputs $inputs -Names $names -ProviderConfiguration $providerConfiguration -Context $context `
            -AssetDirectory $AssetDirectory -Package $package -OutputDirectory $OutputDirectory -SourceBaseUri $SourceBaseUri
    }
    catch {
        Write-Warning 'Deployment did not complete. Previously created resources are left in place; no rollback or policy activation was attempted. Correct the reported failure and rerun with the same inputs and prefix.'
        throw
    }
}

Export-ModuleMember -Function Invoke-EppSetup
