#Requires -Version 7.0

<#
.SYNOPSIS
    Stage 1 of 3: register the customer's multi-tenant CYOT application before purchasing a provider.
.DESCRIPTION
    Returns only the application (client) ID as a string. Use that ID during Security Store/provider
    onboarding, then pass it as -ApplicationId during resource provisioning.
    Tenant and object IDs are not included in the result. Sign-in and approval prompts remain.

    When neither -ApplicationId nor -DisplayName is supplied, a guided menu lets you register or find
    an application by name, reuse an application by client ID, or exit without making changes.
    Supplying either parameter bypasses the menu, and -NonInteractive never displays it.

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
.PARAMETER LogDirectory
    Folder for timestamped event and transcript logs. Defaults to a Logs folder beside this script.
.EXAMPLE
    $appId = .\Step1-Register-CyotApplication.ps1 -TenantId <customer-tenant-id>
    # Type your app name when asked. The result is just the client ID.
    # Complete the provider purchase/onboarding using this ID; it must not change in stage 2.
.EXAMPLE
    $appId = .\Step1-Register-CyotApplication.ps1 -TenantId <customer-tenant-id> -AppName 'Contoso CYOT'
.EXAMPLE
    .\Step1-Register-CyotApplication.ps1 -TenantId <customer-tenant-id> -ApplicationId <existing-client-id>
.EXAMPLE
    .\Step1-Register-CyotApplication.ps1 -TenantId <customer-tenant-id> -AppName 'Contoso CYOT' -LogDirectory C:\Logs\ExternalPhoneProvider
    Writes the event log and PowerShell transcript to the customer-selected folder.
.OUTPUTS
    System.String. The application (client) ID only.
#>
[CmdletBinding()]
param(
    [string] $TenantId,
    [string] $ApplicationId,
    [Alias('AppName')]
    [string] $DisplayName,
    [switch] $NonInteractive,
    [switch] $SkipAzureLogin,
    [string] $LogDirectory = (Join-Path $PSScriptRoot 'Logs')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$script:TranscriptStarted = $false
$script:LogPath = $null
$script:AzureCliContext = $null
$script:GraphTenantId = $TenantId
$script:GraphAccountName = $null
$script:GraphRequiredScopes = @('Application.ReadWrite.All')

function Write-Step { param([string] $Text) Write-Host "`n=== $Text ===" -ForegroundColor Cyan }

function Write-SetupEvent {
    param(
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string] $Level,
        [string] $Message
    )

    $entry = "{0:o} [{1}] {2}" -f [DateTimeOffset]::Now, $Level, $Message
    Write-Host $entry -ForegroundColor ($Level -eq 'ERROR' ? 'Red' : ($Level -eq 'WARN' ? 'Yellow' : 'DarkGray'))
    if ($script:LogPath) { Add-Content -LiteralPath $script:LogPath -Value $entry -Encoding utf8 }
}

function Initialize-SetupLogging {
    if (-not (Test-Path -LiteralPath $LogDirectory)) {
        New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
    }
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $script:LogPath = Join-Path $LogDirectory "Step1-Register-CyotApplication-$timestamp.log"
    $transcriptPath = Join-Path $LogDirectory "Step1-Register-CyotApplication-$timestamp.transcript.log"
    New-Item -ItemType File -Path $script:LogPath -Force | Out-Null
    Start-Transcript -LiteralPath $transcriptPath -Force | Out-Null
    $script:TranscriptStarted = $true
    Write-SetupEvent -Level INFO -Message "Detailed log: $script:LogPath"
    Write-SetupEvent -Level INFO -Message "Transcript: $transcriptPath"
}

