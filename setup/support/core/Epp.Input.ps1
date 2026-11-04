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
