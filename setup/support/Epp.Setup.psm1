#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:MicrosoftPhoneProviderAppId = '25ec60fa-f18d-41a4-b398-50044c90ce13'
$script:MicrosoftGraphAppId = '00000003-0000-0000-c000-000000000000'
$script:MicrosoftGraphApplicationReadAllRoleId = '9a5d68dd-52b0-4cc2-bd40-abcf44ac3a30'
$script:EppInvokeAppRoleId = 'ddf32018-9212-41c7-b73c-f5dfe73a2f24'
$script:EppInvokeAppRoleValue = 'Epp.Invoke'
$script:EppCertificateName = 'phone-provider-encryption'
$script:EppCertificateSubject = 'CN=ExternalPhoneProvider'
$script:KeyVaultSecretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'
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
        [string] $PromptName, [switch] $NonInteractive, [switch] $AllowCancel
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
    if ($AllowCancel) { Write-Host '  [0] Cancel (also Enter)' }
    while ($true) {
        $answer = ([string](Read-Host "$displayName number or name")).Trim()
        if ($AllowCancel -and (-not $answer -or $answer -in @('0', 'Cancel'))) { return $null }
        $number = 0
        if ([int]::TryParse($answer, [ref] $number) -and $number -ge 1 -and $number -le $Entries.Count) { return $Entries[$number - 1] }
        $selected = $Entries | Where-Object { $_['id'] -ieq $answer -or $_['displayName'] -ieq $answer } | Select-Object -First 1
        if ($selected) { return $selected }
        Write-Warning "Choose one of the listed $($displayName.ToLowerInvariant()) options."
    }
}

function Get-EppServicePlan {
    param([string] $ServicePlan, [switch] $NonInteractive)

    Write-Host "`nService plan selection" -ForegroundColor Cyan
    Write-Host 'Flex Consumption has a free usage grant, not a zero-cost guarantee. Additional usage, Key Vault, storage, and telemetry can incur charges.'
    return Select-EppOption -Entries @(
        @{ id = 'FC1'; displayName = 'Flex Consumption FC1 (free grant, cold starts, cache settings false)' }
        @{ id = 'EP1'; displayName = 'Premium EP1 (warm instance, cache settings true)' }
    ) -Name ServicePlan -PromptName 'Service plan' -Value $ServicePlan -NonInteractive:$NonInteractive
}