function Import-SetupModules {
    $requiredModules = @('Microsoft.Graph.Authentication', 'Microsoft.Graph.Applications')
    foreach ($moduleName in $requiredModules) {
        if (-not (Get-Module -ListAvailable -Name $moduleName)) {
            if ($NonInteractive) {
                throw "Required module '$moduleName' is not installed. Install it for the current user before using -NonInteractive."
            }
            Write-Warning "Required module '$moduleName' is not installed."
            $answer = [string](Read-Host -Prompt "Install $moduleName from PowerShell Gallery for the current user? [Y/n]")
            if ($answer.Trim() -and $answer.Trim() -notmatch '^(?i:y|yes)$') {
                throw "Required module '$moduleName' was not installed."
            }
            Write-SetupEvent -Level INFO -Message "Installing PowerShell module '$moduleName' for the current user."
            Install-Module -Name $moduleName -Scope CurrentUser -Repository PSGallery -Force -AllowClobber -ErrorAction Stop
        }
        Import-Module -Name $moduleName -Force -ErrorAction Stop
        $loadedModule = Get-Module -Name $moduleName | Sort-Object Version -Descending | Select-Object -First 1
        Write-SetupEvent -Level INFO -Message "Loaded $moduleName version $($loadedModule.Version)."
    }
}

function Connect-SetupAzureCli {
    param([string] $TenantId)

    if ($SkipAzureLogin) {
        Write-SetupEvent -Level INFO -Message 'Azure CLI sign-in skipped by request.'
        return
    }
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        Write-SetupEvent -Level WARN -Message "Azure CLI isn't installed or isn't on PATH. Azure sign-in was skipped because Stage 1 creates no Azure resources."
        return
    }
    if ($NonInteractive) {
        $account = az account show --output json 2>$null | ConvertFrom-Json
        if (-not $account -or $account.tenantId -ne $TenantId) {
            Write-SetupEvent -Level WARN -Message "Azure CLI isn't signed in to tenant '$TenantId'. Azure sign-in was skipped because Stage 1 creates no Azure resources."
            return
        }
        $script:AzureCliContext = $account
        return
    }

    $answer = [string](Read-Host -Prompt "Sign in to Azure CLI tenant '$TenantId' now for the later provisioning stages? [y/N]")
    if ($answer.Trim() -notmatch '^(?i:y|yes)$') {
        Write-SetupEvent -Level WARN -Message 'Azure CLI sign-in skipped. Stage 1 can continue, but later stages require Azure authentication.'
        return
    }
    Write-SetupEvent -Level INFO -Message "Starting Azure CLI sign-in for tenant '$TenantId'."
    # Azure CLI 2.83 can raise "ValueError: Not a boolean" when an empty environment
    # override takes precedence over the valid value in the Azure CLI config file.
    $loginExperienceOverride = [Environment]::GetEnvironmentVariable('AZURE_CORE_LOGIN_EXPERIENCE_V2', 'Process')
    Remove-Item Env:AZURE_CORE_LOGIN_EXPERIENCE_V2 -ErrorAction SilentlyContinue
    try {
        az config set core.login_experience_v2=false --only-show-errors
        if ($LASTEXITCODE -ne 0) {
            Write-SetupEvent -Level WARN -Message 'Azure CLI compatibility configuration failed. Stage 1 will continue because it creates no Azure resources. Run this command before Step 2: az config set core.login_experience_v2=false'
            return
        }
        Write-SetupEvent -Level INFO -Message 'Configured Azure CLI compatibility setting core.login_experience_v2=false.'

        az login --tenant $TenantId --allow-no-subscriptions --output none
        $loginExitCode = $LASTEXITCODE
    }
    finally {
        if (-not [string]::IsNullOrWhiteSpace($loginExperienceOverride)) {
            $env:AZURE_CORE_LOGIN_EXPERIENCE_V2 = $loginExperienceOverride
        }
    }
    if ($loginExitCode -ne 0) {
        Write-SetupEvent -Level WARN -Message "Azure CLI sign-in failed with exit code $loginExitCode. Stage 1 will continue because it creates no Azure resources."
        return
    }
    $script:AzureCliContext = az account show --output json 2>$null | ConvertFrom-Json
    Write-SetupEvent -Level INFO -Message 'Azure CLI sign-in completed.'
}

function Write-SetupFailure {
    param([System.Management.Automation.ErrorRecord] $ErrorRecord)

    $details = @(
        "Exception: $($ErrorRecord.Exception.GetType().FullName): $($ErrorRecord.Exception.Message)"
        "Error ID: $($ErrorRecord.FullyQualifiedErrorId)"
        "Category: $($ErrorRecord.CategoryInfo)"
        "Position: $($ErrorRecord.InvocationInfo.PositionMessage)"
        "Stack trace: $($ErrorRecord.ScriptStackTrace)"
    ) -join [Environment]::NewLine
    Write-SetupEvent -Level ERROR -Message $details
}

