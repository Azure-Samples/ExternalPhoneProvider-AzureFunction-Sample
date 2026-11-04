$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$plan = $env:EPP_CERTIFICATE_PLAN | ConvertFrom-Json -AsHashtable
$vaultUrl = "https://$($plan.vaultName).vault.azure.net"
if ($plan.vaultName -cnotmatch '^[a-zA-Z][a-zA-Z0-9-]{1,22}[a-zA-Z0-9]$' -or
    $plan.certificateName -cnotmatch '^[a-zA-Z0-9-]{1,127}$' -or
    $plan.action -notin @('Create', 'Replace', 'Reuse')) {
    throw 'The certificate deployment plan is invalid.'
}
$token = (Get-AzAccessToken -ResourceUrl 'https://vault.azure.net').Token
if ($token -isnot [Security.SecureString]) { $token = ConvertTo-SecureString $token -AsPlainText -Force }

function Invoke-VaultRequest {
    param([string] $Uri, [string] $Method = 'GET', $Body)
    if (-not $Uri.StartsWith("$vaultUrl/", [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Certificate requests must stay in the approved vault.'
    }
    for ($attempt = 1; $attempt -le 12; $attempt++) {
        try {
            $arguments = @{ Uri = $Uri; Method = $Method; Authentication = 'Bearer'; Token = $token }
            if ($null -ne $Body) { $arguments.Body = $Body | ConvertTo-Json -Depth 10; $arguments.ContentType = 'application/json' }
            return Invoke-RestMethod @arguments
        }
        catch {
            $status = if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
            if ($Method -ne 'GET' -or $status -notin @(403, 429, 503) -or $attempt -eq 12) { throw }
            Write-Warning "Waiting for certificate metadata access ($attempt/12, HTTP $status)."
            Start-Sleep -Seconds 10
        }
    }
}

function Get-Certificate {
    param([string] $Uri)
    try { return Invoke-VaultRequest -Uri "$Uri`?api-version=7.4" }
    catch {
        if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response -and
            [int]$_.Exception.Response.StatusCode -eq 404 -and $_.ErrorDetails -and
            $_.ErrorDetails.Message -match '"code"\s*:\s*"CertificateNotFound"') { return $null }
        throw
    }
}

try {
    $certificateUri = "$vaultUrl/certificates/$($plan.certificateName)"
    if ($plan.action -eq 'Reuse') {
        if ($plan.certificateId -cnotmatch ('^' + [regex]::Escape($certificateUri) + '/[0-9a-fA-F]{32}$')) {
            throw 'Reuse requires the exact approved certificate version.'
        }
        $certificateUri = $plan.certificateId
    }
    $certificate = Get-Certificate -Uri $certificateUri
    if (-not $certificate) {
        if ($plan.action -eq 'Reuse') { throw 'The approved certificate version does not exist. Reuse will not issue a replacement.' }
        $policy = @{
            issuer = @{ name = 'Self' }
            key_props = @{ exportable = $true; kty = 'RSA'; key_size = 2048; reuse_key = $true }
            secret_props = @{ contentType = 'application/x-pem-file' }
            x509_props = @{ subject = 'CN=ExternalPhoneProvider'; validity_months = 12; key_usage = @('keyEncipherment', 'dataEncipherment') }
            lifetime_actions = @(@{ action = @{ action_type = 'EmailContacts' }; trigger = @{ days_before_expiry = 30 } })
        }
        $null = Invoke-VaultRequest -Uri "$certificateUri/create?api-version=7.4" -Method POST -Body @{ policy = $policy }
        for ($attempt = 1; $attempt -le 30; $attempt++) {
            $certificate = Get-Certificate -Uri $certificateUri
            if ($certificate -and $certificate.PSObject.Properties['cer'] -and $certificate.cer) { break }
            if ($attempt -eq 30) { throw 'Key Vault did not finish certificate issuance within five minutes.' }
            Start-Sleep -Seconds 10
        }
    }
    $policy = $certificate.policy
    $public = $certificate.cer.Replace('-', '+').Replace('_', '/')
    $public = $public.PadRight($public.Length + ((4 - $public.Length % 4) % 4), '=')
    $bundle = @{
        id = $certificate.id; sid = $certificate.sid; cer = $public
        attributes = @{ enabled = $certificate.attributes.enabled }
        policy = @{
            keyProperties = @{
                keyType = $policy.key_props.kty; keySize = $policy.key_props.key_size; exportable = $policy.key_props.exportable
                reuseKey = if ($policy.key_props.PSObject.Properties['reuse_key']) { $policy.key_props.reuse_key } else { $null }
            }
            secretProperties = @{ contentType = $policy.secret_props.contentType }
            lifetimeActions = @(if ($policy.PSObject.Properties['lifetime_actions']) {
                $policy.lifetime_actions | ForEach-Object { @{ action = @{ actionType = $_.action.action_type } } }
            })
        }
    }
    $secretVersionCollection = "$vaultUrl/secrets/$($plan.certificateName)/versions"
    $secretUri = "$secretVersionCollection`?api-version=7.4"
    $versions = @()
    $pages = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    do {
        if ($secretUri -notmatch ('^' + [regex]::Escape($secretVersionCollection) + '\?[^#\r\n]*$')) {
            throw 'Secret-version pagination must stay in the approved metadata collection.'
        }
        if (-not $pages.Add($secretUri) -or $pages.Count -gt 1000) { throw 'Key Vault returned repeated or excessive secret-version pages.' }
        $page = Invoke-VaultRequest -Uri $secretUri
        foreach ($version in $page.value) {
            $attributes = @{ enabled = $version.attributes.enabled }
            foreach ($field in @(@('nbf', 'notBefore'), @('exp', 'expires'))) {
                if ($version.attributes.PSObject.Properties.Name -contains $field[0] -and $null -ne $version.attributes.($field[0])) {
                    $attributes[$field[1]] = [DateTimeOffset]::FromUnixTimeSeconds($version.attributes.($field[0])).ToString('o')
                }
            }
            $versions += @{ id = $version.id; managed = $version.managed; contentType = $version.contentType; attributes = $attributes }
        }
        $secretUri = if ($page.PSObject.Properties['nextLink']) { $page.nextLink } else { $null }
    } while ($secretUri)
    # Keep nested public metadata intact through the host's shallow output serialization; ARM decodes it.
    $DeploymentScriptOutputs = @{
        bundleJson = ConvertTo-Json -InputObject $bundle -Depth 10 -Compress
        secretVersionsJson = ConvertTo-Json -InputObject @($versions) -Depth 8 -Compress
    }
}
finally { $token.Dispose() }
