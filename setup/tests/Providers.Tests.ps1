#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$module = Import-Module (Join-Path $PSScriptRoot '../support/Epp.Setup.psm1') -Force -PassThru
$directory = Join-Path ([IO.Path]::GetTempPath()) "epp-provider-tests-$([Guid]::NewGuid().ToString('N'))"
$profiles = Join-Path $directory 'providers'
New-Item -ItemType Directory -Path $profiles | Out-Null
Copy-Item (Join-Path $PSScriptRoot '../providers/*.json') -Destination $profiles
try {
    & $module {
        param($Directory, $Profiles)

        function script:Assert($Condition, [string] $Message) {
            if (-not $Condition) { throw $Message }
        }
        $script:ForbiddenCalls = [Collections.Generic.List[string]]::new()
        foreach ($command in @('Invoke-WebRequest', 'Invoke-RestMethod', 'Invoke-EppAz', 'Invoke-MgGraphRequest',
            'Get-AzKeyVaultSecret', 'Get-Secret', 'Read-Host')) {
            Set-Item -Path "Function:script:$command" -Value {
                $script:ForbiddenCalls.Add($MyInvocation.MyCommand.Name)
                throw 'Network, credentials and prompts are forbidden in offline validation.'
            }
        }
        $script:AllowedReads = @('catalog.json', 'telesign.json', 'soprano.json') |
            ForEach-Object { Join-Path $Profiles $_ }
        function script:Get-Content {
            param($LiteralPath, [switch] $Raw)
            Assert ($LiteralPath -in $script:AllowedReads) 'Validation must only read local catalog/profile JSON, never credentials.'
            Microsoft.PowerShell.Management\Get-Content -LiteralPath $LiteralPath -Raw:$Raw
        }
        $parameters = @{ Provider = @('telesign', 'soprano'); Channel = 'sms'; EndpointRegion = 'global'; ProfileDirectory = $Profiles }
        foreach ($channel in @('sms', 'voice')) {
            foreach ($region in @('global', 'eu')) {
                $report = Test-EppProviderConfiguration @parameters -Channel $channel -EndpointRegion $region
                Assert ($report.Valid -and $report.Results.Count -eq 2 -and $report.Errors.Count -eq 0) 'Both shipped profiles must pass for every channel/region.'
                Assert (($report.Results.Provider -join ',') -ceq 'telesign,soprano') 'Results must retain selection order and canonical provider IDs.'
                Assert (@($report.Results | Where-Object { $_.Code -ne 'ConfigurationValid' -or $_.Issues.Count }).Count -eq 0) 'Successful results must contain no issues.'
            }
        }
        $single = Test-EppProviderConfiguration @parameters -Provider ' TELESIGN '
        Assert ($single.Valid -and $single.Results.Count -eq 1 -and $single.Results[0].Provider -ceq 'telesign') 'Single selections must normalize case and surrounding whitespace.'

        foreach ($selection in @(@(), @(''), @(' '))) {
            $report = Test-EppProviderConfiguration @parameters -Provider $selection
            Assert (-not $report.Valid) 'Empty selection must fail without prompting or choosing a provider.'
        }
        $report = Test-EppProviderConfiguration @parameters -Provider $null
        Assert (-not $report.Valid -and $report.Errors.Count -eq 1) 'Null selection must be an explicit failed report.'
        $report = Test-EppProviderConfiguration @parameters -Provider @('telesign', '')
        Assert ($report.Results[0].Valid -and $report.Results[1].Code -eq 'InvalidSelection' -and -not $report.Valid) 'An empty entry must not prevent another provider from being validated.'
        $report = Test-EppProviderConfiguration @parameters -Provider @('telesign', ' TELESIGN ', 'soprano')
        Assert (-not $report.Valid -and $report.Results.Count -eq 3) 'Duplicate selections must fail the run.'
        Assert ($report.Results[0].Code -eq 'DuplicateSelection' -and $report.Results[1].Code -eq 'DuplicateSelection' -and $report.Results[2].Valid) 'Every occurrence of a duplicate must fail, without skipping independent providers.'
        $report = Test-EppProviderConfiguration @parameters -Provider @('infobip', 'sinch', 'soprano', 'not-a-provider')
        Assert (-not $report.Valid -and $report.Results[2].Valid) 'Runtime-only and unknown providers must fail without stopping known providers.'
        Assert (@($report.Results | Where-Object Code -eq 'UnknownProvider').Count -eq 3) 'Unknown selections must be identified explicitly.'
        foreach ($invalidRoute in @(@{ Channel = '' }, @{ Channel = 'fax' }, @{ EndpointRegion = '' }, @{ EndpointRegion = 'westus2' })) {
            $arguments = $parameters.Clone()
            foreach ($key in $invalidRoute.Keys) { $arguments[$key] = $invalidRoute[$key] }
            $report = Test-EppProviderConfiguration @arguments
            Assert (-not $report.Valid -and @($report.Results | Where-Object Code -eq 'InvalidSelection').Count -eq 2) 'Invalid/missing routes must not silently select a default.'
        }

        $telesignPath = Join-Path $Profiles 'telesign.json'
        $original = Get-Content -LiteralPath $telesignPath -Raw
        $catalogPath = Join-Path $Profiles 'catalog.json'
        $catalogOriginal = Get-Content -LiteralPath $catalogPath -Raw
        $sentinel = 'DO-NOT-REPORT-PRIVATE-INPUT'
        $profile = $original | ConvertFrom-Json -AsHashtable
        $profile.deployment.routes.voice.eu.endpoint = "https://user:$sentinel@provider.contoso.com/?token=$sentinel"
        $profile.deployment.routes.sms.global.timeoutMilliseconds = 2501
        $profile.deployment.routes.sms.global.retryIntervalSeconds = -1
        $profile.deployment.authentication.keyVaultSecretName = $sentinel
        $profile | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $telesignPath
        $report = Test-EppProviderConfiguration @parameters
        Assert (-not $report.Valid -and -not $report.Results[0].Valid -and $report.Results[1].Valid) 'A bad profile must not stop validation of a good profile.'
        Assert ($report.Results[0].Code -eq 'ProfileInvalid') 'Invalid profiles must be reported explicitly.'
        $json = $report | ConvertTo-Json -Depth 6
        Assert (-not $json.Contains($sentinel)) 'Reports must never echo invalid profile values.'
        Assert ($json.Contains('deployment.routes.voice.eu.endpoint') -and $json.Contains('timeoutMilliseconds') -and $json.Contains('retryIntervalSeconds') -and $json.Contains('keyVaultSecretName')) 'Safe issue descriptions must identify invalid fields, including unselected routes.'

        foreach ($badJson in @("{ malformed-$sentinel", 'null', '[]')) {
            Set-Content -LiteralPath $telesignPath -Value $badJson
            $report = Test-EppProviderConfiguration @parameters
            Assert (-not $report.Valid -and $report.Results[0].Code -eq 'ProfileUnreadable' -and $report.Results[1].Valid) 'Malformed/nonobject JSON must fail independently.'
            Assert (-not ($report | ConvertTo-Json -Depth 6).Contains($sentinel)) 'Parser exception details must not leak input values.'
        }
        foreach ($badProfile in @('{}', '{"deployment":{}}', '{"deployment":{"routes":[]}}')) {
            Set-Content -LiteralPath $telesignPath -Value $badProfile
            $report = Test-EppProviderConfiguration @parameters
            Assert ($report.Results[0].Code -eq 'ProfileInvalid' -and $report.Results[1].Valid) 'Missing profile structure must be a safe independent failure.'
            Assert ($report.Results[0].Issues -is [array]) 'Even a single structural issue must serialize as a JSON array.'
        }
        Remove-Item -LiteralPath $telesignPath
        $report = Test-EppProviderConfiguration @parameters
        Assert ($report.Results[0].Code -eq 'ProfileUnreadable' -and $report.Results[1].Valid) 'A missing profile must not trigger a download.'
        Set-Content -LiteralPath $telesignPath -Value $original
        foreach ($mutation in @('disabled', 'identity', 'tenant', 'authentication', 'timeout', 'retry')) {
            $profile = $original | ConvertFrom-Json -AsHashtable
            switch ($mutation) {
                'disabled' { $profile.deployment.enabled = $false }
                'identity' { $profile.deployment.providerName = 'soprano' }
                'tenant' { $profile.deployment.tenantId = $sentinel }
                'authentication' { $profile.deployment.authentication.mode = $sentinel }
                'timeout' { $profile.deployment.routes.sms.global.timeoutMilliseconds = 0 }
                'retry' { $profile.deployment.routes.sms.global.retryIntervalSeconds = 2147484 }
            }
            $profile | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $telesignPath
            $report = Test-EppProviderConfiguration @parameters
            Assert ($report.Results[0].Code -eq 'ProfileInvalid' -and $report.Results[1].Valid) "Shared validator must reject $mutation independently."
            Assert ($report.Results[0].Issues -is [array] -and $report.Results[0].Issues.Count -eq 1) 'Single field issues must retain array shape.'
            Assert (-not ($report | ConvertTo-Json -Depth 6).Contains($sentinel)) 'Invalid tenant/authentication values must not leak.'
        }
        Set-Content -LiteralPath $telesignPath -Value $original
        $sopranoPath = Join-Path $Profiles 'soprano.json'
        $sopranoOriginal = Get-Content -LiteralPath $sopranoPath -Raw
        $profile = $sopranoOriginal | ConvertFrom-Json -AsHashtable
        $profile.deployment.routes.voice.eu.appId = $sentinel
        $profile.deployment.routes.voice.eu.scope = $sentinel
        $profile | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $sopranoPath
        $report = Test-EppProviderConfiguration @parameters
        Assert (-not $report.Valid -and $report.Results[0].Valid -and $report.Results[1].Code -eq 'ProfileInvalid') 'Invalid OAuth settings must fail independently, including unselected routes.'
        Assert ($report.Results[1].Issues.Count -eq 2 -and -not ($report | ConvertTo-Json -Depth 6).Contains($sentinel)) 'OAuth issues must use safe field descriptions.'
        Set-Content -LiteralPath $sopranoPath -Value $sopranoOriginal

        foreach ($mutation in @('duplicate-id', 'duplicate-file', 'ambiguous-alias', 'path-traversal', 'schema')) {
            $catalog = $catalogOriginal | ConvertFrom-Json -AsHashtable
            switch ($mutation) {
                'duplicate-id' { $catalog.providers[1].id = 'telesign' }
                'duplicate-file' { $catalog.providers[1].file = 'telesign.json' }
                'ambiguous-alias' { $catalog.providers[1].displayName = 'Telesign' }
                'path-traversal' { $catalog.providers[0].file = '../private.json' }
                'schema' { $catalog.schemaVersion = 2 }
            }
            $catalog | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $catalogPath
            $report = Test-EppProviderConfiguration @parameters
            Assert (-not $report.Valid -and $report.Results.Count -eq 0 -and $report.Errors.Count -eq 1) 'Invalid or ambiguous catalogs must fail the entire run before profile reads.'
        }
        Set-Content -LiteralPath $catalogPath -Value "{ malformed-$sentinel"
        $report = Test-EppProviderConfiguration @parameters
        Assert (-not $report.Valid -and -not ($report | ConvertTo-Json -Depth 6).Contains($sentinel)) 'Catalog parser failures must not leak input.'
        Set-Content -LiteralPath $catalogPath -Value $catalogOriginal
        $report = Test-EppProviderConfiguration @parameters -Provider @($sentinel, 'soprano')
        Assert (-not $report.Valid -and $report.Results[0].Index -eq 1 -and $null -eq $report.Results[0].Provider -and $report.Results[1].Valid) 'Unknown selections must be identified by position rather than echoed.'
        Assert (-not ($report | ConvertTo-Json -Depth 6).Contains($sentinel)) 'Unknown selections must not leak arbitrary input.'
        Assert ($script:ForbiddenCalls.Count -eq 0) 'Offline validation must not attempt network, secret access, or prompts even on failures.'

        $script:Downloads = @()
        function script:Invoke-WebRequest {
            param($Uri, $OutFile, $TimeoutSec, $MaximumRedirection)
            $script:Downloads += $Uri
        }
        foreach ($id in @('telesign', 'soprano')) {
            $selected = Get-EppProvider -AssetDirectory $Directory `
                -SourceBaseUri "https://raw.githubusercontent.com/Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample/$('a' * 40)/setup" `
                -Provider $id -Channel voice -EndpointRegion eu -NonInteractive
            $expected = ConvertTo-EppProviderSettings -Profile (Read-EppJson (Join-Path $Profiles "$id.json")) `
                -Id $id -DisplayName $id -Channel voice -EndpointRegion eu -NonInteractive
            foreach ($key in $expected.Settings.Keys) {
                Assert ($selected.Settings[$key] -ceq $expected.Settings[$key]) 'Single-provider setup must preserve its existing app settings.'
            }
            Assert ($selected.Settings.EPP_PROVIDER_NAME -ceq $id -and $selected.Channel -eq 'voice' -and $selected.EndpointRegion -eq 'eu') 'Setup must still select exactly one provider and route.'
        }
        Assert ($script:Downloads.Count -eq 2) 'Existing setup must retain one pinned profile download per selection.'
    } $directory $profiles

    $launcher = (Join-Path $PSScriptRoot '../Test-EppProviders.ps1').Replace("'", "''")
    $escapedProfiles = $profiles.Replace("'", "''")
    foreach ($case in @(
        @{ Selection = 'telesign,soprano'; Exit = 0; Count = 2 },
        @{ Selection = 'telesign'; Exit = 0; Count = 1 },
        @{ Selection = 'telesign,unknown'; Exit = 1; Count = 2 },
        @{ Selection = 'telesign,TELESIGN'; Exit = 1; Count = 2 },
        @{ Selection = '@()'; Exit = 1; Count = 0 },
        @{ Selection = 'telesign,soprano'; Exit = 1; Count = 2; InvalidProfile = $true }
    )) {
        if ($case.ContainsKey('InvalidProfile')) {
            $path = Join-Path $profiles 'telesign.json'
            $profile = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
            $profile.deployment.enabled = $false
            $profile | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path
        }
        $output = & (Join-Path $PSHOME 'pwsh') -NoProfile -Command "& '$launcher' -Provider $($case.Selection) -Channel sms -EndpointRegion global -ProfileDirectory '$escapedProfiles'" 2>&1
        if ($LASTEXITCODE -ne $case.Exit) { throw "Unexpected CLI exit code for $($case.Selection): $LASTEXITCODE" }
        $report = ($output -join "`n") | ConvertFrom-Json
        if ($report.Valid -ne ($case.Exit -eq 0) -or $report.Results.Count -ne $case.Count) { throw 'CLI must emit exactly one JSON report matching its exit code.' }
        foreach ($result in $report.Results) {
            if ($result.Issues -isnot [array]) { throw 'CLI issues must always be JSON arrays, including single-issue failures.' }
        }
    }
    Write-Host 'Provider validation tests passed (offline batch, safe failures, CLI exit codes, single-provider regression).'
}
finally {
    Remove-Module -ModuleInfo $module
    Remove-Item -LiteralPath $directory -Recurse -Force
}
