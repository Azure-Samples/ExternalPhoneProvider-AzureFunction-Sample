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
. (Join-Path $PSScriptRoot 'Epp.Packages.ps1')
. (Join-Path $PSScriptRoot 'Epp.Graph.ps1')

function Read-EppJson {
    param([string] $Path)

    $value = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    if ($value -isnot [Collections.IDictionary]) { throw "Expected a JSON object in '$Path'." }
    return $value
}

function Test-EppJsonEqual {
    param($Left, $Right)

    $leftJson = ConvertTo-Json -InputObject $Left -Depth 30 -Compress
    $rightJson = ConvertTo-Json -InputObject $Right -Depth 30 -Compress
    return [Newtonsoft.Json.Linq.JToken]::DeepEquals(
        [Newtonsoft.Json.Linq.JToken]::Parse($leftJson),
        [Newtonsoft.Json.Linq.JToken]::Parse($rightJson))
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
        [string] $PromptName, [string] $DefaultValue, [switch] $NonInteractive, [switch] $AllowCancel
    )

    $ids = @($Entries | ForEach-Object { $_['id'] })
    $displayName = if ($PromptName) { $PromptName } else { $Name }
    if ($Value) {
        $selected = $Entries | Where-Object { $_['id'] -ieq $Value -or $_['displayName'] -ieq $Value } | Select-Object -First 1
        if (-not $selected) { throw "Unknown $Name '$Value'. Choose: $($ids -join ', ')." }
        return $selected
    }
    if ($NonInteractive) { throw "-$Name is required. Choose: $($ids -join ', ')." }
    $defaultIndex = -1
    if ($DefaultValue) {
        $default = $Entries | Where-Object { $_['id'] -ieq $DefaultValue -or $_['displayName'] -ieq $DefaultValue } | Select-Object -First 1
        if (-not $default) { throw "Unknown default $Name '$DefaultValue'. Choose: $($ids -join ', ')." }
        $defaultIndex = [Array]::IndexOf($ids, $default['id'])
    }
    Write-Host "`nChoose your $($displayName.ToLowerInvariant()):" -ForegroundColor Cyan
    for ($index = 0; $index -lt $Entries.Count; $index++) {
        $label = if ($index -eq $defaultIndex) { ' (default)' } else { '' }
        Write-Host "  [$($index + 1)] $($Entries[$index]['displayName'])$label"
    }
    if ($AllowCancel) { Write-Host '  [0] Cancel' }
    $prompt = "$displayName number or name"
    if ($defaultIndex -ge 0) { $prompt += " [$($defaultIndex + 1)]" }
    while ($true) {
        $answer = ([string](Read-Host $prompt)).Trim()
        if ($AllowCancel -and $answer -in @('0', 'Cancel')) { return $null }
        if (-not $answer -and $defaultIndex -ge 0) { return $Entries[$defaultIndex] }
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
    Write-Host 'Review estimated Azure hosting and provider costs:'
    Write-Host 'https://github.com/Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample/blob/main/docs/COST-CALCULATOR.md'
    Write-Host 'Flex Consumption has a free usage grant, not a zero-cost guarantee. Additional usage, Key Vault, storage, and telemetry can incur charges.'
    return Select-EppOption -Entries @(
        @{ id = 'FC1'; displayName = 'Flex Consumption FC1 (free grant, cold starts)' }
        @{ id = 'EP1'; displayName = 'Premium EP1 (warm instance)' }
    ) -Name ServicePlan -PromptName 'Service plan' -Value $ServicePlan -DefaultValue FC1 -NonInteractive:$NonInteractive
}

function Read-EppInput {
    param(
        [string] $Name, [string] $Value, [string] $Hint,
        [ValidateSet('Text', 'Guid', 'Location', 'Prefix', 'PackageUrl', 'ApplicationName')]
        [string] $Kind = 'Text',
        [switch] $NonInteractive, [switch] $AllowCancel,
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$')]
        [string] $SourceRepository = 'Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample',
        [string] $PromptName, [string] $DefaultValue
    )

    $supplied = -not [string]::IsNullOrWhiteSpace($Value)
    while ($true) {
        if (-not $supplied) {
            if ($NonInteractive) { throw "-$Name is required in noninteractive mode." }
            $displayName = if ($PromptName) { $PromptName } else { $Name }
            $prompt = if ($Hint) { "$displayName - $Hint" } else { $displayName }
            if ($DefaultValue) { $prompt += " [$DefaultValue]" }
            $Value = [string](Read-Host $prompt)
        }
        $Value = $Value.Trim()
        if (-not $supplied -and $AllowCancel -and $Value -ieq 'Cancel') { return $null }
        if (-not $supplied -and -not $Value -and $DefaultValue) { $Value = $DefaultValue }
        try {
            if (-not $Value -or $Value -match '[\x00-\x1f<>]') { throw 'A nonempty value without placeholders is required.' }
            switch ($Kind) {
                'Guid' { $Value = ConvertTo-EppGuid $Value }
                'ApplicationName' {
                    if ($Value.Length -gt 256 -or $Value -match '[\x7f-\x9f]') {
                        throw 'Use an application display name of 1-256 characters without control characters.'
                    }
                }
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
            }
            return $Value
        }
        catch {
            if ($supplied) { throw "Invalid -${Name}: $($_.Exception.Message)" }
            Write-Warning "$Name : $($_.Exception.Message)"
        }
    }
}

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

