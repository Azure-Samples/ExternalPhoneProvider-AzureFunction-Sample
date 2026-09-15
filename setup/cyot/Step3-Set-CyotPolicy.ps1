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
    [switch] $NonInteractive
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$script:GraphTenantId = $TenantId

function Write-Step { param([string] $Text) Write-Host "`n=== $Text ===" -ForegroundColor Cyan }

function Read-SetupValue {
    param(
        [string] $Name,
        $DefaultValue,
        [switch] $Required,
        [ValidateSet('String', 'Boolean', 'HttpsUrl', 'Guid')]
        [string] $ValueType = 'String',
        [string] $Hint
    )

    $needsInput = $Required -and
        ($null -eq $DefaultValue -or [string]::IsNullOrWhiteSpace("$DefaultValue"))
    while ($true) {
        $value = $DefaultValue
        if ($needsInput -and -not $NonInteractive) {
            $prompt = "$Name [required]"
            if ($Hint) { $prompt += " - $Hint" }
            $answer = Read-Host -Prompt $prompt
            if (-not [string]::IsNullOrWhiteSpace($answer)) { $value = $answer.Trim() }
        }

        $errorText = $null
        if ($null -eq $value -or [string]::IsNullOrWhiteSpace("$value")) {
            if ($Required) { $errorText = "-$Name is required." }
            else { return $null }
        }
        else {
            switch ($ValueType) {
                'Guid' {
                    $identifier = [Guid]::Empty
                    if (-not [Guid]::TryParse("$value", [ref] $identifier) -or $identifier -eq [Guid]::Empty) {
                        $errorText = "-$Name must be a nonempty GUID."
                    }
                    else { $value = $identifier.ToString('D') }
                }
                'Boolean' {
                    if ("$value" -match '^(?i:y|yes|true)$') { $value = $true }
                    elseif ("$value" -match '^(?i:n|no|false)$') { $value = $false }
                    else { $errorText = "-$Name must be Yes or No." }
                }
                'HttpsUrl' {
                    $parsedUri = $null
                    if (-not [Uri]::TryCreate("$value", [UriKind]::Absolute, [ref] $parsedUri) -or
                        $parsedUri.Scheme -ne 'https') {
                        $errorText = "-$Name must be an absolute HTTPS URL."
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
        throw "Approval required to $Action '$Target'. Rerun without -NonInteractive; no automatic approval is assumed."
    }
    Write-Host "`n  Approval: $Action '$Target'" -ForegroundColor Yellow
    Write-Host "  Customer tenant: $script:GraphTenantId"
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

function Connect-EndpointGraph {
    param([string[]] $Scopes = @('Policy.ReadWrite.AuthenticationMethod'))

    $script:GraphTenantId = Read-SetupValue -Name TenantId -DefaultValue $script:GraphTenantId -Required -ValueType Guid
    if (-not $Scopes -or @($Scopes | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count) {
        throw 'Graph authentication requires at least one nonempty scope.'
    }

    $context = Get-MgContext -ErrorAction Stop
    $canReuse = $context -and $context.AuthType -eq 'Delegated' -and
        $context.TokenCredentialType -ne 'UserProvidedAccessToken' -and
        $context.Environment -eq 'Global' -and
        @($Scopes | Where-Object { $context.Scopes -notcontains $_ }).Count -eq 0 -and
        $context.TenantId -eq $script:GraphTenantId

    if (-not $canReuse) {
        if ($NonInteractive) {
            throw "Connect-MgGraph -TenantId $script:GraphTenantId with scopes $($Scopes -join ', ') before using -NonInteractive."
        }
        Write-Host "  Graph sign-in: customer tenant $script:GraphTenantId" -ForegroundColor Yellow
        Connect-MgGraph -TenantId $script:GraphTenantId -Scopes $Scopes `
            -ContextScope Process -Environment Global -NoWelcome -ErrorAction Stop | Out-Null
        $context = Get-MgContext -ErrorAction Stop
    }

    if (-not $context -or $context.AuthType -ne 'Delegated' -or
        $context.TokenCredentialType -eq 'UserProvidedAccessToken' -or
        $context.Environment -ne 'Global' -or
        @($Scopes | Where-Object { $context.Scopes -notcontains $_ }).Count -gt 0 -or
        $context.TenantId -ne $script:GraphTenantId) {
        throw 'Microsoft Graph must use a refreshable delegated session in the selected customer tenant with the requested scopes.'
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
    $ClientId = Read-SetupValue -Name ApplicationId -DefaultValue $ClientId -Required -ValueType Guid
    $DeliveryEndpoint = Read-SetupValue -Name EndpointUrl -DefaultValue $DeliveryEndpoint -Required -ValueType HttpsUrl
    $uri = [Uri]::new($DeliveryEndpoint)
    if ($uri.IsLoopback -or $uri.HostNameType -in @('IPv4', 'IPv6') -or $uri.UserInfo -or $uri.Fragment) {
        throw 'The CYOT endpoint must use a public HTTPS hostname without embedded credentials or a fragment.'
    }
    $MigrationPath = Read-SetupValue -Name Migrated -DefaultValue $MigrationPath -Required -ValueType Boolean `
        -Hint 'Yes: migrate from native telephony. No: new CYOT-only tenant. Choose deliberately.'

    $script:GraphTenantId = $CustomerTenantId
    Connect-EndpointGraph -Scopes @('Policy.ReadWrite.AuthenticationMethod')
    $current = Invoke-MgGraphRequest -Method GET -Uri $SchemaStatus.PolicyUri -OutputType PSObject -ErrorAction Stop
    $previous = Get-CyotPolicyState -Policy $current
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
    $latest = Invoke-MgGraphRequest -Method GET -Uri $SchemaStatus.PolicyUri -OutputType PSObject -ErrorAction Stop
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
    Invoke-MgGraphRequest -Method PATCH -Uri $SchemaStatus.PolicyUri -Body $body `
        -ContentType 'application/json' -Headers $headers -ErrorAction Stop | Out-Null
    $after = Invoke-MgGraphRequest -Method GET -Uri $SchemaStatus.PolicyUri -OutputType PSObject -ErrorAction Stop
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
