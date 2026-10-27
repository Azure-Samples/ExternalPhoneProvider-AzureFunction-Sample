#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$runner = Join-Path $PSScriptRoot '..\infra\Invoke-Certificate.ps1'
$originalPlan = $env:EPP_CERTIFICATE_PLAN
$rsa = [Security.Cryptography.RSA]::Create(2048)
$request = [Security.Cryptography.X509Certificates.CertificateRequest]::new(
    'CN=ExternalPhoneProvider', $rsa, [Security.Cryptography.HashAlgorithmName]::SHA256,
    [Security.Cryptography.RSASignaturePadding]::Pkcs1)
$certificate = $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-5), [DateTimeOffset]::UtcNow.AddYears(1))

function Assert($Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}
function Assert-Throws([scriptblock] $Action, [string] $Pattern) {
    try { $null = & $Action }
    catch {
        Assert ($_.Exception.Message -match $Pattern) "Unexpected failure: $($_.Exception.Message)"
        return
    }
    throw "Expected failure matching '$Pattern'."
}
function New-VaultError([int] $Status, [string] $Code) {
    return @{ Status = $Status; Code = $Code }
}
function Reset-Case([string] $Action = 'Create') {
    $script:Plan = @{
        action = $Action; vaultName = 'epptestvault'; certificateName = 'phone-provider-encryption'
        certificateId = 'https://epptestvault.vault.azure.net/certificates/phone-provider-encryption/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    }
    $script:CertificateUri = 'https://epptestvault.vault.azure.net/certificates/phone-provider-encryption'
    $script:VersionsUri = 'https://epptestvault.vault.azure.net/secrets/phone-provider-encryption/versions?api-version=7.4'
    $script:SecretId = 'https://epptestvault.vault.azure.net/secrets/phone-provider-encryption/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
    $script:RestCertificate = @{
        id = $script:Plan.certificateId; sid = $script:SecretId
        cer = [Convert]::ToBase64String($certificate.RawData).TrimEnd('=').Replace('+', '-').Replace('/', '_')
        attributes = @{ enabled = $true }
        policy = @{
            key_props = @{ kty = 'RSA'; key_size = 2048; exportable = $true; reuse_key = $true }
            secret_props = @{ contentType = 'application/x-pem-file' }
            lifetime_actions = @(@{ action = @{ action_type = 'EmailContacts' } })
        }
    } | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    $script:Version = @{
        id = $script:SecretId; managed = $true; contentType = 'application/x-pem-file'
        attributes = @{
            enabled = $true; nbf = [DateTimeOffset]::UtcNow.AddDays(-1).ToUnixTimeSeconds()
            exp = [DateTimeOffset]::UtcNow.AddYears(1).ToUnixTimeSeconds()
        }
    }
    $script:Pages = @{ $script:VersionsUri = @{ value = @($script:Version) } }
    $script:CertificateResponses = [Collections.Generic.Queue[object]]::new()
    $script:Calls = [Collections.Generic.List[object]]::new()
    $script:Sleeps = [Collections.Generic.List[int]]::new()
    $script:Warnings = [Collections.Generic.List[string]]::new()
    $script:CreateError = $null
    $script:PlainToken = $false
    $script:TokenReads = 0
}
function Get-AzAccessToken {
    param($ResourceUrl)
    Assert ($ResourceUrl -ceq 'https://vault.azure.net') 'Request only a Key Vault data-plane token.'
    $script:TokenReads++
    return @{ Token = if ($script:PlainToken) { 'offline-token' } else { ConvertTo-SecureString 'offline-token' -AsPlainText -Force } }
}
function Start-Sleep {
    param([int] $Seconds)
    $script:Sleeps.Add($Seconds)
}
function Write-Warning {
    param([string] $Message)
    $script:Warnings.Add($Message)
}
function Throw-VaultError($Failure) {
    $exception = [InvalidOperationException]::new("HTTP $($Failure.Status): $($Failure.Code)")
    $exception | Add-Member -NotePropertyName Response -NotePropertyValue @{ StatusCode = $Failure.Status }
    $record = [Management.Automation.ErrorRecord]::new(
        $exception, 'OfflineVaultError', [Management.Automation.ErrorCategory]::InvalidOperation, $null)
    $record.ErrorDetails = [Management.Automation.ErrorDetails]::new(
        (@{ error = @{ code = $Failure.Code } } | ConvertTo-Json -Compress))
    throw $record
}
function Invoke-RestMethod {
    param([string] $Uri, [string] $Method, $Authentication, $Token, $Body, $ContentType)
    Assert ($Authentication -ceq 'Bearer' -and $Token -is [Security.SecureString]) 'Use a secure bearer token, never a URL token.'
    $script:Calls.Add(@{ Uri = $Uri; Method = $Method; Body = $Body; ContentType = $ContentType })
    if ($Method -ceq 'POST') {
        Assert ($Uri -ceq "$script:CertificateUri/create?api-version=7.4") 'Only issue the approved certificate.'
        if ($script:CreateError) { Throw-VaultError $script:CreateError }
        return [pscustomobject]@{ status = 'inProgress' }
    }
    Assert ($Method -ceq 'GET') 'Do not mutate Key Vault outside certificate creation.'
    if ($Uri -in @("$script:CertificateUri`?api-version=7.4", "$($script:Plan.certificateId)?api-version=7.4")) {
        $response = if ($script:CertificateResponses.Count) { $script:CertificateResponses.Dequeue() } else { $script:RestCertificate }
        if ($response -is [hashtable] -and $response.ContainsKey('Status')) { Throw-VaultError $response }
        if ($response -is [Exception]) { throw $response }
        return $response
    }
    Assert ($script:Pages.ContainsKey($Uri)) "Unexpected metadata request (no network allowed): $Uri"
    return $script:Pages[$Uri] | ConvertTo-Json -Depth 10 | ConvertFrom-Json
}
function Invoke-Case {
    $env:EPP_CERTIFICATE_PLAN = $script:Plan | ConvertTo-Json -Depth 8
    return & {
        . $runner
        return $DeploymentScriptOutputs
    }
}
try {
    foreach ($action in @('Create', 'Replace', 'Reuse')) {
        Reset-Case $action
        $script:PlainToken = $action -eq 'Create'
        if ($action -ne 'Reuse') { $script:CertificateResponses.Enqueue((New-VaultError 404 CertificateNotFound)) }
        $output = Invoke-Case
        Assert ($script:TokenReads -eq 1) 'Acquire the data-plane token once.'
        Assert (($output.Keys | Sort-Object) -join ',' -ceq 'bundle,secretVersions') 'Export only the public bundle and secret-version metadata.'
        Assert ($output.bundle.id -ceq $script:Plan.certificateId -and $output.bundle.sid -ceq $script:SecretId) 'Preserve versioned public certificate and backing secret IDs.'
        Assert ($output.bundle.cer -ceq [Convert]::ToBase64String($certificate.RawData)) 'Normalize REST base64url public DER to CLI-shaped base64.'
        Assert ($output.bundle.policy.keyProperties.keyType -ceq 'RSA' -and
            $output.bundle.policy.keyProperties.keySize -eq 2048 -and
            $output.bundle.policy.keyProperties.exportable -eq $true -and
            $output.bundle.policy.keyProperties.reuseKey -eq $true -and
            $output.bundle.policy.secretProperties.contentType -ceq 'application/x-pem-file' -and
            $output.bundle.policy.lifetimeActions[0].action.actionType -ceq 'EmailContacts') 'Normalize REST policy names to the local CLI validation contract.'
        Assert ($output.secretVersions.Count -eq 1 -and $output.secretVersions[0].managed -eq $true -and
            [DateTimeOffset]$output.secretVersions[0].attributes.notBefore -lt [DateTimeOffset]::UtcNow -and
            [DateTimeOffset]$output.secretVersions[0].attributes.expires -gt [DateTimeOffset]::UtcNow.AddDays(30)) 'Normalize secret metadata timestamps without reading secret values.'
        $posts = @($script:Calls | Where-Object Method -eq POST)
        if ($action -eq 'Reuse') {
            Assert ($posts.Count -eq 0 -and $script:Calls[0].Uri -ceq "$($script:Plan.certificateId)?api-version=7.4") 'Reuse reads only the approved version, never creates.'
        }
        else {
            Assert ($posts.Count -eq 1 -and $posts[0].ContentType -ceq 'application/json') 'Create once only after CertificateNotFound.'
            $policy = ($posts[0].Body | ConvertFrom-Json).policy
            Assert ($policy.issuer.name -ceq 'Self' -and $policy.x509_props.subject -ceq 'CN=ExternalPhoneProvider' -and
                $policy.x509_props.validity_months -eq 12) 'Issue the fixed subject for twelve months.'
            Assert ($policy.key_props.kty -ceq 'RSA' -and $policy.key_props.key_size -eq 2048 -and
                $policy.key_props.exportable -eq $true -and $policy.key_props.reuse_key -eq $true) 'Issue exportable reusable RSA-2048 keys.'
            Assert ($policy.secret_props.contentType -ceq 'application/x-pem-file' -and
                $policy.lifetime_actions.Count -eq 1 -and
                $policy.lifetime_actions[0].action.action_type -ceq 'EmailContacts' -and
                $policy.lifetime_actions[0].trigger.days_before_expiry -eq 30 -and
                $policy.x509_props.key_usage -contains 'keyEncipherment' -and
                $policy.x509_props.key_usage -contains 'dataEncipherment') 'PEM encryption certificates must use manual renewal, not AutoRenew.'
        }
        Assert (@($script:Calls | Where-Object { $_.Uri -like '*/secrets/*' -and $_.Uri -cne $script:VersionsUri }).Count -eq 0) 'Never fetch private secret values.'
        Assert ($script:Sleeps.Count -eq 0) 'An immediately available certificate must not poll unnecessarily.'
    }

    Reset-Case
    $null = Invoke-Case
    Assert (@($script:Calls | Where-Object Method -eq POST).Count -eq 0) 'Create reruns must reuse an existing compatible certificate.'
    Reset-Case Reuse
    $script:RestCertificate.policy.PSObject.Properties.Remove('lifetime_actions')
    $script:RestCertificate.policy.key_props.PSObject.Properties.Remove('reuse_key')
    $script:Version.attributes.Remove('nbf'); $script:Version.attributes.Remove('exp')
    $output = Invoke-Case
    Assert ($output.bundle.policy.lifetimeActions.Count -eq 0 -and
        $null -eq $output.bundle.policy.keyProperties.reuseKey -and
        -not $output.secretVersions[0].attributes.ContainsKey('expires')) 'Reuse allows absent renewal actions and optional metadata timestamps.'

    foreach ($status in @(403, 429, 503)) {
        Reset-Case
        $script:CertificateResponses.Enqueue((New-VaultError $status TransientFailure))
        $null = Invoke-Case
        Assert ($script:Sleeps.Count -eq 1 -and $script:Sleeps[0] -eq 10 -and
            @($script:Calls | Where-Object Method -eq POST).Count -eq 0) 'Retry transient metadata access, never treat it as missing.'
        Reset-Case
        1..12 | ForEach-Object { $script:CertificateResponses.Enqueue((New-VaultError $status PersistentFailure)) }
        Assert-Throws { Invoke-Case } "HTTP $status"
        Assert ($script:Calls.Count -eq 12 -and $script:Sleeps.Count -eq 11 -and $script:Warnings.Count -eq 11) 'GET retries must be bounded at twelve attempts.'
    }
    foreach ($failure in @(
        (New-VaultError 404 VaultNotFound), (New-VaultError 401 Unauthorized),
        (New-VaultError 400 BadParameter), (New-VaultError 500 InternalServerError)
    )) {
        Reset-Case
        $script:CertificateResponses.Enqueue($failure)
        Assert-Throws { Invoke-Case } $failure.Code
        Assert ($script:Calls.Count -eq 1 -and $script:Sleeps.Count -eq 0) 'Other errors propagate without creation or retries.'
    }
    Reset-Case
    $script:CertificateResponses.Enqueue([InvalidOperationException]::new('offline transport failure'))
    Assert-Throws { Invoke-Case } 'offline transport failure'
    Reset-Case Reuse
    $script:CertificateResponses.Enqueue((New-VaultError 404 CertificateNotFound))
    Assert-Throws { Invoke-Case } 'Reuse will not issue a replacement'
    Assert ($script:Calls.Count -eq 1) 'Missing reused versions must fail without issuance.'
    Reset-Case
    $script:CertificateResponses.Enqueue((New-VaultError 404 CertificateNotFound))
    $script:CreateError = New-VaultError 503 CreationFailed
    Assert-Throws { Invoke-Case } CreationFailed
    Assert ($script:Calls.Count -eq 2 -and $script:Sleeps.Count -eq 0) 'Never retry an uncertain certificate POST.'

    Reset-Case
    1..31 | ForEach-Object { $script:CertificateResponses.Enqueue((New-VaultError 404 CertificateNotFound)) }
    Assert-Throws { Invoke-Case } 'within five minutes'
    Assert (@($script:Calls | Where-Object Method -eq POST).Count -eq 1 -and
        $script:Sleeps.Count -eq 29 -and $script:Calls.Count -eq 32) 'Certificate issuance polling must be bounded at thirty reads after one POST.'
    Reset-Case
    $script:CertificateResponses.Enqueue((New-VaultError 404 CertificateNotFound))
    $script:CertificateResponses.Enqueue((New-VaultError 404 CertificateNotFound))
    $script:CertificateResponses.Enqueue([pscustomobject]@{ cer = '' })
    $null = Invoke-Case
    Assert ($script:Sleeps.Count -eq 2) 'Poll until public certificate bytes become available.'

    Reset-Case Reuse
    $next = "$script:VersionsUri&maxresults=1&skiptoken=next"
    $script:Pages[$script:VersionsUri].nextLink = $next
    $second = @{} + $script:Version; $second.id = $second.id.Replace(('b' * 32), ('c' * 32))
    $script:Pages[$next] = @{ value = @($second) }
    $output = Invoke-Case
    Assert ($output.secretVersions.Count -eq 2 -and $script:Calls[-1].Uri -ceq $next) 'Follow approved same-collection pagination and retain every version.'
    $boundaryFailures = [Collections.Generic.List[string]]::new()
    foreach ($next in @(
        'https://other.vault.azure.net/secrets/phone-provider-encryption/versions?api-version=7.4',
        'https://epptestvault.vault.azure.net.evil.example/secrets/phone-provider-encryption/versions',
        'http://epptestvault.vault.azure.net/secrets/phone-provider-encryption/versions',
        'https://user@epptestvault.vault.azure.net/secrets/phone-provider-encryption/versions',
        'https://epptestvault.vault.azure.net/secrets/phone-provider-encryption/versions#fragment',
        'https://epptestvault.vault.azure.net/secrets/another-secret/versions?api-version=7.4',
        'https://epptestvault.vault.azure.net/secrets/phone-provider-encryption/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb?api-version=7.4',
        'https://epptestvault.vault.azure.net/secrets/phone-provider-encryption/versions/../bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb?api-version=7.4'
        'https://epptestvault.vault.azure.net/secrets/phone-provider-encryption/versions?api-version=7.4#fragment'
        'https://epptestvault.vault.azure.net/secrets/phone-provider-encryption/versions%2f..%2fbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb?api-version=7.4'
        'https://epptestvault.vault.azure.net/secrets/phone-provider-encryption/versions\..\bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb?api-version=7.4'
    )) {
        Reset-Case Reuse
        $script:Pages[$script:VersionsUri].nextLink = $next
        try {
            Assert-Throws { Invoke-Case } 'approved vault|secret.version|pagination'
            Assert ($script:Calls.Count -eq 2) 'Reject unsafe pagination before any off-collection or secret-value request.'
        }
        catch { $boundaryFailures.Add("$next : $($_.Exception.Message)") }
    }
    Reset-Case Reuse
    $script:Pages[$script:VersionsUri].nextLink = $script:VersionsUri
    Assert-Throws { Invoke-Case } 'repeated or excessive'
    Assert ($script:Calls.Count -eq 2) 'A pagination cycle must stop before repeating a request.'
    Reset-Case Reuse
    for ($index = 1; $index -le 1000; $index++) {
        $current = if ($index -eq 1) { $script:VersionsUri } else { "$script:VersionsUri&skiptoken=$index" }
        $script:Pages[$current] = @{ value = @(); nextLink = "$script:VersionsUri&skiptoken=$($index + 1)" }
    }
    Assert-Throws { Invoke-Case } 'repeated or excessive'
    Assert ($script:Calls.Count -eq 1001) 'Stop excessive pagination before requesting page 1001.'

    foreach ($change in @(
        { $script:Plan.vaultName = 'bad/vault' },
        { $script:Plan.certificateName = '../secret' },
        { $script:Plan.action = 'Delete' }
    )) {
        Reset-Case
        & $change
        Assert-Throws { Invoke-Case } 'plan is invalid'
        Assert ($script:TokenReads -eq 0 -and $script:Calls.Count -eq 0) 'Reject invalid plans before acquiring credentials.'
    }
    Reset-Case Reuse
    $script:Plan.certificateId = $script:CertificateUri
    Assert-Throws { Invoke-Case } 'exact approved certificate version'
    Assert ($script:Calls.Count -eq 0) 'Reuse requires a pinned certificate version.'
    Assert ($boundaryFailures.Count -eq 0) ("Unsafe pagination was not rejected before requesting data:`n" + ($boundaryFailures -join "`n"))
    Write-Host 'ARM-hosted certificate issuance, reuse, metadata normalization, pagination boundaries, and bounded retries passed.'
}
finally {
    $env:EPP_CERTIFICATE_PLAN = $originalPlan
    $certificate.Dispose(); $rsa.Dispose()
}
