#Requires -Version 7.0
# A deliberately small, data-only ARM expression reader. No Invoke-Expression, Azure SDK,
# schema downloads or deployment engine. Unknown expressions/references fail closed.

function Split-ArmArguments {
    param([string] $Text)
    $parts = [Collections.Generic.List[string]]::new()
    $depth = 0; $quoted = $false; $start = 0
    for ($index = 0; $index -lt $Text.Length; $index++) {
        $character = $Text[$index]
        if ($character -eq "'") {
            if ($quoted -and $index + 1 -lt $Text.Length -and $Text[$index + 1] -eq "'") { $index++; continue }
            $quoted = -not $quoted
        }
        elseif (-not $quoted) {
            if ($character -in @('(', '[')) { $depth++ }
            elseif ($character -in @(')', ']')) { $depth-- }
            elseif ($character -eq ',' -and $depth -eq 0) { $parts.Add($Text.Substring($start, $index - $start).Trim()); $start = $index + 1 }
        }
    }
    if ($quoted -or $depth -ne 0) { throw '[ARM-TEST] Unbalanced expression.' }
    if ($Text.Trim()) { $parts.Add($Text.Substring($start).Trim()) }
    return ,$parts.ToArray()
}

function Merge-ArmObjects {
    param([Collections.IDictionary] $Left, [Collections.IDictionary] $Right)
    $merged = @{} + $Left
    foreach ($key in $Right.Keys) {
        $merged[$key] = if ($merged.ContainsKey($key) -and $merged[$key] -is [Collections.IDictionary] -and
            $Right[$key] -is [Collections.IDictionary]) { Merge-ArmObjects $merged[$key] $Right[$key] } else { $Right[$key] }
    }
    return $merged
}

function Resolve-ArmTestValue {
    param($Value, [hashtable] $Context, [int] $Depth = 0)
    if ($Depth -gt 80) { throw '[ARM-TEST] Cyclic or excessively deep expression.' }
    if ($Value -is [Collections.IDictionary]) {
        $result = @{}
        foreach ($key in $Value.Keys) { $result[$key] = Resolve-ArmTestValue $Value[$key] $Context ($Depth + 1) }
        return $result
    }
    if ($Value -is [Collections.IList]) {
        return ,@(foreach ($item in $Value) { Resolve-ArmTestValue $item $Context ($Depth + 1) })
    }
    if ($Value -is [string] -and $Value.StartsWith('[') -and $Value.EndsWith(']')) {
        return ,(Resolve-ArmTestExpression $Value.Substring(1, $Value.Length - 2) $Context ($Depth + 1))
    }
    return ,$Value
}