function Read-EppInput {
    param(
        [string] $Name, [string] $Value, [string] $Hint,
        [ValidateSet('Text', 'Guid', 'Location', 'Prefix', 'PackageUrl', 'Hash')]
        [string] $Kind = 'Text',
        [switch] $NonInteractive, [switch] $AllowCancel,
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
        if (-not $supplied -and $AllowCancel -and (-not $Value -or $Value -ieq 'Cancel')) { return $null }
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
        [string] $AssetDirectory, [string] $SourceBaseUri, [string] $Provider,
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
        Assert-EppExistingServicePlan -Inputs $Inputs -Names $Names -Tags $tags
    }
    elseif ($groupExists -ne 'false') { throw 'Azure returned an invalid resource-group existence result.' }

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
            -ProviderTenantId $Inputs.ProviderTenantId
        ResourceProviders = $resourceProviders
    }
}

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
        [pscustomobject]@{ Resource = 'Blob container'; Name = 'packages'; Description = 'Stores the verified deployment package privately.' }
        [pscustomobject]@{ Resource = 'Key Vault'; Name = $Names.keyVault; Description = 'Stores provider credentials and newly issued encryption certificates.' }
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
    Write-Host "Service plan: $($Inputs.ServicePlan)"
    $cacheEnabled = ($Inputs.ServicePlan -eq 'EP1').ToString().ToLowerInvariant()
    Write-Host "Cache app settings: EPP_KEY_VAULT_CACHE_ENABLED=$cacheEnabled; EPP_ACCESS_TOKEN_CACHE_ENABLED=$cacheEnabled"
    Write-Host 'Cache control requires a Function package that reads these settings; setting them alone does not change runtime caching.' -ForegroundColor Yellow
    Write-Host "Provider:     $($ProviderConfiguration.DisplayName)"
    Write-Host 'Channels:     SMS and voice (selected by each request)'
    $tenantScope = if ($ProviderConfiguration.EndpointRegion -eq 'eu') { 'EU' } else { 'Global' }
    Write-Host "Tenant scope: $tenantScope"
    Write-Host "Provider auth: $($ProviderConfiguration.AuthenticationMode)"
    Write-Host "Provider tenant: $($ProviderConfiguration.Settings.EPP_PROVIDER_TENANT_ID)"
    Write-Host "SMS endpoint: $($ProviderConfiguration.Settings.EPP_PROVIDER_SMS_ENDPOINT)"
    Write-Host "Voice endpoint: $($ProviderConfiguration.Settings.EPP_PROVIDER_VOICE_ENDPOINT)"
    Write-Host 'Per-channel routing requires a Function package that reads EPP_PROVIDER_SMS_ENDPOINT and EPP_PROVIDER_VOICE_ENDPOINT.' -ForegroundColor Yellow
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
    Get-EppResourceRows -Names $Names -ServicePlan $Inputs.ServicePlan |
        Format-Table Resource, Name, Description -AutoSize | Out-String -Width 240 | Write-Host
    Write-Host '  - Required Azure resource providers are checked before deployment; existing registrations are reused.'
    $Context.ResourceProviders | Select-Object Namespace, RegistrationState | Format-Table -AutoSize | Out-String -Width 200 | Write-Host

    Write-Host "`nAccess and permissions" -ForegroundColor Cyan
    Write-Host '  - Function App managed identity:'
    Write-Host '      Storage Blob Data Owner - access the private deployment package.'
    Write-Host '      Storage Queue Data Contributor and Storage Table Data Contributor - use Azure Functions host storage.'
    Write-Host '      Key Vault Secrets User - read provider credentials and the encryption private key.'
    Write-Host '      Monitoring Metrics Publisher - publish platform metrics.'
    Write-Host '  - Setup operator, scoped to this Key Vault:'
    Write-Host '      Key Vault Certificates Officer - issue and inspect the encryption certificate.'
    Write-Host '      Key Vault Secrets Officer - manage provider credentials.'
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
    Show-EppCertificatePlan -Plan $Context.CertificatePlan -Names $Names
    if ($Inputs.ProviderAuthentication -eq 'oauth') {
        Write-Host '  - Soprano OAuth: add a federated credential so the outbound managed identity can authenticate without a client secret.'
    }
    else {
        Write-Host '  - Telesign API key: store the required provider credentials in Key Vault; no federated credential is created.'
    }

    Write-Host "`nDeployment notes" -ForegroundColor Cyan
    Write-Host '  - Deploy the verified package, synchronize Function triggers, and enable HTTPS ingress after Easy Auth is verified.'
    if ($Inputs.ServicePlan -eq 'FC1') {
        Write-Host '  - Flex Consumption: publish through One Deploy; Python builds remotely in Azure. No always-ready instances.'
        Write-Host '  - FC1 includes a free usage grant. Usage beyond the grant, Key Vault, storage, and telemetry can incur charges.' -ForegroundColor Yellow
    }
    elseif ($Inputs.BuildStrategy -eq 'remote-build') {
        Write-Host '  - Python: use the Entra-protected SCM endpoint for remote build, then save only the built output in private package storage.'
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
        $answer = ([string](Read-Host 'Deploy this complete plan? Type Yes or No [No]')).Trim()
        if ($answer -ieq 'Yes') { return $true }
        if (-not $answer -or $answer -ieq 'No') { return $false }
        Write-Warning 'Type Yes to deploy, or No/Enter to cancel.'
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
        Write-Host '  Reuse does not change external-vault network rules; the Function must be able to reach the certificate vault.'
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

    Write-Host "`nDeployment completed" -ForegroundColor Green
    Write-Host "`nAzure resources created or updated" -ForegroundColor Cyan
    Get-EppResourceRows -Names $Names -ServicePlan $Inputs.ServicePlan |
        Format-Table Resource, Name -AutoSize | Out-String -Width 160 | Write-Host
    Write-Host "Function endpoint: $EndpointUrl" -ForegroundColor Green
    Write-Host "Service plan: $($Inputs.ServicePlan)"
    Write-Host "Deployment details: $ResultPath"
    Write-Host 'Certificate renewal is manual. Track the expiry in the deployment details and coordinate the Entra certificate update before expiry.' -ForegroundColor Yellow

    if ($ProviderConfiguration.Id -eq 'telesign') {
        $authentication = $ProviderConfiguration.Manifest.deployment.authentication
        Write-Host "`nPending operation" -ForegroundColor Yellow
        Write-Host "Add the Telesign credentials to Key Vault '$($Names.keyVault)':"
        Write-Host "   - $($authentication.identityKeyVaultSecretName) - your Telesign customer ID."
        Write-Host "   - $($authentication.keyVaultSecretName) - your Telesign API key."
        Write-Host '   Store the values as Key Vault secrets; do not enter them into this setup script or shared logs.'
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
    Assert-EppCertificatePlanUnchanged -Application $application -Plan $Context.CertificatePlan
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

function ConvertTo-EppKeyVaultObjectId {
    param([string] $Value, [ValidateSet('certificates', 'secrets')][string] $Kind)

    $pattern = '^https://(?<vault>[a-z][a-z0-9-]{1,22}[a-z0-9])\.vault\.azure\.net/' +
        $Kind + '/(?<name>[a-z0-9-]{1,127})/(?<version>[0-9a-f]{32})$'
    if ($Value -notmatch $pattern) {
        throw "Use a versioned Key Vault URL: https://<vault>.vault.azure.net/$Kind/<name>/<32-character-version>."
    }
    return @{
        Id = $Value; VaultName = $Matches.vault.ToLowerInvariant()
        Name = $Matches.name; Version = $Matches.version
    }
}

function Get-EppKeyCredentialSnapshot {
    param([object[]] $Credentials)

    $values = @(foreach ($key in @($Credentials | Where-Object { $null -ne $_ } | Sort-Object KeyId)) {
        [ordered]@{
            KeyId = [string]$key.KeyId; Type = $key.Type; Usage = $key.Usage; DisplayName = $key.DisplayName
            Key = if ($key.Key) { [Convert]::ToBase64String([byte[]]$key.Key) } else { $null }
            CustomKeyIdentifier = if ($key.CustomKeyIdentifier) { [Convert]::ToBase64String([byte[]]$key.CustomKeyIdentifier) } else { $null }
            StartDateTime = if ($key.StartDateTime) { ([DateTimeOffset]$key.StartDateTime).ToUniversalTime().ToString('o') } else { $null }
            EndDateTime = if ($key.EndDateTime) { ([DateTimeOffset]$key.EndDateTime).ToUniversalTime().ToString('o') } else { $null }
        }
    })
    return ConvertTo-Json -InputObject $values -Depth 5 -Compress
}

function Assert-EppCertificatePlanUnchanged {
    param($Application, [Collections.IDictionary] $Plan)

    if (-not $Plan -or (Get-EppKeyCredentialSnapshot $Application.KeyCredentials) -cne $Plan.Snapshot) {
        throw 'The application credentials changed after certificate selection. No encryption credentials will be removed. Rerun setup and review a new plan.'
    }
}

function ConvertFrom-EppCertificateBundle {
    param([Collections.IDictionary] $Bundle, [switch] $RequireSetupPolicy)

    if (-not $Bundle -or -not $Bundle['cer'] -or -not $Bundle['sid'] -or -not $Bundle['id']) {
        throw 'Key Vault returned incomplete certificate metadata.'
    }
    $certificateId = ConvertTo-EppKeyVaultObjectId $Bundle['id'] certificates
    $secretId = ConvertTo-EppKeyVaultObjectId $Bundle['sid'] secrets
    if ($secretId.VaultName -ine $certificateId.VaultName -or $secretId.Name -ine $certificateId.Name) {
        throw 'The certificate backing secret must belong to the same vault and certificate name.'
    }
    $policy = $Bundle['policy']
    if ($Bundle['attributes'] -isnot [Collections.IDictionary] -or $Bundle['attributes']['enabled'] -ne $true -or
        $policy -isnot [Collections.IDictionary] -or
        $policy['keyProperties'] -isnot [Collections.IDictionary] -or
        $policy['secretProperties'] -isnot [Collections.IDictionary] -or
        $policy['keyProperties']['keyType'] -cne 'RSA' -or $policy['keyProperties']['exportable'] -ne $true -or
        $policy['secretProperties']['contentType'] -cne 'application/x-pem-file') {
        throw 'Use an enabled certificate with exportable RSA and a PEM backing secret. Setup will not overwrite an incompatible certificate.'
    }
    $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new([Convert]::FromBase64String($Bundle['cer']))
    try {
        $rsa = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey($certificate)
        try {
            if (-not $rsa -or $rsa.KeySize -lt 2048 -or $certificate.HasPrivateKey -or
                $certificate.NotBefore.ToUniversalTime() -gt [DateTime]::UtcNow -or
                $certificate.NotAfter.ToUniversalTime() -le [DateTime]::UtcNow.AddDays(30)) {
                throw 'The certificate must contain an RSA public key of at least 2048 bits, be valid now, and have more than 30 days remaining.'
            }
        }
        finally { if ($rsa) { $rsa.Dispose() } }
        if ($RequireSetupPolicy) {
            $actions = @($policy['lifetimeActions'])
            if ($certificate.Subject -cne $script:EppCertificateSubject -or
                $policy['keyProperties']['reuseKey'] -ne $true -or
                $actions.Count -ne 1 -or $actions[0]['action']['actionType'] -cne 'EmailContacts') {
                throw "Setup will not overwrite an incompatible certificate. Its subject must be '$script:EppCertificateSubject', with key reuse and manual renewal."
            }
        }
        return [pscustomobject]@{ Certificate = $certificate; CertificateId = $Bundle['id']; SecretId = $Bundle['sid'] }
    }
    catch { $certificate.Dispose(); throw }
}

function Assert-EppCertificateSecret {
    param([string] $SecretId, [string] $SubscriptionId)

    $secret = ConvertTo-EppKeyVaultObjectId $SecretId secrets
    # Listing version metadata never retrieves the private-key value.
    $versions = Invoke-EppDataOperation {
        Invoke-EppAz keyvault secret list-versions --vault-name $secret.VaultName --name $secret.Name `
            --subscription $SubscriptionId --output json
    } | ConvertFrom-Json -AsHashtable -NoEnumerate
    if ($versions -isnot [array]) { throw 'Key Vault returned an invalid secret-version list.' }
    $matching = @($versions | Where-Object { $_['id'] -ieq $SecretId })
    if ($matching.Count -ne 1 -or $matching[0]['managed'] -ne $true -or
        $matching[0]['contentType'] -cne 'application/x-pem-file' -or
        $matching[0]['attributes'] -isnot [Collections.IDictionary] -or
        $matching[0]['attributes']['enabled'] -ne $true) {
        throw 'The selected certificate must have an enabled, certificate-managed PEM secret version.'
    }
    $attributes = $matching[0]['attributes']
    if (($attributes['notBefore'] -and [DateTimeOffset]$attributes['notBefore'] -gt [DateTimeOffset]::UtcNow) -or
        ($attributes['expires'] -and [DateTimeOffset]$attributes['expires'] -le [DateTimeOffset]::UtcNow.AddDays(30))) {
        throw 'The certificate backing secret must be valid now and have more than 30 days remaining.'
    }
}

function Get-EppExistingEncryptionCertificate {
    param([string] $CertificateId, [string] $SubscriptionId)

    $null = ConvertTo-EppKeyVaultObjectId $CertificateId certificates
    $bundle = Invoke-EppAz keyvault certificate show --id $CertificateId --subscription $SubscriptionId --output json |
        ConvertFrom-Json -AsHashtable
    if ($bundle -isnot [Collections.IDictionary] -or $bundle['id'] -ine $CertificateId) {
        throw 'Key Vault returned a different or incomplete certificate version than requested.'
    }
    $issued = ConvertFrom-EppCertificateBundle -Bundle $bundle
    try {
        Assert-EppCertificateSecret -SecretId $issued.SecretId -SubscriptionId $SubscriptionId
        return $issued
    }
    catch { $issued.Certificate.Dispose(); throw }
}

function Get-EppCertificateVault {
    param([hashtable] $Inputs, [string] $VaultName, [string] $SubscriptionId)

    $vault = Invoke-EppAz keyvault show --name $VaultName --subscription $SubscriptionId --output json |
        ConvertFrom-Json -AsHashtable
    $idPattern = '^/subscriptions/' + [regex]::Escape($SubscriptionId) +
        '/resourceGroups/[^/]+/providers/Microsoft.KeyVault/vaults/' + [regex]::Escape($VaultName) + '$'
    if ($vault -isnot [Collections.IDictionary] -or $vault['id'] -notmatch $idPattern -or
        $vault['properties'] -isnot [Collections.IDictionary] -or
        $vault['properties']['tenantId'] -ine $Inputs.TenantId -or
        $vault['properties']['vaultUri'] -ine "https://$VaultName.vault.azure.net/") {
        throw 'The certificate vault must be in the specified subscription and the Function application tenant.'
    }
    return $vault
}

function Get-EppCertificatePlan {
    param(
        [hashtable] $Inputs, [Collections.IDictionary] $Names, $Application,
        [string] $CertificateAction, [string] $EncryptionKeyId, [string] $KeyVaultCertificateId,
        [string] $KeyVaultSubscriptionId, [switch] $NonInteractive
    )

    $keys = @($Application.KeyCredentials | Where-Object { $null -ne $_ })
    $encryptionKeys = @($keys | Where-Object Usage -eq 'Encrypt')
    if (@($encryptionKeys | Where-Object Type -ne 'AsymmetricX509Cert').Count) {
        throw 'The application has an unsupported Encrypt credential type. Have its owner review it; setup only manages AsymmetricX509Cert encryption credentials.'
    }
    if (@($keys | Where-Object { $_.Usage -ne 'Encrypt' -and -not $_.Key }).Count) {
        throw 'A non-encryption credential is unreadable and cannot be safely preserved. Resolve its read access before setup.'
    }
    $ids = @($keys | ForEach-Object { ConvertTo-EppGuid ([string]$_.KeyId) })
    if (@($ids | Select-Object -Unique).Count -ne $ids.Count) { throw 'The application contains duplicate key IDs. Resolve these invalid credentials before setup.' }
    $snapshot = Get-EppKeyCredentialSnapshot $keys
    $choices = @(foreach ($key in $encryptionKeys) {
        $thumbprint = 'unreadable'
        if ($key.Key) {
            try {
                $public = [Security.Cryptography.X509Certificates.X509Certificate2]::new([byte[]]$key.Key)
                try { $thumbprint = $public.Thumbprint }
                finally { $public.Dispose() }
            }
            catch [Security.Cryptography.CryptographicException] {
                Write-Warning "Encryption credential '$($key.KeyId)' has an unreadable certificate and cannot be reused."
            }
        }
        $expires = if ($key.EndDateTime) { ([DateTimeOffset]$key.EndDateTime).ToUniversalTime().ToString('o') } else { 'unknown' }
        $status = if (-not $key.StartDateTime -or -not $key.EndDateTime) { 'unknown validity' }
            elseif ([DateTimeOffset]$key.StartDateTime -gt [DateTimeOffset]::UtcNow) { 'not yet valid' }
            elseif ([DateTimeOffset]$key.EndDateTime -le [DateTimeOffset]::UtcNow) { 'expired' }
            elseif ([DateTimeOffset]$key.EndDateTime -le [DateTimeOffset]::UtcNow.AddDays(30)) { 'near expiry' }
            else { 'valid' }
        $name = ([string]$key.DisplayName) -replace '[\x00-\x1f\x7f]', ' '
        @{ id = [string]$key.KeyId; displayName = "$name | keyId=$($key.KeyId) | thumbprint=$thumbprint | expires=$expires | $status" }
    })
    Write-Host "`nRegistered encryption certificates: $($encryptionKeys.Count)" -ForegroundColor Cyan
    foreach ($choice in $choices) { Write-Host "  $($choice.displayName)" }

    while ($true) {
        $action = $CertificateAction
        if (-not $encryptionKeys.Count) {
            if ($action -and $action -ine 'Create') { throw 'No encryption certificate is registered. Omit -CertificateAction or use Create.' }
            $action = 'Create'
        }
        else {
            $option = Select-EppOption -Entries @(
                @{ id = 'Reuse'; displayName = 'Keep one existing certificate and remove any other encryption credentials' }
                @{ id = 'Replace'; displayName = 'Create a new certificate and remove all existing encryption credentials' }
            ) -Name CertificateAction -PromptName 'Encryption certificate action' -Value $action -AllowCancel -NonInteractive:$NonInteractive
            if (-not $option) { return $null }
            $action = $option.id
        }
        $plan = @{
            Action = $action; Snapshot = $snapshot; ExistingCertificates = $choices
            NonEncryptionSnapshot = Get-EppKeyCredentialSnapshot @($keys | Where-Object Usage -ne 'Encrypt')
            KeyId = [Guid]::NewGuid().ToString(); RemoveKeyIds = @($encryptionKeys | ForEach-Object { [string]$_.KeyId })
            CertificateName = $script:EppCertificateName; CertificateId = $null; SecretId = $null
            Thumbprint = $null; ExpiresUtc = $null
            VaultName = $Names.keyVault; VaultSubscriptionId = $Inputs.SubscriptionId
            VaultResourceId = "/subscriptions/$($Inputs.SubscriptionId)/resourceGroups/$($Names.resourceGroup)/providers/Microsoft.KeyVault/vaults/$($Names.keyVault)"
            VaultRbac = $true
        }
        if ($action -ne 'Reuse') {
            if ($EncryptionKeyId -or $KeyVaultCertificateId -or $KeyVaultSubscriptionId) {
                throw '-EncryptionKeyId, -KeyVaultCertificateId, and -KeyVaultSubscriptionId are only valid with -CertificateAction Reuse.'
            }
            if ($action -eq 'Replace') {
                # A retry before registration reuses the same staged certificate, without overwriting an active version.
                $sha = [Security.Cryptography.SHA256]::Create()
                try {
                    $seed = Get-EppKeyCredentialSnapshot $encryptionKeys
                    $suffix = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($seed))) -replace '-', '').Substring(0, 16).ToLowerInvariant()
                }
                finally { $sha.Dispose() }
                $plan.CertificateName += "-$suffix"
            }
            return $plan
        }
        $selectedId = $EncryptionKeyId
        if (-not $selectedId -and -not $NonInteractive -and $encryptionKeys.Count -eq 1) { $selectedId = [string]$encryptionKeys[0].KeyId }
        $selected = Select-EppOption -Entries $choices -Name EncryptionKeyId -PromptName 'Certificate to keep' `
            -Value $selectedId -AllowCancel -NonInteractive:$NonInteractive
        if (-not $selected) { return $null }
        $selectedKey = $encryptionKeys | Where-Object { [string]$_.KeyId -eq $selected.id }
        $location = Read-EppInput -Name KeyVaultCertificateId -Value $KeyVaultCertificateId `
            -Hint 'Versioned certificate URL; Enter cancels' -AllowCancel -NonInteractive:$NonInteractive
        if (-not $location) { return $null }
        $issued = $null
        try {
            $certificateLocation = ConvertTo-EppKeyVaultObjectId $location certificates
            $subscription = if ($KeyVaultSubscriptionId) { ConvertTo-EppGuid $KeyVaultSubscriptionId } else { $Inputs.SubscriptionId }
            $vault = Get-EppCertificateVault -Inputs $Inputs -VaultName $certificateLocation.VaultName -SubscriptionId $subscription
            $issued = Get-EppExistingEncryptionCertificate -CertificateId $location -SubscriptionId $subscription
            if (-not $selectedKey.Key -or
                [Convert]::ToBase64String([byte[]]$selectedKey.Key) -cne [Convert]::ToBase64String($issued.Certificate.RawData)) {
                throw 'The Key Vault certificate does not match the selected app-registration certificate. Supply its exact certificate version or choose Replace.'
            }
            if (-not $selectedKey.StartDateTime -or -not $selectedKey.EndDateTime -or
                [DateTimeOffset]$selectedKey.StartDateTime -gt [DateTimeOffset]::UtcNow -or
                [DateTimeOffset]$selectedKey.EndDateTime -le [DateTimeOffset]::UtcNow.AddDays(30)) {
                throw 'The selected app-registration credential must be valid now and have more than 30 days remaining. Choose another certificate or Replace.'
            }
            $plan.KeyId = $selected.id
            $plan.RemoveKeyIds = @($plan.RemoveKeyIds | Where-Object { $_ -ne $selected.id })
            $plan.CertificateName = $certificateLocation.Name
            $plan.CertificateId = $issued.CertificateId; $plan.SecretId = $issued.SecretId
            $plan.Thumbprint = $issued.Certificate.Thumbprint
            $plan.ExpiresUtc = $issued.Certificate.NotAfter.ToUniversalTime().ToString('o')
            $plan.VaultName = $certificateLocation.VaultName; $plan.VaultSubscriptionId = $subscription
            $plan.VaultResourceId = $vault['id']; $plan.VaultRbac = $vault['properties']['enableRbacAuthorization'] -eq $true
            return $plan
        }
        catch {
            if ($NonInteractive -or $KeyVaultCertificateId) { throw }
            Write-Warning "Cannot reuse this certificate: $($_.Exception.Message)"
            Write-Host 'Choose a certificate action again, correct the Key Vault location, or cancel. No resources were changed.'
            $CertificateAction = ''; $EncryptionKeyId = ''
        }
        finally { if ($issued) { $issued.Certificate.Dispose() } }
    }
}

