#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$module = Import-Module (Join-Path $PSScriptRoot '../support/Epp.Setup.psm1') -Force -PassThru
$directory = Join-Path ([IO.Path]::GetTempPath()) "epp-certificate-tests-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $directory | Out-Null
try {
    & $module {
        param($Directory)

        function script:Assert($Condition, [string] $Message) {
            if (-not $Condition) { throw $Message }
        }
        function script:Assert-Throws([scriptblock] $Action, [string] $Pattern) {
            try { $null = & $Action }
            catch {
                Assert ($_.Exception.Message -match $Pattern) "Unexpected failure: $($_.Exception.Message)"
                return
            }
            throw "Expected failure matching '$Pattern'."
        }
        $script:Exists = $false
        $script:ReadError = ''
        $script:CreateError = ''
        $script:SettingsError = ''
        $script:Calls = [Collections.Generic.List[string]]::new()
        $script:GraphWrites = 0
        function script:Invoke-EppAz {
            param([Parameter(ValueFromRemainingArguments)][string[]] $Arguments)
            $command = $Arguments -join ' '
            $script:Calls.Add($command)
            switch -Regex ($command) {
                '^keyvault certificate show ' {
                    if ($script:ReadError) { throw $script:ReadError }
                    if (-not $script:Exists) { throw '(CertificateNotFound) absent' }
                    return $script:Bundle | ConvertTo-Json -Depth 8
                }
                '^keyvault certificate create ' {
                    if ($script:CreateError) { throw $script:CreateError }
                    $path = $Arguments[[Array]::IndexOf($Arguments, '--policy') + 1].Substring(1)
                    $script:Bundle.policy = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
                    $script:Exists = $true
                }
                '^functionapp config appsettings set ' {
                    if ($script:SettingsError) { throw $script:SettingsError }
                    $path = $Arguments[[Array]::IndexOf($Arguments, '--settings') + 1].Substring(1)
                    $script:Settings = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
                }
                default { throw "Unexpected Azure call (no network allowed): $command" }
            }
        }
        function script:Get-MgApplication { param($ApplicationId, $Property, $ErrorAction); return $script:Application }
        function script:Update-MgApplication {
            param($ApplicationId, $IdentifierUris, $KeyCredentials, $ErrorAction)
            $script:GraphWrites++
            $script:Application.IdentifierUris = $IdentifierUris
            $script:Application.KeyCredentials = $KeyCredentials
        }

        $rsa = [Security.Cryptography.RSA]::Create(2048)
        $request = [Security.Cryptography.X509Certificates.CertificateRequest]::new(
            'CN=ExternalPhoneProvider', $rsa, [Security.Cryptography.HashAlgorithmName]::SHA256,
            [Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $certificate = $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-5), [DateTimeOffset]::UtcNow.AddYears(1))
        $issued = $null
        try {
            $script:Bundle = @{
                id = 'https://epptestvault.vault.azure.net/certificates/phone-provider-encryption/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
                sid = 'https://epptestvault.vault.azure.net/secrets/phone-provider-encryption/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
                cer = [Convert]::ToBase64String($certificate.RawData); attributes = @{ enabled = $true }
            }
            $inputs = @{ SubscriptionId = '33333333-3333-3333-3333-333333333333'; ApplicationId = '22222222-2222-2222-2222-222222222222' }
            $parameters = @{ Inputs = $inputs; VaultName = 'epptestvault'; OutputDirectory = $Directory; Directory = $Directory }
            $issued = Get-EppEncryptionCertificate @parameters
            $policy = $script:Bundle.policy
            Assert ($script:Calls.Count -eq 3 -and $script:Calls[1] -like 'keyvault certificate create *') 'Expected show/create/show only.'
            Assert ($policy.x509CertificateProperties.subject -ceq 'CN=ExternalPhoneProvider') 'Subject must not be personalized.'
            Assert ($policy.issuerParameters.name -ceq 'Self' -and $policy.x509CertificateProperties.validityInMonths -eq 12) 'Expected 12-month self-signed issuance.'
            Assert ($policy.keyProperties.keyType -ceq 'RSA' -and $policy.keyProperties.keySize -eq 2048) 'Expected RSA-2048.'
            Assert ($policy.keyProperties.exportable -eq $true -and $policy.keyProperties.reuseKey -eq $true) 'Expected exportable, reusable key.'
            Assert ($policy.secretProperties.contentType -ceq 'application/x-pem-file') 'Expected PEM backing secret.'
            Assert ($policy.lifetimeActions[0].action.actionType -ceq 'EmailContacts') 'Renewal must remain manual.'
            Assert ($issued.SecretId -ceq $script:Bundle.sid -and -not $issued.Certificate.HasPrivateKey) 'Return secret ID and public certificate only.'
            Assert (-not (Test-Path (Join-Path $Directory 'certificate-policy.json'))) 'Temporary policy was not removed.'
            $publicBytes = [IO.File]::ReadAllBytes((Join-Path $Directory "$($certificate.Thumbprint).cer"))
            Assert ([Convert]::ToBase64String($publicBytes) -ceq $script:Bundle.cer) 'Saved output must contain only public DER.'
            $script:Calls.Clear()
            $reused = Get-EppEncryptionCertificate @parameters
            Assert ($script:Calls.Count -eq 1 -and $reused.Certificate.Thumbprint -ceq $certificate.Thumbprint) 'Rerun must reuse the existing certificate.'
            $reused.Certificate.Dispose()

            foreach ($errorText in @('(Forbidden) denied', '(VaultNotFound) absent', '(ServiceUnavailable) unavailable')) {
                $script:ReadError = $errorText; $script:Calls.Clear()
                Assert-Throws { Get-EppEncryptionCertificate @parameters } ([regex]::Escape($errorText))
                Assert ($script:Calls.Count -eq 1) 'Read errors must not trigger creation.'
            }
            $script:ReadError = ''; $script:Exists = $false; $script:CreateError = '(Conflict) pending operation exists'
            Assert-Throws { Get-EppEncryptionCertificate @parameters } '\(Conflict\)'
            Assert (-not (Test-Path (Join-Path $Directory 'certificate-policy.json'))) 'Failed issuance left its temporary policy.'
            $script:CreateError = ''; $script:Exists = $true
            foreach ($mutation in @(
                { $script:Bundle.attributes.enabled = $false },
                { $script:Bundle.policy.keyProperties.exportable = $false },
                { $script:Bundle.policy.secretProperties.contentType = 'application/x-pkcs12' },
                { $script:Bundle.policy.lifetimeActions[0].action.actionType = 'AutoRenew' }
            )) {
                $saved = $script:Bundle | ConvertTo-Json -Depth 8
                & $mutation
                Assert-Throws { Get-EppEncryptionCertificate @parameters } 'incompatible certificate'
                $script:Bundle = $saved | ConvertFrom-Json -AsHashtable
            }

            $script:Application = [pscustomobject]@{
                Id = 'application-object'; AppId = $inputs.ApplicationId; SignInAudience = 'AzureADMultipleOrgs'
                TokenEncryptionKeyId = $null; IdentifierUris = @(); KeyCredentials = @()
            }
            $keyId = [Guid]::NewGuid().ToString()
            $registration = @{
                Inputs = $inputs; Context = @{ Application = $script:Application }
                Outputs = @{ identifierUri = @{ value = 'api://epp-test' } }
                Certificate = $issued.Certificate; KeyId = $keyId; ConfigureFederation = $false
            }
            Set-EppApplicationEndpoint @registration
            $script:Application.KeyCredentials[0].DisplayName = 'Old display name'
            Set-EppApplicationEndpoint @registration
            Assert ($script:Application.KeyCredentials.Count -eq 1) 'Rerun must preserve the credential ID.'
            Assert ($script:Application.KeyCredentials[0].DisplayName -ceq 'CN=ExternalPhoneProvider') 'Display name must match the subject on create and reuse.'
            Assert ($script:Application.KeyCredentials[0].Usage -ceq 'Encrypt' -and $null -eq $script:Application.TokenEncryptionKeyId) 'Preserve JWE usage and signed bearer tokens.'
            $renewed = $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-1), [DateTimeOffset]::UtcNow.AddYears(1))
            try {
                $registration.Certificate = $renewed; $registration.KeyId = [Guid]::NewGuid().ToString()
                Set-EppApplicationEndpoint @registration
                Assert ($script:Application.KeyCredentials.Count -eq 2 -and $script:Application.KeyCredentials[0].KeyId -eq $keyId) 'Same-key renewal must preserve the old credential.'
            }
            finally { $renewed.Dispose() }
            $otherRsa = [Security.Cryptography.RSA]::Create(2048)
            $otherRequest = [Security.Cryptography.X509Certificates.CertificateRequest]::new(
                'CN=ExternalPhoneProvider', $otherRsa, [Security.Cryptography.HashAlgorithmName]::SHA256,
                [Security.Cryptography.RSASignaturePadding]::Pkcs1)
            $other = $otherRequest.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-1), [DateTimeOffset]::UtcNow.AddYears(1))
            try {
                $registration.Certificate = $other
                Assert-Throws { Set-EppApplicationEndpoint @registration } 'different encryption key'
                Assert ($script:GraphWrites -eq 3) 'Key mismatch must stop before updating Entra.'
            }
            finally { $other.Dispose(); $otherRsa.Dispose() }

            $settings = @{ Inputs = $inputs; Names = @{ resourceGroup = 'epp-test-rg'; functionApp = 'epp-test-app' }; SecretId = $issued.SecretId; KeyId = $keyId; Directory = $Directory }
            Set-EppEncryptionSettings @settings
            Assert ($script:Settings.EPP_DECRYPTION_KEY_PEM -ceq "@Microsoft.KeyVault(SecretUri=$($issued.SecretId))" -and $script:Settings.EPP_ENCRYPTION_KEY_ID -eq $keyId) 'Use the selected version and Entra key ID.'
            $script:SettingsError = 'App settings write failed'
            Assert-Throws { Set-EppEncryptionSettings @settings } 'App settings write failed'
            Assert (-not (Test-Path (Join-Path $Directory 'encryption-appsettings.json'))) 'Failed settings update left its temporary file.'
            Write-Host 'Certificate creation, reuse, errors, naming, key continuity, and settings checks passed.'
        }
        finally {
            if ($issued) { $issued.Certificate.Dispose() }
            $certificate.Dispose(); $rsa.Dispose()
        }
    } $directory
}
finally {
    Remove-Module -ModuleInfo $module -Force
    Remove-Item -LiteralPath $directory -Recurse -Force
}
