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
    param([string] $SecretId, [string] $SubscriptionId, [object[]] $Versions)

    $secret = ConvertTo-EppKeyVaultObjectId $SecretId secrets
    # Listing version metadata never retrieves the private-key value.
    if (-not $PSBoundParameters.ContainsKey('Versions')) {
        $Versions = Invoke-EppDataOperation {
            Invoke-EppAz keyvault secret list-versions --vault-name $secret.VaultName --name $secret.Name `
                --subscription $SubscriptionId --output json
        } | ConvertFrom-Json -AsHashtable -NoEnumerate
    }
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
            VaultRbac = $true; VaultAccessPolicies = @()
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
            $plan.VaultAccessPolicies = @($vault['properties']['accessPolicies'] | Where-Object { $null -ne $_ })
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