function Get-EppEncryptionCertificate {
    param(
        [hashtable] $Inputs, [string] $VaultName, [string] $OutputDirectory, [string] $Directory,
        [string] $CertificateName = $script:EppCertificateName
    )

    $readCertificate = {
        Invoke-EppAz keyvault certificate show --vault-name $VaultName --name $CertificateName `
            --subscription $Inputs.SubscriptionId --output json | ConvertFrom-Json -AsHashtable
    }
    try { $bundle = Invoke-EppDataOperation $readCertificate }
    catch {
        if ($_.Exception.Message -notmatch '\(CertificateNotFound\)') { throw }
        $policy = @{
            issuerParameters = @{ name = 'Self' }
            keyProperties = @{ exportable = $true; keyType = 'RSA'; keySize = 2048; reuseKey = $true }
            secretProperties = @{ contentType = 'application/x-pem-file' }
            x509CertificateProperties = @{
                subject = $script:EppCertificateSubject
                validityInMonths = 12
                keyUsage = @('keyEncipherment', 'dataEncipherment')
            }
            lifetimeActions = @(@{ action = @{ actionType = 'EmailContacts' }; trigger = @{ daysBeforeExpiry = 30 } })
        }
        $policyPath = Join-Path $Directory 'certificate-policy.json'
        try {
            $policy | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $policyPath -Encoding utf8NoBOM
            # Azure CLI waits for self-signed issuance; no separate polling loop is needed.
            Invoke-EppDataOperation {
                Invoke-EppAz keyvault certificate create --vault-name $VaultName --name $CertificateName `
                    --policy "@$policyPath" --subscription $Inputs.SubscriptionId --output none
            } | Out-Null
        }
        finally { if (Test-Path -LiteralPath $policyPath) { Remove-Item -LiteralPath $policyPath -Force } }
        $bundle = Invoke-EppDataOperation $readCertificate
    }
    $issued = ConvertFrom-EppCertificateBundle -Bundle $bundle -RequireSetupPolicy
    try {
        $location = ConvertTo-EppKeyVaultObjectId $issued.CertificateId certificates
        if ($location.VaultName -ine $VaultName -or $location.Name -ine $CertificateName) {
            throw 'Key Vault returned a certificate outside the approved vault and name.'
        }
        Assert-EppCertificateSecret -SecretId $issued.SecretId -SubscriptionId $Inputs.SubscriptionId
        [IO.File]::WriteAllBytes((Join-Path $OutputDirectory "$($issued.Certificate.Thumbprint).cer"), $issued.Certificate.RawData)
        return $issued
    }
    catch { $issued.Certificate.Dispose(); throw }
}

