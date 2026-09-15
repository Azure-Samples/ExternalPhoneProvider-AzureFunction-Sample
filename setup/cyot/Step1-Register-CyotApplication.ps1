#Requires -Version 7.0
#Requires -Modules Microsoft.Graph.Applications, Microsoft.Graph.Authentication

<#
.SYNOPSIS
    Stage 1 of 3: register the customer's multi-tenant CYOT application before purchasing a provider.
.DESCRIPTION
    Returns only the application (client) ID as a string. Use that ID during Security Store/provider
    onboarding, then pass it as -ApplicationId during resource provisioning.
    Tenant and object IDs are not included in the result. Sign-in and approval prompts remain.

    This stage creates no Azure resources, secrets, certificates, endpoint bindings or CYOT policy.
    It neither buys an offer nor grants access in the provider's tenant. The provider must complete
    their onboarding, instantiate this app's service principal in their tenant and grant their API
    role. Obtain their tenant ID and API scope for stage 2.

    An existing app is found by explicit client ID, or by an unambiguous display name. Changing an
    existing single-tenant app to multi-tenant requires confirmation; no duplicate app is created.
    This file is self-contained; it does not load or invoke any other setup script.
    Only PowerShell and the Microsoft Graph modules listed above are required.
.PARAMETER TenantId
    Customer tenant. Required at Graph sign-in; never inferred from an unrelated Graph session.
.PARAMETER ApplicationId
    Optional existing customer application CLIENT ID to reuse. Not the application object ID.
.PARAMETER DisplayName
    Name of a new application, or an exact name to reuse when -ApplicationId is absent.
    Also accepts -AppName. If neither an application ID nor a name is supplied, asks the customer
    to type an app name at the registration step. Supplied names are used without prompting.
.PARAMETER NonInteractive
    Allow silent authentication and reuse only; fail rather than prompt for missing inputs or approval.
.EXAMPLE
    $appId = .\Step1-Register-CyotApplication.ps1 -TenantId <customer-tenant-id>
    # Type your app name when asked. The result is just the client ID.
    # Complete the provider purchase/onboarding using this ID; it must not change in stage 2.
.EXAMPLE
    $appId = .\Step1-Register-CyotApplication.ps1 -TenantId <customer-tenant-id> -AppName 'Contoso CYOT'
.EXAMPLE
    .\Step1-Register-CyotApplication.ps1 -TenantId <customer-tenant-id> -ApplicationId <existing-client-id>
.OUTPUTS
    System.String. The application (client) ID only.
