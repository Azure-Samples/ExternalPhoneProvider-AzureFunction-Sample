#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$module = Import-Module (Join-Path $PSScriptRoot '..' 'support' 'core' 'Epp.Setup.psm1') -Force -PassThru
$directory = Join-Path (Get-Location) ".epp-stage-tests-$([Guid]::NewGuid().ToString('N'))"
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
        $owners = @{
            'Read-EppInput' = 'support\core\Epp.Input.ps1'
            'Invoke-EppAz' = 'support\core\Epp.Azure.ps1'
            'Select-EppApplication' = 'support\planning\Epp.Selection.ps1'
            'Get-EppProvider' = 'support\planning\Epp.Providers.ps1'
            'Connect-EppContext' = 'support\planning\Epp.Preflight.ps1'
            'Show-EppPlan' = 'support\planning\Epp.Presentation.ps1'
            'Get-EppCertificatePlan' = 'support\deployment\Epp.Certificates.ps1'
            'Initialize-EppGraphAccess' = 'Epp.Application.ps1'
            'Get-EppDeploymentParameters' = 'support\deployment\Epp.Deployment.ps1'
            'Invoke-EppArmDeployment' = 'Epp.Arm.ps1'
            'Set-EppApplicationEndpoint' = 'Epp.PostArm.ps1'
            'Invoke-EppGraphRequest' = 'support\core\Epp.Graph.ps1'
            'Get-EppPackage' = 'support\deployment\Epp.Packages.ps1'
        }
        foreach ($entry in $owners.GetEnumerator()) {
            $command = Get-Command $entry.Key
            Assert ($command.ScriptBlock.File -ceq (Resolve-Path -LiteralPath (Join-Path $SetupDirectory $entry.Value)).Path) "$($entry.Key) must be implemented in its responsibility folder or root stage file."
        }
        $supportDirectory = Join-Path $SetupDirectory 'support'
        $stageFiles = @(Get-ChildItem -LiteralPath $SetupDirectory -Filter 'Epp.*.ps1' | Sort-Object Name)
        $rootScripts = @(Get-ChildItem -LiteralPath $SetupDirectory -File | Where-Object { $_.Extension -in @('.ps1', '.psm1') } | Sort-Object Name)
        Assert (($rootScripts.Name -join ',') -ceq 'Epp.Application.ps1,Epp.Arm.ps1,Epp.PostArm.ps1,Setup-Epp.ps1') 'Keep only the launcher and three stage scripts at the setup root.'
        Assert (@(Get-ChildItem -LiteralPath $supportDirectory -File).Count -eq 0) 'Keep internal files in responsibility subfolders, not the support root.'
        $tokens = $null; $errors = $null
        $root = [Management.Automation.Language.Parser]::ParseFile((Join-Path $supportDirectory 'core' 'Epp.Setup.psm1'), [ref]$tokens, [ref]$errors)
        $rootFunctions = @($root.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] })
        Assert ($errors.Count -eq 0 -and ($rootFunctions.Name -join ',') -ceq 'Invoke-EppDeployment,Invoke-EppSetup') 'The composition root must contain only the setup orchestrators.'
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $implementationFiles = @($stageFiles) + @(Get-ChildItem -LiteralPath $supportDirectory -Filter '*.ps1' -Recurse)
        foreach ($file in $implementationFiles) {
            $ast = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
            Assert ($errors.Count -eq 0) "$($file.Name) must parse."
            foreach ($function in @($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] })) {
                Assert ($seen.Add($function.Name)) "Duplicate helper definition: $($function.Name)."
                Assert ((Get-Command $function.Name).ScriptBlock.File -ceq $file.FullName) "The root must dot-source $($file.Name) into the same private module scope."
            }
        }
        Assert (((Get-Module Epp.Setup).ExportedFunctions.Keys -join ',') -ceq 'Invoke-EppSetup') 'Keep helpers and stage entries module-private.'
        $script:OriginalArmStage = (Get-Command Invoke-EppArmDeployment).ScriptBlock
        $script:OriginalPostStage = (Get-Command Complete-EppConfiguration).ScriptBlock
        function script:Write-Host { param($Object, $ForegroundColor) }
        $script:Calls = [Collections.Generic.List[string]]::new()
        $script:Failure = ''
        $script:Disposed = 0
        $script:ApplicationState = [pscustomobject]@{ Names = @{ functionApp = 'unit' } }
        $script:Certificate = [pscustomobject]@{ Thumbprint = 'public'; NotAfter = [DateTime]::UtcNow.AddYears(1) }
        $script:Certificate | Add-Member ScriptMethod Dispose { $script:Disposed++ }
        $script:ArmState = [pscustomobject]@{ Issued = @{ Certificate = $script:Certificate } }
        function script:Initialize-EppApplication {
            param($Inputs, $Names, $ProviderConfiguration, $Context, $OutputDirectory)
            $script:Calls.Add('application')
            if ($script:Failure -eq 'application') { throw 'application-failed' }
            return $script:ApplicationState
        }
        function script:Invoke-EppArmDeployment {
            param($Inputs, $ApplicationState, $ProviderConfiguration, $Context, $AssetDirectory, $WorkingDirectory, $Package, $OutputDirectory)
            Assert ([object]::ReferenceEquals($ApplicationState, $script:ApplicationState)) 'Pass the actual application output to ARM.'
            $script:Calls.Add('arm')
            if ($script:Failure -eq 'arm') { throw 'arm-failed' }
            return $script:ArmState
        }
        function script:Complete-EppConfiguration {
            param($Inputs, $ArmState, $ProviderConfiguration, $Context, $AssetDirectory, $WorkingDirectory, $OutputDirectory)
            Assert ([object]::ReferenceEquals($ArmState, $script:ArmState)) 'Pass the actual ARM output to post-ARM.'
            $script:Calls.Add('post')
            if ($script:Failure -eq 'post') { throw 'post-failed' }
            return @{ completed = $true }
        }
        $deployment = @{
            Inputs = @{}; Names = @{}; ProviderConfiguration = @{}; Context = @{}
            AssetDirectory = $Directory; WorkingDirectory = $Directory; Package = @{}; OutputDirectory = $Directory
        }
        foreach ($failure in @('application', 'arm', 'post', '')) {
            $script:Calls.Clear(); $script:Disposed = 0; $script:Failure = $failure
            if ($failure) { Assert-Throws { Invoke-EppDeployment @deployment } "$failure-failed" }
            else { Assert ((Invoke-EppDeployment @deployment).completed) 'Return the completed stage result.' }
            $expected = switch ($failure) { application { 'application' }; arm { 'application,arm' }; default { 'application,arm,post' } }
            Assert (($script:Calls -join ',') -ceq $expected) 'Run each stage once in order and short-circuit on failure.'
            Assert ($script:Disposed -eq [int]($failure -in @('post', ''))) 'Dispose transferred certificate ownership after post-ARM success or failure.'
        }

        Set-Item Function:script:Invoke-EppArmDeployment $script:OriginalArmStage
        Set-Item Function:script:Complete-EppConfiguration $script:OriginalPostStage
        $script:Inputs = @{
            TenantId = '11111111-1111-1111-1111-111111111111'
            SubscriptionId = '22222222-2222-2222-2222-222222222222'
            ApplicationId = '33333333-3333-3333-3333-333333333333'
            Location = 'westus2'; ResourcePrefix = 'unit'; ProviderAuthentication = 'oauth'
            ProviderTenantId = '44444444-4444-4444-4444-444444444444'
            ProviderAllowedTenantIds = @('44444444-4444-4444-4444-444444444444')
            SourceBaseUri = 'https://example.com/setup'; SourceRevision = ('a' * 40)
            PackageFile = 'released-package.zip'; SourcePackageSha256 = ('b' * 64); PackageSha256 = ('b' * 64)
        }
        $script:Names = @{ functionApp = 'unit'; storageAccount = 'unitstorage'; keyVault = 'unitvault'; resourceGroup = 'unit-rg' }
        $script:Context = @{
            TokenVersion = 2
            Application = @{ Id = '33333333-3333-3333-3333-333333333333' }
            CertificatePlan = @{
                Action = 'Create'; KeyId = '55555555-5555-5555-5555-555555555555'
                CertificateName = 'encryption'; CertificateId = $null; VaultName = 'unitvault'
                VaultSubscriptionId = $script:Inputs.SubscriptionId
                VaultResourceId = '/unitvault'; VaultRbac = $true; VaultAccessPolicies = @(); RemoveKeyIds = @()
            }
        }
        $script:Provider = @{
            Id = 'unit'; EndpointRegion = 'global'
            Settings = @{ EPP_PROVIDER_SMS_ENDPOINT = 'https://sms.example.com'; EPP_PROVIDER_VOICE_ENDPOINT = 'https://voice.example.com' }
        }
        $script:Outputs = @{
            functionAppName = @{ value = 'unit' }; storageAccountName = @{ value = 'unitstorage' }
            keyVaultName = @{ value = 'unitvault' }; resourceGroupName = @{ value = 'unit-rg' }
            outboundPrincipalId = @{ value = $script:Inputs.TenantId }
            identifierUri = @{ value = 'api://unit' }; endpointUrl = @{ value = 'https://unit.azurewebsites.net/api/SendOtp' }
            certificateBundle = @{ value = @{} }; certificateSecretVersions = @{ value = @() }
        }
        $script:Issued = @{
            Certificate = $script:Certificate
            CertificateId = "https://unitvault.vault.azure.net/certificates/encryption/$('a' * 32)"
            SecretId = "https://unitvault.vault.azure.net/secrets/encryption/$('b' * 32)"
        }
        function script:Initialize-EppResourceProviders { param($Inputs); $script:Calls.Add('providers') }
        function script:Invoke-EppAz {
            [CmdletBinding(PositionalBinding = $false)]
            param([Parameter(Position = 0, ValueFromRemainingArguments)][string[]] $Arguments, [string] $Activity)
            $command = $Arguments -join ' '
            if ($command -like 'deployment sub create *') {
                $script:Calls.Add('main')
                $path = $Arguments[[Array]::IndexOf($Arguments, '--parameters') + 1].Substring(1)
                $parameters = (Read-EppJson $path).parameters
                Assert ($parameters.packageUri.value -ceq $script:Inputs.PackageUrl -and
                    $parameters.language.value -ceq $script:Inputs.Language -and
                    $parameters.servicePlan.value -ceq $script:Inputs.ServicePlan) 'Pass the exact selected package, plan, and runtime to the single main submission.'
                if ($script:Failure -eq 'code') { throw 'code-failed' }
                return $script:Outputs | ConvertTo-Json -Depth 10
            }
            if ($command -like 'rest --method get *Microsoft.Web/sites/*') {
                $script:Calls.Add('site-readback')
                if ($script:Failure -eq 'site-readback') { return '{"id":"wrong-site","properties":{"publicNetworkAccess":"Enabled"}}' }
                $siteId = ($Arguments[[Array]::IndexOf($Arguments, '--url') + 1] -split '\?')[0].Substring('https://management.azure.com'.Length)
                if ($script:Failure -eq 'site-null') { return 'null' }
                if ($script:Failure -eq 'site-properties') { return @{ id = $siteId; properties = 'invalid' } | ConvertTo-Json }
                $access = if ($script:Failure -eq 'site-open') { 'Enabled' } else { 'Disabled' }
                return @{ id = $siteId; properties = @{ publicNetworkAccess = $access } } | ConvertTo-Json
            }
            throw "Unexpected Azure request: $command"
        }
        $script:Certificate | Add-Member NoteProperty RawData ([byte[]]@(1, 2, 3))
        function script:ConvertFrom-EppCertificateBundle { param($Bundle, [switch] $RequireSetupPolicy); return $script:Issued }
        function script:Assert-EppCertificateSecret { param($SecretId, $Versions) }
        function script:Assert-EppEncryptionReference {
            param($Inputs, $Names, $SecretId, $KeyId)
            $script:Calls.Add('reference')
            if ($script:Failure -eq 'reference') { throw 'reference-failed' }
        }
        function script:Set-EppApplicationEndpoint {
            param($Inputs, $Context, $Outputs, $Certificate, $KeyId, [switch] $ConfigureFederation)
            $script:Calls.Add('graph')
            if ($script:Failure -eq 'graph') { throw 'graph-failed' }
        }
        function script:Assert-EppGraphAccess {
            param($Inputs, $Certificate, $KeyId, $IdentifierUri, $CertificatePlan)
            $script:Calls.Add('graph-readback')
            if ($script:Failure -eq 'graph-readback') { throw 'graph-readback-failed' }
            return @{ EndpointPrincipalId = 'endpoint'; CallerPrincipalId = 'caller' }
        }
        function script:Assert-EppAuthentication {
            param($SiteId, $Inputs, $Context, $IdentifierUri)
            $script:Calls.Add('auth')
            if ($script:Failure -eq 'auth') { throw 'auth-failed' }
        }
        function script:Assert-EppOutboundFederation {
            param($Inputs, $ApplicationObjectId, $OutboundPrincipalId)
            $script:Calls.Add('federation')
            if ($script:Failure -eq 'federation') { throw 'federation-failed' }
        }
        $script:CloseFailure = $false
        function script:Set-EppPublicAccess {
            param($SiteId, $SubscriptionId, $Access, $AssetDirectory, $Directory)
            $script:Calls.Add($Access)
            if ($Access -eq 'Enabled' -and $script:Failure -eq 'enable') { throw 'enable-failed' }
            if ($Access -eq 'Disabled' -and $script:CloseFailure) { throw 'close-failed' }
        }
        function script:Assert-EppFunctionPublished {
            param($Inputs, $Names)
            $script:Calls.Add('startup')
            if ($script:Failure -eq 'startup') { throw 'startup-failed' }
        }
        function script:Show-EppDeploymentResult {
            param($Inputs, $Names, $ProviderConfiguration, $EndpointUrl, $ResultPath)
            $script:Calls.Add('handoff')
            if ($script:Failure -eq 'handoff') { throw 'handoff-failed' }
        }
        $arm = @{
            Inputs = $script:Inputs; ApplicationState = @{ Names = $script:Names }; Context = $script:Context
            ProviderConfiguration = $script:Provider; AssetDirectory = $Directory; WorkingDirectory = $Directory
            Package = @{ RequiresRemoteBuild = $false }; OutputDirectory = $Directory
        }
        foreach ($plan in @('FC1', 'EP1')) {
            foreach ($language in @('javascript', 'dotnet', 'python')) {
                $script:Inputs.ServicePlan = $plan; $script:Inputs.Language = $language
                $script:Inputs.PackageReleaseTag = "epp-packages-1-1-$language"
                $script:Inputs.PackageUrl = "https://github.com/unit/repo/releases/download/$($script:Inputs.PackageReleaseTag)/released-package.zip"
                $script:Failure = ''; $script:Calls.Clear()
                $state = Invoke-EppArmDeployment @arm
                Assert (($script:Calls -join ',') -ceq 'providers,main,reference,auth,site-readback,startup') 'Every plan/language must deploy infrastructure and code through one main submission, then validate closed-ingress outputs.'
                Assert ($state.PackageSha256 -ceq ('b' * 64) -and $state.Names.functionApp -ceq 'unit') 'Carry verified package identity and actual resources into post-ARM.'
            }
        }
        foreach ($failure in @('code', 'reference', 'auth', 'site-readback', 'site-null', 'site-properties', 'site-open', 'startup')) {
            $script:Failure = $failure; $script:Disposed = 0; $script:Calls.Clear()
            $pattern = if ($failure -like 'site-*') { 'public ingress disabled' } else { "$failure-failed" }
            Assert-Throws { Invoke-EppArmDeployment @arm } $pattern
            Assert ($script:Disposed -eq [int]($failure -ne 'code')) 'Dispose validated certificates on readback failure, but never invent an object after failed native publication.'
            Assert (-not $script:Calls.Contains('Enabled') -and -not $script:Calls.Contains('graph')) 'ARM failures must not open ingress or mutate Graph encryption credentials.'
            Assert (-not (Test-Path (Join-Path $Directory 'deployment.parameters.json'))) 'Clean primary deployment parameters on every failure.'
        }
        $post = @{
            Inputs = $script:Inputs; ArmState = $state; Context = $script:Context; ProviderConfiguration = $script:Provider
            AssetDirectory = $Directory; WorkingDirectory = $Directory; OutputDirectory = $Directory
        }
        foreach ($failure in @('reference', 'graph', 'graph-readback', 'federation', 'auth', 'enable', 'startup', 'handoff', 'save', '')) {
            $script:Failure = $failure; $script:Calls.Clear()
            $post.OutputDirectory = if ($failure -eq 'save') { Join-Path $Directory 'absent-parent' } else { $Directory }
            if ($failure) {
                $pattern = if ($failure -eq 'save') { 'Could not find a part of the path' } else { "$failure-failed" }
                Assert-Throws { Complete-EppConfiguration @post } $pattern
            }
            else {
                $result = Complete-EppConfiguration @post
                Assert ($result.packageSha256 -ceq ('b' * 64) -and -not $result.policyChanged) 'Persist the verified ARM result without activating policy.'
                Assert (($script:Calls -join ',') -ceq 'reference,graph,graph-readback,federation,auth,Enabled,startup,handoff') 'Complete trust and auth before opening ingress and handing off.'
            }
            Assert (-not $script:Calls.Contains('main')) 'Post-ARM must never submit infrastructure or Function code.'
            if ($failure -in @('reference', 'graph', 'graph-readback', 'federation', 'auth')) {
                Assert (-not $script:Calls.Contains('Enabled')) 'Failed trust preconditions must not open ingress.'
            }
            elseif ($failure) {
                Assert ($script:Calls[-1] -ceq 'Disabled') 'Every failure after ingress may open must close it, including result persistence.'
            }
        }
        $script:Failure = 'startup'; $script:CloseFailure = $true
        Assert-Throws { Complete-EppConfiguration @post } 'public ingress could not be disabled'
        $script:CloseFailure = $false
    } $directory (Split-Path -Parent $PSScriptRoot)
    Write-Host 'Three-stage sequencing, state transfer, native publication ownership, failure short-circuiting, and final ingress safety checks passed.'
}
finally {
    Remove-Module $module -Force
    Remove-Item -LiteralPath $directory -Recurse -Force
}
