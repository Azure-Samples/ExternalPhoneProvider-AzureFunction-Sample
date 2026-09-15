#Requires -Version 7.0
#Requires -Modules Microsoft.Graph.Authentication

<#
.SYNOPSIS
    Stage 3 of 3: check the live Graph contract, then explicitly activate/update CYOT when supported.
.DESCRIPTION
    Run only after app registration, provider purchase/onboarding, and resource provisioning
    have completed and the delivery endpoint has been tested.

    The design snapshot proposes authenticationMethodsPolicy.cyot { endpoint, appId, migrated }.
    Live public v1.0 and beta metadata checked on 2026-09-14 DID NOT expose that contract. Therefore
    this script intentionally refuses a policy write unless a fresh metadata check exposes the
    exact supported shape. There is no bypass switch or guessed fallback to externalAuthenticationMethod.
    A private-preview contract must be confirmed with CCE/Graph if it differs.

    When supported, sign in to the explicitly selected customer tenant with
    Policy.ReadWrite.AuthenticationMethod. Authentication Policy Administrator is the least
    privileged supported Entra role. Only the cyot property is patched; no SMS/Voice target lists,
    authentication-method states or other policy fields are sent. Save the previous CYOT value,
    confirm the operation, detect a changed policy before writing and verify the result afterwards.
    This file is self-contained; it does not load or invoke any other setup script.
    Only PowerShell and the Microsoft Graph authentication module are required.
.PARAMETER CheckSchemaOnly
    Read public Graph metadata and report capability without sign-in, input prompts, backups or writes.
.PARAMETER GraphApiVersion
    Public Graph API version to inspect and use. Defaults to beta. No preview URL is invented.
.PARAMETER TenantId
    Customer tenant from stages 1 and 2. Required only when the metadata contract is supported.
.PARAMETER ApplicationId
    Customer application CLIENT ID returned by stage 1 and reused in stage 2.
.PARAMETER EndpointUrl
    Validated delivery endpoint returned by stage 2.
.PARAMETER Migrated
    Required explicit path selector from the design: true for migration from native telephony,
    false for a new CYOT-only tenant. If omitted, ask at the policy-update step; do not default to live.
.PARAMETER BackupPath
    Optional new JSON path for the previous CYOT value. Existing files are never overwritten.
    Otherwise a unique timestamped file is written next to this script, only after approval.
.EXAMPLE
    .\Step3-Set-CyotPolicy.ps1 -CheckSchemaOnly
.EXAMPLE
    .\Step3-Set-CyotPolicy.ps1 -TenantId <customer-tenant-id> -ApplicationId <stage-1-client-id> -EndpointUrl https://contoso-otp.azurewebsites.net/api/SendOtp -Migrated $true
