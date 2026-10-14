#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$module = Import-Module (Join-Path $PSScriptRoot '../support/Epp.Setup.psm1') -Force -PassThru
$directory = Join-Path ([IO.Path]::GetTempPath()) "epp-certificate-tests-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $directory | Out-Null
try {
    & $module {
        param($Directory, $SetupDirectory)

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
        $script:GraphError = ''
        $script:Messages = [Collections.Generic.List[string]]::new()
        $script:Prompts = [Collections.Generic.List[string]]::new()
        $script:Answers = [Collections.Generic.Queue[string]]::new()
        $script:ReferenceStates = [Collections.Generic.Queue[string]]::new()
        $script:ReferenceStatus = 'Resolved'
        $script:ReferenceOverride = @{}
        $script:ReferenceError = ''
        $script:AccessError = ''
        $script:RoleAssignments = @()
        $script:Sleeps = 0
        function script:Write-Host {
            param([Parameter(ValueFromPipeline)] $Object, $ForegroundColor, [switch] $NoNewline)
            process { $script:Messages.Add([string]$Object) }
        }
        function script:Read-Host {
            param($Prompt)
            $script:Prompts.Add($Prompt)
            Assert ($script:Answers.Count -gt 0) "Unexpected prompt: $Prompt"
            return $script:Answers.Dequeue()
        }
        function script:Start-Sleep { param($Seconds); $script:Sleeps++ }
        function script:Set-TestBundle {
            param($Certificate, [string] $VaultName = 'epptestvault', [string] $Name = 'phone-provider-encryption')
            $script:Bundle = @{
                id = "https://$VaultName.vault.azure.net/certificates/$Name/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
                sid = "https://$VaultName.vault.azure.net/secrets/$Name/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
                cer = [Convert]::ToBase64String($Certificate.RawData); attributes = @{ enabled = $true }
                policy = @{
                    keyProperties = @{ keyType = 'RSA'; keySize = 2048; exportable = $true; reuseKey = $true }
                    secretProperties = @{ contentType = 'application/x-pem-file' }
                    lifetimeActions = @(@{ action = @{ actionType = 'EmailContacts' } })
                }
            }
            $script:SecretVersions = @(@{
                id = $script:Bundle.sid; managed = $true
                contentType = 'application/x-pem-file'; attributes = @{ enabled = $true }
            })
            $script:Exists = $true
        }
        function script:New-TestCredential {
            param($Certificate, [string] $KeyId, [string] $Usage = 'Encrypt')
            return [pscustomobject]@{
                KeyId = $KeyId; Type = 'AsymmetricX509Cert'; Usage = $Usage; DisplayName = $Certificate.Subject
                Key = $Certificate.RawData; CustomKeyIdentifier = $Certificate.GetCertHash()
                StartDateTime = $Certificate.NotBefore.ToUniversalTime(); EndDateTime = $Certificate.NotAfter.ToUniversalTime()
            }
        }
        function script:Invoke-EppAz {
            param([Parameter(ValueFromRemainingArguments)][string[]] $Arguments)
            $command = $Arguments -join ' '
            $script:Calls.Add($command)
            switch -Regex ($command) {
                '^keyvault certificate show ' {
                    if ($script:ReadError) { throw $script:ReadError }
                    if (-not $script:Exists) { throw '(CertificateNotFound) absent' }
                    if ($Arguments -contains '--name') {
                        $name = $Arguments[[Array]::IndexOf($Arguments, '--name') + 1]
                        if (([Uri]$script:Bundle.id).Segments[2].TrimEnd('/') -cne $name) { throw '(CertificateNotFound) absent' }
                    }
                    return $script:Bundle | ConvertTo-Json -Depth 8
                }
                '^keyvault certificate create ' {
                    if ($script:CreateError) { throw $script:CreateError }
                    $path = $Arguments[[Array]::IndexOf($Arguments, '--policy') + 1].Substring(1)
                    $name = $Arguments[[Array]::IndexOf($Arguments, '--name') + 1]
                    $vault = $Arguments[[Array]::IndexOf($Arguments, '--vault-name') + 1]
                    Set-TestBundle -Certificate $script:CreatedCertificate -VaultName $vault -Name $name
                    $script:Bundle.policy = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
                }
                '^keyvault secret list-versions ' { return ConvertTo-Json -InputObject $script:SecretVersions -Depth 8 }
                '^keyvault show ' { return $script:Vault | ConvertTo-Json -Depth 8 }
                '^functionapp config appsettings set ' {
                    if ($script:SettingsError) { throw $script:SettingsError }
                    $path = $Arguments[[Array]::IndexOf($Arguments, '--settings') + 1].Substring(1)
                    $script:Settings = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
                }
                '^functionapp config appsettings list ' {
                    Assert ($command.Contains("[?name=='EPP_ENCRYPTION_KEY_ID'].value")) 'Read back only the nonsecret key ID.'
                    return ConvertTo-Json -InputObject @($script:Settings.EPP_ENCRYPTION_KEY_ID)
                }
                '^functionapp identity show ' { return '77777777-7777-7777-7777-777777777777' }
                '^role assignment list ' { return ConvertTo-Json -InputObject $script:RoleAssignments }
                '^role assignment create ' {
                    if ($script:AccessError) { throw $script:AccessError }
                }
                '^rest --method put .*accessPolicies/add' {
                    if ($script:AccessError) { throw $script:AccessError }
                    $path = $Arguments[[Array]::IndexOf($Arguments, '--body') + 1].Substring(1)
                    $script:AccessPolicy = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
                }
                '^rest --method post .*configreferences/appsettings/refresh' {
                    if ($script:ReferenceError) { throw $script:ReferenceError }
                }
                '^rest --method get .*configreferences/appsettings/EPP_DECRYPTION_KEY_PEM' {
                    $secret = ConvertTo-EppKeyVaultObjectId $script:Bundle.sid secrets
                    $status = if ($script:ReferenceStates.Count) { $script:ReferenceStates.Dequeue() } else { $script:ReferenceStatus }
                    $properties = @{
                        status = $status; reference = $script:Settings.EPP_DECRYPTION_KEY_PEM
                        vaultName = $secret.VaultName; secretName = $secret.Name
                        secretVersion = $secret.Version; activeVersion = $secret.Version
                    }
                    foreach ($key in $script:ReferenceOverride.Keys) { $properties[$key] = $script:ReferenceOverride[$key] }
                    return @{ properties = $properties } | ConvertTo-Json
                }
                '^deployment sub create ' { return $script:DeploymentOutputs | ConvertTo-Json -Depth 8 }
                default { throw "Unexpected Azure call (no network allowed): $command" }
            }
        }
        function script:Get-EppApplication { param($Inputs, $ClientId, $ObjectId); return $script:Application }
        function script:Invoke-EppGraphRequest {
            param($Inputs, $Method, $Path, $Body, $Query)
            if ($script:GraphError) { throw $script:GraphError }
            Assert ($Method -eq 'PATCH' -and $Path -like '/v1.0/applications/*') 'Certificate registration must use one explicit Graph application PATCH.'
            Assert (($Body.Keys | Sort-Object) -join ',' -ceq 'identifierUris,keyCredentials') 'Do not modify unrelated application properties during certificate registration.'
            $script:GraphWrites++
            $script:Calls.Add('graph:keys')
            $script:Application.IdentifierUris = $Body.identifierUris
            $script:Application.KeyCredentials = (ConvertFrom-EppGraphApplication -Application @{
                id = '11111111-1111-1111-1111-111111111111'; appId = '22222222-2222-2222-2222-222222222222'
                keyCredentials = $Body.keyCredentials
            }).KeyCredentials
        }

        $rsa = [Security.Cryptography.RSA]::Create(2048)
        $request = [Security.Cryptography.X509Certificates.CertificateRequest]::new(
            'CN=ExternalPhoneProvider', $rsa, [Security.Cryptography.HashAlgorithmName]::SHA256,
            [Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $certificate = $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-5), [DateTimeOffset]::UtcNow.AddYears(1))
        $otherRsa = [Security.Cryptography.RSA]::Create(2048)
        $otherRequest = [Security.Cryptography.X509Certificates.CertificateRequest]::new(
            'CN=ExternalPhoneProvider', $otherRsa, [Security.Cryptography.HashAlgorithmName]::SHA256,
            [Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $other = $otherRequest.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-5), [DateTimeOffset]::UtcNow.AddYears(1))
        $issued = $null
        try {
            Set-TestBundle $certificate
            $certificateId = $script:Bundle.id
            $script:Exists = $false
            $script:CreatedCertificate = $certificate
            $inputs = @{
                TenantId = '11111111-1111-1111-1111-111111111111'
                SubscriptionId = '33333333-3333-3333-3333-333333333333'; ApplicationId = '22222222-2222-2222-2222-222222222222'
                ServicePlan = 'FC1'; Language = 'javascript'; ProviderAuthentication = 'apiKey'
                Location = 'westus2'; ResourcePrefix = 'unit'; PackageSha256 = ('a' * 64); SourcePackageSha256 = ('a' * 64)
                PackageFile = 'epp-javascript.zip'; SourceRevision = ('a' * 40)
                SourceBaseUri = "https://raw.githubusercontent.com/Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample/$('a' * 40)/setup"
                PackageReleaseTag = 'epp-packages-1-1'
                PackageUrl = 'https://github.com/Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample/releases/download/epp-packages-1-1/epp-javascript.zip'
                ProviderTenantId = '44444444-4444-4444-4444-444444444444'
                ProviderAllowedTenantIds = @('44444444-4444-4444-4444-444444444444')
            }
            $names = Get-EppResourceNames -SubscriptionId $inputs.SubscriptionId -ApplicationId $inputs.ApplicationId -ResourcePrefix unit
            $names.keyVault = 'epptestvault'
            $script:Vault = @{
                id = "/subscriptions/$($inputs.SubscriptionId)/resourceGroups/$($names.resourceGroup)/providers/Microsoft.KeyVault/vaults/epptestvault"
                properties = @{
                    tenantId = $inputs.TenantId; vaultUri = 'https://epptestvault.vault.azure.net/'
                    enableRbacAuthorization = $true; accessPolicies = @()
                }
            }
            $parameters = @{ Inputs = $inputs; VaultName = 'epptestvault'; OutputDirectory = $Directory; Directory = $Directory }
            $issued = Get-EppEncryptionCertificate @parameters
            $policy = $script:Bundle.policy
            Assert ($script:Calls.Count -eq 4 -and $script:Calls[1] -like 'keyvault certificate create *' -and
                $script:Calls[-1] -like 'keyvault secret list-versions *') 'Expected show/create/show and secret metadata only.'
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
            Assert ($script:Calls.Count -eq 2 -and $reused.Certificate.Thumbprint -ceq $certificate.Thumbprint) 'Rerun must reuse the existing certificate.'
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
            foreach ($mutation in @(
                { $script:SecretVersions[0].attributes.enabled = $false },
                { $script:SecretVersions[0].managed = $false },
                { $script:SecretVersions[0].contentType = 'application/x-pkcs12' },
                { $script:SecretVersions[0].attributes.notBefore = [DateTimeOffset]::UtcNow.AddDays(1).ToString('o') },
                { $script:SecretVersions[0].attributes.expires = [DateTimeOffset]::UtcNow.AddDays(30).ToString('o') },
                { $script:SecretVersions = @() }
            )) {
                Set-TestBundle $certificate
                & $mutation
                Assert-Throws { Get-EppExistingEncryptionCertificate -CertificateId $certificateId -SubscriptionId $inputs.SubscriptionId } 'secret'
            }
            foreach ($days in @(-1, 30)) {
                $short = $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-2), [DateTimeOffset]::UtcNow.AddDays($days))
                try {
                    Set-TestBundle $short
                    Assert-Throws { ConvertFrom-EppCertificateBundle -Bundle $script:Bundle } 'more than 30 days'
                }
                finally { $short.Dispose() }
            }
            foreach ($keySize in @(1024, 2048, 3072)) {
                $sizedRsa = [Security.Cryptography.RSA]::Create($keySize)
                $sizedRequest = [Security.Cryptography.X509Certificates.CertificateRequest]::new(
                    'CN=ExternalPhoneProvider', $sizedRsa, [Security.Cryptography.HashAlgorithmName]::SHA256,
                    [Security.Cryptography.RSASignaturePadding]::Pkcs1)
                $sizedCertificate = $sizedRequest.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-1), [DateTimeOffset]::UtcNow.AddYears(1))
                try {
                    Set-TestBundle $sizedCertificate
                    if ($keySize -lt 2048) {
                        Assert-Throws { ConvertFrom-EppCertificateBundle -Bundle $script:Bundle } '2048 bits'
                    }
                    else {
                        $validated = ConvertFrom-EppCertificateBundle -Bundle $script:Bundle
                        try {
                            Assert ($validated.Certificate.Thumbprint -ceq $sizedCertificate.Thumbprint) "RSA-$keySize must be accepted on every supported test platform."
                        }
                        finally { $validated.Certificate.Dispose() }
                    }
                }
                finally { $sizedCertificate.Dispose(); $sizedRsa.Dispose() }
            }
            Set-TestBundle $certificate
            foreach ($invalid in @(
                'https://epptestvault.vault.azure.net/certificates/phone-provider-encryption',
                $certificateId.Replace('https:', 'http:'),
                $certificateId.Replace('/certificates/', '/secrets/'),
                $certificateId.Replace('epptestvault.vault.azure.net', 'epptestvault.vault.azure.net.evil.contoso.com'),
                "$certificateId`?token=private", "$certificateId#fragment",
                $certificateId.Replace('https://', 'https://user@')
            )) {
                Assert-Throws { ConvertTo-EppKeyVaultObjectId $invalid certificates } 'versioned Key Vault URL'
            }

            $script:Application = [pscustomobject]@{
                Id = 'application-object'; AppId = $inputs.ApplicationId; SignInAudience = 'AzureADMultipleOrgs'
                TokenEncryptionKeyId = $null; IdentifierUris = @('api://preserve'); KeyCredentials = @()
                PasswordCredentials = @('preserve-client-secret')
            }
            $keyId = '55555555-5555-5555-5555-555555555555'
            $secondId = '66666666-6666-6666-6666-666666666666'
            $thirdId = '88888888-8888-8888-8888-888888888888'
            $signing = New-TestCredential $other '99999999-9999-9999-9999-999999999999' Verify
            $script:Application.KeyCredentials = @($signing)
            $planArgs = @{ Inputs = $inputs; Names = $names; Application = $script:Application }
            $context = @{ Application = $script:Application; CertificatePlan = $null; GraphOperatorId = 'operator'; TokenVersion = 2; OperatorId = $inputs.TenantId }
            $registration = @{
                Inputs = $inputs; Context = $context
                Outputs = @{ identifierUri = @{ value = 'api://epp-test' } }
                Certificate = $issued.Certificate; ConfigureFederation = $false
            }
            $reuseArgs = @{ CertificateAction = 'Reuse'; EncryptionKeyId = $keyId; KeyVaultCertificateId = $certificateId }
            $script:Calls.Clear()
            $createPlan = Get-EppCertificatePlan @planArgs -NonInteractive
            Assert ($createPlan.Action -ceq 'Create' -and $createPlan.RemoveKeyIds.Count -eq 0) 'Signing certificates must not prevent automatic first-time creation.'
            Assert ($script:Calls.Count -eq 0 -and $script:GraphWrites -eq 0) 'Planning must not issue certificates or mutate Graph.'
            Assert-Throws { Get-EppCertificatePlan @planArgs -CertificateAction Reuse -NonInteractive } 'No encryption certificate'
            Assert-Throws { Get-EppCertificatePlan @planArgs -KeyVaultCertificateId $certificateId -NonInteractive } 'only valid'
            $context.CertificatePlan = $createPlan
            Set-EppApplicationEndpoint @registration -KeyId $createPlan.KeyId
            Assert-EppApplicationEncryption -Application $script:Application -Certificate $issued.Certificate -KeyId $createPlan.KeyId -Plan $createPlan
            Assert ($script:Application.IdentifierUris -contains 'api://preserve' -and $script:Application.PasswordCredentials[0] -ceq 'preserve-client-secret') 'Preserve unrelated app configuration and client secrets.'

            $first = New-TestCredential $certificate $keyId
            $first.DisplayName = 'Customer certificate name'
            $script:Application.KeyCredentials = @($first, $signing)
            Assert-Throws { Get-EppCertificatePlan @planArgs -NonInteractive } '\-CertificateAction is required'
            Assert-Throws { Get-EppCertificatePlan @planArgs -CertificateAction Create -NonInteractive } 'Unknown CertificateAction'
            Assert-Throws { Get-EppCertificatePlan @planArgs -CertificateAction Reuse -KeyVaultCertificateId $certificateId -NonInteractive } '\-EncryptionKeyId is required'
            Assert-Throws { Get-EppCertificatePlan @planArgs -CertificateAction Reuse -EncryptionKeyId $keyId -NonInteractive } '\-KeyVaultCertificateId is required'
            $script:Answers.Enqueue('')
            $script:Calls.Clear()
            Assert ($null -eq (Get-EppCertificatePlan @planArgs)) 'Enter must cancel without choosing a certificate.'
            Assert ($script:Calls.Count -eq 0) 'Cancelling the decision must not contact Key Vault.'
            $script:Answers.Enqueue('Reuse'); $script:Answers.Enqueue($certificateId)
            $singlePlan = Get-EppCertificatePlan @planArgs
            Assert ($singlePlan.KeyId -ceq $keyId -and $singlePlan.RemoveKeyIds.Count -eq 0) 'Interactive single-certificate reuse must retain its key ID.'
            Assert ($script:Answers.Count -eq 0) 'Single-certificate reuse should only ask for the action and location.'

            $script:Application.KeyCredentials = @($first, (New-TestCredential $other $secondId), (New-TestCredential $certificate $thirdId), $signing)
            $script:Answers.Enqueue('Reuse'); $script:Answers.Enqueue($keyId); $script:Answers.Enqueue($certificateId)
            $multiplePlan = Get-EppCertificatePlan @planArgs
            Assert ($multiplePlan.RemoveKeyIds.Count -eq 2 -and $multiplePlan.RemoveKeyIds -contains $secondId -and
                $multiplePlan.RemoveKeyIds -contains $thirdId) 'Keep the selected key ID even when another entry has the same thumbprint.'
            $script:Messages.Clear()
            Show-EppCertificatePlan -Plan $multiplePlan -Names $names
            $planText = $script:Messages -join "`n"
            foreach ($value in @($keyId, $secondId, $thirdId, $certificateId, $script:Bundle.sid, 'not zero-downtime', 'Preserve non-encryption')) {
                Assert ($planText.Contains($value)) "The final approval must disclose '$value'."
            }
            $context.CertificatePlan = $multiplePlan
            Set-EppApplicationEndpoint @registration -KeyId $keyId
            Assert-EppApplicationEncryption -Application $script:Application -Certificate $issued.Certificate -KeyId $keyId -Plan $multiplePlan
            Assert ($script:Application.KeyCredentials.Count -eq 2 -and $script:Application.KeyCredentials[-1].DisplayName -ceq 'Customer certificate name') 'Retain the selected credential and the signing credential unchanged.'
            for ($run = 0; $run -lt 3; $run++) {
                $context.CertificatePlan = Get-EppCertificatePlan @planArgs @reuseArgs -NonInteractive
                Set-EppApplicationEndpoint @registration -KeyId $keyId
                Assert-EppApplicationEncryption -Application $script:Application -Certificate $issued.Certificate -KeyId $keyId -Plan $context.CertificatePlan
            }
            Assert ($script:Application.KeyCredentials.Count -eq 2) 'Three reruns must not append any encryption credentials.'
            Assert ($null -eq $script:Application.TokenEncryptionKeyId) 'Do not enable bearer-token encryption.'

            $first = $script:Application.KeyCredentials | Where-Object KeyId -eq $keyId
            $signing = $script:Application.KeyCredentials | Where-Object Usage -ne Encrypt
            $beforeWrites = $script:GraphWrites
            $context.CertificatePlan = Get-EppCertificatePlan @planArgs @reuseArgs -NonInteractive
            $first.DisplayName = 'Changed after approval'
            Assert-Throws { Set-EppApplicationEndpoint @registration -KeyId $keyId } 'changed after certificate selection'
            Assert-Throws { Initialize-EppGraphAccess -Inputs $inputs -Context $context } 'changed after certificate selection'
            $first.DisplayName = 'Customer certificate name'
            $signing.DisplayName = 'Changed signing credential'
            Assert-Throws { Set-EppApplicationEndpoint @registration -KeyId $keyId } 'changed after certificate selection'
            $signing.DisplayName = $other.Subject
            $script:Application.TokenEncryptionKeyId = $keyId
            Assert-Throws { Set-EppApplicationEndpoint @registration -KeyId $keyId } 'changed after preflight'
            $script:Application.TokenEncryptionKeyId = $null
            $renewed = $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-2), [DateTimeOffset]::UtcNow.AddYears(1))
            try {
                $registration.Certificate = $renewed; $registration.KeyId = [Guid]::NewGuid().ToString()
                Assert-Throws { Set-EppApplicationEndpoint @registration } 'does not match the approved'
                $registration.KeyId = $keyId
                Assert-Throws { Set-EppApplicationEndpoint @registration } 'no longer matches'
                Set-TestBundle $renewed
                Assert-Throws { Get-EppCertificatePlan @planArgs @reuseArgs -NonInteractive } 'does not match the selected'
            }
            finally { $renewed.Dispose(); $registration.Remove('KeyId'); $registration.Certificate = $issued.Certificate; Set-TestBundle $certificate }
            Assert ($script:GraphWrites -eq $beforeWrites) 'Stale plans and unapproved renewal must not write Graph.'
            $script:GraphError = 'Graph update denied'
            Assert-Throws { Set-EppApplicationEndpoint @registration -KeyId $keyId } 'Graph update denied'
            $script:GraphError = ''
            $first.EndDateTime = [DateTime]::UtcNow.AddDays(30)
            Assert-Throws { Get-EppCertificatePlan @planArgs @reuseArgs -NonInteractive } 'app-registration credential'
            $first.EndDateTime = $certificate.NotAfter.ToUniversalTime()
            $first.Type = 'Symmetric'
            Assert-Throws { Get-EppCertificatePlan @planArgs @reuseArgs -NonInteractive } 'unsupported Encrypt credential type'
            $first.Type = 'AsymmetricX509Cert'
            $signingBytes = $signing.Key; $signing.Key = $null
            Assert-Throws { Get-EppCertificatePlan @planArgs @reuseArgs -NonInteractive } 'non-encryption credential is unreadable'
            $signing.Key = $signingBytes
            $script:ReadError = '(CertificateNotFound) absent'; $script:Calls.Clear()
            Assert-Throws { Get-EppCertificatePlan @planArgs @reuseArgs -NonInteractive } 'CertificateNotFound'
            Assert (@($script:Calls | Where-Object { $_ -like 'keyvault certificate create *' }).Count -eq 0) 'Failed reuse must never fall back to certificate creation.'
            $script:ReadError = ''
            Set-TestBundle $other
            $script:Answers.Enqueue('Reuse'); $script:Answers.Enqueue($certificateId); $script:Answers.Enqueue('Replace')
            Assert ((Get-EppCertificatePlan @planArgs).Action -ceq 'Replace') 'A bad interactive location must allow a new action instead of silent replacement.'
            Set-TestBundle $certificate

            $script:Application.KeyCredentials = @($first, (New-TestCredential $other $secondId), $signing)
            $replacePlan = Get-EppCertificatePlan @planArgs -CertificateAction Replace -NonInteractive
            $retryPlan = Get-EppCertificatePlan @planArgs -CertificateAction Replace -NonInteractive
            Assert ($replacePlan.RemoveKeyIds.Count -eq 2 -and $replacePlan.CertificateName -ceq $retryPlan.CertificateName -and
                $replacePlan.CertificateName -cne 'phone-provider-encryption') 'Replacement must stage a separate, repeatable certificate name.'
            $context.CertificatePlan = $replacePlan; $script:CreatedCertificate = $other
            $replacement = Get-EppEncryptionCertificate @parameters -CertificateName $replacePlan.CertificateName
            try {
                $registration.Certificate = $replacement.Certificate
                Set-EppApplicationEndpoint @registration -KeyId $replacePlan.KeyId
                Assert-EppApplicationEncryption -Application $script:Application -Certificate $replacement.Certificate -KeyId $replacePlan.KeyId -Plan $replacePlan
            }
            finally { $replacement.Certificate.Dispose(); $registration.Certificate = $issued.Certificate }
            Assert ($script:Application.KeyCredentials.Count -eq 2) 'Replace all must preserve signing credentials and register only one new encryption key.'
            $script:Application.KeyCredentials += New-TestCredential $other $thirdId
            Assert-Throws {
                Assert-EppApplicationEncryption -Application $script:Application -Certificate $other -KeyId $replacePlan.KeyId -Plan $replacePlan
            } 'exactly one'

            Set-TestBundle $certificate
            $settings = @{ Inputs = $inputs; Names = @{ resourceGroup = 'epp-test-rg'; functionApp = 'epp-test-app' }; SecretId = $issued.SecretId; KeyId = $keyId; Directory = $Directory }
            Set-EppEncryptionSettings @settings
            Assert ($script:Settings.EPP_DECRYPTION_KEY_PEM -ceq "@Microsoft.KeyVault(SecretUri=$($issued.SecretId))" -and $script:Settings.EPP_ENCRYPTION_KEY_ID -eq $keyId) 'Use the selected version and Entra key ID.'
            $script:SettingsError = 'App settings write failed'
            Assert-Throws { Set-EppEncryptionSettings @settings } 'App settings write failed'
            Assert (-not (Test-Path (Join-Path $Directory 'encryption-appsettings.json'))) 'Failed settings update left its temporary file.'
            $script:SettingsError = ''
            $referenceArgs = @{ Inputs = $inputs; Names = $names; SecretId = $issued.SecretId; KeyId = $keyId }
            Assert-EppEncryptionReference @referenceArgs
            $script:ReferenceStates.Enqueue('AccessToKeyVaultDenied'); $script:Sleeps = 0
            Assert-EppEncryptionReference @referenceArgs
            Assert ($script:Sleeps -eq 1) 'Retry transient role propagation, then verify successful resolution.'
            $script:ReferenceOverride = @{ activeVersion = ('c' * 32) }
            Assert-Throws { Assert-EppEncryptionReference @referenceArgs } 'different secret reference or version'
            $script:ReferenceOverride = @{ status = $null }
            Assert-Throws { Assert-EppEncryptionReference @referenceArgs } 'incomplete decryption-key reference status'
            $script:ReferenceOverride = @{}
            $script:ReferenceStatus = 'AccessToKeyVaultDenied'; $script:Sleeps = 0
            Assert-Throws { Assert-EppEncryptionReference @referenceArgs } 'cannot resolve'
            Assert ($script:Sleeps -eq 11) 'Unresolved references must stop after the bounded retry limit.'
            $script:ReferenceStatus = 'Resolved'
            $script:Settings.EPP_ENCRYPTION_KEY_ID = $secondId
            Assert-Throws { Assert-EppEncryptionReference @referenceArgs } 'does not match the approved'
            Set-EppEncryptionSettings @settings

            $script:Application.KeyCredentials = @($first, $signing)
            $externalNames = @{} + $names; $externalNames.keyVault = 'differentvault'
            $externalArgs = @{} + $planArgs; $externalArgs.Names = $externalNames
            $externalPlan = Get-EppCertificatePlan @externalArgs @reuseArgs -NonInteractive
            $script:Calls.Clear()
            Initialize-EppCertificateAccess -Inputs $inputs -Names $externalNames -Plan $externalPlan -Directory $Directory
            $roleCommand = $script:Calls | Where-Object { $_ -like 'role assignment create *' }
            Assert ($roleCommand -like "*/secrets/phone-provider-encryption*" -and $roleCommand -like '*--assignee-object-id 77777777-7777-7777-7777-777777777777*') 'Grant only certificate-secret access to the Function system identity.'
            $script:RoleAssignments = @(@{ principalId = '77777777-7777-7777-7777-777777777777'; roleDefinitionId = "scope/$script:KeyVaultSecretsUserRoleId" })
            $script:Calls.Clear()
            Initialize-EppCertificateAccess -Inputs $inputs -Names $externalNames -Plan $externalPlan -Directory $Directory
            Assert (@($script:Calls | Where-Object { $_ -like 'role assignment create *' }).Count -eq 0) 'Reuse an existing secret-read grant.'
            $script:RoleAssignments = @()
            $script:Vault.properties.enableRbacAuthorization = $false
            Assert-Throws {
                Initialize-EppCertificateAccess -Inputs $inputs -Names $externalNames -Plan $externalPlan -Directory $Directory
            } 'permission model changed'
            $externalPlan = Get-EppCertificatePlan @externalArgs @reuseArgs -NonInteractive
            $script:Vault.properties.accessPolicies = @(@{
                tenantId = $inputs.TenantId; objectId = '77777777-7777-7777-7777-777777777777'
                permissions = @{ keys = @('sign'); secrets = @('list'); certificates = @('get') }
            })
            Initialize-EppCertificateAccess -Inputs $inputs -Names $externalNames -Plan $externalPlan -Directory $Directory
            $permissions = $script:AccessPolicy.properties.accessPolicies[0].permissions
            Assert ($permissions.keys -contains 'sign' -and $permissions.secrets -contains 'list' -and
                $permissions.secrets -contains 'get' -and $permissions.certificates -contains 'get') 'Adding secret read must preserve existing access-policy permissions.'
            Assert (-not (Test-Path (Join-Path $Directory 'certificate-access-policy.json'))) 'Temporary access-policy files must be removed.'
            $script:AccessError = 'access policy update denied'
            Assert-Throws {
                Initialize-EppCertificateAccess -Inputs $inputs -Names $externalNames -Plan $externalPlan -Directory $Directory
            } 'access policy update denied'
            Assert (-not (Test-Path (Join-Path $Directory 'certificate-access-policy.json'))) 'Failed permission writes must also remove their temporary file.'
            $script:AccessError = ''
            $script:Vault.properties.enableRbacAuthorization = $true
            $script:Vault.properties.tenantId = $secondId
            Assert-Throws { Get-EppCertificatePlan @externalArgs @reuseArgs -NonInteractive } 'Function application tenant'
            $script:Vault.properties.tenantId = $inputs.TenantId
            $originalVaultId = $script:Vault.id
            $script:Vault.id = $script:Vault.id.Replace($inputs.SubscriptionId, $secondId)
            $crossSubscription = Get-EppCertificatePlan @externalArgs @reuseArgs -KeyVaultSubscriptionId $secondId -NonInteractive
            Assert ($crossSubscription.VaultSubscriptionId -ceq $secondId) 'A same-tenant certificate vault may be in another explicitly supplied subscription.'
            $script:Vault.id = $originalVaultId

            function script:Get-EppGraphOperator { param($Inputs); return @{ Id = 'operator' } }
            $script:ArmOperator = $context.OperatorId
            function script:Get-EppArmOperatorObjectId { param($Inputs); return $script:ArmOperator }
            function script:Initialize-EppGraphAccess {
                param($Inputs, $Context)
                Assert-EppCertificatePlanUnchanged -Application $script:Application -Plan $Context.CertificatePlan
                return @{}
            }
            function script:Initialize-EppResourceProviders { param($Inputs) }
            function script:Assert-EppGraphAccess {
                param($Inputs, $Certificate, $KeyId, $IdentifierUri, $CertificatePlan)
                Assert-EppApplicationEncryption -Application $script:Application -Certificate $Certificate -KeyId $KeyId -Plan $CertificatePlan
                return @{ EndpointPrincipalId = 'endpoint'; CallerPrincipalId = 'caller' }
            }
            function script:Publish-EppFunction {
                param($Inputs, $Names, $Context, $Outputs, $SiteId, $Package, $Directory)
                $script:Calls.Add('publish')
                return $Inputs.PackageSha256
            }
            $script:DeploymentOutputs = @{
                functionAppName = @{ value = $names.functionApp }; storageAccountName = @{ value = $names.storageAccount }
                keyVaultName = @{ value = $names.keyVault }; resourceGroupName = @{ value = $names.resourceGroup }
                outboundPrincipalId = @{ value = $inputs.TenantId }; identifierUri = @{ value = 'api://epp-test' }
                endpointUrl = @{ value = 'https://epp-test.azurewebsites.net/api/SendOtp' }
            }
            $provider = @{
                Id = 'unit'; EndpointRegion = 'global'; AuthenticationMode = 'apiKey'
                Settings = @{ EPP_PROVIDER_SMS_ENDPOINT = 'https://sms.contoso.com/send'; EPP_PROVIDER_VOICE_ENDPOINT = 'https://voice.contoso.com/send'; EPP_PROVIDER_TENANT_ID = $inputs.ProviderTenantId }
            }
            $deployment = @{
                Inputs = $inputs; Names = $names; ProviderConfiguration = $provider; Context = $context
                AssetDirectory = $Directory; WorkingDirectory = $Directory; Package = @{ RequiresRemoteBuild = $false }; OutputDirectory = $Directory
            }
            foreach ($action in @('Create', 'Reuse', 'Replace')) {
                Set-TestBundle $certificate
                $script:Application.KeyCredentials = if ($action -eq 'Create') { @($signing) } else { @($first, (New-TestCredential $other $secondId), $signing) }
                $context.CertificatePlan = if ($action -eq 'Reuse') { Get-EppCertificatePlan @planArgs @reuseArgs -NonInteractive }
                    else { Get-EppCertificatePlan @planArgs -CertificateAction $action -NonInteractive }
                $script:CreatedCertificate = $other
                $script:ReferenceError = 'reference check failed'; $script:GraphWrites = 0
                $snapshotBefore = Get-EppKeyCredentialSnapshot $script:Application.KeyCredentials
                Assert-Throws { Invoke-EppDeployment @deployment } 'reference check failed'
                Assert ($script:GraphWrites -eq 0 -and (Get-EppKeyCredentialSnapshot $script:Application.KeyCredentials) -ceq $snapshotBefore) 'Failed access validation must leave all registered credentials intact.'
                $script:ReferenceError = ''; $script:Calls.Clear()
                $result = Invoke-EppDeployment @deployment
                Assert ($result.certificateAction -ceq $action -and $result.certificateReferenceResolved -eq $true) 'The persisted result must identify the action and resolved reference.'
                Assert ($result.sourceRevision -ceq ('a' * 40) -and $result.source -ceq $inputs.SourceBaseUri -and
                    $result.packageFile -ceq 'epp-javascript.zip' -and $result.packageUrl -ceq $inputs.PackageUrl -and
                    $result.packageReleaseTag -ceq $inputs.PackageReleaseTag) 'The persisted result must identify the setup source and downloaded Function release.'
                Assert ($result.removedEncryptionKeyIds.Count -eq $context.CertificatePlan.RemoveKeyIds.Count) 'Record the exact retired credential IDs.'
                $trace = $script:Calls.ToArray()
                $referenceCall = $trace | Where-Object { $_ -like 'rest --method get */EPP_DECRYPTION_KEY_PEM?*' } | Select-Object -Last 1
                $referenceIndex = [Array]::IndexOf($trace, $referenceCall)
                $graphIndex = [Array]::IndexOf($trace, 'graph:keys')
                Assert ($referenceIndex -ge 0 -and $referenceIndex -lt $graphIndex -and
                    $graphIndex -lt [Array]::IndexOf($trace, 'publish')) 'Resolve the staged private-key reference before one Graph update, then publish.'
                Assert (@($script:Application.KeyCredentials | Where-Object Usage -eq Encrypt).Count -eq 1) 'Each completed deployment must leave exactly one encryption credential.'
            }
            Assert (@(Get-ChildItem -LiteralPath $Directory -Filter 'deployment-*.json').Count -eq 3) 'Successful scenarios must persist a deployment summary.'

            Set-TestBundle $certificate
            $script:Application.KeyCredentials = @($first, (New-TestCredential $other $secondId), $signing)
            $context.CertificatePlan = Get-EppCertificatePlan @externalArgs @reuseArgs -NonInteractive
            $externalDeployment = @{} + $deployment; $externalDeployment.Names = $externalNames
            $script:DeploymentOutputs.keyVaultName.value = $externalNames.keyVault
            $script:AccessError = 'source vault role denied'; $script:GraphWrites = 0
            $snapshotBefore = Get-EppKeyCredentialSnapshot $script:Application.KeyCredentials
            Assert-Throws { Invoke-EppDeployment @externalDeployment } 'source vault role denied'
            Assert ($script:GraphWrites -eq 0 -and (Get-EppKeyCredentialSnapshot $script:Application.KeyCredentials) -ceq $snapshotBefore) 'External-vault permission failures must leave every encryption credential intact.'
            $script:AccessError = ''; $script:Calls.Clear()
            $result = Invoke-EppDeployment @externalDeployment
            Assert ($result.certificateId -ceq $certificateId -and $result.resources.keyVault -ceq $externalNames.keyVault) 'Reuse must keep the source certificate separate from the deployment/provider vault.'
            Assert (@($script:Calls | Where-Object { $_ -like 'keyvault certificate create *' }).Count -eq 0) 'External reuse must not issue another certificate.'
            Assert (@(Get-ChildItem -LiteralPath $Directory -Filter 'deployment-*.json').Count -eq 4) 'External reuse must also persist its completed summary.'
            $script:DeploymentOutputs.keyVaultName.value = $names.keyVault

            $script:SetupContext = $context; $script:TestProvider = $provider
            function script:Connect-EppContext {
                param($Inputs, $Names, [switch] $NonInteractive, [switch] $InstallPrerequisites, [switch] $ForceAuthentication)
                return $script:SetupContext
            }
            function script:Get-EppProvider {
                param($AssetDirectory, $Provider, $EndpointRegion, [switch] $NonInteractive)
                return $script:TestProvider
            }
            function script:Resolve-EppApplicationProvider {
                param($Inputs, $AssetDirectory, $Provider, [switch] $NonInteractive)
                return $Provider
            }
            function script:Get-EppLanguage {
                param($AssetDirectory, $Language, $SourceRepository, $PackageReleaseTag, [switch] $NonInteractive)
                return @{
                    Id = 'javascript'; DisplayName = 'Node.js'; BuildStrategy = 'ready'
                    Url = 'https://github.com/Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample/releases/download/epp-packages-1-1/epp-javascript.zip'
                    ReleaseTag = 'epp-packages-1-1'
                }
            }
            function script:Get-EppPackage { param($Selection, $Directory); throw 'package-boundary' }
            $setupInputs = @{
                TenantId = $inputs.TenantId; SubscriptionId = $inputs.SubscriptionId; ApplicationId = $inputs.ApplicationId
                Location = 'westus2'; ResourcePrefix = 'unit'; Language = 'javascript'; ServicePlan = 'FC1'
                Provider = 'unit'; EndpointRegion = 'global'; OutputDirectory = $Directory
                AssetDirectory = $SetupDirectory
                SourceBaseUri = "https://raw.githubusercontent.com/Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample/$('a' * 40)/setup"
            }
            Set-TestBundle $certificate
            $script:Application.KeyCredentials = @($first, $signing)
            $script:Answers.Enqueue(''); $script:Calls.Clear()
            Invoke-EppSetup @setupInputs
            Assert ($script:Calls.Count -eq 0 -and $null -eq $context.CertificatePlan) 'Cancelling certificate onboarding must stop before package preparation or deployment.'
            Assert-Throws { Invoke-EppSetup @setupInputs -NonInteractive -ApproveDeployment } '\-CertificateAction is required'
            Assert-Throws { Invoke-EppSetup @setupInputs @reuseArgs -NonInteractive } '^package-boundary$'
            Assert ($context.CertificatePlan.Action -ceq 'Reuse' -and $context.CertificatePlan.KeyId -ceq $keyId) 'The entry point must forward the explicit reuse inputs to preflight.'
            $tokens = $null; $parseErrors = $null
            $launcher = [Management.Automation.Language.Parser]::ParseFile(
                (Join-Path $PSScriptRoot '..\Setup-Epp.ps1'), [ref]$tokens, [ref]$parseErrors)
            Assert ($parseErrors.Count -eq 0) 'The compatibility wrapper must parse.'
            foreach ($parameter in @('CertificateAction', 'EncryptionKeyId', 'KeyVaultCertificateId', 'KeyVaultSubscriptionId')) {
                Assert ($launcher.ParamBlock.Parameters.Name.VariablePath.UserPath -contains $parameter) "The launcher must forward $parameter."
            }
            Assert ($script:Answers.Count -eq 0) 'Every expected interactive answer must be consumed.'
        }
        finally {
            if ($issued) { $issued.Certificate.Dispose() }
            $certificate.Dispose(); $rsa.Dispose(); $other.Dispose(); $otherRsa.Dispose()
        }
    } $directory (Split-Path -Parent $PSScriptRoot)
    Write-Host 'Certificate discovery, selection, staging, cleanup, preservation, vault access, and reference checks passed.'
}
finally {
    Remove-Module -ModuleInfo $module -Force
    Remove-Item -LiteralPath $directory -Recurse -Force
}
