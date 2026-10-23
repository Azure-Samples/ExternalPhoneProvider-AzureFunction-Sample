#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$module = Import-Module (Join-Path $PSScriptRoot '..\support\Epp.Setup.psm1') -Force -PassThru
$directory = Join-Path ([IO.Path]::GetTempPath()) "epp-federation-tests-$([Guid]::NewGuid().ToString('N'))"
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
        $script:Inputs = @{
            TenantId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
            SubscriptionId = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
            ApplicationId = 'cccccccc-cccc-cccc-cccc-cccccccccccc'
            ResourcePrefix = 'unit'; ProviderAuthentication = 'oauth'
        }
        $script:ObjectId = 'dddddddd-dddd-dddd-dddd-dddddddddddd'
        $script:Names = Get-EppResourceNames -SubscriptionId $script:Inputs.SubscriptionId -ApplicationId $script:Inputs.ApplicationId -ResourcePrefix unit
        $script:Identity = [pscustomobject]@{
            ResourceId = "/subscriptions/$($script:Inputs.SubscriptionId)/resourceGroups/$($script:Names.resourceGroup)/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$($script:Names.outboundIdentity)"
            ClientId = 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee'
            PrincipalId = 'ffffffff-ffff-ffff-ffff-ffffffffffff'
        }
        $script:Issuer = "https://login.microsoftonline.com/$($script:Inputs.TenantId)/v2.0"
        function script:New-TestTrust([string] $Name, [string] $Subject = $script:Identity.PrincipalId) {
            @{
                id = [Guid]::NewGuid().ToString('D'); name = $Name; issuer = $script:Issuer
                subject = $Subject; audiences = @('api://AzureADTokenExchange')
            }
        }
        function script:Reset-TestState {
            $script:State = @{
                Trusts = [Collections.Generic.List[object]]::new()
                Calls = [Collections.Generic.List[string]]::new()
                Files = [Collections.Generic.List[string]]::new()
                Creates = 0; Reads = 0; Sleeps = 0; Lag = 0; Mode = ''; ReadError = ''
                AccountTenant = $script:Inputs.TenantId; IdentityTenant = $script:Inputs.TenantId
                AppId = $script:Inputs.ApplicationId; Attached = $true; AuthMode = 'oauth'
                RuntimeClientId = $script:Identity.ClientId; PrincipalId = $script:Identity.PrincipalId
            }
        }
        function script:Start-Sleep { param($Seconds); $script:State.Sleeps++ }
        function script:Read-Host { throw 'Federation must not require a separate prompt or mode.' }
        function script:Invoke-EppAz {
            param([Parameter(ValueFromRemainingArguments)][string[]] $Arguments)
            $command = $Arguments -join ' '
            $script:State.Calls.Add($command)
            switch -Regex ($command) {
                '^account show ' {
                    return @{ tenantId = $script:State.AccountTenant; environmentName = 'AzureCloud'; user = @{ type = 'user' } } | ConvertTo-Json
                }
                '^identity show ' {
                    return @{
                        id = $script:Identity.ResourceId; tenantId = $script:State.IdentityTenant
                        clientId = $script:Identity.ClientId; principalId = $script:State.PrincipalId
                    } | ConvertTo-Json
                }
                '^functionapp show ' {
                    $assigned = @{}
                    if ($script:State.Attached) {
                        $assigned[$script:Identity.ResourceId.ToLowerInvariant()] = @{
                            clientId = $script:Identity.ClientId; principalId = $script:State.PrincipalId
                        }
                    }
                    return @{
                        id = "/subscriptions/$($script:Inputs.SubscriptionId)/resourceGroups/$($script:Names.resourceGroup)/providers/Microsoft.Web/sites/$($script:Names.functionApp)"
                        tags = @{ managedBy = 'EPP-Setup'; eppApplicationId = $script:State.AppId }
                        identity = @{ userAssignedIdentities = $assigned }
                    } | ConvertTo-Json -Depth 6
                }
                '^functionapp config appsettings list ' {
                    Assert ($command -match '--query .*EPP_OUTBOUND_MI_CLIENT_ID') 'Read only nonsecret outbound settings.'
                    return @(
                        @{ name = 'EPP_PROVIDER_AUTH_MODE'; value = $script:State.AuthMode }
                        @{ name = 'EPP_OUTBOUND_CLIENT_ID'; value = $script:Inputs.ApplicationId }
                        @{ name = 'EPP_OUTBOUND_MI_CLIENT_ID'; value = $script:State.RuntimeClientId }
                    ) | ConvertTo-Json
                }
                '^ad app show ' { return @{ id = $script:ObjectId; appId = $script:Inputs.ApplicationId } | ConvertTo-Json }
                '^ad app federated-credential create ' {
                    $script:State.Creates++
                    $path = $Arguments[[Array]::IndexOf($Arguments, '--parameters') + 1]
                    $script:State.Files.Add($path)
                    $trust = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
                    $trust.id = [Guid]::NewGuid().ToString('D')
                    if ($script:State.Mode -eq 'denied') { throw 'Authorization_RequestDenied: 403' }
                    if ($script:State.Mode -eq 'throttle' -and $script:State.Creates -eq 1) { throw 'TooManyRequests: 429' }
                    if ($script:State.Mode -eq 'timeout-no-write' -and $script:State.Creates -eq 1) { throw 'Request timed out' }
                    if (@($script:State.Trusts | Where-Object name -eq $trust.name).Count) { throw 'Conflict: 409' }
                    if ($script:State.Mode -ne 'drop') { $script:State.Trusts.Add($trust) }
                    if ($script:State.Mode -eq 'lost-response') { throw 'Request timed out' }
                    if ($script:State.Mode -eq 'empty-response') { return '' }
                    return $trust | ConvertTo-Json
                }
                '^rest --method get ' {
                    $url = $Arguments[[Array]::IndexOf($Arguments, '--url') + 1]
                    if ($url -eq "https://graph.microsoft.com/v1.0/applications/$script:ObjectId") {
                        return @{
                            id = $script:ObjectId; appId = $script:Inputs.ApplicationId; signInAudience = 'AzureADMultipleOrgs'
                            keyCredentials = @(@{
                                keyId = '11111111-1111-1111-1111-111111111111'; usage = 'Encrypt'; type = 'AsymmetricX509Cert'
                                key = 'AQIDBA=='
                            })
                        } | ConvertTo-Json -Depth 5
                    }
                    Assert ($url -eq "https://graph.microsoft.com/v1.0/applications/$script:ObjectId/federatedIdentityCredentials") 'Read only the selected customer application federation.'
                    $script:State.Reads++
                    if ($script:State.ReadError) { throw $script:State.ReadError }
                    $visible = @($script:State.Trusts.ToArray())
                    if ($script:State.Creates -and $script:State.Lag -gt 0) {
                        $script:State.Lag--
                        $visible = @()
                    }
                    return @{ value = $visible } | ConvertTo-Json -Depth 6
                }
                default { throw "Unexpected Azure call (deployment, settings, certificate and provider writes are forbidden): $command" }
            }
        }
        function script:Ensure-TestFederation {
            Ensure-EppOutboundFederation -Inputs $script:Inputs -ApplicationObjectId $script:ObjectId `
                -FunctionAppName $script:Names.functionApp -Identity $script:Identity
        }
        $expectedName = "epp-$($script:Names.functionApp)-outbound"
        foreach ($oldCount in @(0, 1, 4, 6)) {
            Reset-TestState
            for ($i = 0; $i -lt $oldCount; $i++) {
                $script:State.Trusts.Add((New-TestTrust "old-$i" ([Guid]::NewGuid().ToString('D'))))
            }
            $old = ConvertTo-Json -InputObject $script:State.Trusts.ToArray() -Depth 5
            $result = Ensure-TestFederation
            Assert ($script:State.Creates -eq 1 -and $script:State.Reads -eq 2 -and $result.action -eq 'created') 'Create missing trust and read it back, including when several old deployments exist.'
            Assert ($result.credentialName -eq $expectedName -and $result.subject -eq $script:Identity.PrincipalId) 'Use principal ID, not client ID, for the trust subject.'
            Assert ($result.identityClientId -eq $script:Identity.ClientId -and $result.credentialId) 'Retain verified linkage metadata.'
            $remaining = @($script:State.Trusts | Where-Object name -ne $expectedName)
            Assert ((ConvertTo-Json -InputObject $remaining -Depth 5) -ceq $old) 'Preserve all older trusts.'
            $again = Ensure-TestFederation
            Assert ($script:State.Creates -eq 1 -and $again.action -eq 'reused') 'Reruns must not create duplicate trust.'
            foreach ($file in $script:State.Files) { Assert (-not (Test-Path -LiteralPath $file)) 'Remove temporary creation files.' }
        }
        Reset-TestState
        $script:State.Trusts.Add((New-TestTrust 'custom-name'))
        Assert ((Ensure-TestFederation).credentialName -eq 'custom-name' -and $script:State.Creates -eq 0) 'Matching trust can have any name.'

        Reset-TestState
        $script:State.Trusts.Add((New-TestTrust $expectedName $script:ObjectId))
        $result = Ensure-TestFederation
        Assert ($result.credentialName -eq "$expectedName-$($script:Identity.PrincipalId.Replace('-', ''))") 'Use an identity-specific name after recreation rather than retargeting an existing trust.'
        Assert ($script:State.Trusts[0].subject -eq $script:ObjectId) 'Keep the older identity trust intact.'

        foreach ($case in @('delay', 'long-delay', 'lost-response', 'empty-response', 'throttle', 'timeout-no-write')) {
            Reset-TestState
            $script:State.Mode = $case
            if ($case -eq 'delay') { $script:State.Lag = 2 }
            if ($case -eq 'long-delay') { $script:State.Lag = 5 }
            $result = Ensure-TestFederation
            Assert ($result.credentialId -and $script:State.Trusts.Count -eq 1 -and $script:State.Creates -le 2) 'Recover transient/uncertain writes without duplicates.'
        }
        Reset-TestState
        $script:State.Mode = 'drop'
        Assert-Throws { Ensure-TestFederation } 'not yet confirmed.*Setup is not complete'
        Assert ($script:State.Creates -eq 2 -and $script:State.Reads -eq 8) 'Bound recovery and never report success from an unpersisted creation response.'
        foreach ($case in @('denied', 'read-denied')) {
            Reset-TestState
            if ($case -eq 'denied') { $script:State.Mode = $case } else { $script:State.ReadError = 'Authorization_RequestDenied: 403' }
            Assert-Throws { Ensure-TestFederation } 'Authorization_RequestDenied'
            Assert ($script:State.Sleeps -eq 0 -and $script:State.Creates -le 1) 'Do not retry or swallow permission failures.'
        }
        Reset-TestState
        $wrongAudience = New-TestTrust 'different-audience'
        $wrongAudience.audiences = @('different')
        $script:State.Trusts.Add($wrongAudience)
        Assert-Throws { Ensure-TestFederation } 'different audience'
        Assert ($script:State.Creates -eq 0) 'Do not overwrite or duplicate issuer/subject with different audience.'

        Reset-TestState
        for ($i = 0; $i -lt 20; $i++) { $script:State.Trusts.Add((New-TestTrust "old-$i" ([Guid]::NewGuid().ToString('D')))) }
        Assert-Throws { Ensure-TestFederation } 'limit'
        Assert ($script:State.Creates -eq 0 -and $script:State.Trusts.Count -eq 20) 'Never evict another deployment at capacity.'
        $script:State.Trusts[0] = New-TestTrust 'matching-at-capacity'
        Assert ((Ensure-TestFederation).credentialName -eq 'matching-at-capacity') 'Reuse matching trust even at capacity.'

        Assert (-not (Get-Command Invoke-EppSetup).Parameters.ContainsKey('RepairOutboundAuthentication')) 'The public setup flow must not expose a separate federation mode.'
        $deployment = @{
            Inputs = $script:Inputs; Names = $script:Names
            Context = @{ Application = @{ Id = $script:ObjectId } }
            Outputs = @{ outboundPrincipalId = @{ value = $script:Identity.PrincipalId } }
            OutputDirectory = $Directory
        }
        Reset-TestState
        $result = Initialize-EppOutboundFederation @deployment
        Assert ($result.credentialName -eq $expectedName -and $script:State.Creates -eq 1) 'Normal OAuth setup must create and confirm the required trust without an additional option.'
        $checkpoint = Get-Content -LiteralPath (Join-Path $Directory "federation-$($script:Names.functionApp).json") -Raw | ConvertFrom-Json
        Assert ($checkpoint.outboundFederation.credentialId -eq $result.credentialId -and
            $checkpoint.outboundFederation.identityResourceId -eq $script:Identity.ResourceId) 'Persist actual verified credential and identity linkage.'
        $reused = Initialize-EppOutboundFederation @deployment
        Assert ($reused.credentialId -eq $result.credentialId -and $script:State.Creates -eq 1) 'The normal pre-publication check must reuse verified trust.'
        $script:State.Trusts.Clear()
        $recreated = Initialize-EppOutboundFederation @deployment
        Assert ($recreated.credentialId -ne $result.credentialId -and $script:State.Creates -eq 2) 'If trust disappears during setup, the normal reconciliation must recreate it instead of merely reporting failure.'
        Assert (@($script:State.Calls | Where-Object { $_ -match 'config appsettings set|restart|deployment|keyvault|rest --method (post|patch)' }).Count -eq 0) 'Federation initialization must not rotate certificates, change settings or contact the provider.'

        foreach ($case in @('wrong-app', 'wrong-tenant', 'detached', 'wrong-client', 'api-key', 'context-switch', 'identity-replaced')) {
            Reset-TestState
            switch ($case) {
                wrong-app { $script:State.AppId = $script:ObjectId }
                wrong-tenant { $script:State.IdentityTenant = $script:ObjectId }
                detached { $script:State.Attached = $false }
                wrong-client { $script:State.RuntimeClientId = $script:ObjectId }
                api-key { $script:State.AuthMode = 'apiKey' }
                context-switch { $script:State.AccountTenant = $script:ObjectId }
                identity-replaced { $script:State.PrincipalId = $script:ObjectId }
            }
            Assert-Throws { Initialize-EppOutboundFederation @deployment } 'does not match|not attached|do not match|disagree'
            Assert ($script:State.Creates -eq 0) 'Normal setup must reject mismatched identity/application linkage before writing trust.'
        }
        Reset-TestState
        $inputs = @{} + $script:Inputs
        $inputs.ProviderAuthentication = 'apiKey'
        Assert ($null -eq (Initialize-EppOutboundFederation -Inputs $inputs -Names $script:Names -OutputDirectory $Directory)) 'API-key deployments skip federation.'
        Assert ($script:State.Calls.Count -eq 0) 'No provider readiness gate or unnecessary trust.'
        Write-Host 'Automatic federation creation, reuse, recovery, identity linkage and checkpoint checks passed.'
    } $directory
}
finally {
    Remove-Module $module
    if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force }
}