function Show-ApplicationSelectionMenu {
    Write-Host ''
    Write-Host ('=' * 78) -ForegroundColor DarkCyan
    Write-Host '  Select how to register the CYOT application:' -ForegroundColor Cyan
    Write-Host ('=' * 78) -ForegroundColor DarkCyan
    Write-Host ''
    Write-Host '    [1] Register a new application or reuse an existing app by name' -ForegroundColor White
    Write-Host '    [2] Reuse an existing application by client ID' -ForegroundColor White
    Write-Host '    [Q] Exit without making changes' -ForegroundColor White
    Write-Host ''

    while ($true) {
        $choice = ([string](Read-Host -Prompt '  Enter your choice [1 / 2 / Q]')).Trim()
        switch -Regex ($choice) {
            '^1$' {
                Write-SetupEvent -Level INFO -Message "Menu: selected application name lookup or registration."
                return 'Name'
            }
            '^2$' {
                Write-SetupEvent -Level INFO -Message 'Menu: selected existing application client ID.'
                return 'ApplicationId'
            }
            '^(?i:q|quit|exit)$' {
                Write-SetupEvent -Level INFO -Message 'Menu: selected exit; no setup changes were requested.'
                return 'Exit'
            }
            default { Write-Warning 'Enter 1, 2, or Q.' }
        }
    }
}

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
        throw "Approval required to $Action '$Target'. Rerun without -NonInteractive; no automatic approval is assumed."
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

function Get-CyotApplication {
    param([string] $ApplicationId, [switch] $RequireMultiTenant)

    $ApplicationId = Read-SetupValue -Name ApplicationId -DefaultValue $ApplicationId -Required -ValueType Guid
    $matches = @(Invoke-EndpointGraph {
        Get-MgApplication -Filter "appId eq '$ApplicationId'" -Property Id, AppId -All -ErrorAction Stop
    })
    if ($matches.Count -ne 1) {
        throw "Expected exactly one app registration with client ID '$ApplicationId' in tenant '$script:GraphTenantId'; found $($matches.Count). Complete app registration in the correct tenant. No replacement app will be created."
    }
    $application = Invoke-EndpointGraph {
        Get-MgApplication -ApplicationId $matches[0].Id `
            -Property Id, AppId, DisplayName, SignInAudience, Api, IdentifierUris, KeyCredentials, TokenEncryptionKeyId `
            -ErrorAction Stop
    }
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

    $principals = @(Invoke-EndpointGraph {
        Get-MgServicePrincipal -Filter "appId eq '$ApplicationId'" -All -ErrorAction Stop
    })
    if ($principals.Count -gt 1) { throw "Multiple service principals match application '$ApplicationId'." }
    if (-not $principals.Count) {
        Confirm-SetupAction -Action 'create endpoint service principal' -Target $ApplicationId `
            -Details "Tenant: $script:GraphTenantId. No permission is granted to the provider or Microsoft."
        $principal = Invoke-EndpointGraph { New-MgServicePrincipal -AppId $ApplicationId -ErrorAction Stop }
    }
    else { $principal = $principals[0] }
    if (-not $principal -or -not $principal.Id) { throw 'Graph did not return an endpoint service-principal ID.' }
    if ($principal.AppRoleAssignmentRequired) {
        Confirm-SetupAction -Action 'remove endpoint app-role assignment requirement' -Target $principal.Id `
            -Details 'Microsoft EPP uses its pre-authorized caller identity. Easy Auth must still restrict callers to the Microsoft EPP application.'
        Invoke-EndpointGraph {
            Update-MgServicePrincipal -ServicePrincipalId $principal.Id -AppRoleAssignmentRequired:$false -ErrorAction Stop
        } | Out-Null
    }
    return $principal
}