#>
[CmdletBinding()]
param(
    [string] $TenantId,
    [string] $ApplicationId,
    [string] $EndpointUrl,
    [Nullable[bool]] $Migrated,
    [ValidateSet('beta', 'v1.0')]
    [string] $GraphApiVersion = 'beta',
    [string] $BackupPath,
    [switch] $CheckSchemaOnly,
    [switch] $NonInteractive,
    [switch] $ApprovePolicyActivation
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$script:AzureCliContext = $null
$script:GraphTenantId = $TenantId
$script:GraphAccountName = $null
$script:GraphRequiredScopes = @('Policy.ReadWrite.AuthenticationMethod')

function Write-Step { param([string] $Text) Write-Host "`n=== $Text ===" -ForegroundColor Cyan }

function Read-SetupValue {
    param(
        [string] $Name,
        $DefaultValue,
        [switch] $Required,
        [ValidateSet('String', 'Integer', 'Choice', 'Boolean', 'File', 'HttpsUrl', 'Url', 'StorageName', 'VaultName', 'Guid', 'Scope')]
        [string] $ValueType = 'String',
        [string[]] $Choices = @(),
        [string] $Hint,
        [switch] $Secret
    )

    $needsInput = $Required -and
        ($null -eq $DefaultValue -or [string]::IsNullOrWhiteSpace("$DefaultValue"))
    while ($true) {
        $value = $DefaultValue
        if ($needsInput -and -not $NonInteractive) {
            $prompt = "$Name [required]"
            if ($Hint) { $prompt += " - $Hint" }
            if ($Choices.Count) { $prompt += " ($($Choices -join ' / '))" }

            if ($Secret) {
                $secureValue = Read-Host -Prompt $prompt -AsSecureString
                $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureValue)
                try { $answer = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
                finally {
                    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
                    $secureValue.Dispose()
                }
            }
            else { $answer = Read-Host -Prompt $prompt }
            if (-not [string]::IsNullOrWhiteSpace($answer)) { $value = $answer.Trim() }
        }

        $errorText = $null
        if ($null -eq $value -or [string]::IsNullOrWhiteSpace("$value")) {
            if ($Required) { $errorText = "-$Name is required." }
            else { return $null }
        }
        else {
            switch ($ValueType) {
                'Integer' {
                    $number = 0
                    if (-not [int]::TryParse("$value", [ref] $number) -or $number -lt 0) {
                        $errorText = "-$Name must be a whole number from 0 to $([int]::MaxValue)."
                    }
                    else { $value = $number }
                }
                'Guid' {
                    $identifier = [Guid]::Empty
                    if (-not [Guid]::TryParse("$value", [ref] $identifier) -or $identifier -eq [Guid]::Empty) {
                        $errorText = "-$Name must be a nonempty GUID."
                    }
                    else { $value = $identifier.ToString('D') }
                }
                'Scope' {
                    $resource = "$value" -replace '/\.default$', ''
                    $resourceId = [Guid]::Empty
                    $resourceUri = $null
                    $isGuid = [Guid]::TryParse($resource, [ref] $resourceId)
                    $isUri = [Uri]::TryCreate($resource, [UriKind]::Absolute, [ref] $resourceUri)
                    if ("$value" -notmatch '/\.default$' -or
                        ($isGuid -and $resourceId -eq [Guid]::Empty) -or
                        (-not $isGuid -and (-not $isUri -or $resourceUri.Scheme -notin @('api', 'https') -or
                            $resourceUri.Query -or $resourceUri.Fragment -or $resourceUri.UserInfo -or -not $resourceUri.Host)) -or
                        "$value" -match '\s') {
                        $errorText = "-$Name must be the provider API's App ID URI or application ID followed by /.default."
                    }
                }
                'Boolean' {
                    if ("$value" -match '^(?i:y|yes|true)$') { $value = $true }
                    elseif ("$value" -match '^(?i:n|no|false)$') { $value = $false }
                    else { $errorText = "-$Name must be Yes or No." }
                }
                'Choice' {
                    if ($Choices -notcontains "$value") { $errorText = "-$Name must be one of: $($Choices -join ', ')." }
                    else { $value = $Choices | Where-Object { $_ -eq "$value" } | Select-Object -First 1 }
                }
                'File' {
                    if (-not (Test-Path -LiteralPath "$value" -PathType Leaf)) { $errorText = "-$Name must point to an existing file." }
                }
                { $_ -in @('HttpsUrl', 'Url') } {
                    $parsedUri = $null
                    if (-not [Uri]::TryCreate("$value", [UriKind]::Absolute, [ref] $parsedUri) -or
                        $parsedUri.Scheme -notin @('http', 'https') -or
                        ($ValueType -eq 'HttpsUrl' -and $parsedUri.Scheme -ne 'https')) {
                        $errorText = "-$Name must be an absolute $($ValueType -eq 'HttpsUrl' ? 'HTTPS' : 'HTTP or HTTPS') URL."
                    }
                }
                'StorageName' {
                    if ("$value" -cnotmatch '^[a-z0-9]{3,24}$') { $errorText = '-StorageAccountName must be 3-24 lowercase letters or digits.' }
                }
                'VaultName' {
                    if ("$value" -notmatch '^[a-zA-Z][a-zA-Z0-9-]{1,22}[a-zA-Z0-9]$' -or "$value" -match '--') {
                        $errorText = '-KeyVaultName must be 3-24 letters, digits or single hyphens, start with a letter and end with a letter or digit.'
                    }
                }
            }
        }

        if (-not $errorText) { return $value }
        if (-not $needsInput -or $NonInteractive) { throw $errorText }
        Write-Warning $errorText
    }
}

function Confirm-SetupAction {
    param([string] $Action, [string] $Target, [string] $Details)

    if ($NonInteractive) {
        if ($ApprovePolicyActivation) {
            Write-Host "  Approval      : explicitly supplied for noninteractive policy activation" -ForegroundColor Yellow
            return
        }
        throw "Approval required to $Action '$Target'. Supply -ApprovePolicyActivation or rerun without -NonInteractive; no automatic approval is assumed."
    }
    Write-Host "`n  Approval: $Action '$Target'" -ForegroundColor Yellow
    if ($script:AzureCliContext) {
        Write-Host "  Subscription: $($script:AzureCliContext.name) ($($script:AzureCliContext.id))"
    }
    if ($Details) { Write-Host "  $Details" }
    while ($true) {
        $answer = [string](Read-Host -Prompt 'Proceed? Type Yes to approve [y/N]')
        $answer = $answer.Trim()
        if ($answer -match '^(?i:y|yes)$') { return }
        if (-not $answer -or $answer -match '^(?i:n|no)$') {
            throw [OperationCanceledException]::new("Setup cancelled before attempting to $Action '$Target'. Previously completed changes are left in place.")
        }
        Write-Warning 'Enter Yes to approve, or No/empty to stop.'
    }
}

function Test-AuthenticationFailure {
    param([string] $Message)

    # Do not retry authorization failures (403), policy blocks, network errors or invalid arguments.
    return $Message -match ('(?i)Status_InteractionRequired|interaction_required|MsalUiRequiredException|' +
        'AuthenticationRequiredException|Authentication_ExpiredToken|InvalidAuthenticationToken|' +
        'ExpiredAuthenticationToken|AADSTS(?:50058|50076|50078|50079|50173|65001|70043|700082|700084)\b|' +
        '(?:access|refresh) token (?:has |is )?expired|Please explicitly log in|' +
        '\brun:?\s+[''"`]?az login\b|Can''t find token from MSAL cache|' +
        'Connect-MgGraph.*must be called|Authentication needed\.\s*Please call Connect-MgGraph')
}

function Connect-EndpointGraph {
    param([switch] $Reconnect, [string[]] $Scopes)

    if ($PSBoundParameters.ContainsKey('Scopes')) {
        if (-not $Scopes -or @($Scopes | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count) {
            throw 'Graph authentication requires at least one nonempty scope.'
        }
        $script:GraphRequiredScopes = $Scopes
    }

    $context = Get-MgContext -ErrorAction Stop
    $canReuse = $context -and $context.AuthType -eq 'Delegated' -and
        $context.TokenCredentialType -ne 'UserProvidedAccessToken' -and
        $context.Environment -eq 'Global' -and
        @($script:GraphRequiredScopes | Where-Object { $context.Scopes -notcontains $_ }).Count -eq 0 -and
        (-not $script:GraphTenantId -or $context.TenantId -eq $script:GraphTenantId)

    if ($Reconnect -or -not $canReuse) {
        if ($NonInteractive) {
            throw "Microsoft Graph PowerShell needs sign-in with $($script:GraphRequiredScopes -join ', ') in the target tenant. Connect-MgGraph first, or rerun without -NonInteractive."
        }
        $connectParameters = @{
            Scopes       = $script:GraphRequiredScopes
            ContextScope = 'Process'
            Environment  = 'Global'
            NoWelcome    = $true
            ErrorAction  = 'Stop'
        }
        if ($script:GraphTenantId) { $connectParameters['TenantId'] = $script:GraphTenantId }
        Write-Host '  Graph sign-in: complete any consent/MFA prompt for Microsoft Graph PowerShell.' -ForegroundColor Yellow
        Connect-MgGraph @connectParameters | Out-Null
        $context = Get-MgContext -ErrorAction Stop
    }

    if (-not $context -or $context.AuthType -ne 'Delegated' -or
        $context.Environment -ne 'Global' -or
        @($script:GraphRequiredScopes | Where-Object { $context.Scopes -notcontains $_ }).Count -gt 0 -or
        ($script:GraphTenantId -and $context.TenantId -ne $script:GraphTenantId) -or
        ($script:GraphAccountName -and $context.Account -ne $script:GraphAccountName)) {
        throw 'Microsoft Graph sign-in has the wrong tenant, account or permissions. Use the original Graph account in the target tenant.'
    }
    $script:GraphTenantId = $context.TenantId
    $script:GraphAccountName = $context.Account
}

function Invoke-EndpointGraph {
    param([scriptblock] $Operation)

    try {
        & $Operation
    }
    catch {
        $exception = $_.Exception
        $authenticationFailure = Test-AuthenticationFailure ($_ | Out-String)
        while ($exception) {
            if ($exception.GetType().Name -in @('MsalUiRequiredException', 'AuthenticationRequiredException') -or
                ($exception.PSObject.Properties['ResponseStatusCode'] -and $exception.ResponseStatusCode -eq 401) -or
                ($exception.PSObject.Properties['StatusCode'] -and $exception.StatusCode -eq 401)) {
                $authenticationFailure = $true
            }
            $exception = $exception.InnerException
        }
        if (-not $authenticationFailure) { throw }
        Write-Host '  Graph auth    : renewing the SDK session; retrying the operation once' -ForegroundColor Yellow
        Connect-EndpointGraph -Reconnect
        & $Operation
    }
}


function Get-CyotGraphSchemaStatus {
    param([ValidateSet('beta', 'v1.0')] [string] $ApiVersion)

    $metadataUri = "https://graph.microsoft.com/$ApiVersion/`$metadata"
    $response = Invoke-WebRequest -Uri $metadataUri -TimeoutSec 60 -ErrorAction Stop
    $readerSettings = [Xml.XmlReaderSettings]::new()
    $readerSettings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
    $readerSettings.XmlResolver = $null
    $textReader = [IO.StringReader]::new([string]$response.Content)
    $reader = [Xml.XmlReader]::Create($textReader, $readerSettings)
    $document = [Xml.XmlDocument]::new()
    $document.XmlResolver = $null
    try { $document.Load($reader) }
    finally { $reader.Dispose(); $textReader.Dispose() }
    $ns = [Xml.XmlNamespaceManager]::new($document.NameTable)
    $ns.AddNamespace('edm', 'http://docs.oasis-open.org/odata/ns/edm')
    $schema = $document.SelectSingleNode('//edm:Schema[@Namespace="microsoft.graph"]', $ns)
    if (-not $schema) { throw "Graph metadata at $metadataUri does not contain the microsoft.graph schema." }
    $policyType = $schema.SelectSingleNode('edm:EntityType[@Name="authenticationMethodsPolicy"]', $ns)
    if (-not $policyType) { throw 'The Graph schema does not contain authenticationMethodsPolicy.' }

    $property = $null
    $visited = @{}
    while ($policyType -and -not $property) {
        $typeName = $policyType.GetAttribute('Name')
        if ($visited.ContainsKey($typeName)) { throw 'Graph metadata contains cyclic policy inheritance.' }
        $visited[$typeName] = $true
        $property = $policyType.SelectSingleNode('edm:Property[@Name="cyot"]', $ns)
        $baseName = ($policyType.GetAttribute('BaseType') -split '\.')[-1]
        $policyType = $schema.SelectSingleNode("edm:EntityType[@Name='$baseName']", $ns)
    }

    $supported = $false
    $reason = 'authenticationMethodsPolicy.cyot is not declared in the live Graph schema.'
    if ($property) {
        $qualifiedType = $property.GetAttribute('Type')
        $typeName = ($qualifiedType -split '\.')[-1]
        $allowedPrefixes = @('microsoft.graph')
        if ($schema.GetAttribute('Alias')) { $allowedPrefixes += $schema.GetAttribute('Alias') }
        $prefix = $qualifiedType.Substring(0, [Math]::Max(0, $qualifiedType.Length - $typeName.Length - 1))
        $configuration = $schema.SelectSingleNode("edm:ComplexType[@Name='$typeName']", $ns)
        $reason = 'The cyot property is present, but its type does not match the supported endpoint/appId/migrated contract.'
        if ($configuration -and $allowedPrefixes -contains $prefix) {
            $fields = @($configuration.SelectNodes('edm:Property', $ns))
            $expected = @{ endpoint = 'Edm.String'; appId = 'Edm.String'; migrated = 'Edm.Boolean' }
            $supported = $fields.Count -eq 3 -and -not $configuration.HasAttribute('BaseType') -and
                $configuration.GetAttribute('OpenType') -ne 'true'
            foreach ($name in $expected.Keys) {
                $field = $configuration.SelectSingleNode("edm:Property[@Name='$name']", $ns)
                if (-not $field -or $field.GetAttribute('Type') -ne $expected[$name]) { $supported = $false }
            }
            if ($supported) { $reason = 'The declared CYOT property matches endpoint, appId and migrated. Tenant authorization and feature availability are still required.' }
        }
    }
    return [PSCustomObject]@{
        ApiVersion = $ApiVersion
        MetadataUri = $metadataUri
        PolicyUri = "https://graph.microsoft.com/$ApiVersion/policies/authenticationMethodsPolicy"
        Supported = $supported
        Reason = $reason
        CheckedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
}

function Get-CyotPolicyState {
    param($Policy)

    if (-not $Policy -or -not $Policy.PSObject.Properties['cyot'] -or $null -eq $Policy.cyot) { return $null }
    $configuration = $Policy.cyot
    $unknown = @($configuration.PSObject.Properties.Name | Where-Object {
        $_ -notin @('endpoint', 'appId', 'migrated', '@odata.type')
    })
    if ($unknown.Count) { throw "Existing CYOT policy contains unsupported fields: $($unknown -join ', '). Nothing will be overwritten." }
    if (-not $configuration.PSObject.Properties['endpoint'] -or -not $configuration.PSObject.Properties['appId']) {
        throw 'Existing CYOT policy is missing its endpoint or appId. Resolve the policy contract before updating.'
    }
    return [ordered]@{
        endpoint = $configuration.endpoint
        appId = $configuration.appId
        migrated = $(if ($configuration.PSObject.Properties['migrated']) { $configuration.migrated } else { $null })
    }
}

function Invoke-CyotPolicyUpdate {
    param(
        $SchemaStatus, [string] $CustomerTenantId, [string] $ClientId,
        [string] $DeliveryEndpoint, [Nullable[bool]] $MigrationPath, [string] $SnapshotPath
    )

    if (-not $SchemaStatus.Supported) {
        throw "$($SchemaStatus.Reason) No policy change was attempted. Ask CCE/Graph for the supported preview contract before activation."
    }
    $CustomerTenantId = Read-SetupValue -Name TenantId -DefaultValue $CustomerTenantId -Required -ValueType Guid
    $script:GraphTenantId = $CustomerTenantId
    Connect-EndpointGraph -Scopes @('Policy.ReadWrite.AuthenticationMethod')
    $current = Invoke-EndpointGraph {
        Invoke-MgGraphRequest -Method GET -Uri $SchemaStatus.PolicyUri -OutputType PSObject -ErrorAction Stop
    }
    $previous = Get-CyotPolicyState -Policy $current

    $ClientId = Read-SetupValue -Name ApplicationId -DefaultValue $ClientId -Required -ValueType Guid
    $DeliveryEndpoint = Read-SetupValue -Name EndpointUrl -DefaultValue $DeliveryEndpoint -Required -ValueType HttpsUrl
    $uri = [Uri]::new($DeliveryEndpoint)
    if ($uri.IsLoopback -or $uri.HostNameType -in @('IPv4', 'IPv6') -or $uri.UserInfo -or $uri.Fragment) {
        throw 'The CYOT endpoint must use a public HTTPS hostname without embedded credentials or a fragment.'
    }
    $MigrationPath = Read-SetupValue -Name Migrated -DefaultValue $MigrationPath -Required -ValueType Boolean `
        -Hint 'Yes: migrate from native telephony. No: new CYOT-only tenant. Choose deliberately.'
    $desired = [ordered]@{ endpoint = $DeliveryEndpoint; appId = $ClientId; migrated = [bool]$MigrationPath }
    $previousJson = ConvertTo-Json -InputObject $previous -Depth 10 -Compress
    $desiredJson = ConvertTo-Json -InputObject $desired -Depth 10 -Compress
    if ($previousJson -ceq $desiredJson) {
        Write-Host '  CYOT policy   : already matches; no update or approval needed'
        return [PSCustomObject]@{ Stage = 3; TenantId = $CustomerTenantId; Updated = $false; PolicyUri = $SchemaStatus.PolicyUri }
    }

    $body = @{ cyot = $desired } | ConvertTo-Json -Depth 10
    Confirm-SetupAction -Action 'update CYOT authentication policy' -Target $CustomerTenantId `
        -Details "This can change SMS/Voice sign-in routing. Confirm the provider is purchased, onboarded and the stage-2 endpoint tested. Only this property will be patched:`n$body"
    $latest = Invoke-EndpointGraph {
        Invoke-MgGraphRequest -Method GET -Uri $SchemaStatus.PolicyUri -OutputType PSObject -ErrorAction Stop
    }
    $latestJson = ConvertTo-Json -InputObject (Get-CyotPolicyState -Policy $latest) -Depth 10 -Compress
    if ($latestJson -cne $previousJson) {
        throw 'CYOT policy changed while awaiting approval. No PATCH was sent; rerun to review the new state.'
    }

    if ([string]::IsNullOrWhiteSpace($SnapshotPath)) {
        $SnapshotPath = Join-Path $PSScriptRoot "cyot-policy-before-$CustomerTenantId-$([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))-$([Guid]::NewGuid().ToString('N')).json"
    }
    $snapshot = @{
        TenantId = $CustomerTenantId; PolicyUri = $SchemaStatus.PolicyUri
        SavedAtUtc = [DateTime]::UtcNow.ToString('o'); PreviousCyot = $previous
    } | ConvertTo-Json -Depth 10
    $stream = [IO.File]::Open($SnapshotPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
    try {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($snapshot)
        $stream.Write($bytes, 0, $bytes.Length)
    }
    finally { $stream.Dispose() }
    Write-Host "  Policy backup : $SnapshotPath"
    $headers = @{}
    if ($latest.PSObject.Properties['@odata.etag']) { $headers['If-Match'] = $latest.'@odata.etag' }
    Invoke-EndpointGraph {
        Invoke-MgGraphRequest -Method PATCH -Uri $SchemaStatus.PolicyUri -Body $body `
            -ContentType 'application/json' -Headers $headers -ErrorAction Stop
    } | Out-Null
    $after = Invoke-EndpointGraph {
        Invoke-MgGraphRequest -Method GET -Uri $SchemaStatus.PolicyUri -OutputType PSObject -ErrorAction Stop
    }
    if ((ConvertTo-Json -InputObject (Get-CyotPolicyState -Policy $after) -Depth 10 -Compress) -cne $desiredJson) {
        throw "Graph accepted the update but readback does not match. Do not assume CYOT is active. Previous value: $SnapshotPath"
    }
    return [PSCustomObject]@{
        Stage = 3; TenantId = $CustomerTenantId; ApplicationId = $ClientId; EndpointUrl = $DeliveryEndpoint
        Migrated = [bool]$MigrationPath; Updated = $true; PolicyUri = $SchemaStatus.PolicyUri; BackupPath = $SnapshotPath
    }
}

Write-Step 'Stage 3: checking the live CYOT Graph contract'
$schemaStatus = Get-CyotGraphSchemaStatus -ApiVersion $GraphApiVersion
if ($CheckSchemaOnly) {
    $schemaStatus
    return
}
Invoke-CyotPolicyUpdate -SchemaStatus $schemaStatus -CustomerTenantId $TenantId -ClientId $ApplicationId `
    -DeliveryEndpoint $EndpointUrl -MigrationPath $Migrated -SnapshotPath $BackupPath