function Assert-EppApplicationEncryption {
    param($Application, $Certificate, [string] $KeyId, [Collections.IDictionary] $Plan)

    $keys = @($Application.KeyCredentials | Where-Object { $_ -and $_.Usage -eq 'Encrypt' })
    if ($keys.Count -ne 1 -or $keys[0].Type -ne 'AsymmetricX509Cert' -or
        [string]$keys[0].KeyId -ne $KeyId -or -not $keys[0].Key -or
        [Convert]::ToBase64String([byte[]]$keys[0].Key) -cne [Convert]::ToBase64String($Certificate.RawData)) {
        throw 'Application readback must contain exactly one matching AsymmetricX509Cert/Encrypt credential with the selected key ID.'
    }
    $otherKeys = @($Application.KeyCredentials | Where-Object { $_ -and $_.Usage -ne 'Encrypt' })
    if ((Get-EppKeyCredentialSnapshot $otherKeys) -cne $Plan.NonEncryptionSnapshot) {
        throw 'Application readback did not preserve the non-encryption credentials. Inspect the application before proceeding.'
    }
}

function Assert-EppGraphAccess {
    param(
        [hashtable] $Inputs, $Certificate, [string] $KeyId, [string] $IdentifierUri,
        [Collections.IDictionary] $CertificatePlan
    )

    $applications = @(Get-MgApplication -Filter "appId eq '$($Inputs.ApplicationId)'" -All -ErrorAction Stop)
    if ($applications.Count -ne 1) { throw 'The endpoint application was not uniquely readable after configuration.' }
    $application = Get-MgApplication -ApplicationId $applications[0].Id `
        -Property Id,AppId,SignInAudience,AppRoles,IdentifierUris,KeyCredentials,TokenEncryptionKeyId -ErrorAction Stop
    $tenantRestriction = Get-EppSignInAudienceRestrictions -ApplicationObjectId $application.Id
    $invokeRoles = @($application.AppRoles | Where-Object {
        $_.Id -eq $script:EppInvokeAppRoleId -and $_.Value -eq $script:EppInvokeAppRoleValue -and
        $_.IsEnabled -and $_.AllowedMemberTypes -contains 'Application'
    })
    Assert-EppApplicationEncryption -Application $application -Certificate $Certificate -KeyId $KeyId -Plan $CertificatePlan
    if ($application.SignInAudience -ne 'AzureADMultipleOrgs' -or $application.TokenEncryptionKeyId -or
        $application.IdentifierUris -notcontains $IdentifierUri -or $invokeRoles.Count -ne 1) {
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

function Initialize-EppCertificateAccess {
    param([hashtable] $Inputs, [Collections.IDictionary] $Names, [Collections.IDictionary] $Plan, [string] $Directory)

    if ($Plan.Action -ne 'Reuse' -or $Plan.VaultName -ieq $Names.keyVault) { return }
    $vault = Get-EppCertificateVault -Inputs $Inputs -VaultName $Plan.VaultName -SubscriptionId $Plan.VaultSubscriptionId
    if ($vault['id'] -ine $Plan.VaultResourceId -or
        ($vault['properties']['enableRbacAuthorization'] -eq $true) -ne $Plan.VaultRbac) {
        throw 'The reused vault or its permission model changed after approval. Rerun setup and review a new plan.'
    }
    $principalId = ConvertTo-EppGuid (Invoke-EppAz functionapp identity show --resource-group $Names.resourceGroup `
        --name $Names.functionApp --subscription $Inputs.SubscriptionId --query principalId --output tsv)
    if ($Plan.VaultRbac) {
        $scope = "$($Plan.VaultResourceId)/secrets/$($Plan.CertificateName)"
        $assignments = Invoke-EppAz role assignment list --scope $scope --include-inherited `
            --subscription $Plan.VaultSubscriptionId --output json | ConvertFrom-Json -AsHashtable -NoEnumerate
        if ($assignments -isnot [array]) { throw 'Azure returned an invalid certificate-secret role-assignment list.' }
        if (@($assignments | Where-Object {
            $_['principalId'] -ieq $principalId -and $_['roleDefinitionId'] -like "*/$script:KeyVaultSecretsUserRoleId"
        }).Count) { return }
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $hash = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes("$scope|$principalId|$script:KeyVaultSecretsUserRoleId".ToLowerInvariant()))
            $assignmentId = [Guid]::new([byte[]]($hash[0..15])).ToString()
        }
        finally { $sha.Dispose() }
        Invoke-EppAz role assignment create --name $assignmentId --scope $scope --role $script:KeyVaultSecretsUserRoleId `
            --assignee-object-id $principalId --assignee-principal-type ServicePrincipal `
            --subscription $Plan.VaultSubscriptionId --output none | Out-Null
        return
    }
    $existing = @($vault['properties']['accessPolicies'] | Where-Object { $_ -and $_['objectId'] -ieq $principalId })
    if ($existing.Count -gt 1 -or ($existing.Count -and
        ($existing[0]['tenantId'] -ine $Inputs.TenantId -or $existing[0]['applicationId'] -or
            $existing[0]['permissions'] -isnot [Collections.IDictionary]))) {
        throw 'The Function identity has an ambiguous or application-restricted vault access policy. Have the vault administrator review it.'
    }
    $permissions = if ($existing.Count) { @{} + $existing[0]['permissions'] } else { @{} }
    if (@($permissions['secrets']) -contains 'get' -or @($permissions['secrets']) -contains 'all') { return }
    $permissions['secrets'] = @($permissions['secrets'] | Where-Object { $_ }) + @('get')
    $entry = @{ tenantId = $Inputs.TenantId; objectId = $principalId; permissions = $permissions }
    $path = Join-Path $Directory 'certificate-access-policy.json'
    try {
        @{ properties = @{ accessPolicies = @($entry) } } | ConvertTo-Json -Depth 8 |
            Set-Content -LiteralPath $path -Encoding utf8NoBOM
        Invoke-EppAz rest --method put --url "https://management.azure.com$($Plan.VaultResourceId)/accessPolicies/add?api-version=2024-11-01" `
            --body "@$path" --subscription $Plan.VaultSubscriptionId --output none | Out-Null
    }
    finally { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force } }
}

