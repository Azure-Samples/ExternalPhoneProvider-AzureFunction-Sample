function Get-EppOutboundIdentity {
    param([hashtable] $Inputs, [Collections.IDictionary] $Names)

    $identity = Invoke-EppAz identity show --subscription $Inputs.SubscriptionId --resource-group $Names.resourceGroup `
        --name $Names.outboundIdentity --output json | ConvertFrom-Json -AsHashtable
    $site = Invoke-EppAz functionapp show --subscription $Inputs.SubscriptionId --resource-group $Names.resourceGroup `
        --name $Names.functionApp --output json | ConvertFrom-Json -AsHashtable
    $expectedId = "/subscriptions/$($Inputs.SubscriptionId)/resourceGroups/$($Names.resourceGroup)/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$($Names.outboundIdentity)"
    $expectedSiteId = "/subscriptions/$($Inputs.SubscriptionId)/resourceGroups/$($Names.resourceGroup)/providers/Microsoft.Web/sites/$($Names.functionApp)"
    if ($identity['id'] -ine $expectedId -or $identity['tenantId'] -ine $Inputs.TenantId -or
        $site['id'] -ine $expectedSiteId -or
        $site['tags'] -isnot [Collections.IDictionary] -or $site.tags['managedBy'] -cne 'EPP-Setup' -or
        $site.tags['eppApplicationId'] -ine $Inputs.ApplicationId) {
        throw 'The existing Function or outbound identity does not match this deployment. No federation was changed.'
    }
    $clientId = ConvertTo-EppGuid $identity['clientId']
    $principalId = ConvertTo-EppGuid $identity['principalId']
    $assigned = $site['identity']
    if ($assigned -isnot [Collections.IDictionary] -or $assigned['userAssignedIdentities'] -isnot [Collections.IDictionary]) {
        throw 'The setup-owned outbound identity is not attached to the Function. Inspect the approved identity assignment before rerunning setup.'
    }
    $identityKeys = @($assigned.userAssignedIdentities.Keys | Where-Object { $_ -ieq $identity['id'] })
    if ($identityKeys.Count -ne 1) { throw 'The setup-owned outbound identity is not attached to the Function.' }
    $attached = $assigned.userAssignedIdentities[$identityKeys[0]]
    if ($attached['clientId'] -ine $clientId -or $attached['principalId'] -ine $principalId) {
        throw 'Function identity assignment differs from the managed identity readback.'
    }
    [pscustomobject]@{ ResourceId = $identity['id']; ClientId = $clientId; PrincipalId = $principalId }
}

function Test-EppFederationTransientError {
    param([string] $Message)
    if ($Message -match '(?i)Authorization_RequestDenied|AuthorizationFailed|Forbidden|\b40[13]\b') { return $false }
    return $Message -match '(?i)\b(429|500|502|503|504)\b|TooManyRequests|ServiceUnavailable|GatewayTimeout|InternalServerError|Request_ResourceNotFound|Request_Timeout|timed out|temporarily unavailable'
}

function Ensure-EppOutboundFederation {
    param([hashtable] $Inputs, [string] $ApplicationObjectId, [string] $FunctionAppName, $Identity)

    $applicationId = ConvertTo-EppGuid $ApplicationObjectId
    $subject = ConvertTo-EppGuid $Identity.PrincipalId
    $issuer = "https://login.microsoftonline.com/$(ConvertTo-EppGuid $Inputs.TenantId)/v2.0"
    $audience = 'api://AzureADTokenExchange'
    $baseName = "epp-$FunctionAppName-outbound"
    $path = "/v1.0/applications/$applicationId/federatedIdentityCredentials"
    $createAttempts = 0
    $created = $false
    $lastCreateAttempt = -3

    for ($attempt = 0; $attempt -lt 8; $attempt++) {
        try {
            $credentials = @(Get-EppGraphCollection -Inputs $Inputs -Path $path)
            $matching = @($credentials | Where-Object {
                $_.issuer -ceq $issuer -and $_.subject -ceq $subject -and
                @($_.audiences).Count -eq 1 -and $_.audiences[0] -ceq $audience
            })
            if ($matching.Count) {
                $credential = $matching[0]
                $id = ConvertTo-EppGuid $credential.id
                return [pscustomobject]@{
                    applicationObjectId = $applicationId
                    identityResourceId = $Identity.ResourceId
                    identityClientId = $Identity.ClientId
                    identityPrincipalId = $subject
                    credentialId = $id
                    credentialName = $credential.name
                    issuer = $issuer
                    subject = $subject
                    audiences = @($audience)
                    action = if ($created) { 'created' } else { 'reused' }
                    verifiedAtUtc = [DateTime]::UtcNow.ToString('o')
                }
            }
            if (@($credentials | Where-Object { $_.issuer -ceq $issuer -and $_.subject -ceq $subject }).Count) {
                throw 'This identity already has a trust with a different audience. Existing trusts are preserved; an administrator must review that conflict.'
            }
            $name = $baseName
            if (@($credentials | Where-Object name -eq $name).Count) {
                # Recreated identities must not retarget a trust still used by another deployment.
                $name = "$baseName-$($subject.Replace('-', ''))"
                if (@($credentials | Where-Object name -eq $name).Count) {
                    throw 'Both deployment-owned credential names are occupied by different trusts. No existing trust was overwritten.'
                }
            }
            if ($credentials.Count -ge 20) {
                throw 'The application has reached its federated-credential limit. An administrator must retire an unused trust; setup will not delete one automatically.'
            }
            # Re-list before every write, including after a lost response. A stable name makes
            # concurrent creation conflict rather than produce duplicate credentials.
            if ($createAttempts -lt 2 -and $attempt - $lastCreateAttempt -ge 3) {
                $createAttempts++
                $lastCreateAttempt = $attempt
                try {
                    $result = New-EppFederatedCredential -Inputs $Inputs -ObjectId $applicationId -Credential @{
                        name = $name; issuer = $issuer; subject = $subject; audiences = @($audience)
                    }
                    $created = $true
                    if ($result -isnot [Collections.IDictionary] -or
                        $result['issuer'] -cne $issuer -or $result['subject'] -cne $subject -or
                        @($result['audiences']).Count -ne 1 -or $result.audiences[0] -cne $audience) {
                        throw 'Federated-credential creation returned an unexpected trust. No deployment completion was recorded.'
                    }
                    $null = ConvertTo-EppGuid $result['id']
                }
                catch {
                    if ($_.Exception.Message -match '(?i)Authorization_RequestDenied|AuthorizationFailed|Forbidden|\b40[13]\b') { throw }
                    if (-not (Test-EppFederationTransientError $_.Exception.Message) -and
                        $_.Exception.Message -notmatch '(?i)\b409\b|Request_MultipleObjectsWithSameKeyValue|Conflict|federated.{0,200}already exists|Azure CLI returned an empty directory response') { throw }
                }
            }
        }
        catch {
            if (-not (Test-EppFederationTransientError $_.Exception.Message)) { throw }
        }
        if ($attempt -lt 7) {
            Write-Host "Waiting for outbound application federation ($($attempt + 1)/8)..."
            Start-Sleep -Seconds ([Math]::Min(30, 2 * [Math]::Pow(2, $attempt)))
        }
    }
    throw 'Outbound federation is not yet confirmed after bounded recovery. Setup is not complete. This federation step does not delete trusts or change certificates. Review saved deployment and certificate state, resolve access or propagation issues, and rerun setup with the same tenant, subscription, application and prefix.'
}