function Resolve-ArmTestExpression {
    param([string] $Text, [hashtable] $Context, [int] $Depth = 0)
    if ($Depth -gt 80) { throw '[ARM-TEST] Cyclic or excessively deep expression.' }
    $text = $Text.Trim()
    if ($text -match "^'(?:[^']|'')*'$") { return $text.Substring(1, $text.Length - 2).Replace("''", "'") }
    if ($text -match '^-?[0-9]+$') { return [int]$text }
    if ($text -notmatch '^([a-zA-Z][a-zA-Z0-9]*)\(') { throw "[ARM-TEST] Unsupported expression: $text" }
    $name = $Matches[1].ToLowerInvariant()
    $open = $text.IndexOf('('); $level = 1; $quoted = $false; $close = -1
    for ($index = $open + 1; $index -lt $text.Length; $index++) {
        $character = $text[$index]
        if ($character -eq "'") {
            if ($quoted -and $index + 1 -lt $text.Length -and $text[$index + 1] -eq "'") { $index++; continue }
            $quoted = -not $quoted
        }
        elseif (-not $quoted) {
            if ($character -eq '(') { $level++ }
            elseif ($character -eq ')') { $level--; if ($level -eq 0) { $close = $index; break } }
        }
    }
    if ($close -lt 0) { throw '[ARM-TEST] Missing closing parenthesis.' }
    $arguments = Split-ArmArguments $text.Substring($open + 1, $close - $open - 1)
    if ($name -eq 'if') {
        if ($arguments.Count -ne 3) { throw '[ARM-TEST] if requires three arguments.' }
        $choice = if (Resolve-ArmTestExpression $arguments[0] $Context ($Depth + 1)) { 1 } else { 2 }
        $result = Resolve-ArmTestExpression $arguments[$choice] $Context ($Depth + 1)
    }
    else {
        $values = [Collections.Generic.List[object]]::new()
        foreach ($argument in $arguments) { $values.Add((Resolve-ArmTestExpression $argument $Context ($Depth + 1))) }
        $result = switch ($name) {
            'parameters' {
                if (-not $Context.Parameters.Contains($values[0])) { throw "[ARM-TEST] Unbound parameter '$($values[0])'." }
                $Context.Parameters[$values[0]]
            }
            'variables' {
                if (-not $Context.Template.variables.Contains($values[0])) { throw "[ARM-TEST] Unbound variable '$($values[0])'." }
                Resolve-ArmTestValue $Context.Template.variables[$values[0]] $Context ($Depth + 1)
            }
            'equals' { $values[0] -ceq $values[1] }
            'not' { -not $values[0] }
            'true' { $true }
            'false' { $false }
            'contains' { $values[0].Contains($values[1]) }
            'json' { ConvertFrom-Json -InputObject $values[0] -AsHashtable }
            'format' { [string]::Format([Globalization.CultureInfo]::InvariantCulture, [string]$values[0], [object[]]$values.ToArray()[1..($values.Count - 1)]) }
            'concat' { $values.ToArray() -join '' }
            'createobject' {
                $object = @{}
                for ($item = 0; $item -lt $values.Count; $item += 2) { $object[$values[$item]] = $values[$item + 1] }
                $object
            }
            'union' {
                $object = @{}
                foreach ($value in $values) {
                    if ($value -isnot [Collections.IDictionary]) { throw '[ARM-TEST] Only object unions are supported.' }
                    $object = Merge-ArmObjects $object $value
                }
                $object
            }
            'resourceid' {
                $segments = ([string]$values[0]).Split('/')
                if ($values.Count -ne $segments.Count) { throw '[ARM-TEST] Unsupported resourceId overload.' }
                $id = "/subscriptions/$selectedSubscription/resourceGroups/cyot-offline-rg/providers/$($segments[0])"
                for ($item = 1; $item -lt $segments.Count; $item++) { $id += "/$($segments[$item])/$($values[$item])" }
                $id
            }
            'subscriptionresourceid' { "/subscriptions/$selectedSubscription/providers/$($values[0])/$($values[1])" }
            'reference' {
                if (-not $Context.References.ContainsKey($values[0])) { throw "[ARM-TEST] Unmocked ARM reference '$($values[0])'." }
                $Context.ReferenceCalls.Add([string]$values[0])
                $Context.References[$values[0]]
            }
            'guid' {
                # Assert the exact principal/scope/role passed to ARM's deterministic GUID function,
                # rather than duplicating ARM's UUID implementation in the test harness.
                $Context.GuidCalls.Add($values.ToArray())
                'symbolic-arm-guid'
            }
            default { throw "[ARM-TEST] Unsupported ARM function '$name'." }
        }
    }
    $suffix = $text.Substring($close + 1)
    while ($suffix) {
        if ($suffix -notmatch '^\.([a-zA-Z_][a-zA-Z0-9_]*)') { throw "[ARM-TEST] Unsupported property selector: $suffix" }
        $property = $Matches[1]
        if ($result -isnot [Collections.IDictionary] -or -not $result.Contains($property)) { throw "[ARM-TEST] Missing property '$property'." }
        $result = $result[$property]
        $suffix = $suffix.Substring($Matches[0].Length)
    }
    return ,$result
}

function Read-ArmContract {
    param([string] $Leaf)
    $path = Join-Path (Split-Path -Parent $ScriptAsts[$step2].Extent.File) "arm\$Leaf"
    Assert-True (Test-Path -LiteralPath $path -PathType Leaf) "package the separate arm\$Leaf alongside Step2"
    $document = [IO.File]::ReadAllText($path) | ConvertFrom-Json -AsHashtable
    Assert-Equal $document.'$schema' 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#' 'use a standard external ARM deployment template'
    return $document
}

