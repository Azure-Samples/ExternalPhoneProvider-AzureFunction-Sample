#Requires -Version 7.4
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$module = Import-Module (Join-Path $PSScriptRoot '../support/Epp.FrontDoor.psm1') -Force -PassThru
try {
    & $module {
        function Assert($Value, $Message) { if (-not $Value) { throw $Message } }
        function Reject([scriptblock]$Action) {
            try { & $Action | Out-Null } catch { return }
            throw 'Expected unsafe configuration to be rejected.'
        }
        $tenant = '11111111-1111-1111-1111-111111111111'
        $app = '22222222-2222-2222-2222-222222222222'
        $caller = '33333333-3333-3333-3333-333333333333'
        $site = @{ kind = 'functionapp,linux' }
        $settings = @{
            FUNCTIONS_WORKER_RUNTIME = 'node'
            WEBSITE_RUN_FROM_PACKAGE = 'https://teststorage.blob.core.windows.net/packages/app.zip'
            WEBSITE_RUN_FROM_PACKAGE_BLOB_MI_RESOURCE_ID = 'SystemAssigned'
            EPP_DECRYPTION_KEY_PEM = '@Microsoft.KeyVault(SecretUri=https://testvault.vault.azure.net/secrets/phone-provider-encryption/aaaaaaaa)'
        }
        $auth = @{
            platform = @{ enabled = $true }
            httpSettings = @{ requireHttps = $true }
            globalValidation = @{ requireAuthentication = $true; unauthenticatedClientAction = 'Return401'; excludedPaths = @() }
            identityProviders = @{ azureActiveDirectory = @{
                enabled = $true
                registration = @{ clientId = $app; openIdIssuer = "https://login.microsoftonline.com/$tenant/v2.0" }
                validation = @{
                    allowedAudiences = @($app)
                    defaultAuthorizationPolicy = @{ allowedApplications = @($caller); allowedPrincipals = @{} }
                    jwtClaimChecks = @{}
                }
            } }
        }
        $result = Assert-FdSource $site $settings $auth $tenant $true
        Assert ($result.sourceVault -eq 'testvault' -and $result.callers[0] -eq $caller) 'Source selection failed.'
        Reject { Assert-FdSource $site $settings $auth $tenant $false }
        foreach ($worker in @('python','dotnet-isolated')) {
            $settings.FUNCTIONS_WORKER_RUNTIME = $worker
            Reject { Assert-FdSource $site $settings $auth $tenant $true }
        }
        $settings.FUNCTIONS_WORKER_RUNTIME = 'node'
        $original = $settings.WEBSITE_RUN_FROM_PACKAGE
        foreach ($url in @('1','http://teststorage.blob.core.windows.net/packages/app.zip',
            'https://teststorage.blob.core.windows.net/packages/app.zip?sig=SECRET',
            'https://example.com/a.zip')) {
            $settings.WEBSITE_RUN_FROM_PACKAGE = $url
            Reject { Assert-FdSource $site $settings $auth $tenant $true }
        }
        $settings.WEBSITE_RUN_FROM_PACKAGE = $original
        $auth.globalValidation.excludedPaths = @('/api/*')
        Reject { Assert-FdSource $site $settings $auth $tenant $true }
        $auth.globalValidation.excludedPaths = @('/api/health/ready')
        Assert-FdSource $site $settings $auth $tenant $true | Out-Null
        $auth.identityProviders.azureActiveDirectory.validation.defaultAuthorizationPolicy.allowedApplications = @()
        Reject { Assert-FdSource $site $settings $auth $tenant $true }
        $auth.identityProviders.azureActiveDirectory.validation.defaultAuthorizationPolicy.allowedApplications = @($caller)
        $auth.identityProviders.azureActiveDirectory.validation.defaultAuthorizationPolicy.allowedPrincipals = @{ identities = @('restricted') }
        Reject { Assert-FdSource $site $settings $auth $tenant $true }
        $auth.identityProviders.azureActiveDirectory.validation.defaultAuthorizationPolicy.allowedPrincipals = @{}
        $settings.EPP_PROVIDER_NAME = 'example'
        $settings.EPP_PROVIDER_AUTH_MODE = 'oauth'
        Reject { Assert-FdSource $site $settings $auth $tenant $false }
        $settings.EPP_PROVIDER_AUTH_MODE = 'apiKey'
        Assert-FdSource $site $settings $auth $tenant $false | Out-Null
        $settings.EPP_DECRYPTION_KEY_PEM = 'PRIVATE-KEY-MUST-NOT-BE-COPIED'
        Reject { Assert-FdSource $site $settings $auth $tenant $true }
        Write-Host 'PASS: source guards reject unsupported runtimes, auth widening, SAS URLs, unpinned keys, and unsupported provider cloning.'
        $regions = @(
            @{ location = 'centralus'; hostname = 'test-0-func.azurewebsites.net'; names = @{
                resourceGroup = 'test-0-rg'; functionApp = 'test-0-func'; keyVault = 'test-0-kv'; storageAccount = 'eppfd1234567890123'
            } },
            @{ location = 'westus2'; hostname = 'test-1-func.azurewebsites.net'; names = @{
                resourceGroup = 'test-1-rg'; functionApp = 'test-1-func'; keyVault = 'test-1-kv'; storageAccount = 'eppfd1234567890124'
            } }
        )
        Assert-FdRegions $regions test @('centralus','westus2')
        $regions[1].names.resourceGroup = 'source'
        Reject { Assert-FdRegions $regions test @('centralus','westus2') }

        $directory = Join-Path ([IO.Path]::GetTempPath()) ('fd-package-test-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory $directory | Out-Null
        $zipPath = Join-Path $directory 'app.zip'
        $handler = Join-Path $directory 'health.js'
        try {
            $statePath = Join-Path $directory 'state.json'
            Write-FdState $statePath @{ phase = 'one' }
            Write-FdState $statePath @{ phase = 'two' }
            Assert ((Get-Content $statePath -Raw | ConvertFrom-Json).phase -eq 'two') 'State replacement failed.'
            Assert ((Get-Content "$statePath.previous" -Raw | ConvertFrom-Json).phase -eq 'one') 'Previous checkpoint lost.'
            $catalog = @(
                @{ name = 'centralus'; metadata = @{ geography = 'United States' } },
                @{ name = 'westus2'; metadata = @{ geography = 'United States' } },
                @{ name = 'northeurope'; metadata = @{ geography = 'Europe' } }
            )
            $vault = @{ id = "/subscriptions/$tenant/resourceGroups/source/providers/Microsoft.KeyVault/vaults/source"; location = 'centralus' }
            Assert-FdGeography $vault $catalog @('centralus','westus2') $tenant
            Reject { Assert-FdGeography $vault $catalog @('centralus','northeurope') $tenant }
            Reject { Assert-FdGeography $vault $catalog @('centralus','missing') $tenant }
            Reject { Assert-FdGeography $vault $catalog @('centralus','westus2') $app }
            $backupPath = Join-Path $directory 'encrypted.backup'
            [IO.File]::WriteAllBytes($backupPath, [byte[]]@(0, 250, 255, 10))
            $restoreState = @{ status = 200; calls = 0 }
            function Invoke-WebRequest {
                param($Uri, $Method, $Authentication, $Token, $ContentType, $Body, $TimeoutSec, $MaximumRedirection, [switch]$SkipHttpErrorCheck)
                Assert ($Uri -eq 'https://testvault.vault.azure.net/certificates/restore?api-version=7.4') 'Unexpected restore target.'
                Assert ($Authentication -eq 'Bearer' -and $Token -is [Security.SecureString]) 'Restore must use a protected token.'
                Assert ($TimeoutSec -eq 120 -and $MaximumRedirection -eq 0) 'Restore timeout/redirect policy changed.'
                Assert (($Body | ConvertFrom-Json).value -ceq 'APr_Cg') 'Backup bytes must be base64url encoded.'
                $restoreState.calls++
                @{ StatusCode = $restoreState.status; Content = '{"error":{"code":"Conflict"}}' }
            }
            $secure = ConvertTo-SecureString 'unit-test-token' -AsPlainText -Force
            try {
                Restore-FdBackup testvault certificates $backupPath $secure
                Assert ($restoreState.calls -eq 1) 'Restore should complete once.'
                $restoreState.status = 409
                Reject { Restore-FdBackup testvault certificates $backupPath $secure }
            } finally { $secure.Dispose() }
            'readiness-content' | Set-Content -LiteralPath $handler -Encoding ascii
            $zip = [IO.Compression.ZipFile]::Open($zipPath, [IO.Compression.ZipArchiveMode]::Create)
            try {
                foreach ($name in @('host.json','package.json','node_modules/@azure/functions/package.json',
                    'src/functions/SendOtp.js','src/functions/config.js','src/functions/logging.js')) {
                    $writer = [IO.StreamWriter]::new($zip.CreateEntry($name).Open())
                    try { $writer.Write($(if ($name -eq 'package.json') { '{"main":"src/functions/*.js"}' } else { 'unchanged' })) }
                    finally { $writer.Dispose() }
                }
            } finally { $zip.Dispose() }
            Add-FdReadiness $zipPath $handler
            Add-FdReadiness $zipPath $handler
            $zip = [IO.Compression.ZipFile]::OpenRead($zipPath)
            try {
                Assert (@($zip.Entries | Where-Object FullName -eq 'src/functions/health.js').Count -eq 1) 'Duplicate health entry.'
                $reader = [IO.StreamReader]::new($zip.GetEntry('src/functions/SendOtp.js').Open())
                try { Assert ($reader.ReadToEnd() -eq 'unchanged') 'Existing handler was changed.' } finally { $reader.Dispose() }
            } finally { $zip.Dispose() }
            $rsa = [Security.Cryptography.RSA]::Create(2048)
            $request = [Security.Cryptography.X509Certificates.CertificateRequest]::new(
                'CN=OfflineDeployment', $rsa, [Security.Cryptography.HashAlgorithmName]::SHA256,
                [Security.Cryptography.RSASignaturePadding]::Pkcs1)
            $certificate = $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddDays(60))
            $output = Join-Path $directory 'deployment'
            $settings.EPP_DECRYPTION_KEY_PEM = '@Microsoft.KeyVault(SecretUri=https://testvault.vault.azure.net/secrets/phone-provider-encryption/aaaaaaaa)'
            $script:deploymentTest = @{
                package = $zipPath; settings = $settings; auth = $auth; tenant = $tenant
                certificate = @{
                    sid = 'https://testvault.vault.azure.net/secrets/phone-provider-encryption/aaaaaaaa'
                    cer = [Convert]::ToBase64String($certificate.RawData); attributes = @{ enabled = $true }
                    policy = @{ keyProperties = @{ exportable = $true; keyType = 'RSA' }
                        secretProperties = @{ contentType = 'application/x-pem-file' } }
                }
                closed = [Collections.Generic.List[string]]::new()
                cleanupFailure = $false
            }
            $script:mockSetup = New-Module -ArgumentList $deploymentTest -ScriptBlock {
                param($Test)
                function Get-EppArmOperatorObjectId { param($Inputs); return $Test.tenant }
                function Invoke-EppDataOperation { param($Operation); & $Operation }
                function Invoke-EppAz {
                    param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
                    switch -Regex ($Arguments -join ' ') {
                        '^account show ' { return @{ tenantId = $Test.tenant } | ConvertTo-Json }
                        '^account get-access-token ' { return '{"accessToken":"offline-test"}' }
                        '^keyvault show ' {
                            return @{ id = "/subscriptions/$($Test.tenant)/resourceGroups/source/providers/Microsoft.KeyVault/vaults/testvault"
                                location = 'centralus' } | ConvertTo-Json
                        }
                        '^keyvault certificate show ' { return $Test.certificate | ConvertTo-Json -Depth 5 }
                        '^rest .*locations\?' {
                            return @{ value = @('centralus','westus2') | ForEach-Object {
                                @{ name = $_; metadata = @{ geography = 'United States' } }
                            } } | ConvertTo-Json -Depth 5
                        }
                        '^rest .*profiles/test-fd\?' { return @{ properties = @{ frontDoorId = $Test.tenant } } | ConvertTo-Json }
                        '^storage blob download ' {
                            Copy-Item -LiteralPath $Test.package -Destination $Arguments[[Array]::IndexOf($Arguments, '--file') + 1]
                            return
                        }
                        '^group exists ' { return 'false' }
                        '^provider show ' { return 'Registered' }
                        '^(group create|deployment group (what-if|create)|deployment sub (validate|what-if)) ' { return }
                        '^deployment sub create ' { throw 'Simulated regional deployment failure.' }
                        default { throw "Unexpected Azure call (no network allowed): $($Arguments -join ' ')" }
                    }
                }
            }
            function script:Import-Module { param($Name, [switch]$PassThru, [switch]$Force); $script:mockSetup }
            function script:Remove-Module { param($ModuleInfo) }
            function script:Invoke-RestMethod {
                param([uri]$Uri, $Method, $Headers, $ContentType, $TimeoutSec, $Body)
                switch -Regex ($Uri.AbsolutePath) {
                    '/sites/test-[01]-func$' {
                        if ($Method -ne 'Patch' -or ($Body | ConvertFrom-Json).properties.publicNetworkAccess -ne 'Disabled') {
                            throw 'Recovery must only disable target ingress.'
                        }
                        $deploymentTest.closed.Add($Uri.AbsolutePath)
                        if ($deploymentTest.cleanupFailure -and $deploymentTest.closed.Count -eq 1) {
                            throw 'Simulated ingress cleanup failure.'
                        }
                        return @{}
                    }
                    '/sites/source/config/appsettings/list$' { return @{ properties = $deploymentTest.settings } }
                    '/sites/source/config/authsettingsV2/list$' { return @{ properties = $deploymentTest.auth } }
                    '/sites/source$' { return @{ kind = 'functionapp,linux'; properties = @{ serverFarmId = '/serverfarms/source-plan' } } }
                    '/serverfarms/source-plan$' { return @{ sku = @{ name = 'EP1' } } }
                    default { throw "Unexpected ARM call (no network allowed): $Method $Uri" }
                }
            }
            $script:writeState = ${function:Write-FdState}
            function script:Write-FdState {
                param($Path, $State)
                if ($deploymentTest.cleanupFailure -and $State.phase -eq 'failed') { throw 'Simulated checkpoint write failure.' }
                & $script:writeState $Path $State
            }
            try {
                $parameters = @{
                    SubscriptionId = $tenant; TenantId = $tenant; SourceResourceGroup = 'source'
                    SourceFunctionApp = 'source'; ResourcePrefix = 'test'; Locations = @('centralus','westus2')
                    EvaluationOnly = $true; NonInteractive = $true; OutputDirectory = $output
                    AssetDirectory = (Split-Path $PSScriptRoot)
                }
                foreach ($scenario in @('unapproved','partial','resume','cleanup-failure')) {
                    $approved = $scenario -ne 'unapproved'
                    $deploymentTest.cleanupFailure = $scenario -eq 'cleanup-failure'
                    $deploymentTest.closed.Clear()
                    $failure = $null
                    try { Invoke-EppFrontDoor @parameters -ApproveDeployment:$approved -WarningVariable warnings -WarningAction SilentlyContinue }
                    catch { $failure = $_.Exception.Message }
                    if (-not $approved) {
                        Assert ($failure -eq 'Noninteractive deployment requires -ApproveDeployment.') 'Expected approval guard.'
                        Assert ($deploymentTest.closed.Count -eq 0 -and -not (Test-Path $output)) 'Unapproved runs must not mutate resources or state.'
                        continue
                    }
                    Assert ($failure -eq 'Simulated regional deployment failure.') "Original deployment failure lost: $failure"
                    Assert ($deploymentTest.closed.Count -eq 2) 'Partial deployment must close both targets even without a regions checkpoint.'
                    $checkpoint = Get-Content (Join-Path $output 'frontdoor-state.json') -Raw | ConvertFrom-Json -AsHashtable
                    $phase = if ($deploymentTest.cleanupFailure) { 'deploying' } else { 'failed' }
                    Assert ($checkpoint.phase -eq $phase -and -not $checkpoint.ContainsKey('regions')) 'Unexpected partial-deployment checkpoint.'
                    Assert ((Get-FileHash (Join-Path $output 'frontdoor-package.zip')).Hash -ceq $checkpoint.packageHash) 'Resume changed the approved package.'
                    if ($deploymentTest.cleanupFailure) {
                        Assert (@($warnings | Where-Object { $_ -like '*Could not close ingress*' }).Count -eq 1) 'Missing ingress cleanup warning.'
                        Assert (@($warnings | Where-Object { $_ -like '*Could not save the failure checkpoint*' }).Count -eq 1) 'Missing checkpoint warning.'
                    }
                }
                Write-Host 'PASS: approval and partial-deployment recovery preserve the source and close every target on retry.'
            } finally {
                Remove-Item Function:\script:Import-Module, Function:\script:Remove-Module, Function:\script:Invoke-RestMethod
                Set-Item Function:\script:Write-FdState $script:writeState
                $certificate.Dispose(); $rsa.Dispose()
                if (Test-Path $output) {
                    Get-ChildItem -LiteralPath $output -File | Remove-Item -Force
                    Remove-Item -LiteralPath $output
                }
            }
            $zip = [IO.Compression.ZipFile]::Open($zipPath, [IO.Compression.ZipArchiveMode]::Update)
            try { $null = $zip.CreateEntry('../unsafe') } finally { $zip.Dispose() }
            Reject { Add-FdReadiness $zipPath $handler }
            Write-Host 'PASS: readiness insertion preserves delivery files and rejects unsafe ZIP paths.'
        } finally {
            Remove-Item -LiteralPath $zipPath, $handler -Force
            foreach ($file in @($statePath, "$statePath.previous", $backupPath)) {
                if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
            }
            Remove-Item -LiteralPath $directory
        }
    }
} finally { Remove-Module -ModuleInfo $module }

