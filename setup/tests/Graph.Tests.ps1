#Requires -Version 7.0
param([string] $ModulePath = (Split-Path -Parent $PSScriptRoot))

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$module = Import-Module (Join-Path $ModulePath 'support\Epp.Setup.psm1') -Force -PassThru
try {
    & $module {
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
        $script:Tenant = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        $script:Subscription = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
        $script:User = 'cccccccc-cccc-cccc-cccc-cccccccccccc'
        $script:ApplicationId = '11111111-1111-1111-1111-111111111111'
        $script:ObjectId = '22222222-2222-2222-2222-222222222222'
        $inputs = @{ TenantId = $script:Tenant; SubscriptionId = $script:Subscription }
        $script:Calls = [Collections.Generic.List[object]]::new()
        $script:Files = [Collections.Generic.List[string]]::new()
        $script:Responses = [Collections.Generic.Queue[object]]::new()
        function script:Reset-TestState {
            $script:Calls.Clear(); $script:Files.Clear(); $script:Responses.Clear()
            $script:CurrentTenant = $script:Tenant; $script:CurrentUser = $script:User
            $script:UserType = 'user'; $script:Cloud = 'AzureCloud'; $script:Failure = ''
            $script:Principals = @(); $script:AdResponse = $null
        }
        function script:Invoke-EppAz {
            param([Parameter(ValueFromRemainingArguments)][string[]] $Arguments)
            $command = $Arguments -join ' '
            if ($command -like 'account show *') {
                return @{
                    id = $script:Subscription; tenantId = $script:CurrentTenant; environmentName = $script:Cloud
                    state = 'Enabled'; user = @{ type = $script:UserType; name = 'operator@contoso.test' }
                } | ConvertTo-Json -Depth 5
            }
            if ($command -like 'account get-access-token *') {
                Assert ($Arguments -notcontains '--tenant') 'Cloud Shell token acquisition must not use --tenant.'
                $json = @{ tid = $script:Tenant; oid = $script:User } | ConvertTo-Json -Compress
                $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json)).TrimEnd('=').Replace('+','-').Replace('/','_')
                return "header.$payload.signature"
            }
            if ($Arguments[0] -eq 'ad') {
                $script:Calls.Add(@{ Kind = 'ad'; Command = $command })
                if ($script:Failure) { throw $script:Failure }
                switch -Regex ($command) {
                    '^ad signed-in-user show ' { return @{ id = $script:CurrentUser; userPrincipalName = 'operator@contoso.test' } | ConvertTo-Json }
                    '^ad app show --id ' { return @{ id = $script:ObjectId; appId = $script:ApplicationId } | ConvertTo-Json }
                    '^ad sp list --filter ' { return ConvertTo-Json -InputObject $script:Principals -Depth 10 }
                    '^ad sp create --id ' { return $script:AdResponse | ConvertTo-Json -Depth 10 }
                    '^ad app federated-credential create ' {
                        $path = $Arguments[[Array]::IndexOf($Arguments, '--parameters') + 1]
                        $script:Files.Add($path)
                        $script:Federation = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
                        return '{"id":"federation"}'
                    }
                    default { throw "Unexpected directory command: $command" }
                }
            }
            Assert ($Arguments[0] -ceq 'rest') "Unexpected CLI command: $command"
            Assert ($Arguments[[Array]::IndexOf($Arguments, '--subscription') + 1] -ceq $script:Subscription) 'Pin REST token acquisition to the selected subscription.'
            Assert ($Arguments[[Array]::IndexOf($Arguments, '--resource') + 1] -ceq 'https://graph.microsoft.com/') 'Request a Graph-audience token, not an ARM token.'
            Assert ($Arguments -notcontains '--tenant' -and $Arguments -notcontains '--headers') 'Do not pass tenant overrides or manually expose bearer headers.'
            $url = $Arguments[[Array]::IndexOf($Arguments, '--url') + 1]
            Assert ($url -notmatch '[?&]') 'Pass Graph query values in a file to avoid az.cmd quoting issues.'
            $record = @{
                Kind = 'rest'; Url = $url; Method = $Arguments[[Array]::IndexOf($Arguments, '--method') + 1]
                Query = @{}; Body = $null
            }
            foreach ($mapping in @{ '--url-parameters' = 'Query'; '--body' = 'Body' }.GetEnumerator()) {
                if ($Arguments -contains $mapping.Key) {
                    $path = $Arguments[[Array]::IndexOf($Arguments, $mapping.Key) + 1].Substring(1)
                    $script:Files.Add($path)
                    $record[$mapping.Value] = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
                }
            }
            $script:Calls.Add($record)
            if ($script:Failure) { throw $script:Failure }
            if ($script:Responses.Count) { return ConvertTo-Json -InputObject $script:Responses.Dequeue() -Depth 20 }
            if ($record.Method -eq 'patch') { return '' }
            throw 'No test response was queued.'
        }
        function script:Start-Sleep { param($Seconds) }
        function script:Connect-MgGraph { throw 'The Graph SDK must never be invoked.' }
        function script:Invoke-MgGraphRequest { throw 'The Graph SDK must never be invoked.' }

        Reset-TestState
        $connection = Connect-EppGraphAccount -Inputs $inputs -NonInteractive
        Assert ($connection.Context.Authentication -ceq 'AzureCli' -and $connection.Operator.Id -ceq $script:User) 'Reuse the CLI identity without Graph SDK authentication.'
        Assert ($script:Calls.Count -eq 1 -and $script:Calls[0].Command -like 'ad signed-in-user show *') 'Use the signed-in-user command rather than a separate login.'
        foreach ($case in @('tenant', 'appOnly', 'cloud')) {
            Reset-TestState
            switch ($case) {
                tenant { $script:CurrentTenant = $script:Subscription }
                appOnly { $script:UserType = 'servicePrincipal' }
                cloud { $script:Cloud = 'AzureUSGovernment' }
            }
            Assert-Throws { Connect-EppGraphAccount -Inputs $inputs -NonInteractive } 'selected tenant|requested enabled subscription|differs from'
        }
        Reset-TestState
        $script:CurrentUser = $script:Subscription
        $connection = Connect-EppGraphAccount -Inputs $inputs -NonInteractive
        Assert ($connection.Operator.Id -ceq $script:Subscription -and
            (Get-EppArmOperatorObjectId -Inputs $inputs) -ceq $script:User) 'Track Graph and ARM identities independently; never substitute Graph /me for the ARM role-assignment principal.'
        foreach ($path in @(
            'https://graph.microsoft.com.evil.invalid/v1.0/me',
            'http://graph.microsoft.com/v1.0/me', 'https://graph.microsoft.com:444/v1.0/me',
            'https://user@graph.microsoft.com/v1.0/me', '/other/me', '/v1.0/applications%2fescape',
            'https://graph.microsoft.com/v1.0/me#fragment'
        )) {
            Reset-TestState
            Assert-Throws { Invoke-EppGraphRequest -Inputs $inputs -Path $path } 'must target'
            Assert ($script:Calls.Count -eq 0) 'Reject unsafe Graph destinations before token-bearing calls.'
        }
        Reset-TestState
        $script:CurrentTenant = $script:Subscription
        Assert-Throws { Invoke-EppGraphRequest -Inputs $inputs -Path '/v1.0/me' } 'does not match'
        Assert ($script:Calls.Count -eq 0) 'A wrong CLI tenant must block Graph requests.'
        Reset-TestState
        $script:Responses.Enqueue(@{ value = @() })
        $null = Invoke-EppGraphRequest -Inputs $inputs -Path '/v1.0/applications' -Query @{
            '$top' = '50'; '$select' = 'appId,displayName'; '$filter' = "startswith(displayName,'O''Reilly & Co')"
        }
        Assert ($script:Calls[0].Query['$filter'] -ceq "startswith(displayName,'O''Reilly & Co')") 'Preserve query quoting through the JSON query file.'
        foreach ($path in $script:Files) { Assert (-not (Test-Path -LiteralPath $path)) 'Remove temporary query files.' }

        Reset-TestState
        $collection = "/v1.0/servicePrincipals/$script:ObjectId/appRoleAssignments"
        $script:Responses.Enqueue(@{ value = @(@{ id = 'first' }); '@odata.nextLink' = "https://graph.microsoft.com$collection`?`$skiptoken=a%2Bb%26c&`$top=100" })
        $script:Responses.Enqueue(@{ value = @(@{ id = 'second' }) })
        $items = @(Get-EppGraphCollection -Inputs $inputs -Path $collection)
        Assert ($items.Count -eq 2 -and $script:Calls[1].Query['$skiptoken'] -ceq 'a+b&c') 'Follow bounded Graph pagination without corrupting continuation tokens.'
        foreach ($next in @('https://evil.invalid/v1.0/me', 'https://graph.microsoft.com/v1.0/users')) {
            Reset-TestState
            $script:Responses.Enqueue(@{ value = @(); '@odata.nextLink' = $next })
            Assert-Throws { Get-EppGraphCollection -Inputs $inputs -Path $collection } 'invalid or repeated'
        }
        Reset-TestState
        $next = "https://graph.microsoft.com$collection`?`$skiptoken=repeat"
        $script:Responses.Enqueue(@{ value = @(); '@odata.nextLink' = $next })
        $script:Responses.Enqueue(@{ value = @(); '@odata.nextLink' = $next })
        Assert-Throws { Get-EppGraphCollection -Inputs $inputs -Path $collection } 'invalid or repeated'
        Reset-TestState
        $script:Responses.Enqueue(@{ value = @{} })
        Assert-Throws { Get-EppGraphCollection -Inputs $inputs -Path $collection } 'invalid collection'

        $credential = @{
            keyId = '33333333-3333-3333-3333-333333333333'; type = 'AsymmetricX509Cert'; usage = 'Encrypt'
            displayName = 'CN=ExternalPhoneProvider'; key = 'AQIDBA=='; customKeyIdentifier = 'BQYHCA=='
            startDateTime = '2026-01-01T00:00:00Z'; endDateTime = '2027-01-01T00:00:00Z'
        }
        $rawApplication = @{
            id = $script:ObjectId; appId = $script:ApplicationId; displayName = 'EPP'
            signInAudience = 'AzureADMyOrg'; keyCredentials = @($credential)
        }
        Reset-TestState
        $script:Responses.Enqueue($rawApplication)
        $app = Get-EppApplication -Inputs $inputs -ClientId $script:ApplicationId
        Assert ($app.Id -ceq $script:ObjectId -and $app.AppId -ceq $script:ApplicationId) 'Resolve client IDs separately from application object IDs.'
        Assert ($app.KeyCredentials[0].Key -is [byte[]] -and $app.KeyCredentials[0].CustomKeyIdentifier -is [byte[]]) 'Normalize Graph base64 fields for existing certificate checks.'
        $wire = @(ConvertTo-EppGraphKeyCredentials -Credentials $app.KeyCredentials)
        Assert ($wire[0].key -ceq $credential.key -and $wire[0].customKeyIdentifier -ceq $credential.customKeyIdentifier) 'Serialize binary certificate fields as Graph base64 strings, not JSON byte arrays.'
        Assert ($script:Calls[1].Query['$select'] -match 'keyCredentials') 'Explicitly request public key material required for safe preservation.'
        $invalid = @{} + $credential; $invalid.key = 'invalid-base64'
        Assert-Throws { ConvertFrom-EppGraphApplication @{ id = $script:ObjectId; appId = $script:ApplicationId; keyCredentials = @($invalid) } } 'invalid base64'

        Reset-TestState
        Set-EppProviderTenantRestriction -Inputs $inputs -ApplicationObjectId $script:ObjectId -ProviderTenantId $script:User
        Assert ($script:Calls[0].Method -ceq 'patch' -and $script:Calls[0].Url -like '*/beta/applications/*') 'Use beta only for the allowed-tenants preview.'
        $body = $script:Calls[0].Body
        Assert ($body.signInAudience -ceq 'AzureADMultipleOrgs' -and $body.signInAudienceRestrictions.isHomeTenantAllowed -eq $true) 'Update the audience and tenant restriction together.'
        Assert ($body.signInAudienceRestrictions.allowedTenantIds.Count -eq 1 -and $body.signInAudienceRestrictions.allowedTenantIds[0] -ceq $script:User) 'Allow only the approved provider tenant in addition to home.'
        foreach ($path in $script:Files) { Assert (-not (Test-Path -LiteralPath $path)) 'Remove temporary Graph body files.' }

        Reset-TestState
        $script:Responses.Enqueue(@{ value = @() })
        $script:Responses.Enqueue(@{ id = 'assignment' })
        Ensure-EppAppRoleAssignment -Inputs $inputs -Principal @{ Id = $script:ObjectId } -Resource @{ Id = $script:ApplicationId } `
            -AppRoleId $script:User -Description 'test role'
        Assert ($script:Calls.Count -eq 2 -and $script:Calls[1].Method -ceq 'post') 'Create only a missing exact app-role assignment.'
        Assert ($script:Calls[1].Body.principalId -ceq $script:ObjectId -and $script:Calls[1].Body.resourceId -ceq $script:ApplicationId -and
            $script:Calls[1].Body.appRoleId -ceq $script:User) 'Do not use blanket admin consent or Azure RBAC for Graph role assignment.'
        Reset-TestState
        $script:Responses.Enqueue(@{ value = @(@{ resourceId = $script:ApplicationId; appRoleId = $script:User }) })
        Ensure-EppAppRoleAssignment -Inputs $inputs -Principal @{ Id = $script:ObjectId } -Resource @{ Id = $script:ApplicationId } `
            -AppRoleId $script:User -Description 'test role'
        Assert ($script:Calls.Count -eq 1) 'Reuse existing assignments without another POST.'

        Reset-TestState
        $script:Principals = @(@{ id = $script:ObjectId; appId = $script:ApplicationId; accountEnabled = $true })
        $principal = Get-EppServicePrincipal -Inputs $inputs -AppId $script:ApplicationId -Description test
        Assert ($principal.id -ceq $script:ObjectId) 'Read a unique service principal through az ad.'
        $script:Principals += $script:Principals[0]
        Assert-Throws { Get-EppServicePrincipal -Inputs $inputs -AppId $script:ApplicationId -Description test } 'Multiple'
        Reset-TestState
        $script:AdResponse = @{ id = $script:ObjectId; appId = $script:ApplicationId; accountEnabled = $true }
        $null = Ensure-EppServicePrincipal -Inputs $inputs -AppId $script:ApplicationId -Description test
        Assert ($script:Calls[-1].Command -like 'ad sp create --id *' -and $script:Calls[-1].Command -notmatch 'create-for-rbac|credential') 'Create only a service principal, not an app/secret/RBAC bundle.'
        Reset-TestState
        New-EppFederatedCredential -Inputs $inputs -ObjectId $script:ObjectId -Credential @{
            name = 'epp-outbound'; issuer = "https://login.microsoftonline.com/$script:Tenant/v2.0"
            subject = $script:User; audiences = @('api://AzureADTokenExchange')
        }
        Assert ($script:Federation.subject -ceq $script:User -and $script:Federation.audiences.Count -eq 1) 'Preserve the approved outbound federation.'
        foreach ($path in $script:Files) { Assert (-not (Test-Path -LiteralPath $path)) 'Remove temporary federation files.' }
        Reset-TestState
        $script:Failure = 'Authorization_RequestDenied: insufficient privileges'
        Assert-Throws { Invoke-EppGraphRequest -Inputs $inputs -Method PATCH -Path "/v1.0/applications/$script:ObjectId" -Body @{ displayName = 'test' } } 'Authorization_RequestDenied'
        foreach ($path in $script:Files) { Assert (-not (Test-Path -LiteralPath $path)) 'Clean up after permission failures without swallowing the error.' }
    }
    Write-Host 'CLI Graph identity, audience, tenant guards, requests, pagination, credentials, exact grants, federation, and failure checks passed.'
}
finally { Remove-Module -ModuleInfo $module -Force }