function New-ArmContractContext {
    param($Template, [string] $Plan = 'FlexConsumption', [int] $TokenVersion = 1)
    $prefix = "/subscriptions/$selectedSubscription/resourceGroups/cyot-offline-rg/providers"
    $values = @{
        functionAppName = 'cyot-offline'; storageAccountName = 'cyotoffline'; keyVaultName = 'cyot-offline-vault'
        outboundIdentityName = 'cyot-outbound'; hostingPlanName = 'old-plan'; workspaceName = 'old-workspace'; location = 'westus2'
        deployerObjectId = '12121212-1212-4212-8212-121212121212'; tenantId = $customerTenant
        applicationId = '33333333-3333-4333-8333-333333333333'; planType = $Plan; tokenVersion = $TokenVersion; enableEasyAuth = $true
        tags = @{ Purpose = 'Entra - external = offline'; Owned = 'new' }; deploymentContainerName = 'old-releases'; contentShareName = 'old-content'
        existing = @{}; existingAppSettings = @{}; managedSettings = @{}
        applicationInsightsResourceId = "$prefix/Microsoft.Insights/components/cyot-offline"
        encryptionKeyId = 'abcdefab-1234-4123-8123-abcdefabcdef'
        decryptionSecretUri = 'https://cyot-offline-vault.vault.azure.net/secrets/phone-provider-decryption-key'
        contentStorageSecretUri = 'https://cyot-offline-vault.vault.azure.net/secrets/phone-provider-content-storage'
    }
    $parameters = @{}
    foreach ($name in $Template.parameters.Keys) {
        if ($values.ContainsKey($name)) { $parameters[$name] = $values[$name] }
        elseif ($Template.parameters[$name].Contains('defaultValue')) { $parameters[$name] = $Template.parameters[$name].defaultValue }
    }
    return @{
        Template = $Template; Parameters = $parameters
        References = @{
            "$prefix/Microsoft.Web/sites/cyot-offline" = @{ defaultHostName = 'actual-arm-host.example.invalid'; identity = @{ principalId = '66666666-6666-4666-8666-666666666666' } }
            "$prefix/Microsoft.Storage/storageAccounts/cyotoffline" = @{ primaryEndpoints = @{ blob = 'https://cyotoffline.blob.core.windows.net/' } }
            "$prefix/Microsoft.KeyVault/vaults/cyot-offline-vault" = @{ vaultUri = 'https://cyot-offline-vault.vault.azure.net/' }
            "$prefix/Microsoft.ManagedIdentity/userAssignedIdentities/cyot-outbound" = @{ clientId = '88888888-8888-4888-8888-888888888888'; principalId = '99999999-9999-4999-8999-999999999999' }
            "$prefix/Microsoft.Insights/components/cyot-offline" = @{ ConnectionString = 'synthetic-server-resolved-insights-connection' }
        }
        GuidCalls = [Collections.Generic.List[object]]::new(); ReferenceCalls = [Collections.Generic.List[string]]::new()
    }
}

function Get-ArmContractResource {
    param($Context, [string] $Type)
    $resources = @($Context.Template.resources | Where-Object {
        $_.type -eq $Type -and (-not $_.Contains('condition') -or (Resolve-ArmTestValue $_.condition $Context))
    })
    Assert-Equal $resources.Count 1 "exactly one enabled $Type resource"
    return $resources[0]
}

foreach ($expression in @("[invokeExternal('never-run')]", "[reference('https://unmocked.example.invalid')]")) {
    Invoke-OfflineTest "ARM expression reader refuses unmocked operations ($expression)" {
        $context = New-ArmContractContext @{ parameters = @{}; variables = @{} }
        Assert-Throws { Resolve-ArmTestValue $expression $context } -Pattern '\[ARM-TEST\].*(Unsupported|Unmocked)'
    }
}