function Set-EppEncryptionSettings {
    param([hashtable] $Inputs, [Collections.IDictionary] $Names, [string] $SecretId, [string] $KeyId, [string] $Directory)

    $reference = "@Microsoft.KeyVault(SecretUri=$SecretId)"
    $path = Join-Path $Directory 'encryption-appsettings.json'
    try {
        @{ EPP_DECRYPTION_KEY_PEM = $reference; EPP_ENCRYPTION_KEY_ID = $KeyId } |
            ConvertTo-Json | Set-Content -LiteralPath $path -Encoding utf8NoBOM
        Invoke-EppAz functionapp config appsettings set --resource-group $Names.resourceGroup --name $Names.functionApp `
            --subscription $Inputs.SubscriptionId --settings "@$path" --output none | Out-Null
    }
    finally { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force } }
}

function Assert-EppEncryptionReference {
    param([hashtable] $Inputs, [Collections.IDictionary] $Names, [string] $SecretId, [string] $KeyId)

    $secret = ConvertTo-EppKeyVaultObjectId $SecretId secrets
    $configuredIds = @(Invoke-EppAz functionapp config appsettings list --resource-group $Names.resourceGroup `
        --name $Names.functionApp --subscription $Inputs.SubscriptionId `
        --query "[?name=='EPP_ENCRYPTION_KEY_ID'].value" --output json | ConvertFrom-Json)
    if ($configuredIds.Count -ne 1 -or $configuredIds[0] -ne $KeyId) {
        throw 'The Function encryption key ID does not match the approved certificate plan.'
    }
    $url = "https://management.azure.com/subscriptions/$($Inputs.SubscriptionId)/resourceGroups/$($Names.resourceGroup)/providers/Microsoft.Web/sites/$($Names.functionApp)/config/configreferences/appsettings"
    for ($attempt = 1; $attempt -le 12; $attempt++) {
        Invoke-EppAz rest --method post --url "$url/refresh?api-version=2024-04-01" `
            --subscription $Inputs.SubscriptionId --output none | Out-Null
        $reference = Invoke-EppAz rest --method get --url "$url/EPP_DECRYPTION_KEY_PEM`?api-version=2024-04-01" `
            --subscription $Inputs.SubscriptionId --output json | ConvertFrom-Json -AsHashtable
        if ($reference -isnot [Collections.IDictionary]) {
            throw 'Azure returned invalid decryption-key reference metadata. Encryption credentials will not be changed.'
        }
        $properties = $reference['properties']
        if ($properties -isnot [Collections.IDictionary] -or -not $properties['status']) {
            throw 'Azure returned incomplete decryption-key reference status. Encryption credentials will not be changed.'
        }
        if ($properties['status'] -eq 'Resolved') {
            if ($properties['reference'] -ine "@Microsoft.KeyVault(SecretUri=$SecretId)" -or
                $properties['vaultName'] -ine $secret.VaultName -or $properties['secretName'] -ine $secret.Name -or
                $properties['secretVersion'] -ine $secret.Version -or
                ($properties['activeVersion'] -and $properties['activeVersion'] -ine $secret.Version)) {
                throw 'The Function resolved a different secret reference or version than approved. Encryption credentials will not be changed.'
            }
            return
        }
        if ($attempt -eq 12 -or $properties['status'] -notin @('Initialized', 'AccessToKeyVaultDenied', 'UnauthorizedClient', 'FetchTimedOut')) {
            throw "The Function cannot resolve its certificate secret (status: $($properties['status'])). Check its system-assigned identity permissions and vault networking; encryption credentials were not changed."
        }
        Write-Warning "Waiting for the Function certificate-secret reference ($attempt/12, $($properties['status']))."
        Start-Sleep -Seconds 10
    }
}

function Set-EppApplicationEndpoint {
    param([hashtable] $Inputs, $Context, $Outputs, $Certificate, [string] $KeyId, [bool] $ConfigureFederation = $true)

    $application = Get-MgApplication -ApplicationId $Context.Application.Id `
        -Property Id, AppId, SignInAudience, IdentifierUris, KeyCredentials, TokenEncryptionKeyId -ErrorAction Stop
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
    # The single setup approval covers these planned writes, including certificate issuance.
    $ConfirmPreference = 'None'
    $graphAccess = Initialize-EppGraphAccess -Inputs $Inputs -Context $Context
    Initialize-EppResourceProviders -Inputs $Inputs
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    $settings = @{} + $ProviderConfiguration.Settings
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
        servicePlan = @{ value = $Inputs.ServicePlan }
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
    $issued = $null
    try {
        $certificatePlan = $Context.CertificatePlan
        if ($certificatePlan.Action -eq 'Reuse') {
            $issued = Get-EppExistingEncryptionCertificate -CertificateId $certificatePlan.CertificateId `
                -SubscriptionId $certificatePlan.VaultSubscriptionId
            if ($issued.SecretId -ine $certificatePlan.SecretId -or $issued.Certificate.Thumbprint -ine $certificatePlan.Thumbprint) {
                throw 'The selected certificate or backing secret changed after approval. Rerun setup and review a new plan.'
            }
            [IO.File]::WriteAllBytes((Join-Path $OutputDirectory "$($issued.Certificate.Thumbprint).cer"), $issued.Certificate.RawData)
        }
        else {
            $issued = Get-EppEncryptionCertificate -Inputs $Inputs -VaultName $Names.keyVault `
                -CertificateName $certificatePlan.CertificateName -OutputDirectory $OutputDirectory -Directory $AssetDirectory
        }
        $certificate = $issued.Certificate
        $keyId = $certificatePlan.KeyId
        Write-Host "Selected encryption key ID: $keyId"
        Write-Host "Key Vault certificate: $($issued.CertificateId)"
        Initialize-EppCertificateAccess -Inputs $Inputs -Names $Names -Plan $certificatePlan -Directory $AssetDirectory
        Set-EppEncryptionSettings -Inputs $Inputs -Names $Names -SecretId $issued.SecretId -KeyId $keyId -Directory $AssetDirectory
        Assert-EppEncryptionReference -Inputs $Inputs -Names $Names -SecretId $issued.SecretId -KeyId $keyId
        Set-EppApplicationEndpoint -Inputs $Inputs -Context $Context -Outputs $outputs -Certificate $certificate -KeyId $keyId `
            -ConfigureFederation:($Inputs.ProviderAuthentication -eq 'oauth')
        $graphAccess = Assert-EppGraphAccess -Inputs $Inputs -Certificate $certificate -KeyId $keyId `
            -IdentifierUri $outputs.identifierUri.value -CertificatePlan $certificatePlan
        $siteId = "/subscriptions/$($Inputs.SubscriptionId)/resourceGroups/$($Names.resourceGroup)/providers/Microsoft.Web/sites/$($Names.functionApp)"
        $Inputs.PackageSha256 = Publish-EppFunction -Inputs $Inputs -Names $Names -Context $Context -Outputs $outputs `
            -SiteId $siteId -Package $Package -Directory $AssetDirectory
        $result = [ordered]@{
            tenantId = $Inputs.TenantId; subscriptionId = $Inputs.SubscriptionId; applicationId = $Inputs.ApplicationId
            provider = $ProviderConfiguration.Id
            endpointRegion = $ProviderConfiguration.EndpointRegion; providerAuthentication = $Inputs.ProviderAuthentication
            providerTenantId = $Inputs.ProviderTenantId
            providerSmsEndpoint = $ProviderConfiguration.Settings.EPP_PROVIDER_SMS_ENDPOINT
            providerVoiceEndpoint = $ProviderConfiguration.Settings.EPP_PROVIDER_VOICE_ENDPOINT
            resourcePrefix = $Inputs.ResourcePrefix; resources = $Names
            language = $Inputs.Language; servicePlan = $Inputs.ServicePlan
            keyVaultCacheEnabled = $Inputs.ServicePlan -eq 'EP1'
            accessTokenCacheEnabled = $Inputs.ServicePlan -eq 'EP1'
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
    finally { if ($issued) { $issued.Certificate.Dispose() } }
}

function Publish-EppFunction {
    param(
        [hashtable] $Inputs, [Collections.IDictionary] $Names, $Context, $Outputs,
        [string] $SiteId, $Package, [string] $Directory
    )

    if ($Inputs.ServicePlan -notin @('FC1', 'EP1')) { throw "Unknown service plan '$($Inputs.ServicePlan)'." }
    $ingressOpened = $false
    $deployedHash = $Inputs.PackageSha256
    try {
        Assert-EppAuthentication -SiteId $SiteId -Inputs $Inputs -Context $Context -IdentifierUri $Outputs.identifierUri.value
        if ($Inputs.ServicePlan -eq 'FC1') {
            $ingressOpened = $true
            Set-EppPublicAccess -SiteId $SiteId -SubscriptionId $Inputs.SubscriptionId -Access Enabled
            Write-Host 'Publishing the Function package through Flex Consumption One Deploy...' -ForegroundColor Cyan
            $remoteBuild = ([bool]$Package.RequiresRemoteBuild).ToString().ToLowerInvariant()
            Invoke-EppAz functionapp deployment source config-zip --resource-group $Names.resourceGroup --name $Names.functionApp `
                --subscription $Inputs.SubscriptionId --src $Package.Path --build-remote $remoteBuild --timeout 1800 --output none | Out-Null
            # One Deploy builds and stores Python output in Azure; its bytes are not downloaded or hashed locally.
            if ($Package.RequiresRemoteBuild) { $deployedHash = $null }
        }
        else {
            $packagePath = $Package.Path
            if ($Package.RequiresRemoteBuild) {
                $ingressOpened = $true
                Set-EppPublicAccess -SiteId $SiteId -SubscriptionId $Inputs.SubscriptionId -Access Enabled
                $packagePath = Build-EppPythonPackage -Inputs $Inputs -Names $Names -SiteId $SiteId -SourcePath $Package.Path -Directory $Directory
                $deployedHash = (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash.ToLowerInvariant()
            }
            Write-Host 'Publishing the ready-to-run Function package...' -ForegroundColor Cyan
            Invoke-EppDataOperation {
                Invoke-EppAz storage blob upload --account-name $Names.storageAccount --container-name packages `
                    --name "$deployedHash.zip" --file $packagePath --auth-mode login --overwrite true `
                    --subscription $Inputs.SubscriptionId --output none
            } | Out-Null
            if ($Package.RequiresRemoteBuild) {
                if ($Outputs.packageContainerUrl.value -cne "https://$($Names.storageAccount).blob.core.windows.net/packages/") {
                    throw 'Azure returned an unexpected package storage URL. The app will not mount it.'
                }
                $packageUrl = "$($Outputs.packageContainerUrl.value)$deployedHash.zip"
                Assert-EppHttpsUrl $packageUrl
                Set-EppPackageSettings -SiteId $SiteId -SubscriptionId $Inputs.SubscriptionId -PackageUrl $packageUrl -Directory $Directory
            }
            if (-not $ingressOpened) {
                $ingressOpened = $true
                Set-EppPublicAccess -SiteId $SiteId -SubscriptionId $Inputs.SubscriptionId -Access Enabled
            }
            Invoke-EppAz functionapp restart --resource-group $Names.resourceGroup --name $Names.functionApp `
                --subscription $Inputs.SubscriptionId --output none | Out-Null
            Sync-EppFunctionTriggers -SiteId $SiteId -SubscriptionId $Inputs.SubscriptionId
        }
        Assert-EppFunctionPublished -Inputs $Inputs -Names $Names
    }
    catch {
        $deploymentError = $_
        if ($ingressOpened) {
            try { Set-EppPublicAccess -SiteId $SiteId -SubscriptionId $Inputs.SubscriptionId -Access Disabled }
            catch { throw [AggregateException]::new('Deployment failed and public ingress could not be disabled. Inspect the Function App immediately.', [Exception[]]@($deploymentError.Exception, $_.Exception)) }
        }
        throw $deploymentError
    }
    return $deployedHash
}

function Invoke-EppSetup {
    [CmdletBinding()]
    param(
        [string] $TenantId, [string] $SubscriptionId, [string] $ApplicationId, [string] $Location,
        [string] $Provider, [string] $EndpointRegion,
        [string] $ResourcePrefix,
        [string] $Language,
        [string] $ServicePlan,
        [ValidateSet('Create', 'Reuse', 'Replace')]
        [string] $CertificateAction,
        [string] $EncryptionKeyId, [string] $KeyVaultCertificateId, [string] $KeyVaultSubscriptionId,
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
    $tenantScopeSelection = Select-EppOption -Entries @(
        @{ id = 'global'; displayName = 'Global' }
        @{ id = 'eu'; displayName = 'EU' }
    ) -Name EndpointRegion -PromptName 'Tenant scope' -Value $EndpointRegion -NonInteractive:$NonInteractive

    $providerConfiguration = Get-EppProvider -AssetDirectory $AssetDirectory -SourceBaseUri $SourceBaseUri -Provider $Provider `
        -EndpointRegion $tenantScopeSelection['id'] `
        -NonInteractive:$NonInteractive -SourceRepository $SourceRepository
    $inputs.ProviderAuthentication = $providerConfiguration.AuthenticationMode
    $inputs.ProviderTenantId = $providerConfiguration.Settings.EPP_PROVIDER_TENANT_ID
    $selection = Get-EppLanguage -AssetDirectory $AssetDirectory -Language $Language -SourceRepository $SourceRepository `
        -PackageReleaseTag $PackageReleaseTag -NonInteractive:$NonInteractive
    $inputs.Language = $selection.Id
    $inputs.Platform = $selection.DisplayName
    $inputs.PackageUrl = $selection.Url
    $inputs.BuildStrategy = $selection.BuildStrategy
    $plan = Get-EppServicePlan -ServicePlan $ServicePlan -NonInteractive:$NonInteractive
    $inputs.ServicePlan = $plan.id
    $inputs.ResourcePrefix = Read-EppInput ResourcePrefix $ResourcePrefix -Kind Prefix `
        -Hint 'All resources created by this script will start with this prefix' -NonInteractive:$NonInteractive
    $names = Get-EppResourceNames -SubscriptionId $inputs.SubscriptionId -ApplicationId $inputs.ApplicationId -ResourcePrefix $inputs.ResourcePrefix

    Write-Host "`nChecking prerequisites and the selected Azure context (no resource changes)..." -ForegroundColor Cyan
    $context = Connect-EppContext -Inputs $inputs -Names $names -NonInteractive:$NonInteractive `
        -InstallPrerequisites:$InstallPrerequisites -ForceAuthentication:$ForceAuthentication
    $context.CertificatePlan = Get-EppCertificatePlan -Inputs $inputs -Names $names -Application $context.Application `
        -CertificateAction $CertificateAction -EncryptionKeyId $EncryptionKeyId -KeyVaultCertificateId $KeyVaultCertificateId `
        -KeyVaultSubscriptionId $KeyVaultSubscriptionId -NonInteractive:$NonInteractive
    if (-not $context.CertificatePlan) {
        Write-Host 'Cancelled. No Azure resources or application credentials were changed.' -ForegroundColor Yellow
        return
    }
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