function Assert-EppOutboundSettings {
    param([hashtable] $Inputs, [Collections.IDictionary] $Names, $Identity)

    $settings = Invoke-EppAz functionapp config appsettings list --subscription $Inputs.SubscriptionId `
        --resource-group $Names.resourceGroup --name $Names.functionApp `
        --query "[?name=='EPP_PROVIDER_AUTH_MODE' || name=='EPP_OUTBOUND_CLIENT_ID' || name=='EPP_OUTBOUND_MI_CLIENT_ID']" `
        --output json | ConvertFrom-Json -AsHashtable -NoEnumerate
    $values = @{}
    foreach ($setting in $settings) { $values[$setting.name] = $setting.value }
    if ($values['EPP_PROVIDER_AUTH_MODE'] -cne 'oauth') {
        throw 'The Function authentication mode does not match the approved OAuth configuration. No provider mode was changed.'
    }
    if ($values['EPP_OUTBOUND_CLIENT_ID'] -ieq $Inputs.ApplicationId -and
        $values['EPP_OUTBOUND_MI_CLIENT_ID'] -ieq $Identity.ClientId) { return }
    throw 'Function outbound application/identity settings do not match the approved deployment. No federation was changed.'
}

function Initialize-EppOutboundFederation {
    param([hashtable] $Inputs, [Collections.IDictionary] $Names, $Context, $Outputs, [string] $OutputDirectory)

    if ($Inputs.ProviderAuthentication -ne 'oauth') { return }
    $application = Get-EppApplication -Inputs $Inputs -ObjectId $Context.Application.Id
    if ($application.AppId -ine $Inputs.ApplicationId -or $application.SignInAudience -cne 'AzureADMultipleOrgs') {
        throw 'The application changed after preflight. No federation was changed.'
    }
    $identity = Get-EppOutboundIdentity -Inputs $Inputs -Names $Names
    if ($identity.PrincipalId -ine $Outputs.outboundPrincipalId.value) { throw 'Deployment and live outbound identity disagree.' }
    Assert-EppOutboundSettings -Inputs $Inputs -Names $Names -Identity $identity
    $federation = Ensure-EppOutboundFederation -Inputs $Inputs -ApplicationObjectId $application.Id -FunctionAppName $Names.functionApp -Identity $identity
    Save-EppOutboundFederation -Inputs $Inputs -Names $Names -Federation $federation -OutputDirectory $OutputDirectory
    return $federation
}

function Save-EppOutboundFederation {
    param([hashtable] $Inputs, [Collections.IDictionary] $Names, $Federation, [string] $OutputDirectory)

    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    $path = Join-Path $OutputDirectory "federation-$($Names.functionApp).json"
    @{
        tenantId = $Inputs.TenantId; subscriptionId = $Inputs.SubscriptionId
        applicationId = $Inputs.ApplicationId; resourcePrefix = $Inputs.ResourcePrefix
        outboundFederation = $Federation
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $path -Encoding utf8NoBOM
    Write-Host "Outbound federation verified: $($Federation.credentialName). Details: $path"
}