$path = Join-Path $PSScriptRoot '../Setup-EppFrontDoor.ps1'
$errors = $null; $tokens = $null
[Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors) | Out-Null
if ($errors.Count) { throw ($errors.Message -join '; ') }
$command = Get-Command $path
$deploy = @($command.ParameterSets | Where-Object Name -eq 'Deploy')
$verify = @($command.ParameterSets | Where-Object Name -eq 'Verify')
if ($deploy.Count -ne 1 -or $verify.Count -ne 1 -or
    'AccessToken' -in $deploy[0].Parameters.Name -or 'SubscriptionId' -in $verify[0].Parameters.Name -or
    'ApproveDeployment' -in $verify[0].Parameters.Name -or
    -not ($verify[0].Parameters | Where-Object Name -eq 'AccessToken').IsMandatory) {
    throw 'Deploy and Verify must have separate, unambiguous parameter sets.'
}
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('fd-verify-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $temporary | Out-Null
$token = ConvertTo-SecureString 'test-token' -AsPlainText -Force
try {
    foreach ($url in @('http://test.azurefd.net/api/SendOtp','https://example.com/api/SendOtp',
        'https://test.azurefd.net/api/SendOtp?redirect=elsewhere','https://user@test.azurefd.net/api/SendOtp',
        'https://test.azurefd.net:8443/api/SendOtp')) {
        @{ endpointUrl = $url } | ConvertTo-Json | Set-Content (Join-Path $temporary 'frontdoor-state.json')
        $rejected = $false
        try { & $path -Verify -OutputDirectory $temporary -AccessToken $token }
        catch {
            if ($_.Exception.Message -ne 'State does not identify an HTTPS Front Door SendOtp endpoint.') { throw }
            $rejected = $true
        }
        if (-not $rejected) { throw 'Invalid verification endpoint was not rejected.' }
    }
    Write-Host 'PASS: the shared entry point separates deployment from verification and rejects unsafe token destinations.'
    $module = Import-Module (Join-Path $PSScriptRoot '../support/Epp.FrontDoor.psm1') -Force -PassThru
    & $module {
        param($Directory, $AccessToken)
        $rsa = [Security.Cryptography.RSA]::Create(2048)
        $request = [Security.Cryptography.X509Certificates.CertificateRequest]::new(
            'CN=OfflineTest', $rsa, [Security.Cryptography.HashAlgorithmName]::SHA256,
            [Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $certificate = $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-1), [DateTimeOffset]::UtcNow.AddDays(1))
        $test = @{ calls = 0; fail = $false; privateKey = $rsa }
        function Decode([string]$Value) {
            $value = $Value.Replace('-','+').Replace('_','/')
            [Convert]::FromBase64String($value.PadRight($value.Length + (4-$value.Length%4)%4, '='))
        }
        function Invoke-WebRequest {
            param($Uri, $Method, $ContentType, $Body, $MaximumRedirection, $TimeoutSec, $SkipHttpErrorCheck, $Authentication, $Token)
            if ($Uri -ne 'https://test.azurefd.net/api/SendOtp' -or $MaximumRedirection -ne 0 -or
                $TimeoutSec -ne 30 -or -not $SkipHttpErrorCheck) { throw 'Unsafe verification request.' }
            $test.calls++
            if ($test.calls -eq 1) {
                if ($Token) { throw 'Missing-token test must omit authentication.' }
                return @{ StatusCode = 401; Content = '' }
            }
            if ($Authentication -ne 'Bearer' -or $Token -isnot [Security.SecureString]) { throw 'Expected secure bearer authentication.' }
            if ($test.calls -eq 2) { return @{ StatusCode = 403; Content = '' } }
            if (-not [object]::ReferenceEquals($Token, $AccessToken)) { throw 'Caller token not passed through securely.' }
            $payload = $Body | ConvertFrom-Json
            if ($payload.mode -ne 2) { throw 'Verification must never send a live OTP.' }
            $parts = $payload.encryptedDeliveryContext.Split('.')
            $key = $test.privateKey.Decrypt((Decode $parts[1]), [Security.Cryptography.RSAEncryptionPadding]::OaepSHA256)
            $cipher = Decode $parts[3]; $plain = [byte[]]::new($cipher.Length)
            $aes = [Security.Cryptography.AesGcm]::new($key, 16)
            try { $aes.Decrypt((Decode $parts[2]), $cipher, (Decode $parts[4]), $plain, [Text.Encoding]::ASCII.GetBytes($parts[0])) }
            finally { $aes.Dispose(); [Array]::Clear($key, 0, $key.Length) }
            $delivery = [Text.Encoding]::UTF8.GetString($plain) | ConvertFrom-Json
            @{ StatusCode = 200; Content = (@{
                nonce = $(if ($test.fail) { 'wrong-nonce' } else { $delivery.nonce })
                correlationId = $payload.correlationId
            } | ConvertTo-Json) }
        }
        try {
            [IO.File]::WriteAllBytes((Join-Path $Directory 'encryption-public.cer'), $certificate.RawData)
            @{ endpointUrl = 'https://test.azurefd.net/api/SendOtp' } | ConvertTo-Json | Set-Content (Join-Path $Directory 'frontdoor-state.json')
            foreach ($fail in @($false, $true)) {
                $test.calls = 0; $test.fail = $fail; $rejected = $false
                try { Test-EppFrontDoor -OutputDirectory $Directory -AccessToken $AccessToken }
                catch {
                    if ($_.Exception.Message -ne 'Front Door evaluation/authentication checks failed. No live messages were sent.') { throw }
                    $rejected = $true
                }
                if ($test.calls -ne 5 -or $rejected -ne $fail) { throw 'Verification changed its five-check or nonce-validation behavior.' }
            }
            Write-Host 'PASS: five offline HTTP checks use secure tokens and encrypted evaluation; wrong nonces still fail.'
        } finally { $certificate.Dispose(); $rsa.Dispose() }
    } $temporary $token
}
finally {
    $token.Dispose()
    foreach ($name in @('frontdoor-state.json','encryption-public.cer','evaluation-results.json')) {
        $file = Join-Path $temporary $name
        if (Test-Path $file) { Remove-Item -LiteralPath $file }
    }
    Remove-Item -LiteralPath $temporary
    if ($module) { Remove-Module -ModuleInfo $module -ErrorAction SilentlyContinue }
}