#>
[CmdletBinding()]
param(
    [string] $TenantId,
    [string] $ApplicationId,
    [Alias('AppName')]
    [string] $DisplayName,
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
        [ValidateSet('String', 'Guid')]
        [string] $ValueType = 'String'
    )

    $needsInput = $Required -and
        ($null -eq $DefaultValue -or [string]::IsNullOrWhiteSpace("$DefaultValue"))
    while ($true) {
        $value = $DefaultValue
        if ($needsInput -and -not $NonInteractive) {
            $answer = Read-Host -Prompt "$Name [required]"
            if (-not [string]::IsNullOrWhiteSpace($answer)) { $value = $answer.Trim() }
        }

        $errorText = $null
        if ($null -eq $value -or [string]::IsNullOrWhiteSpace("$value")) {
            if ($Required) { $errorText = "-$Name is required." }
            else { return $null }
        }
        elseif ($ValueType -eq 'Guid') {
            $identifier = [Guid]::Empty
            if (-not [Guid]::TryParse("$value", [ref] $identifier) -or $identifier -eq [Guid]::Empty) {
                $errorText = "-$Name must be a nonempty GUID."
            }
            else { $value = $identifier.ToString('D') }
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
    param([string[]] $Scopes = @('Application.ReadWrite.All'))

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

function Get-CyotApplication {
    param([string] $ApplicationId, [switch] $RequireMultiTenant)

    $ApplicationId = Read-SetupValue -Name ApplicationId -DefaultValue $ApplicationId -Required -ValueType Guid
    $matches = @(
        Get-MgApplication -Filter "appId eq '$ApplicationId'" -Property Id, AppId -All -ErrorAction Stop
    )
    if ($matches.Count -ne 1) {
        throw "Expected exactly one app registration with client ID '$ApplicationId' in tenant '$script:GraphTenantId'; found $($matches.Count). Complete app registration in the correct tenant. No replacement app will be created."
    }
    $application = Get-MgApplication -ApplicationId $matches[0].Id `
        -Property Id, AppId, DisplayName, SignInAudience -ErrorAction Stop
    if (-not $application -or $application.AppId -ne $ApplicationId) {
        throw 'Graph did not return the requested application.'
    }
    if ($RequireMultiTenant -and $application.SignInAudience -ne 'AzureADMultipleOrgs') {
        throw "Application '$ApplicationId' is not multi-tenant. Review and approve that change in the app-registration stage before provisioning."
    }
    return $application
}

function Ensure-CyotEndpointServicePrincipal {
    param([string] $ApplicationId)

    $principals = @(
        Get-MgServicePrincipal -Filter "appId eq '$ApplicationId'" -All -ErrorAction Stop
    )
    if ($principals.Count -gt 1) { throw "Multiple service principals match application '$ApplicationId'." }
    if (-not $principals.Count) {
        Confirm-SetupAction -Action 'create endpoint service principal' -Target $ApplicationId `
            -Details "Tenant: $script:GraphTenantId. No permission is granted to the provider or Microsoft."
        $principal = New-MgServicePrincipal -AppId $ApplicationId -ErrorAction Stop
    }
    else { $principal = $principals[0] }
    if (-not $principal -or -not $principal.Id) { throw 'Graph did not return an endpoint service-principal ID.' }
    if ($principal.AppRoleAssignmentRequired) {
        Confirm-SetupAction -Action 'remove endpoint app-role assignment requirement' -Target $principal.Id `
            -Details 'Microsoft EPP uses its pre-authorized caller identity. Easy Auth must still restrict callers to the Microsoft EPP application.'
        Update-MgServicePrincipal -ServicePrincipalId $principal.Id -AppRoleAssignmentRequired:$false -ErrorAction Stop | Out-Null
    }
    return $principal
}


Write-Step 'Stage 1: registering the customer application'
$TenantId = Read-SetupValue -Name TenantId -DefaultValue $TenantId -Required -ValueType Guid
$ApplicationId = Read-SetupValue -Name ApplicationId -DefaultValue $ApplicationId -ValueType Guid
if (-not $ApplicationId) {
    $DisplayName = Read-SetupValue -Name AppName -DefaultValue $DisplayName -Required
}
$script:GraphTenantId = $TenantId
Connect-EndpointGraph -Scopes @('Application.ReadWrite.All')

$application = $null
if ([string]::IsNullOrWhiteSpace($ApplicationId)) {
    $matches = @(
        Get-MgApplication -Filter "displayName eq '$($DisplayName.Replace("'", "''"))'" -Property Id, AppId -All -ErrorAction Stop
    )
    if ($matches.Count -gt 1) {
        throw "Multiple applications use display name '$DisplayName'. Supply -ApplicationId to choose one; no new app was created."
    }
    if ($matches.Count -eq 1) { $ApplicationId = $matches[0].AppId }
    else {
        Confirm-SetupAction -Action 'create multi-tenant CYOT application' -Target $DisplayName `
            -Details "Customer tenant: $TenantId. This client ID will be given to the provider. No secrets or API permissions are created."
        $createdApplication = New-MgApplication -DisplayName $DisplayName -SignInAudience AzureADMultipleOrgs `
            -Api @{ RequestedAccessTokenVersion = 1 } -ErrorAction Stop
        if (-not $createdApplication -or -not $createdApplication.Id -or -not $createdApplication.AppId) {
            throw 'Graph did not return the new application client ID.'
        }
        $ApplicationId = $createdApplication.AppId
        $application = $createdApplication
    }
}

if (-not $application) { $application = Get-CyotApplication -ApplicationId $ApplicationId }
if ($application.SignInAudience -ne 'AzureADMultipleOrgs') {
    if ($application.SignInAudience -ne 'AzureADMyOrg') {
        throw 'This app is not an organizational single- or multi-tenant app. Select a dedicated CYOT application.'
    }
    Confirm-SetupAction -Action 'make existing CYOT application multi-tenant' -Target $ApplicationId `
        -Details 'Other organizational tenants will be able to instantiate its service principal. The application client ID and existing credentials remain unchanged.'
    Update-MgApplication -ApplicationId $application.Id -SignInAudience AzureADMultipleOrgs -ErrorAction Stop | Out-Null
    $application = Get-CyotApplication -ApplicationId $ApplicationId -RequireMultiTenant
}
Ensure-CyotEndpointServicePrincipal -ApplicationId $application.AppId | Out-Null
[string] $application.AppId
