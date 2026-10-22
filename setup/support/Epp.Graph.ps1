function Assert-EppCliDirectoryContext {
    param([hashtable] $Inputs)

    $account = Invoke-EppAz account show --output json | ConvertFrom-Json -AsHashtable
    if ($account -isnot [Collections.IDictionary] -or $account['user'] -isnot [Collections.IDictionary] -or
        $account['tenantId'] -ine $Inputs.TenantId -or $account['environmentName'] -cne 'AzureCloud' -or
        $account.user['type'] -cne 'user') {
        throw 'The current Azure CLI directory does not match the selected tenant and public-cloud user session. Start Cloud Shell in the intended directory (or sign in with Azure CLI first). Setup will not switch the CLI default tenant.'
    }
}

function Invoke-EppDirectoryCommand {
    param([hashtable] $Inputs, [string[]] $Arguments)

    Assert-EppCliDirectoryContext -Inputs $Inputs
    if ($Arguments.Count -lt 2 -or $Arguments[0] -cne 'ad') { throw 'Expected an Azure CLI directory command.' }
    $output = Invoke-EppAz @Arguments --output json
    if ([string]::IsNullOrWhiteSpace($output)) { throw 'Azure CLI returned an empty directory response.' }
    return ConvertFrom-Json -InputObject $output -AsHashtable -NoEnumerate
}

function Invoke-EppGraphRequest {
    param(
        [hashtable] $Inputs,
        [ValidateSet('GET', 'POST', 'PATCH')][string] $Method = 'GET',
        [string] $Path,
        [Collections.IDictionary] $Query,
        [Collections.IDictionary] $Body
    )

    $uri = $null
    $address = if ($Path.StartsWith('/')) { "https://graph.microsoft.com$Path" } else { $Path }
    if (-not [Uri]::TryCreate($address, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -cne 'https' -or $uri.Host -ine 'graph.microsoft.com' -or $uri.Port -ne 443 -or
        $uri.UserInfo -or $uri.Fragment -or $uri.AbsolutePath -cnotmatch '^/(v1\.0|beta)/' -or
        $uri.AbsolutePath -match '(?i)%2f|%5c|%2e|\\') {
        throw 'Graph requests must target the public Microsoft Graph v1.0 or beta endpoint.'
    }
    Assert-EppCliDirectoryContext -Inputs $Inputs
    $parameters = @{}
    foreach ($pair in $uri.Query.TrimStart('?').Split('&', [StringSplitOptions]::RemoveEmptyEntries)) {
        $parts = $pair.Split('=', 2)
        if ($parts.Count -ne 2) { throw 'Graph returned an invalid continuation query.' }
        $name = [Uri]::UnescapeDataString($parts[0].Replace('+', ' '))
        if ($parameters.ContainsKey($name)) { throw 'Graph returned duplicate continuation parameters.' }
        $parameters[$name] = [Uri]::UnescapeDataString($parts[1].Replace('+', ' '))
    }
    if ($Query) {
        foreach ($entry in $Query.GetEnumerator()) {
            if ($parameters.ContainsKey($entry.Key)) { throw 'Duplicate Graph query parameter.' }
            $parameters[$entry.Key] = $entry.Value
        }
    }
    $directory = Join-Path ([IO.Path]::GetTempPath()) "epp-graph-$([Guid]::NewGuid().ToString('N'))"
    try {
        New-Item -ItemType Directory -Path $directory | Out-Null
        $arguments = @('rest', '--method', $Method.ToLowerInvariant(), '--url', $uri.GetLeftPart([UriPartial]::Path),
            '--resource', 'https://graph.microsoft.com/', '--subscription', $Inputs.SubscriptionId, '--output', 'json')
        if ($parameters.Count) {
            $queryPath = Join-Path $directory 'query.json'
            $parameters | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $queryPath -Encoding utf8NoBOM
            $arguments += @('--url-parameters', "@$queryPath")
        }
        if ($null -ne $Body) {
            $bodyPath = Join-Path $directory 'body.json'
            $Body | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $bodyPath -Encoding utf8NoBOM
            $arguments += @('--body', "@$bodyPath")
        }
        # Azure CLI obtains/renews a Graph-audience token; no bearer token is exposed to PowerShell.
        $output = Invoke-EppAz @arguments
        if ([string]::IsNullOrWhiteSpace($output)) {
            if ($Method -eq 'PATCH') { return $null }
            throw 'Microsoft Graph returned an empty response.'
        }
        return ConvertFrom-Json -InputObject $output -AsHashtable -NoEnumerate
    }
    finally {
        if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force }
    }
}

