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
