#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$module = Import-Module (Join-Path $PSScriptRoot '../support/Epp.Setup.psm1') -Force -PassThru
try {
    & $module {
        param([string] $ProviderDirectory)

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
        function script:Invoke-EppAz { throw 'No Azure calls are allowed in provider setup tests.' }
        function script:Get-MgApplication { param($ApplicationId, $Property, $ErrorAction); return $script:Application }
        function script:Update-MgApplication {
            param($ApplicationId, $IdentifierUris, $KeyCredentials, $ErrorAction)
            $script:Application.IdentifierUris = $IdentifierUris
            $script:Application.KeyCredentials = $KeyCredentials
        }
        function script:Get-MgApplicationFederatedIdentityCredential {
            param($ApplicationId, [switch] $All, $ErrorAction)
            return $script:Federations
        }
        function script:New-MgApplicationFederatedIdentityCredential {
            param($ApplicationId, $BodyParameter, $ErrorAction)
            Assert ($ApplicationId -eq $script:Application.Id) 'Federation must be created on the calling app.'
            $script:Federations.Add([pscustomobject]$BodyParameter)
        }

        $inputs = @{
            TenantId = '11111111-1111-1111-1111-111111111111'
            ApplicationId = '22222222-2222-2222-2222-222222222222'
            SubscriptionId = '33333333-3333-3333-3333-333333333333'
        }
        $names = Get-EppResourceNames -SubscriptionId $inputs.SubscriptionId `
            -ApplicationId $inputs.ApplicationId -ResourcePrefix 'oauth'
        $rsa = [Security.Cryptography.RSA]::Create(2048)
        $request = [Security.Cryptography.X509Certificates.CertificateRequest]::new(
            'CN=ExternalPhoneProvider', $rsa, [Security.Cryptography.HashAlgorithmName]::SHA256,
            [Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $certificate = $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-1), [DateTimeOffset]::UtcNow.AddDays(1))
        try {
            foreach ($provider in @('telesign', 'soprano')) {
                $profile = Get-Content -LiteralPath (Join-Path $ProviderDirectory "$provider.json") -Raw |
                    ConvertFrom-Json -AsHashtable
                $expectedAppId = if ($provider -eq 'telesign') {
                    'f1117a41-5e56-48d1-836a-1313846d1610'
                } else { '32dfc82a-86dd-4515-a0a2-f20ef2f5c7fe' }
                foreach ($channel in @('sms', 'voice')) {
                    foreach ($region in @('global', 'eu')) {
                        $settings = ConvertTo-EppProviderSettings -Profile $profile -Id $provider `
                            -DisplayName $profile.deployment.providerName -Channel $channel -EndpointRegion $region -NonInteractive
                        Assert ($settings.AuthenticationMode -ceq 'oauth') 'Both guided providers must select OAuth.'
                        Assert ($settings.Settings.EPP_PROVIDER_AUTH_MODE -ceq 'oauth') 'Runtime auth mode must match the provider.'
                        Assert ($settings.Settings.EPP_PROVIDER_APP_ID -ceq $expectedAppId) 'Use the provider API application ID.'
                        Assert ($settings.Settings.EPP_PROVIDER_SCOPE -ceq "api://$expectedAppId/.default") 'Preserve the exact provider /.default scope.'
                        Assert ($settings.Settings.EPP_PROVIDER_TENANT_ID -ceq $profile.deployment.tenantId) 'Use the provider tenant, not the calling app home tenant.'
                        Assert ($settings.Settings.EPP_PROVIDER_ENDPOINT -ceq $profile.deployment.routes[$channel][$region].endpoint) 'Do not change the selected route.'
                        Assert (-not $profile.deployment.authentication.Contains('keyVaultSecretName')) 'OAuth profiles must not require provider API-key secrets.'
                        Assert (-not $profile.deployment.authentication.Contains('identityKeyVaultSecretName')) 'OAuth profiles must not require account secrets.'
                    }
                }

                $handoff = (& {
                    Show-EppDeploymentResult -Inputs $inputs -Names $names -ProviderConfiguration $settings `
                        -EndpointUrl 'https://endpoint.example/api/SendOtp' -ResultPath 'deployment.json'
                } 6>&1 | Out-String)
                Assert ($handoff -match [regex]::Escape($settings.Settings.EPP_PROVIDER_SCOPE)) 'Handoff must show the provider scope.'
                Assert ($handoff -match 'did not grant provider API consent') 'Handoff must disclose provider authorization is separate.'
                Assert ($handoff -notmatch 'telesign-api-key|telesign-customer-id|Add the Telesign credentials') 'Do not direct OAuth customers to create old API-key secrets.'

                $script:Application = [pscustomobject]@{
                    Id = 'application-object'; AppId = $inputs.ApplicationId; SignInAudience = 'AzureADMultipleOrgs'
                    TokenEncryptionKeyId = $null; IdentifierUris = @(); KeyCredentials = @()
                }
                $script:Federations = [Collections.Generic.List[object]]::new()
                $outputs = @{
                    identifierUri = @{ value = 'api://endpoint.example' }
                    functionAppName = @{ value = $names.functionApp }
                    outboundPrincipalId = @{ value = '44444444-4444-4444-4444-444444444444' }
                }
                $registration = @{
                    Inputs = $inputs; Context = @{ Application = $script:Application }; Outputs = $outputs
                    Certificate = $certificate; KeyId = [Guid]::NewGuid().ToString()
                    ConfigureFederation = $settings.AuthenticationMode -eq 'oauth'
                }
                Set-EppApplicationEndpoint @registration
                Set-EppApplicationEndpoint @registration
                Assert ($script:Federations.Count -eq 1) 'Setup must create and reuse one federated credential.'
                $federation = $script:Federations[0]
                Assert ($federation.Subject -ceq $outputs.outboundPrincipalId.value) 'Federation must trust the outbound identity principal, not its client ID.'
                Assert ($federation.Issuer -ceq "https://login.microsoftonline.com/$($inputs.TenantId)/v2.0") 'Assertion issuer must be the home tenant.'
                Assert ($federation.Audiences.Count -eq 1 -and $federation.Audiences[0] -ceq 'api://AzureADTokenExchange') 'Federation audience must be the exchange resource.'

                foreach ($field in @('appId', 'scope')) {
                    $invalid = $profile | ConvertTo-Json -Depth 8 | ConvertFrom-Json -AsHashtable
                    $invalid.deployment.routes.sms.global.Remove($field)
                    Assert-Throws {
                        ConvertTo-EppProviderSettings -Profile $invalid -Id $provider -DisplayName $provider `
                            -Channel sms -EndpointRegion global -NonInteractive
                    } ([regex]::Escape("deployment.routes.sms.global.$field"))
                }
                $invalid = $profile | ConvertTo-Json -Depth 8 | ConvertFrom-Json -AsHashtable
                $invalid.deployment.routes.sms.global.scope = "api://$expectedAppId"
                Assert-Throws {
                    ConvertTo-EppProviderSettings -Profile $invalid -Id $provider -DisplayName $provider `
                        -Channel sms -EndpointRegion global -NonInteractive
                } 'scope must be the provider API resource followed by'
            }
            Write-Host 'Provider routes, OAuth settings, federation reuse, handoff, and malformed-profile checks passed.'
        }
        finally { $certificate.Dispose(); $rsa.Dispose() }
    } (Join-Path $PSScriptRoot '../providers')
}
finally { Remove-Module -ModuleInfo $module -Force }