function Test-EppAnimationEnabled {
    return $ProgressPreference -eq 'Continue' -and $Host.Name -eq 'ConsoleHost' -and -not [Console]::IsOutputRedirected
}

function Invoke-EppAz {
    [CmdletBinding(PositionalBinding = $false)]
    param(
        [Parameter(Position = 0, ValueFromRemainingArguments)][string[]] $Arguments,
        [string] $Activity
    )

    $PSNativeCommandUseErrorActionPreference = $false
    if ($Arguments[0] -eq 'login') {
        # Device-code instructions must be visible while Azure CLI waits for sign-in.
        & az @Arguments --only-show-errors 2>&1 | ForEach-Object { Write-Host $_ }
        if ($LASTEXITCODE -ne 0) {
            throw "Azure CLI operation 'login' failed (exit $LASTEXITCODE). Review the sign-in error above."
        }
        return
    }
    $errorPath = Join-Path ([IO.Path]::GetTempPath()) "epp-az-$([Guid]::NewGuid().ToString('N')).stderr"
    try {
        if ($Activity -and (Test-EppAnimationEnabled)) {
            $command = Get-Command az -CommandType Application, ExternalScript -ErrorAction Stop | Select-Object -First 1
            $worker = [PowerShell]::Create()
            $line = ''
            try {
                # Keep native invocation in PowerShell so az.cmd and argument quoting work on Windows too.
                $null = $worker.AddScript({
                    param($CommandPath, $Arguments, $ErrorPath)
                    $ErrorActionPreference = 'Stop'
                    $PSNativeCommandUseErrorActionPreference = $false
                    $output = & $CommandPath @Arguments --only-show-errors 2> $ErrorPath
                    @{ Output = $output; ExitCode = $LASTEXITCODE }
                }).AddArgument($command.Source).AddArgument($Arguments).AddArgument($errorPath)
                $pending = $worker.BeginInvoke()
                $frames = @('|', '/', '-', '\')
                $frame = 0
                while (-not $pending.IsCompleted) {
                    $line = "$($frames[$frame % $frames.Count]) $Activity..."
                    Write-Host "`r$line" -NoNewline -ForegroundColor Cyan
                    $frame++
                    Start-Sleep -Milliseconds 150
                }
                $completed = $worker.EndInvoke($pending)
                if ($worker.Streams.Error.Count) { throw $worker.Streams.Error[0] }
                if ($completed.Count -ne 1 -or $null -eq $completed[0].ExitCode) {
                    throw 'Azure CLI did not return an operation result.'
                }
                $output = $completed[0].Output
                $exitCode = $completed[0].ExitCode
            }
            finally {
                try {
                    if ($worker.InvocationStateInfo.State -eq 'Running') { $worker.Stop() }
                }
                finally {
                    $worker.Dispose()
                    if ($line) { Write-Host ("`r" + (' ' * $line.Length) + "`r") -NoNewline }
                }
            }
        }
        else {
            if ($Activity) { Write-Host "$Activity..." -ForegroundColor Cyan }
            $output = & az @Arguments --only-show-errors 2> $errorPath
            $exitCode = $LASTEXITCODE
        }
        $errorText = if (Test-Path -LiteralPath $errorPath) { [string](Get-Content -LiteralPath $errorPath -Raw) } else { '' }
        $message = (($output -join "`n") + "`n" + $errorText) -replace '(?i)([?&](?:sig|token|code|client_secret|password)=)[^&\s]+', '$1[REDACTED]'
        $message = $message -replace '(?i)(Bearer\s+)[^\s,;]+', '$1[REDACTED]'
        if ($exitCode -ne 0) {
            $operation = ($Arguments | Select-Object -First 2) -join ' '
            throw "Azure CLI operation '$operation' failed (exit $exitCode): $message"
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

function Get-EppAzureSubscriptions {
    param([switch] $Refresh)

    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw 'Azure CLI is not installed or not on PATH. Install Azure CLI, open a new PowerShell 7 window, and rerun setup.'
    }
    $arguments = @('account', 'list', '--all', '--output', 'json')
    if ($Refresh) { $arguments += '--refresh' }
    $accounts = Invoke-EppAz @arguments | ConvertFrom-Json -AsHashtable -NoEnumerate
    if ($accounts -isnot [Array]) { throw 'Azure CLI returned an invalid subscription list.' }
    $seen = @{}
    foreach ($account in $accounts) {
        if ($account -isnot [Collections.IDictionary] -or $account['user'] -isnot [Collections.IDictionary]) {
            throw 'Azure CLI returned invalid subscription metadata.'
        }
        # account list uses cloudName; account show exposes environmentName instead.
        foreach ($value in @($account['state'], $account['cloudName'], $account.user['type'])) {
            if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value)) {
                throw 'Azure CLI returned invalid subscription eligibility metadata: state, cloudName, and user.type must be nonempty strings.'
            }
        }
        if ($account['state'] -ne 'Enabled' -or $account['cloudName'] -ne 'AzureCloud' -or
            $account.user['type'] -ne 'user' -or $account['name'] -eq 'N/A(tenant level account)') { continue }
        $id = ConvertTo-EppGuid $account['id']
        $tenantId = ConvertTo-EppGuid $account['tenantId']
        foreach ($label in @($account['name'], $account.user['name'])) {
            if ($label -isnot [string] -or [string]::IsNullOrWhiteSpace($label) -or $label -match '[\x00-\x1f\x7f-\x9f]') {
                throw 'Azure CLI returned an invalid subscription or user display name.'
            }
        }
        $tenantName = $account['tenantDisplayName']
        if (($null -ne $tenantName -and $tenantName -isnot [string]) -or
            $tenantName -match '[\x00-\x1f\x7f-\x9f]' -or $account['isDefault'] -isnot [bool]) {
            throw 'Azure CLI returned invalid tenant or default-subscription metadata.'
        }
        if ($seen.ContainsKey($id)) { throw "Azure CLI returned duplicate entries for subscription '$id'. Refresh the CLI account cache before retrying." }
        $seen[$id] = $true
        [pscustomobject]@{
            Id = $id; TenantId = $tenantId; Name = $account['name']
            TenantDisplayName = [string]$tenantName; UserName = $account.user['name']
            IsDefault = $account['isDefault']
        }
    }
}

function Select-EppAzureContext {
    param([string] $TenantId, [string] $SubscriptionId, [switch] $NonInteractive)

    $TenantId = ([string]$TenantId).Trim()
    $SubscriptionId = ([string]$SubscriptionId).Trim()
    if ($TenantId -or $NonInteractive) {
        $TenantId = Read-EppInput -Name TenantId -Value $TenantId -Kind Guid -NonInteractive
    }
    if ($SubscriptionId -or $NonInteractive) {
        $SubscriptionId = Read-EppInput -Name SubscriptionId -Value $SubscriptionId -Kind Guid -NonInteractive
    }
    if ($TenantId -and $SubscriptionId) {
        return @{ TenantId = $TenantId; SubscriptionId = $SubscriptionId }
    }

    $actions = @(
        @{ id = 'refresh'; displayName = 'Refresh subscriptions from Azure' }
        @{ id = 'signin'; displayName = 'Sign in to Azure (device code)' }
    )
    $refresh = $false
    while ($true) {
        $subscriptions = @(Get-EppAzureSubscriptions -Refresh:$refresh)
        $currentSubscription = $subscriptions | Where-Object IsDefault | Select-Object -First 1
        $refresh = $false
        $tenant = $TenantId
        $selection = $null
        if ($subscriptions.Count) {
            $users = @($subscriptions.UserName | Sort-Object -Unique)
            Write-Host "`nAzure CLI cached user accounts: $($users -join ', ')" -ForegroundColor Cyan
            Write-Host 'Choose from enabled public-Azure subscriptions. Refresh or sign in if the expected account is missing.'
        }
        else {
            Write-Warning 'No enabled public-Azure subscriptions for a user account are cached. Choose Sign in, Refresh, or Cancel.'
        }
        if ($SubscriptionId) {
            $subscription = $subscriptions | Where-Object Id -eq $SubscriptionId | Select-Object -First 1
            if ($subscription) {
                Write-Host "Using supplied subscription: $($subscription.Name) [$($subscription.Id)], tenant $($subscription.TenantId), user $($subscription.UserName)"
                return @{ TenantId = $subscription.TenantId; SubscriptionId = $SubscriptionId }
            }
            Write-Warning "The supplied subscription '$SubscriptionId' is not in the eligible cached accounts. It will not be replaced with another subscription."
            $selection = Select-EppOption -Entries $actions -Name AzureAccount -PromptName 'Azure account action' -DefaultValue refresh -AllowCancel
        }
        else {
            if (-not $tenant) {
                $tenants = @($subscriptions | Group-Object TenantId | ForEach-Object {
                    $name = $_.Group | Where-Object TenantDisplayName | Select-Object -First 1 -ExpandProperty TenantDisplayName
                    $label = if ($name) { "$name [$($_.Name)]" } else { "$($_.Name) (tenant name unavailable)" }
                    @{ id = $_.Name; displayName = $label }
                } | Sort-Object { $_.displayName })
                $defaultTenant = if ($currentSubscription) { $currentSubscription.TenantId }
                    elseif ($tenants.Count) { $tenants[0].id } else { 'signin' }
                $selection = Select-EppOption -Entries ($tenants + $actions) -Name TenantId -PromptName 'Azure tenant' `
                    -DefaultValue $defaultTenant -AllowCancel
                if (-not $selection) { return $null }
                if ($selection.id -notin @('refresh', 'signin')) { $tenant = $selection.id }
            }
            if ($tenant) {
                Write-Host "`nAzure tenant: $tenant" -ForegroundColor Cyan
                $options = @($subscriptions | Where-Object TenantId -eq $tenant | Sort-Object Name, Id | ForEach-Object {
                    $default = if ($_.IsDefault) { ' (current CLI default)' } else { '' }
                    @{ id = $_.Id; displayName = "$($_.Name) [$($_.Id)] - $($_.UserName)$default" }
                })
                if (-not $options.Count) {
                    Write-Warning "No eligible subscriptions are cached for tenant '$tenant'. Refresh or sign in to this tenant."
                }
                $defaultSubscription = if ($currentSubscription -and $currentSubscription.TenantId -eq $tenant) { $currentSubscription.Id }
                    elseif ($options.Count) { $options[0].id } else { 'signin' }
                $selection = Select-EppOption -Entries ($options + $actions) -Name SubscriptionId -PromptName 'Azure subscription' `
                    -DefaultValue $defaultSubscription -AllowCancel
                if (-not $selection) { return $null }
                if ($selection.id -notin @('refresh', 'signin')) {
                    return @{ TenantId = $tenant; SubscriptionId = $selection.id }
                }
            }
        }
        if (-not $selection) { return $null }
        switch ($selection.id) {
            'refresh' { $refresh = $true }
            'signin' {
                $arguments = @('login', '--use-device-code', '--output', 'none')
                if ($tenant) { $arguments += @('--tenant', $tenant) }
                Invoke-EppAz @arguments | Out-Null
            }
            default { throw 'Unexpected Azure account selection action.' }
        }
    }
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
        $account = Invoke-EppAz account show --subscription $Inputs.SubscriptionId --output json | ConvertFrom-Json
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
    param([hashtable] $Inputs)

    $operator = Invoke-EppDirectoryCommand -Inputs $Inputs -Arguments @('ad', 'signed-in-user', 'show')
    if ($operator -isnot [Collections.IDictionary]) { throw 'Azure CLI did not return the signed-in Graph user.' }
    $id = ConvertTo-EppGuid ([string]$operator.id)
    $account = if ([string]::IsNullOrWhiteSpace([string]$operator.userPrincipalName)) { $id } else { [string]$operator.userPrincipalName }
    return [pscustomobject]@{ Id = $id; Account = $account }
}

function Connect-EppGraphAccount {
    param([hashtable] $Inputs, [switch] $NonInteractive, [switch] $ForceAuthentication)

    $null = Connect-EppAzureAccount -Inputs $Inputs -NonInteractive:$NonInteractive `
        -ForceAuthentication:($ForceAuthentication -and -not $Inputs['AzureSelectionAuthenticated'])
    $Inputs.AzureSelectionAuthenticated = $true
    $operator = Get-EppGraphOperator -Inputs $Inputs
    return [pscustomobject]@{
        Context = @{ TenantId = $Inputs.TenantId; Authentication = 'AzureCli'; OperatorId = $operator.Id }
        Operator = $operator
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
    $Inputs.ProviderAllowedTenantIds = @(($allowedTenants + @($Inputs.ProviderTenantId)) | Sort-Object -Unique)
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
    Write-Host "Provider tenant: $($ProviderConfiguration.Settings.EPP_PROVIDER_TENANT_ID)"
    if ($Inputs['ProviderAllowedTenantIds']) {
        Write-Host "Allowed provider tenants after deployment: $($Inputs.ProviderAllowedTenantIds -join ', ') (home tenant also allowed)"
        Write-Host 'Existing allowed provider tenants are preserved; selecting a provider does not configure multi-provider runtime fallback.'
    }
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
    Write-Host '  - Setup operator, scoped to this Key Vault:'
    Write-Host '      Key Vault Certificates Officer - issue and inspect the encryption certificate.'
    Write-Host '      Key Vault Secrets Officer - manage provider credentials.'
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
        Write-Host '  - Telesign API key: store the required provider credentials in Key Vault; no federated credential is created.'
    }

    Write-Host "`nDeployment notes" -ForegroundColor Cyan
    Write-Host '  - Deploy the verified package, synchronize Function triggers, and enable HTTPS ingress after Easy Auth is verified.'
    Write-Host '  - Azure resource and Function deployment may each take several minutes. Keep this session open until deployment completes.'
    if ($Inputs.ServicePlan -eq 'FC1') {
        Write-Host '  - Flex Consumption: publish through One Deploy. No always-ready instances.'
        Write-Host '  - FC1 includes a free usage grant. Usage beyond the grant, Key Vault, storage, and telemetry can incur charges.' -ForegroundColor Yellow
    }
    if ($Inputs.BuildStrategy -eq 'remote-build') {
        Write-Host '  - Azure installs Python dependencies and prepares the Function deployment package. No local Python installation is required.'
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

    Write-Host "`nDeployment completed successfully." -ForegroundColor Green
    Write-Host 'IMPORTANT: Save this output. The endpoint URL and Application (client) ID are required for policy updates.' -ForegroundColor Yellow
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
    Write-Host '   Policy configuration and validation guidance:'
    Write-Host '   https://github.com/Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample/blob/main/docs/GETTING-STARTED.md#4-connect-your-provider-and-test'
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
            # RSAOpenSsl overrides only the setter; call the inherited getter to avoid PowerShell's write-only property view.
            if (-not $rsa -or $rsa.get_KeySize() -lt 2048 -or $certificate.HasPrivateKey -or
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
            ) -Name CertificateAction -PromptName 'Encryption certificate action' -Value $action -DefaultValue Replace `
                -AllowCancel -NonInteractive:$NonInteractive
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
            -Value $selectedId -DefaultValue $choices[0].id -AllowCancel -NonInteractive:$NonInteractive
        if (-not $selected) { return $null }
        $selectedKey = $encryptionKeys | Where-Object { [string]$_.KeyId -eq $selected.id }
        $location = Read-EppInput -Name KeyVaultCertificateId -Value $KeyVaultCertificateId `
            -Hint 'Versioned certificate URL; type Cancel to cancel' -AllowCancel -NonInteractive:$NonInteractive
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
    $credentialName = "epp-$($Outputs.functionAppName.value)-outbound"
    $credentials = Invoke-EppDirectoryCommand -Inputs $Inputs -Arguments @('ad', 'app', 'federated-credential', 'list', '--id', $application.Id)
    if ($credentials -isnot [Array]) { throw 'Azure CLI returned an invalid federated-credential list.' }
    $credentials = @($credentials | ForEach-Object { [pscustomobject]$_ })
    $matching = @($credentials | Where-Object {
        $_.Issuer -ceq $issuer -and $_.Subject -ceq $Outputs.outboundPrincipalId.value -and
        @($_.Audiences).Count -eq 1 -and $_.Audiences[0] -ceq $audience
    })
    if (-not $matching.Count) {
        if (@($credentials | Where-Object Name -eq $credentialName).Count) { throw 'The outbound federated credential name is already used for a different trust. It will not be overwritten.' }
        New-EppFederatedCredential -Inputs $Inputs -ObjectId $application.Id -Credential @{
            name = $credentialName; issuer = $issuer; subject = $Outputs.outboundPrincipalId.value; audiences = @($audience)
        }
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

    Invoke-EppAz -Activity 'Preparing the Python deployment package in Azure' `
        functionapp deployment source config-zip --resource-group $Names.resourceGroup --name $Names.functionApp `
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
        [string] $AssetDirectory, [string] $WorkingDirectory, $Package, [string] $OutputDirectory
    )

    $graphOperator = Get-EppGraphOperator -Inputs $Inputs
    if ($graphOperator.Id -ne $Context.GraphOperatorId -or
        (Get-EppArmOperatorObjectId -Inputs $Inputs) -ne $Context.OperatorId) {
        throw 'The Azure CLI user changed after the plan was reviewed. Rerun setup.'
    }
    # The single setup approval covers these planned writes, including certificate issuance.
    $ConfirmPreference = 'None'
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
    Initialize-EppResourceProviders -Inputs $Inputs
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
    $parameterPath = Join-Path $WorkingDirectory 'deployment.parameters.json'
    @{ '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'; contentVersion = '1.0.0.0'; parameters = $parameters } |
        ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $parameterPath -Encoding utf8NoBOM
    Write-Host 'Deployment may take several minutes. Keep this session open.' -ForegroundColor Cyan
    $deploymentName = "epp-$($Inputs.ResourcePrefix)-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
    $outputs = Invoke-EppRegistrationRetry -Operation {
        Invoke-EppAz -Activity 'Deploying Azure resources' deployment sub create --name $deploymentName `
            --subscription $Inputs.SubscriptionId --location $Inputs.Location --template-file (Join-Path $AssetDirectory 'main.json') `
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
                -CertificateName $certificatePlan.CertificateName -OutputDirectory $OutputDirectory -Directory $WorkingDirectory
        }
        $certificate = $issued.Certificate
        $keyId = $certificatePlan.KeyId
        Write-Host "Selected encryption key ID: $keyId"
        Write-Host "Key Vault certificate: $($issued.CertificateId)"
        Initialize-EppCertificateAccess -Inputs $Inputs -Names $Names -Plan $certificatePlan -Directory $WorkingDirectory
        Set-EppEncryptionSettings -Inputs $Inputs -Names $Names -SecretId $issued.SecretId -KeyId $keyId -Directory $WorkingDirectory
        Assert-EppEncryptionReference -Inputs $Inputs -Names $Names -SecretId $issued.SecretId -KeyId $keyId
        Set-EppApplicationEndpoint -Inputs $Inputs -Context $Context -Outputs $outputs -Certificate $certificate -KeyId $keyId `
            -ConfigureFederation:($Inputs.ProviderAuthentication -eq 'oauth')
        $graphAccess = Assert-EppGraphAccess -Inputs $Inputs -Certificate $certificate -KeyId $keyId `
            -IdentifierUri $outputs.identifierUri.value -CertificatePlan $certificatePlan
        $siteId = "/subscriptions/$($Inputs.SubscriptionId)/resourceGroups/$($Names.resourceGroup)/providers/Microsoft.Web/sites/$($Names.functionApp)"
        $Inputs.PackageSha256 = Publish-EppFunction -Inputs $Inputs -Names $Names -Context $Context -Outputs $outputs `
            -SiteId $siteId -Package $Package -Directory $WorkingDirectory
        $result = [ordered]@{
            tenantId = $Inputs.TenantId; subscriptionId = $Inputs.SubscriptionId; applicationId = $Inputs.ApplicationId
            tenantRegionScope = $Inputs['TenantRegionScope']
            provider = $ProviderConfiguration.Id
            endpointRegion = $ProviderConfiguration.EndpointRegion; providerAuthentication = $Inputs.ProviderAuthentication
            providerTenantId = $Inputs.ProviderTenantId
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
            if ($Package.RequiresRemoteBuild) {
                Write-Host 'Azure installs Python dependencies and prepares the Function deployment package. No local Python installation is required.'
            }
            $remoteBuild = ([bool]$Package.RequiresRemoteBuild).ToString().ToLowerInvariant()
            Invoke-EppAz -Activity 'Deploying the Azure Function' `
                functionapp deployment source config-zip --resource-group $Names.resourceGroup --name $Names.functionApp `
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
            Invoke-EppDataOperation {
                Invoke-EppAz -Activity 'Publishing the Azure Function package' `
                    storage blob upload --account-name $Names.storageAccount --container-name packages `
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
            Invoke-EppAz -Activity 'Starting the Azure Function' functionapp restart --resource-group $Names.resourceGroup --name $Names.functionApp `
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
    <#
    .SYNOPSIS
        Configure and deploy one External Phone Provider endpoint in Azure.
    .DESCRIPTION
        Uses commit-pinned infrastructure, provider profiles, and setup helpers downloaded by
        Setup-Epp.ps1. Downloads and verifies the selected Function ZIP from a stable GitHub release.
        Azure CLI is required. The .NET selection also needs the .NET 8 SDK and NuGet access;
        Python dependencies are built in Azure. The Azure CLI Bicep component is also required
        and can be installed after confirmation. Interactive setup can create a dedicated app
        registration after deployment approval. Policy activation remains manual.
        Review the complete plan before approving resource or tenant changes.
        Microsoft Graph calls reuse the existing Azure CLI user session through az ad and az rest.
        No Microsoft Graph PowerShell SDK or separate Graph sign-in is required.
        Interactive setup discovers cached Azure CLI accounts before asking for other settings.
        Choose a tenant and subscription, or explicitly refresh/sign in when the list is incomplete.
        Enter accepts the displayed default; 0 or Cancel cancels where offered.
        Provider selection has no default, and final deployment approval defaults to No.
    .PARAMETER TenantId
        Customer tenant ID. When omitted interactively, select from cached Azure subscriptions,
        or resolve it from an explicitly supplied subscription. Required in noninteractive mode.
        The interactive default is the current CLI tenant, or the first eligible tenant.
    .PARAMETER SubscriptionId
        Azure subscription ID. When omitted interactively, select an enabled user subscription
        in the chosen tenant. Required in noninteractive mode.
        Defaults to the current CLI subscription in that tenant, or its first eligible subscription.
    .PARAMETER ApplicationId
        Existing application client ID. When omitted interactively, use the current CLI tenant
        to choose/search an app registration, enter its client ID, or plan a new application.
        Enter at the picker or manual client-ID prompt defaults to creating a new application.
        The new application display name defaults to EPP Application when Enter is pressed.
        A new application is created only after final deployment approval. Required in noninteractive mode.
    .PARAMETER Provider
        Provider name, never a numbered selection. When omitted interactively, read the app's
        allowed-tenants configuration: enter a name if none match, confirm one match, or choose
        by name among multiple matches. New applications show supported providers alphabetically.
        Blank provider-name input prompts again; there is no default provider.
        Explicit input confirms the choice; required unattended.
    .PARAMETER Location
        Azure region name. When omitted interactively, choose an Azure-recommended shortlist,
        show all physical regions returned for the subscription, or enter the name manually.
        Enter accepts the first region in the displayed list.
        EU tenants receive EU Data Boundary recommendations; explicit out-of-boundary choices warn.
        Recommendations do not guarantee plan availability or quota. Required noninteractively.
    .PARAMETER EndpointRegion
        Optional eu/global provider route assertion. Setup detects the tenant replication scope
        and rejects a conflicting value. Omit to use the detected route.
    .PARAMETER Language
        JavaScript by default, without a prompt. Use csharp or python to select another language.
        The legacy dotnet value remains supported for C#.
    .PARAMETER ResourcePrefix
        Interactive resource-name prefix, defaulting to epp on Enter. Required noninteractively.
    .PARAMETER PackageReleaseTag
        Latest stable package release by default. Supply an epp-packages-<run>-<attempt> tag
        to pin a reviewed Function release.
    .PARAMETER OutputDirectory
        Destination for deployment summaries and public certificates.
    .PARAMETER CertificateAction
        Create when no encryption certificate is registered, Reuse a selected certificate,
        or Replace all registered encryption certificates after explicit approval.
        Interactive selection defaults to Replace when encryption certificates exist.
        Unattended runs with existing certificates still require an explicit action.
    .PARAMETER EncryptionKeyId
        App-registration key ID to keep when reusing a certificate. Required for unattended reuse.
    .PARAMETER KeyVaultCertificateId
        Versioned Key Vault certificate URL for reuse, not a public certificate or secret value.
    .PARAMETER KeyVaultSubscriptionId
        Subscription containing the reused certificate. Defaults to the deployment subscription.
    .PARAMETER ForceAuthentication
        Explicitly request a new Azure CLI device-code sign-in. Omit in Cloud Shell to reuse
        its existing login. Graph always uses the resulting CLI session, never a separate SDK login.
    .PARAMETER InstallPrerequisites
        Install the Azure CLI Bicep component if it is missing. The Graph SDK is not required.
    .PARAMETER PassThru
        Return the structured deployment summary. By default, only the ordered human-readable
        result is displayed, ending with Next steps; the summary JSON is always saved.
    .PARAMETER NonInteractive
        Require mandatory settings and existing user authentication. Language defaults to JavaScript
        and provider routing is detected from the tenant. Does not approve deployment.
    .PARAMETER ApproveDeployment
        Authorize the displayed deployment plan without another prompt. This changes Azure
        resources and application configuration; it is not a preview.
    .EXAMPLE
        Invoke-EppSetup
    .EXAMPLE
        Invoke-EppSetup -ForceAuthentication -ServicePlan FC1 -Language javascript
    .OUTPUTS
        System.Management.Automation.PSCustomObject
        With PassThru, the completed deployment summary. Cancellation returns no object.
    #>
    [CmdletBinding()]
    param(
        [string] $TenantId, [string] $SubscriptionId, [string] $ApplicationId, [string] $Location,
        [string] $Provider, [string] $EndpointRegion,
        [string] $ResourcePrefix,
        [string] $Language = 'javascript',
        [string] $PackageReleaseTag,
        [string] $ServicePlan,
        [ValidateSet('Create', 'Reuse', 'Replace')]
        [string] $CertificateAction,
        [string] $EncryptionKeyId, [string] $KeyVaultCertificateId, [string] $KeyVaultSubscriptionId,
        [string] $OutputDirectory = (Join-Path (Get-Location).Path 'epp-output'),
        [string] $AssetDirectory, [string] $SourceBaseUri,
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$')]
        [string] $SourceRepository = 'Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample',
        [switch] $NonInteractive, [switch] $InstallPrerequisites,
        [switch] $ForceAuthentication, [switch] $ApproveDeployment, [switch] $PassThru
    )

    if ($NonInteractive -and $ForceAuthentication) {
        throw '-ForceAuthentication requires interactive device-code sign-in and cannot be combined with -NonInteractive.'
    }
    if ($NonInteractive) { $ProgressPreference = 'SilentlyContinue' }
    if (-not (Test-Path -LiteralPath $AssetDirectory -PathType Container)) {
        throw 'Setup assets are missing. Run Setup-Epp.ps1 instead of invoking the temporary helper directly.'
    }
    $sourcePattern = '^https://raw\.githubusercontent\.com/' + [regex]::Escape($SourceRepository) + '/(?<revision>[0-9a-fA-F]{40})/setup$'
    if ($SourceBaseUri -cnotmatch $sourcePattern) {
        throw 'Setup assets must come from one commit-pinned source repository.'
    }
    $sourceRevision = $Matches.revision.ToLowerInvariant()
    $OutputDirectory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
    $assetPrefix = $AssetDirectory.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if ($OutputDirectory.Equals($AssetDirectory, [StringComparison]::OrdinalIgnoreCase) -or
        $OutputDirectory.StartsWith($assetPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw '-OutputDirectory must be outside the temporary setup download directory.'
    }
    $workingDirectory = Join-Path ([IO.Path]::GetTempPath()) "epp-setup-$([Guid]::NewGuid().ToString('N'))"
    try {
        New-Item -ItemType Directory -Path $workingDirectory | Out-Null
        Write-Host "`nExternal Phone Provider (EPP) setup" -ForegroundColor Cyan
        Write-Host 'Connect Microsoft Entra ID to your phone provider for SMS and voice one-time passwords.'
        $azureContext = Select-EppAzureContext -TenantId $TenantId -SubscriptionId $SubscriptionId -NonInteractive:$NonInteractive
        if (-not $azureContext) {
            Write-Host 'Cancelled. No Azure resources or application credentials were changed.' -ForegroundColor Yellow
            return
        }
        Write-Host "`nEnter remaining customer settings. Supplied values will not be requested again."
        $inputs = @{
            SourceBaseUri = $SourceBaseUri
            SourceRevision = $sourceRevision
            TenantId = $azureContext.TenantId
            SubscriptionId = $azureContext.SubscriptionId
        }
        $inputs.ApplicationId = Select-EppApplication -Inputs $inputs -ApplicationId $ApplicationId -NonInteractive:$NonInteractive `
            -InstallPrerequisites:$InstallPrerequisites -ForceAuthentication:$ForceAuthentication
        if (-not $inputs.ApplicationId) {
            Write-Host 'Cancelled. No Azure resources or application credentials were changed.' -ForegroundColor Yellow
            return
        }
        if ($inputs.ApplicationId -ceq 'create') {
            $inputs.ApplicationId = $null
            $inputs.NewApplicationDisplayName = Read-EppInput -Name ApplicationDisplayName -Kind ApplicationName `
                -PromptName 'New application display name' -DefaultValue 'EPP Application'
        }
        if (-not [string]::IsNullOrWhiteSpace($Location) -or $NonInteractive) {
            $Location = Read-EppInput -Name Location -Value $Location -Kind Location -NonInteractive
        }
        $inputs.TenantRegionScope = Get-EppTenantRegionScope -TenantId $inputs.TenantId
        $endpointRegion = Resolve-EppEndpointRegion -TenantRegionScope $inputs.TenantRegionScope -EndpointRegion $EndpointRegion
        Write-Host "Tenant replication scope: $($inputs.TenantRegionScope)"
        Write-Host "Provider route: $(if ($endpointRegion -eq 'eu') { 'EU' } else { 'Global' })"
        $inputs.Location = Select-EppLocation -Inputs $inputs -Location $Location -NonInteractive:$NonInteractive `
            -ForceAuthentication:$ForceAuthentication
        if (-not $inputs.Location) {
            Write-Host 'Cancelled. No Azure resources or application credentials were changed.' -ForegroundColor Yellow
            return
        }
        if (-not $NonInteractive -and [string]::IsNullOrWhiteSpace($Provider)) {
            $null = Connect-EppGraphAccount -Inputs $inputs -ForceAuthentication:$ForceAuthentication
        }
        $providerName = Resolve-EppApplicationProvider -Inputs $inputs -AssetDirectory $assetDirectory -Provider $Provider -NonInteractive:$NonInteractive
        if (-not $providerName) {
            Write-Host 'Cancelled. No Azure resources or application credentials were changed.' -ForegroundColor Yellow
            return
        }
        $providerConfiguration = Get-EppProvider -AssetDirectory $assetDirectory -Provider $providerName `
            -EndpointRegion $endpointRegion -NonInteractive:$NonInteractive
        $inputs.ProviderAuthentication = $providerConfiguration.AuthenticationMode
        $inputs.ProviderTenantId = $providerConfiguration.Settings.EPP_PROVIDER_TENANT_ID
        $selection = Get-EppLanguage -AssetDirectory $assetDirectory -Language $Language -SourceRepository $SourceRepository `
            -PackageReleaseTag $PackageReleaseTag -NonInteractive:$NonInteractive
        $inputs.Language = $selection.Id
        $inputs.Platform = $selection.DisplayName
        Write-Host "Programming language: $($selection.DisplayName)"
        $inputs.PackageFile = ([Uri]$selection.Url).Segments[-1]
        $inputs.BuildStrategy = $selection.BuildStrategy
        $plan = Get-EppServicePlan -ServicePlan $ServicePlan -NonInteractive:$NonInteractive
        $inputs.ServicePlan = $plan.id
        $inputs.ResourcePrefix = Read-EppInput ResourcePrefix $ResourcePrefix -Kind Prefix `
            -PromptName 'Resource name prefix' -DefaultValue 'epp' -NonInteractive:$NonInteractive
        $names = Get-EppResourceNames -SubscriptionId $inputs.SubscriptionId -ApplicationId $inputs.ApplicationId `
            -ResourcePrefix $inputs.ResourcePrefix -PendingApplication:([bool]$inputs['NewApplicationDisplayName'])

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
        $package = Get-EppPackage -Selection $selection -Directory $workingDirectory
        $inputs.PackageSha256 = $package.Sha256
        $inputs.SourcePackageSha256 = $package.SourceSha256
        $inputs.PackageUrl = $selection.Url
        $inputs.PackageReleaseTag = $selection.ReleaseTag
        Invoke-EppAz bicep build --file (Join-Path $assetDirectory 'infra/main.bicep') `
            --outfile (Join-Path $assetDirectory 'main.json') | Out-Null
        Show-EppPlan -Inputs $inputs -Names $names -ProviderConfiguration $providerConfiguration -Context $context
        if (-not (Confirm-EppDeployment -NonInteractive:$NonInteractive -ApproveDeployment:$ApproveDeployment)) {
            Write-Host 'Cancelled. No Azure resources or app registrations were changed.' -ForegroundColor Yellow
            return
        }
        try {
            $result = Invoke-EppDeployment -Inputs $inputs -Names $names -ProviderConfiguration $providerConfiguration -Context $context `
                -AssetDirectory $assetDirectory -WorkingDirectory $workingDirectory -Package $package -OutputDirectory $OutputDirectory
            if ($PassThru) { return $result }
        }
        catch {
            Write-Warning 'Deployment did not complete. Previously created app registrations and Azure resources are left in place; no rollback or policy activation was attempted. Correct the reported failure and rerun with the same inputs and prefix.'
            if ($inputs['NewApplicationDisplayName']) {
                if ($inputs.ApplicationId) {
                    Write-Warning "Reuse the created app with -ApplicationId '$($inputs.ApplicationId)' -ResourcePrefix '$($inputs.ResourcePrefix)'. Do not create another app for this deployment."
                }
                else {
                    Write-Warning "If app creation was attempted, check the selected tenant for '$($inputs.NewApplicationDisplayName)' before retrying; a failed response does not prove that no app was created."
                }
            }
            throw
        }
    }
    finally {
        try {
            if (Test-Path -LiteralPath $workingDirectory) {
                Remove-Item -LiteralPath $workingDirectory -Recurse -Force -ErrorAction Stop
            }
        }
        catch { Write-Warning "Could not remove temporary setup files at '$workingDirectory': $($_.Exception.Message)" -WarningAction Continue }
    }
}

Export-ModuleMember -Function Invoke-EppSetup