function Get-EppGraphCollection {
    param([hashtable] $Inputs, [string] $Path, [Collections.IDictionary] $Query)

    $next = $Path
    $collection = [Uri]$(if ($Path.StartsWith('/')) { "https://graph.microsoft.com$Path" } else { $Path })
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    for ($pageNumber = 1; $pageNumber -le 100; $pageNumber++) {
        $page = Invoke-EppGraphRequest -Inputs $Inputs -Path $next -Query $Query
        if ($page -isnot [Collections.IDictionary] -or $page['value'] -isnot [Array]) {
            throw 'Microsoft Graph returned an invalid collection response.'
        }
        foreach ($item in $page.value) {
            if ($item -isnot [Collections.IDictionary]) { throw 'Microsoft Graph returned an invalid collection item.' }
            [pscustomobject]$item
        }
        if (-not $page['@odata.nextLink']) { return }
        $uri = $null
        if (-not [Uri]::TryCreate([string]$page['@odata.nextLink'], [UriKind]::Absolute, [ref]$uri) -or
            $uri.GetLeftPart([UriPartial]::Path) -cne $collection.GetLeftPart([UriPartial]::Path) -or
            -not $seen.Add($uri.AbsoluteUri)) {
            throw 'Microsoft Graph returned an invalid or repeated collection continuation.'
        }
        $next = $uri.AbsoluteUri
        $Query = $null
    }
    throw 'Microsoft Graph collection pagination exceeded the supported limit.'
}

function ConvertFrom-EppGraphApplication {
    param([Collections.IDictionary] $Application)

    if (-not $Application) { throw 'Microsoft Graph returned an empty application.' }
    $keys = @(foreach ($credential in @($Application['keyCredentials'])) {
        if ($null -eq $credential) { continue }
        if ($credential -isnot [Collections.IDictionary]) { throw 'Microsoft Graph returned an invalid key credential.' }
        $binary = @{}
        foreach ($field in @('key', 'customKeyIdentifier')) {
            $binary[$field] = $null
            try { if ($credential[$field]) { $binary[$field] = [Convert]::FromBase64String([string]$credential[$field]) } }
            catch [FormatException] { throw "Microsoft Graph returned invalid base64 in keyCredentials.$field." }
        }
        [pscustomobject]@{
            KeyId = ConvertTo-EppGuid ([string]$credential['keyId'])
            Type = $credential['type']; Usage = $credential['usage']; DisplayName = $credential['displayName']
            Key = $binary.key; CustomKeyIdentifier = $binary.customKeyIdentifier
            StartDateTime = $credential['startDateTime']; EndDateTime = $credential['endDateTime']
        }
    })
    $api = $Application['api']
    if ($api -and $api -isnot [Collections.IDictionary]) { throw 'Microsoft Graph returned invalid application API settings.' }
    return [pscustomobject]@{
        Id = ConvertTo-EppGuid ([string]$Application['id'])
        AppId = ConvertTo-EppGuid ([string]$Application['appId'])
        DisplayName = [string]$Application['displayName']; SignInAudience = [string]$Application['signInAudience']
        Api = [pscustomobject]@{ RequestedAccessTokenVersion = if ($api) { $api['requestedAccessTokenVersion'] } else { $null } }
        AppRoles = @($Application['appRoles'] | Where-Object { $null -ne $_ } | ForEach-Object { [pscustomobject]$_ })
        IdentifierUris = @($Application['identifierUris'] | Where-Object { $null -ne $_ })
        KeyCredentials = $keys; TokenEncryptionKeyId = $Application['tokenEncryptionKeyId']
    }
}

function Get-EppApplication {
    param([hashtable] $Inputs, [string] $ClientId, [string] $ObjectId)

    if ($ClientId) {
        $ClientId = ConvertTo-EppGuid $ClientId
        $basic = Invoke-EppDirectoryCommand -Inputs $Inputs -Arguments @('ad', 'app', 'show', '--id', $ClientId)
        if ($basic -isnot [Collections.IDictionary] -or $basic['appId'] -ine $ClientId) {
            throw 'The selected application client ID did not resolve to the expected app registration.'
        }
        $ObjectId = ConvertTo-EppGuid ([string]$basic['id'])
    }
    else { $ObjectId = ConvertTo-EppGuid $ObjectId }
    $raw = Invoke-EppGraphRequest -Inputs $Inputs -Path "/v1.0/applications/$ObjectId" -Query @{
        '$select' = 'id,appId,displayName,signInAudience,api,appRoles,identifierUris,keyCredentials,tokenEncryptionKeyId'
    }
    $application = ConvertFrom-EppGraphApplication -Application $raw
    if ($application.Id -ine $ObjectId -or ($ClientId -and $application.AppId -ine $ClientId)) {
        throw 'Microsoft Graph application readback does not match the requested registration.'
    }
    return $application
}