try {
    Initialize-SetupLogging
    if (-not $NonInteractive -and
        [string]::IsNullOrWhiteSpace($ApplicationId) -and
        [string]::IsNullOrWhiteSpace($DisplayName)) {
        $applicationSelection = Show-ApplicationSelectionMenu
        if ($applicationSelection -eq 'Exit') { return }
        if ($applicationSelection -eq 'ApplicationId') {
            $ApplicationId = Read-SetupValue -Name ApplicationId -Required -ValueType Guid `
                -Hint 'Use the application (client) ID, not the object ID'
        }
    }

    Write-Step 'Stage 1: preparing prerequisites'
    Import-SetupModules

    Write-Step 'Stage 1: registering the customer application'
    $tenantGuid = [Guid]::Empty
    $tenantIdIsValid = [Guid]::TryParse($TenantId, [ref] $tenantGuid) -and $tenantGuid -ne [Guid]::Empty
    if (-not $tenantIdIsValid) {
        if ($NonInteractive) {
            throw '-TenantId must be supplied as a nonempty GUID when using -NonInteractive.'
        }
        if (-not [string]::IsNullOrWhiteSpace($TenantId)) {
            Write-Warning "The supplied -TenantId '$TenantId' is not a valid nonempty GUID."
        }
        Write-Host '  Enter the Microsoft Entra tenant ID where the CYOT application will be registered.' -ForegroundColor Yellow
        while ($true) {
            $tenantAnswer = ([string](Read-Host -Prompt 'TenantId [required] - use the Directory (tenant) ID')).Trim()
            $tenantGuid = [Guid]::Empty
            if ([Guid]::TryParse($tenantAnswer, [ref] $tenantGuid) -and $tenantGuid -ne [Guid]::Empty) {
                break
            }
            Write-Warning '-TenantId must be a nonempty GUID.'
        }
    }
    $TenantId = $tenantGuid.ToString('D')
    $script:GraphTenantId = $TenantId
    Connect-SetupAzureCli -TenantId $TenantId
    Write-Host "  Entra sign-in: authenticate to tenant '$TenantId' when prompted." -ForegroundColor Yellow
    Connect-EndpointGraph -Scopes @('Application.ReadWrite.All')
    Write-SetupEvent -Level INFO -Message "Microsoft Entra sign-in completed for tenant '$script:GraphTenantId' as '$script:GraphAccountName'."

    $application = $null
    if ([string]::IsNullOrWhiteSpace($ApplicationId)) {
        $DisplayName = Read-SetupValue -Name AppName -DefaultValue $DisplayName -Required
        $matches = @(Invoke-EndpointGraph {
            Get-MgApplication -Filter "displayName eq '$($DisplayName.Replace("'", "''"))'" -Property Id, AppId -All -ErrorAction Stop
        })
        if ($matches.Count -gt 1) {
            throw "Multiple applications use display name '$DisplayName'. Supply -ApplicationId to choose one; no new app was created."
        }
        if ($matches.Count -eq 1) { $ApplicationId = $matches[0].AppId }
        else {
            Confirm-SetupAction -Action 'create multi-tenant CYOT application' -Target $DisplayName `
                -Details "Customer tenant: $TenantId. This client ID will be given to the provider. No secrets or API permissions are created."
            $createdApplication = Invoke-EndpointGraph {
                New-MgApplication -DisplayName $DisplayName -SignInAudience AzureADMultipleOrgs `
                    -Api @{ RequestedAccessTokenVersion = 1 } -ErrorAction Stop
            }
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
        Invoke-EndpointGraph {
            Update-MgApplication -ApplicationId $application.Id -SignInAudience AzureADMultipleOrgs -ErrorAction Stop
        } | Out-Null
        $application = Get-CyotApplication -ApplicationId $ApplicationId -RequireMultiTenant
    }
    Ensure-CyotEndpointServicePrincipal -ApplicationId $application.AppId | Out-Null
    Write-SetupEvent -Level INFO -Message "Stage 1 completed successfully for application '$($application.AppId)'."
    Write-Host "`nApplication ID: $($application.AppId)" -ForegroundColor Green
    Write-Host 'Save this application ID. You will need it for Step 2 and later configuration steps.' -ForegroundColor Yellow
    [string] $application.AppId
}
catch {
    Write-SetupFailure -ErrorRecord $_
    throw
}
finally {
    if ($script:TranscriptStarted) { Stop-Transcript | Out-Null }
}