foreach ($leaf in @('infrastructure.json', 'function-config.json')) {
    Invoke-OfflineTest "External ARM parameter/output contract ($leaf)" {
        $template = Read-ArmContract $leaf
        $types = if ($leaf -eq 'infrastructure.json') {
            @{ functionAppName = 'string'; storageAccountName = 'string'; keyVaultName = 'string'; outboundIdentityName = 'string'
                hostingPlanName = 'string'; workspaceName = 'string'; location = 'string'; deployerObjectId = 'string'; tenantId = 'string'
                applicationId = 'string'; planType = 'string'; tokenVersion = 'int'; enableEasyAuth = 'bool'; tags = 'object'
                deploymentContainerName = 'string'; contentShareName = 'string'; existing = 'object' }
        } else {
            @{ functionAppName = 'string'; planType = 'string'; storageAccountName = 'string'; applicationInsightsResourceId = 'string'
                encryptionKeyId = 'string'; decryptionSecretUri = 'string'; contentShareName = 'string'; contentStorageSecretUri = 'string'
                managedSettings = 'object'; existingAppSettings = 'secureObject' }
        }
        Assert-Sequence @($template.parameters.Keys | Sort-Object) @($types.Keys | Sort-Object) 'exact documented parameter surface, without private keys or storage-key inputs'
        foreach ($name in $types.Keys) { Assert-True ($template.parameters[$name].type -eq $types[$name]) "ARM type of $name" }
        Assert-Sequence $template.parameters.planType.allowedValues @('FlexConsumption', 'Premium') 'supported plan choices'
        $outputs = @('functionAppResourceId')
        if ($leaf -eq 'infrastructure.json') {
            Assert-Sequence $template.parameters.tokenVersion.allowedValues @(1, 2) 'supported token versions'
            Assert-True $template.parameters.enableEasyAuth.defaultValue 'Easy Auth is enabled by default'
            Assert-Equal $template.parameters.deploymentContainerName.defaultValue 'function-releases' 'default deployment container'
            Assert-Equal $template.parameters.contentShareName.defaultValue 'function-content' 'default Premium content share'
            $outputs += @('defaultHostName', 'systemAssignedPrincipalId', 'outboundIdentityResourceId', 'outboundIdentityClientId',
                'outboundIdentityPrincipalId', 'storageAccountResourceId', 'keyVaultResourceId', 'keyVaultUri', 'applicationInsightsResourceId',
                'deploymentContainerName', 'contentShareName', 'contentStorageSecretName', 'planType')
        }
        else {
            Assert-Equal $template.parameters.contentShareName.defaultValue '' 'Flex needs no content share'
            Assert-Equal $template.parameters.contentStorageSecretUri.defaultValue '' 'Flex needs no content connection secret'
        }
        Assert-Sequence @($template.outputs.Keys | Sort-Object) @($outputs | Sort-Object) 'only nonsecret identifiers/URIs leave ARM'
        foreach ($output in $template.outputs.Values) { Assert-True ($output.type -eq 'string') 'never return settings, keys or secure output objects' }
        Assert-True (-not ((ConvertTo-Json -InputObject $template -Depth 100) -match '(?i)listKeys\(|BEGIN PRIVATE KEY|AccountKey=')) 'ARM must not handle plaintext private keys or content-storage keys'
        $documents = @($template) + @($template.resources | Where-Object {
            $_.type -eq 'Microsoft.Resources/deployments'
        } | ForEach-Object { $_.properties.template })
        foreach ($document in $documents) {
            if ($document.Contains('variables')) {
                Assert-True (-not ((ConvertTo-Json -InputObject $document.variables -Depth 100) -match '(?i)\breference\s*\(')) (
                    'runtime reference() calls belong in resource properties/outputs, never template variables')
            }
        }
    }
}

