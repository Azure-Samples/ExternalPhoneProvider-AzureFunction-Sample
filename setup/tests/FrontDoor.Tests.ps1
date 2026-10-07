#Requires -Version 7.0
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