function New-EppApplication {
    param([hashtable] $Inputs, [string] $DisplayName)

    $DisplayName = Read-EppInput -Name ApplicationDisplayName -Value $DisplayName -Kind ApplicationName -NonInteractive
    $raw = Invoke-EppGraphRequest -Inputs $Inputs -Method POST -Path '/v1.0/applications' -Body @{
        displayName = $DisplayName
        signInAudience = 'AzureADMyOrg'
    }
    $application = ConvertFrom-EppGraphApplication -Application $raw
    if ($application.DisplayName -cne $DisplayName -or $application.SignInAudience -cne 'AzureADMyOrg' -or
        $application.KeyCredentials.Count -or $application.AppRoles.Count -or $application.IdentifierUris.Count -or
        $application.TokenEncryptionKeyId -or
        ($application.Api.RequestedAccessTokenVersion -and $application.Api.RequestedAccessTokenVersion -ne 1)) {
        throw "Created application '$($application.AppId)' does not match the approved new registration. Inspect it before rerunning setup."
    }
    return $application
}

function ConvertTo-EppGraphKeyCredentials {
    param([object[]] $Credentials)

    foreach ($key in $Credentials) {
        [ordered]@{
            keyId = [string]$key.KeyId; type = $key.Type; usage = $key.Usage; displayName = $key.DisplayName
            key = if ($key.Key) { [Convert]::ToBase64String([byte[]]$key.Key) } else { $null }
            customKeyIdentifier = if ($key.CustomKeyIdentifier) { [Convert]::ToBase64String([byte[]]$key.CustomKeyIdentifier) } else { $null }
            startDateTime = if ($key.StartDateTime) { ([DateTimeOffset]$key.StartDateTime).ToUniversalTime().ToString('o') } else { $null }
            endDateTime = if ($key.EndDateTime) { ([DateTimeOffset]$key.EndDateTime).ToUniversalTime().ToString('o') } else { $null }
        }
    }
}

function Get-EppAppRoleAssignments {
    param([hashtable] $Inputs, [string] $PrincipalId)

    $id = ConvertTo-EppGuid $PrincipalId
    Get-EppGraphCollection -Inputs $Inputs -Path "/v1.0/servicePrincipals/$id/appRoleAssignments"
}

function ConvertFrom-EppGraphServicePrincipal {
    param([Collections.IDictionary] $Principal)

    if (-not $Principal) { throw 'Azure CLI returned an empty service principal.' }
    foreach ($field in @('accountEnabled', 'appRoleAssignmentRequired')) {
        if ($null -ne $Principal[$field] -and $Principal[$field] -isnot [bool]) {
            throw "Azure CLI returned invalid service-principal $field metadata."
        }
    }
    return [pscustomobject]@{
        Id = ConvertTo-EppGuid ([string]$Principal['id'])
        AppId = ConvertTo-EppGuid ([string]$Principal['appId'])
        DisplayName = [string]$Principal['displayName']
        AccountEnabled = $Principal['accountEnabled']
        AppRoleAssignmentRequired = $Principal['appRoleAssignmentRequired']
        AppRoles = @($Principal['appRoles'] | Where-Object { $null -ne $_ } | ForEach-Object { [pscustomobject]$_ })
    }
}

function New-EppFederatedCredential {
    param([hashtable] $Inputs, [string] $ObjectId, [Collections.IDictionary] $Credential)

    $id = ConvertTo-EppGuid $ObjectId
    $path = Join-Path ([IO.Path]::GetTempPath()) "epp-federation-$([Guid]::NewGuid().ToString('N')).json"
    try {
        $Credential | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $path -Encoding utf8NoBOM
        Invoke-EppDirectoryCommand -Inputs $Inputs -Arguments @('ad', 'app', 'federated-credential', 'create', '--id', $id, '--parameters', $path) | Out-Null
    }
    finally { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force } }
}