foreach ($plan in @('FlexConsumption', 'Premium')) {
    Invoke-OfflineTest "ARM infrastructure resources, identity, monitoring and adoption ($plan)" {
        $context = New-ArmContractContext (Read-ArmContract 'infrastructure.json') $plan
        $existing = @{ tags = @{}; locations = @{ workspace = 'eastus'; vault = 'centralus' }; userAssignedIdentities = @{ unrelated = @{} }
            siteConfig = @{ http20Enabled = $true; minTlsVersion = '1.0' }; siteProperties = @{ clientAffinityEnabled = $false; httpsOnly = $false }
            storageProperties = @{ publicNetworkAccess = 'Disabled'; allowSharedKeyAccess = $true; supportsHttpsTrafficOnly = $false; allowBlobPublicAccess = $true }
            vaultProperties = @{ enablePurgeProtection = $true; enableRbacAuthorization = $false }; planProperties = @{ perSiteScaling = $true }
            workspaceProperties = @{ publicNetworkAccessForQuery = 'Disabled' }
            insightsProperties = @{ SamplingPercentage = 50; DisableLocalAuth = $false; WorkspaceResourceId = 'wrong-workspace' } }
        foreach ($key in @('storage', 'vault', 'plan', 'workspace', 'insights', 'outboundIdentity', 'function')) {
            $existing.tags[$key] = @{ UNRELATED = 'keep'; Owned = 'old' }
        }
        $context.Parameters.existing = $existing
        Assert-Equal @($context.Template.resources | Where-Object type -eq 'Microsoft.Web/sites').Count 1 'one top-level Function resource owns the site properties'
        foreach ($child in $context.Template.resources | Where-Object type -eq 'Microsoft.Web/sites/config') {
            Assert-True (-not (Resolve-ArmTestValue $child.name $context).EndsWith('/appsettings')) 'infrastructure must not emit an appsettings child'
        }
        foreach ($entry in @{
            'Microsoft.Storage/storageAccounts' = 'storage'; 'Microsoft.KeyVault/vaults' = 'vault'; 'Microsoft.Web/serverfarms' = 'plan'
            'Microsoft.OperationalInsights/workspaces' = 'workspace'; 'Microsoft.Insights/components' = 'insights'
            'Microsoft.ManagedIdentity/userAssignedIdentities' = 'outboundIdentity'; 'Microsoft.Web/sites' = 'function'
        }.GetEnumerator()) {
            $resource = Get-ArmContractResource $context $entry.Key
            $tags = Resolve-ArmTestValue $resource.tags $context
            Assert-Equal $tags.UNRELATED 'keep' 'adopt unrelated tags'
            Assert-Equal $tags.Owned 'new' 'managed tags take precedence'
            Assert-Equal $tags.Purpose 'Entra - external = offline' 'tag values retain spaces and equals signs in resource JSON'
            $expectedLocation = if ($existing.locations.ContainsKey($entry.Value)) { $existing.locations[$entry.Value] } else { $context.Parameters.location }
            Assert-Equal (Resolve-ArmTestValue $resource.location $context) $expectedLocation 'preserve an existing per-resource location, otherwise use the supplied default'
        }
        $storage = Resolve-ArmTestValue (Get-ArmContractResource $context 'Microsoft.Storage/storageAccounts').properties $context
        Assert-True $storage.supportsHttpsTrafficOnly 'HTTPS-only storage'
        Assert-Equal $storage.minimumTlsVersion 'TLS1_2' 'minimum storage TLS'
        Assert-True (-not $storage.allowBlobPublicAccess) 'no public blobs'
        Assert-Equal $storage.publicNetworkAccess 'Disabled' 'retain supported storage network settings'
        $vault = Resolve-ArmTestValue (Get-ArmContractResource $context 'Microsoft.KeyVault/vaults').properties $context
        Assert-True $vault.enableRbacAuthorization 'vault uses Azure RBAC'
        Assert-Equal $vault.tenantId $customerTenant 'vault belongs to the customer tenant'
        Assert-True $vault.enablePurgeProtection 'retain existing purge protection'
        $insights = Resolve-ArmTestValue (Get-ArmContractResource $context 'Microsoft.Insights/components').properties $context
        Assert-True ($insights.DisableLocalAuth -is [bool] -and $insights.DisableLocalAuth) 'Application Insights disables local-key authentication'
        Assert-Equal $insights.Application_Type 'web' 'web Application Insights component'
        Assert-True $insights.WorkspaceResourceId.EndsWith('/old-workspace') 'link the resolved/adopted workspace'
        Assert-Equal $insights.SamplingPercentage 50 'retain supported monitoring customization'
        $site = Get-ArmContractResource $context 'Microsoft.Web/sites'
        $properties = Resolve-ArmTestValue $site.properties $context
        $identity = Resolve-ArmTestValue $site.identity $context
        Assert-True ($identity.type -match 'SystemAssigned' -and $identity.type -match 'UserAssigned') 'both system and outbound managed identities'
        Assert-True $identity.userAssignedIdentities.Contains('unrelated') 'retain unrelated identities'
        Assert-True (@($identity.userAssignedIdentities.Keys | Where-Object { $_ -like '*/cyot-outbound' }).Count -eq 1) 'attach the outbound identity'
        Assert-True $properties.httpsOnly 'Function requires HTTPS'
        Assert-Equal $properties.keyVaultReferenceIdentity 'SystemAssigned' 'private-key references use the system identity'
        Assert-True $properties.siteConfig.http20Enabled 'retain supported existing siteConfig'
        Assert-Equal $properties.siteConfig.minTlsVersion '1.2' 'required TLS settings override the adopted snapshot'
        Assert-True (-not $properties.clientAffinityEnabled) 'retain supported site properties'
        Assert-True (-not $properties.siteConfig.Contains('appSettings')) 'infra must not race/replace configuration-phase settings'
        $sku = Resolve-ArmTestValue (Get-ArmContractResource $context 'Microsoft.Web/serverfarms').sku $context
        Assert-Equal $sku.name $(if ($plan -eq 'Premium') { 'EP1' } else { 'FC1' }) 'correct hosting SKU'
        if ($plan -eq 'FlexConsumption') {
            $container = Get-ArmContractResource $context 'Microsoft.Storage/storageAccounts/blobServices/containers'
            Assert-True (Resolve-ArmTestValue $container.name $context).EndsWith('/old-releases') 'adopt the existing deployment container name'
            Assert-Equal $container.properties.publicAccess 'None' 'private deployment container'
            Assert-Equal $properties.functionAppConfig.runtime.name 'node' 'Flex runtime'
            Assert-Equal $properties.functionAppConfig.runtime.version '24' 'Flex Node 24'
            Assert-Equal $properties.functionAppConfig.scaleAndConcurrency.alwaysReady[0].name 'http' 'always-ready HTTP group'
            Assert-Equal $properties.functionAppConfig.scaleAndConcurrency.alwaysReady[0].instanceCount 1 'one always-ready HTTP instance'
            Assert-Equal $properties.functionAppConfig.deployment.storage.authentication.type 'SystemAssignedIdentity' 'identity-based deployment storage'
        }
        else {
            Assert-True (-not $properties.Contains('functionAppConfig')) 'Premium must not receive Flex functionAppConfig'
            $share = Get-ArmContractResource $context 'Microsoft.Storage/storageAccounts/fileServices/shares'
            Assert-True (Resolve-ArmTestValue $share.name $context).EndsWith('/old-content') 'precreate the adopted Premium content share'
            Assert-Equal $properties.siteConfig.linuxFxVersion 'NODE|24' 'Premium Node 24'
        }
        $outputs = @{}
        foreach ($name in $context.Template.outputs.Keys) { $outputs[$name] = Resolve-ArmTestValue $context.Template.outputs[$name].value $context }
        Assert-Equal $outputs.defaultHostName 'actual-arm-host.example.invalid' 'return the actual host from reference(), not a guessed hostname'
        Assert-Equal $outputs.systemAssignedPrincipalId '66666666-6666-4666-8666-666666666666' 'return the created Function principal'
        Assert-Equal $outputs.outboundIdentityClientId '88888888-8888-4888-8888-888888888888' 'return the actual outbound client ID'
        Assert-Equal $outputs.outboundIdentityPrincipalId '99999999-9999-4999-8999-999999999999' 'return the actual outbound principal'
        Assert-Equal $outputs.contentShareName $(if ($plan -eq 'Premium') { 'old-content' } else { '' }) 'no content-share setting for Flex'
        Assert-Equal $outputs.contentStorageSecretName $(if ($plan -eq 'Premium') { 'phone-provider-content-storage' } else { '' }) 'only Premium requests the content secret'
    }
    foreach ($version in @(1, 2)) {
        Invoke-OfflineTest "ARM Easy Auth is fail-closed and pins issuer/audience/caller ($plan token v$version)" {
            $context = New-ArmContractContext (Read-ArmContract 'infrastructure.json') $plan $version
            $auth = Get-ArmContractResource $context 'Microsoft.Web/sites/config'
            Assert-True (Resolve-ArmTestValue $auth.name $context).EndsWith('/authsettingsV2') 'configure Easy Auth, not application auth fallback'
            $properties = Resolve-ArmTestValue $auth.properties $context
            Assert-True $properties.platform.enabled 'enable Easy Auth'
            Assert-True $properties.globalValidation.requireAuthentication 'all requests require authentication'
            Assert-Equal $properties.globalValidation.unauthenticatedClientAction 'Return401' 'unauthenticated requests fail closed'
            Assert-Equal @($properties.globalValidation.excludedPaths).Count 0 'no unauthenticated path exclusions'
            Assert-True $properties.httpSettings.requireHttps 'require HTTPS at the authentication boundary'
            $aad = $properties.identityProviders.azureActiveDirectory
            Assert-Equal $aad.registration.clientId $context.Parameters.applicationId 'pin the registered endpoint application'
            Assert-Equal $aad.registration.openIdIssuer $(if ($version -eq 1) { "https://sts.windows.net/$customerTenant/" } else { "https://login.microsoftonline.com/$customerTenant/v2.0" }) 'explicit customer-tenant issuer'
            Assert-Sequence $aad.validation.allowedAudiences @($(if ($version -eq 1) { "api://actual-arm-host.example.invalid/$($context.Parameters.applicationId)" } else { $context.Parameters.applicationId })) 'exact endpoint audience'
            Assert-Sequence $aad.validation.defaultAuthorizationPolicy.allowedApplications @('25ec60fa-f18d-41a4-b398-50044c90ce13') 'nonempty fixed Microsoft EPP caller allowlist'
            $context.Parameters.enableEasyAuth = $false
            Assert-True (-not (Resolve-ArmTestValue $auth.condition $context)) 'the explicit opt-out skips the resource instead of disabling existing auth'
        }
    }
    Invoke-OfflineTest "ARM appsettings merge keeps unrelated values but required host settings win ($plan)" {
        $context = New-ArmContractContext (Read-ArmContract 'function-config.json') $plan
        Assert-Equal $context.Template.resources.Count 1 'configuration phase only writes the appsettings child resource'
        $resource = Get-ArmContractResource $context 'Microsoft.Web/sites/config'
        Assert-True (Resolve-ArmTestValue $resource.name $context).EndsWith('/appsettings') 'only the appsettings child is configured'
        $context.Parameters.existingAppSettings = @{ USER_KEEP = 'preserved-private-fixture'; OVERLAP = 'existing'
            AzureWebJobsStorage__accountName = 'wrong-storage'; APPLICATIONINSIGHTS_CONNECTION_STRING = 'wrong-existing-insights' }
        $context.Parameters.managedSettings = @{ OVERLAP = 'managed'; EPP_PROVIDER_NAME = 'provider'
            AzureWebJobsStorage__accountName = 'wrong-managed-storage'; AzureWebJobsStorage__credential = 'wrong-credential'
            APPLICATIONINSIGHTS_CONNECTION_STRING = 'wrong-managed-insights'; APPLICATIONINSIGHTS_AUTHENTICATION_STRING = 'wrong-auth'
            EPP_ENCRYPTION_KEY_ID = 'wrong-key-id'; EPP_DECRYPTION_KEY_PEM = 'wrong-private-key-reference' }
        if ($plan -eq 'Premium') {
            foreach ($name in $flexObsolete) {
                $context.Parameters.existingAppSettings[$name] = 'wrong-existing-host-value'
                $context.Parameters.managedSettings[$name] = 'wrong-managed-host-value'
            }
        }
        $settings = Resolve-ArmTestValue $resource.properties $context
        Assert-Equal $settings.USER_KEEP 'preserved-private-fixture' 'retain unrelated settings without logging or outputting them'
        Assert-Equal $settings.OVERLAP 'managed' 'managed settings override the matching existing value'
        Assert-Equal $settings.AzureWebJobsStorage__accountName 'cyotoffline' 'required storage settings override both inputs'
        Assert-Equal $settings.AzureWebJobsStorage__credential 'managedidentity' 'identity-based host storage'
        Assert-Equal $settings.APPLICATIONINSIGHTS_CONNECTION_STRING 'synthetic-server-resolved-insights-connection' 'resolve Insights server-side'
        Assert-True $context.ReferenceCalls.Contains($context.Parameters.applicationInsightsResourceId) 'connection string comes from a reference(), not a parameter'
        Assert-Equal $settings.APPLICATIONINSIGHTS_AUTHENTICATION_STRING 'Authorization=AAD' 'use AAD telemetry authentication'
        Assert-Equal $settings.EPP_ENCRYPTION_KEY_ID $context.Parameters.encryptionKeyId 'publish the actual encryption key ID'
        Assert-Equal $settings.EPP_DECRYPTION_KEY_PEM "@Microsoft.KeyVault(SecretUri=$($context.Parameters.decryptionSecretUri))" 'private-key value is only a Key Vault reference'
        foreach ($name in $commonObsolete) { Assert-True (-not $settings.ContainsKey($name)) "do not add obsolete $name" }
        if ($plan -eq 'FlexConsumption') {
            foreach ($name in $flexObsolete) { Assert-True (-not $settings.ContainsKey($name)) "Flex must not receive legacy $name" }
        }
        else {
            Assert-Equal $settings.FUNCTIONS_WORKER_RUNTIME 'node' 'Premium Node worker'
            Assert-Equal $settings.FUNCTIONS_EXTENSION_VERSION.TrimStart('~') '4' 'Premium Functions v4'
            Assert-Equal $settings.WEBSITE_NODE_DEFAULT_VERSION.TrimStart('~') '24' 'Premium Node 24'
            Assert-Equal $settings.WEBSITE_RUN_FROM_PACKAGE '1' 'Premium package deployment'
            Assert-Equal $settings.WEBSITE_CONTENTSHARE 'old-content' 'use the precreated content share'
            Assert-Equal $settings.WEBSITE_CONTENTAZUREFILECONNECTIONSTRING "@Microsoft.KeyVault(SecretUri=$($context.Parameters.contentStorageSecretUri))" 'content storage uses only a Key Vault connection-string reference'
            Assert-Equal $settings.WEBSITE_SKIP_CONTENTSHARE_VALIDATION '1' 'avoid plaintext-key validation when referencing the precreated share'
        }
        foreach ($value in $settings.Values) { Assert-True ($value -is [string]) 'application settings are string-valued' }
    }
}

foreach ($adopt in @($false, $true)) {
    Invoke-OfflineTest "ARM creates six scoped least-privilege roles using actual principals or adopted names (adopt=$adopt)" {
        $context = New-ArmContractContext (Read-ArmContract 'infrastructure.json')
        $roles = @{
            storageBlob = @('Microsoft.Storage/storageAccounts/cyotoffline', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe', 'ServicePrincipal')
            storageQueue = @('Microsoft.Storage/storageAccounts/cyotoffline', '974c5e8b-45b9-4653-ba55-5f855dd0fb88', 'ServicePrincipal')
            storageTable = @('Microsoft.Storage/storageAccounts/cyotoffline', '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3', 'ServicePrincipal')
            vaultReader = @('Microsoft.KeyVault/vaults/cyot-offline-vault', '4633458b-17de-408a-b874-0445c86b69e6', 'ServicePrincipal')
            vaultWriter = @('Microsoft.KeyVault/vaults/cyot-offline-vault', 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7', 'User')
            metricsPublisher = @('Microsoft.Insights/components/cyot-offline', '3913510d-42f4-4e42-8a64-420c390055eb', 'ServicePrincipal')
        }
        $oldNames = @{}
        $index = 0
        foreach ($key in $roles.Keys | Sort-Object) { $index++; $oldNames[$key] = "77777777-7777-4777-8777-$('{0:d12}' -f $index)" }
        $context.Parameters.existing = @{ roleAssignmentNames = $(if ($adopt) { $oldNames } else { @{} }) }
        $deployment = Get-ArmContractResource $context 'Microsoft.Resources/deployments'
        Assert-Equal $deployment.properties.mode 'Incremental' 'nested RBAC deployment must be incremental'
        Assert-True ($deployment.properties.expressionEvaluationOptions.scope -eq 'inner') 'bind runtime identities inside the nested deployment (ARM enum casing is not significant)'
        $nested = @{
            Template = $deployment.properties.template
            Parameters = @{}; References = $context.References
            GuidCalls = [Collections.Generic.List[object]]::new(); ReferenceCalls = [Collections.Generic.List[string]]::new()
        }
        foreach ($name in $deployment.properties.parameters.Keys) { $nested.Parameters[$name] = Resolve-ArmTestValue $deployment.properties.parameters[$name].value $context }
        Assert-Equal $nested.Template.resources.Count 6 'exactly six least-privilege role assignments'
        $seenRoles = @()
        foreach ($resource in $nested.Template.resources) {
            Assert-Equal $resource.type 'Microsoft.Authorization/roleAssignments' 'all nested resources are scoped roles'
            $properties = Resolve-ArmTestValue $resource.properties $nested
            $scope = Resolve-ArmTestValue $resource.scope $nested
            $roleId = ($properties.roleDefinitionId -split '/')[-1]
            $keys = @($roles.Keys | Where-Object { $roles[$_][1] -eq $roleId })
            Assert-Equal $keys.Count 1 'no broad, extra or unknown role is granted'
            $key = $keys[0]; $seenRoles += $roleId
            Assert-Equal $scope $roles[$key][0] 'scope assignments to the exact storage/vault/Insights resource'
            Assert-Equal $properties.principalType $roles[$key][2] 'use the proper principal type'
            $principal = if ($key -eq 'vaultWriter') { $context.Parameters.deployerObjectId } else { '66666666-6666-4666-8666-666666666666' }
            Assert-Equal $properties.principalId $principal 'use the actual deployed Function principal or selected deployer'
            $name = Resolve-ArmTestValue $resource.name $nested
            if ($adopt) { Assert-Equal $name $oldNames[$key] 'keep the old assignment name rather than creating a duplicate' }
            else {
                $guidInputs = $nested.GuidCalls[-1]
                Assert-Equal $guidInputs.Count 3 'new assignment GUID is based on scope, principal and role only'
                foreach ($expected in @("/subscriptions/$selectedSubscription/resourceGroups/cyot-offline-rg/providers/$scope", $principal, $roleId)) {
                    Assert-True ($guidInputs -contains $expected) 'GUID inputs must include actual scope, actual principal and exact role'
                }
            }
        }
        Assert-Equal @($seenRoles | Select-Object -Unique).Count 6 'no role is duplicated in place of another'
        Assert-Equal $nested.GuidCalls.Count $(if ($adopt) { 0 } else { 6 }) 'adopt old IDs without evaluating the new-ID branch'
    }
}
