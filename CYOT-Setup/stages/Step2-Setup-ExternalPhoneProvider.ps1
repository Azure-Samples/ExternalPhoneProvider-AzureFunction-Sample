#Requires -Version 7.0
#Requires -Modules Microsoft.Graph.Applications, Microsoft.Graph.Authentication

<#
.SYNOPSIS
    Stage 2 of 3: configure the delivery endpoint for the CYOT application registered in stage 1.

.DESCRIPTION
    Run stage 1 first, then complete Security Store/provider onboarding with the application (client)
    ID it returns. This script takes that SAME -ApplicationId and validates the existing multi-tenant
    application in the customer tenant. It never creates a replacement application or selects one by
    display name.

    Choose one of two endpoint modes: provide -FunctionAppName to provision an Azure Function and its
    supporting resources, or provide -EndpointUrl to configure an HTTPS endpoint you already operate.
    The script configures the application identifier URI, encryption certificate, endpoint metadata,
    managed identities, provider settings, and telemetry required by the selected mode.

    When neither endpoint parameter is supplied, a guided menu lets you choose Azure Function
    provisioning, an existing HTTPS endpoint, or exit without making changes. Supplying either
    endpoint parameter bypasses the menu, and -NonInteractive never displays it.

    For a provisioned Function, adds a user-assigned managed identity and federated identity credential
    to authenticate as the customer's multi-tenant app to the provider. Obtain -ProviderTenantId and
    -ProviderScope from the provider after purchase. Their API role assignment is a provider-side step,
    not something this script grants. The deployed package must implement the EPP_* outbound settings.
    The system-assigned identity continues to handle storage and Key Vault.

    Policy activation is a SEPARATE stage after validating the deployed endpoint. This stage does not
    enable CYOT or change any Graph policy. This file is self-contained; it does not load or invoke
    any other setup script. Azure CLI and the Microsoft Graph modules are still required.

    Microsoft's application is first party and pre-authorized. Nothing is consented, and no
    permission is granted to Microsoft anywhere in this script.

    Safe to re-run: existing objects are reused rather than duplicated.

    Azure CLI prepares separate ARM, Microsoft Graph and Key Vault tokens before provisioning.
    Azure CLI and the Graph PowerShell SDK refresh expired access tokens using their own caches.
    Authentication failures trigger one recovery attempt, with interactive sign-in only when silent
    refresh is no longer possible. Access tokens are never printed or copied between the two clients.

    Required settings are requested only when the step that needs them is reached. Supplied values
    and defaults are used without prompting; omitted optional settings are not requested. Empty input
    for a missing required setting prompts again. Provider settings are collected when configuring
    the Function, not before provisioning. Every new resource still requires an explicit Yes. Empty
    input or No at a creation confirmation stops the script without deleting anything already created.
    Existing resources are reused without a creation confirmation.
    New telemetry workspaces are created explicitly in the same resource group. A soft-deleted vault
    can be recovered with confirmation; the script never purges vaults or performs subscription cleanup.

    Each run writes a timestamped event log and PowerShell transcript under the script's Logs folder,
    or under -LogDirectory when supplied. Failure entries include the exception type, error ID,
    category, source position, and script stack trace. The script redacts common credential-bearing
    values and does not intentionally log access tokens, SAS signatures, private keys, provider
    credentials, or Function app-setting values.

.PARAMETER TenantId
    Optional tenant for sign-in. Inferred from the selected Azure subscription when provisioning.
    Also pins the Graph PowerShell connection so app registrations are created in the same tenant.

.PARAMETER ApplicationId
    Required application CLIENT ID string from app registration, not the object ID.
    The existing app must be multi-tenant and registered in the customer tenant.

.PARAMETER ProviderTenantId
    Provider's tenant, which issues the outbound provider API token. Not the customer/app tenant.
    Requested when configuring the Function if missing.

.PARAMETER ProviderScope
    Provider API App ID URI or application ID followed by /.default. This is NOT the customer app ID.

.PARAMETER OutboundIdentityName
    Optional name for the user-assigned managed identity. Defaults to <FunctionAppName>-outbound.

.PARAMETER LogDirectory
    Folder for timestamped event and transcript logs. Defaults to a Logs folder beside this script.

.PARAMETER StartFromStep
    Resume at a numbered step from 1 through 11. Steps before the selected step are verified and
    their required state is reconstructed without repeating their changes. If a prerequisite from a
    skipped step is missing, the script stops and tells you which earlier step to resume from.

.PARAMETER DisplayName
    Retained for command-line compatibility. Stage 2 selects the existing app only by -ApplicationId.

.PARAMETER NonInteractive
    Do not prompt for settings, creation approval or sign-in. Defaults and supplied values are used.
    The script stops at the first step that needs a missing required input, resource-creation approval,
    or interactive sign-in. Cached credentials may still refresh silently.

.PARAMETER UseWindowsBroker
    Use Azure CLI's configured Windows authentication broker rather than the browser-login
    workaround for older CLI versions. Use this if your tenant requires broker-based authentication.
    By default the workaround applies only while this script invokes Azure CLI; persistent CLI
    configuration and the caller's environment are not changed.

.PARAMETER FunctionAppName
    Globally unique name for the Azure Function to create. If neither this nor -EndpointUrl is
    supplied, the guided flow asks which endpoint mode to use and requests the corresponding value.

.PARAMETER EndpointUrl
    An HTTPS endpoint you already operate, for example https://otp.contoso.com/api/SendOtp.
    Supplying this skips Azure provisioning entirely.

.PARAMETER ZipUrl
    Optional. URL of a zip package to deploy, typically the reference endpoint Microsoft publishes to
    blob storage. Downloaded and pushed to the Function.

.PARAMETER ZipPath
    Optional. A local zip package, used in preference to -ZipUrl.

.PARAMETER PlanType
    FlexConsumption (default) keeps one instance always ready. Premium (EP1) is the fallback where
    Flex Consumption is unavailable. Plain Consumption is deliberately not offered: its cold start
    exceeds the 3.2 s delivery budget.

.PARAMETER KeyVaultName
    Key Vault to hold the encryption private key. Created if absent. Defaults to a name derived from
    the Function name. The key is stored as a secret and the Function reads it through a Key Vault
    reference, so the private key never appears in app settings. A matching soft-deleted vault in the
    same resource group is offered for recovery, retaining its keys and secrets rather than purging it.

.PARAMETER ResourceTagName
    Tag name applied to every resource this script creates. Defaults to 'Purpose'.

.PARAMETER ResourceTagValue
    Tag value applied to every resource this script creates. Defaults to
    'Entra - External Phone Provider', which is what makes these resources findable as a set.

.PARAMETER CertificatePath
    Optional. An existing .cer/.crt public certificate to publish as the encryption key. When
    omitted a self-signed certificate is created in CurrentUser\My and exported next to this script.

.PARAMETER ProviderName
    Telephony provider to use, chosen from the supported set. Written to EPP_PROVIDER_NAME.
    Requested at the Function configuration step if omitted.

.PARAMETER ProviderEndpoint
    The provider's API endpoint. Supplied by the onboarding experience from the security store.

.PARAMETER ProviderTimeoutMs
    Per-call timeout against the provider, in milliseconds. From the security store.

.PARAMETER ProviderRetryIntervalMs
    Delay between provider retries, in milliseconds. From the security store.

.PARAMETER ProviderAccountName
    Your account name with the provider. Supplied by you.

.PARAMETER NoEasyAuth
    Skips App Service Authentication and leaves token validation to your function code. By default
    Easy Auth is configured to reject anything that is not a Microsoft token, before your code
    runs.

.EXAMPLE
    .\Step2-Setup-ExternalPhoneProvider.ps1
    Asks which endpoint to use, then requests missing required values only as each step needs them.
    Defaults and optional settings do not prompt; resource creation still needs Yes.

.EXAMPLE
    .\Step2-Setup-ExternalPhoneProvider.ps1 -ApplicationId <stage-1-client-id> -FunctionAppName contoso-otp -Location westus2

.EXAMPLE
    .\Step2-Setup-ExternalPhoneProvider.ps1 -ApplicationId <stage-1-client-id> -FunctionAppName contoso-otp -ZipPath .\SendOtp.zip -ProviderTenantId <provider-tenant-id> -ProviderScope api://provider-api/.default

.EXAMPLE
    .\Step2-Setup-ExternalPhoneProvider.ps1 -ApplicationId <stage-1-client-id> -EndpointUrl https://otp.contoso.com/api/SendOtp -TenantId <customer-tenant-id>

.EXAMPLE
    .\Step2-Setup-ExternalPhoneProvider.ps1 -ApplicationId <stage-1-client-id> -FunctionAppName contoso-otp -StartFromStep 9 -LogDirectory C:\Logs\ExternalPhoneProvider
    Reconstructs existing state, resumes with Function configuration and deployment, and writes logs
    to the customer-selected folder.
#>

[CmdletBinding()]
param(
    [string] $FunctionAppName,

    [string] $EndpointUrl,

    [string] $SubscriptionId,

    [string] $ResourceGroup = 'rg-external-phone-provider',

    [string] $Location = 'westus2',

    [string] $StorageAccountName,

    [string] $KeyVaultName,

    [string] $ResourceTagName = 'Purpose',

    [string] $ResourceTagValue = 'Entra - External Phone Provider',

    [ValidateSet('FlexConsumption', 'Premium')]
    [string] $PlanType = 'FlexConsumption',

    [string] $ZipUrl,

    [string] $ZipPath,

    [string] $FunctionRoute = 'api/SendOtp',

    [string] $DisplayName = 'Contoso MFA Telephony Endpoint',

    [string] $CertificatePath,

    [string] $ProviderName,

    [string] $ProviderEndpoint,

    [int] $ProviderTimeoutMs,

    [int] $ProviderRetryIntervalMs,

    [string] $ProviderAccountName,

    [switch] $NoEasyAuth,

    [string] $TenantId,

    [switch] $NonInteractive,

    [switch] $UseWindowsBroker,

    [string] $ApplicationId,

    [string] $ProviderTenantId,

    [string] $ProviderScope,

    [string] $OutboundIdentityName,

    [string] $LogDirectory = (Join-Path $PSScriptRoot 'Logs'),

    [ValidateRange(1, 11)]
    [int] $StartFromStep = 1
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Microsoft's first-party application. It reads your published key and calls your endpoint. You do
# not grant it anything: it is pre-authorized, and this value is the same in all public clouds.
$MicrosoftPhoneProviderAppId = '25ec60fa-f18d-41a4-b398-50044c90ce13'

# The reference endpoint implementation Microsoft publishes to blob storage. Deployed when neither
# -ZipPath nor -ZipUrl is supplied.
#
# The container is private, so this URL needs a read SAS appended before it will download. Pass the
# full URL including the SAS as -ZipUrl, or replace this value with one. The token is deliberately
# not stored here: this script is handed to customers, and a SAS in it is a credential in a document.
$ReferencePackageUrl = 'https://cyote2ecodesample.blob.core.windows.net/packages/external-phone-provider-endpoint.zip'

# TODO: replace with the published provider list before release.
# ProviderName is a selection rather than free text, so it is validated here instead of with a
# ValidateSet attribute: the list changes independently of this script and is easier to maintain in
# one place. An empty list disables the check.
$SupportedProviders = @()

$script:AzureCliContext = $null
$script:GraphTenantId = $TenantId
$script:GraphAccountName = $null
$script:GraphRequiredScopes = @('Application.ReadWrite.All')
$script:TranscriptStarted = $false
$script:EventLogPath = $null
$script:TranscriptPath = $null
$script:AzureCliResources = @{
    Arm      = 'https://management.core.windows.net/'
    Graph    = 'https://graph.microsoft.com'
    KeyVault = 'https://vault.azure.net'
}

function Set-FunctionAppSettings {
    <#
        Merges app settings into the Function.

        Deliberately a read-merge-PUT against ARM rather than 'az functionapp config appsettings
        set'. A Key Vault reference contains parentheses, az.cmd is a batch wrapper, and cmd.exe
        treats those as metacharacters -- passing one inline mangles the command line. Routing the
        value through a request body file means no shell ever parses it.

        The ARM appsettings endpoint replaces rather than merges, so existing settings are read and
        carried forward. Dropping that step would silently wipe the platform's own settings.
    #>
    param(
        [string] $Name,
        [string] $ResourceGroup,
        [string] $SubscriptionId,
        [hashtable] $Settings
    )

    $existingJson = (Invoke-Az functionapp config appsettings list `
            --name $Name --resource-group $ResourceGroup -o json --only-show-errors) -join "`n"

    $merged = @{}
    foreach ($item in ($existingJson | ConvertFrom-Json)) {
        $merged[$item.name] = $item.value
    }
    foreach ($key in $Settings.Keys) {
        $merged[$key] = $Settings[$key]
    }

    $bodyFile = Join-Path ([System.IO.Path]::GetTempPath()) "epp-appsettings-$([Guid]::NewGuid()).json"
    [System.IO.File]::WriteAllText(
        $bodyFile,
        (@{ properties = $merged } | ConvertTo-Json -Depth 5),
        [System.Text.UTF8Encoding]::new($false))

    try {
        Invoke-Az rest --method put `
            --url ("https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup" +
                   "/providers/Microsoft.Web/sites/$Name/config/appsettings?api-version=2022-03-01") `
            --body "@$bodyFile" `
            --headers 'Content-Type=application/json' | Out-Null
    }
    finally {
        Remove-Item $bodyFile -Force -ErrorAction SilentlyContinue
    }

    return $merged.Count
}

function Protect-SetupLogText {
    param([AllowEmptyString()][string] $Text)

    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $redacted = $Text -replace '(?i)(Authorization\s*[:=]\s*Bearer\s+)[^\s,;]+', '$1[REDACTED]'
    $redacted = $redacted -replace '(?i)([?&](?:sig|token|code|client_secret|password)=)[^&\s]+', '$1[REDACTED]'
    return $redacted
}

function Write-SetupEvent {
    param(
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string] $Level,
        [string] $Message,
        [switch] $NoConsole
    )

    $safeMessage = Protect-SetupLogText -Text $Message
    $entry = "{0:o} [{1}] {2}" -f [DateTimeOffset]::Now, $Level, $safeMessage
    if (-not $NoConsole) {
        Write-Host $entry -ForegroundColor ($Level -eq 'ERROR' ? 'Red' : ($Level -eq 'WARN' ? 'Yellow' : 'DarkGray'))
    }
    if ($script:EventLogPath) {
        Add-Content -LiteralPath $script:EventLogPath -Value $entry -Encoding utf8
    }
}

function Initialize-SetupLogging {
    if (-not (Test-Path -LiteralPath $LogDirectory)) {
        New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
    }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $script:EventLogPath = Join-Path $LogDirectory "Step2-Setup-ExternalPhoneProvider-$timestamp.log"
    $script:TranscriptPath = Join-Path $LogDirectory "Step2-Setup-ExternalPhoneProvider-$timestamp.transcript.log"
    New-Item -ItemType File -Path $script:EventLogPath -Force | Out-Null
    Start-Transcript -LiteralPath $script:TranscriptPath -Force | Out-Null
    $script:TranscriptStarted = $true
    Write-SetupEvent -Level INFO -Message 'Stage 2 setup started.'
    Write-SetupEvent -Level INFO -Message "Event log: $script:EventLogPath"
    Write-SetupEvent -Level INFO -Message "Transcript: $script:TranscriptPath"
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

function Write-Step {
    param([string] $Text)

    Write-Host "`n=== $Text ===" -ForegroundColor Cyan
    Write-SetupEvent -Level INFO -Message "Step: $Text" -NoConsole
}

function Get-DefaultStorageAccountName {
    param([string] $FunctionName)
    $stem = ($FunctionName -replace '[^a-zA-Z0-9]', '').ToLowerInvariant()
    if ($stem.Length -gt 18) { $stem = $stem.Substring(0, 18) }
    return "${stem}eppsa"
}

function Get-DefaultKeyVaultName {
    param([string] $FunctionName)
    $stem = ($FunctionName -replace '[^a-zA-Z0-9-]', '').ToLowerInvariant()
    if ($stem.Length -gt 20) { $stem = $stem.Substring(0, 20) }
    return "kv-$stem"
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

function Show-EndpointSelectionMenu {
    Write-Host ''
    Write-Host ('=' * 78) -ForegroundColor DarkCyan
    Write-Host '  Select the delivery endpoint to configure:' -ForegroundColor Cyan
    Write-Host ('=' * 78) -ForegroundColor DarkCyan
    Write-Host ''
    Write-Host '    [1] Provision a new Azure Function and supporting resources' -ForegroundColor White
    Write-Host '    [2] Configure an existing HTTPS endpoint' -ForegroundColor White
    Write-Host '    [Q] Exit without making changes' -ForegroundColor White
    Write-Host ''

    while ($true) {
        $choice = ([string](Read-Host -Prompt '  Enter your choice [1 / 2 / Q]')).Trim()
        switch -Regex ($choice) {
            '^1$' {
                Write-SetupEvent -Level INFO -Message 'Menu: selected Azure Function provisioning.' -NoConsole
                return 'Function'
            }
            '^2$' {
                Write-SetupEvent -Level INFO -Message 'Menu: selected existing HTTPS endpoint.' -NoConsole
                return 'Existing'
            }
            '^(?i:q|quit|exit)$' {
                Write-SetupEvent -Level INFO -Message 'Menu: selected exit; no setup changes were requested.' -NoConsole
                return 'Exit'
            }
            default { Write-Warning 'Enter 1, 2, or Q.' }
        }
    }
}

function Show-ResumeSelectionMenu {
    Write-Host ''
    Write-Host ('=' * 78) -ForegroundColor DarkCyan
    Write-Host '  Select where Stage 2 should start:' -ForegroundColor Cyan
    Write-Host ('=' * 78) -ForegroundColor DarkCyan
    Write-Host ''
    Write-Host '    [1] Full run, including Azure Function provisioning' -ForegroundColor White
    Write-Host '    [6] Resume application configuration and key publication' -ForegroundColor White
    Write-Host '    [9] Resume Function security, settings, and deployment' -ForegroundColor White
    Write-Host '   [10] Resume resource tagging and completion checks' -ForegroundColor White
    Write-Host ''

    while ($true) {
        $choice = ([string](Read-Host -Prompt '  Enter your choice [1 / 6 / 9 / 10]')).Trim()
        if ($choice -in @('1', '6', '9', '10')) { return [int]$choice }
        Write-Warning 'Enter 1, 6, 9, or 10.'
    }
}

function Resolve-EndpointParameters {
    param([string] $FunctionName, [string] $ExistingEndpoint)

    $useExistingEndpoint = -not [string]::IsNullOrWhiteSpace($ExistingEndpoint)
    if (-not $useExistingEndpoint -and [string]::IsNullOrWhiteSpace($FunctionName)) {
        if ($NonInteractive) { throw 'Supply -FunctionAppName or -EndpointUrl when using -NonInteractive.' }
        $mode = Show-EndpointSelectionMenu
        if ($mode -eq 'Exit') {
            return [PSCustomObject]@{
                FunctionAppName = $null
                EndpointUrl = $null
                ProvisionFunction = $false
                ExitRequested = $true
            }
        }
        $useExistingEndpoint = $mode -eq 'Existing'
    }

    if ($useExistingEndpoint) {
        $ExistingEndpoint = Read-SetupValue -Name EndpointUrl -DefaultValue $ExistingEndpoint -Required -ValueType HttpsUrl
    }
    else {
        $FunctionName = Read-SetupValue -Name FunctionAppName -DefaultValue $FunctionName -Required
        $ExistingEndpoint = $null
    }
    return [PSCustomObject]@{
        FunctionAppName = $FunctionName
        EndpointUrl = $ExistingEndpoint
        ProvisionFunction = -not $useExistingEndpoint
        ExitRequested = $false
    }
}

function Get-ProviderAppSettings {
    param(
        [string] $Name,
        [string] $Endpoint,
        [Nullable[int]] $TimeoutMs,
        [Nullable[int]] $RetryIntervalMs,
        [string] $AccountName
    )

    if ($SupportedProviders.Count) {
        $Name = Read-SetupValue -Name ProviderName -DefaultValue $Name -Required -ValueType Choice -Choices $SupportedProviders
    }
    else { $Name = Read-SetupValue -Name ProviderName -DefaultValue $Name -Required }
    $Endpoint = Read-SetupValue -Name ProviderEndpoint -DefaultValue $Endpoint -Required -ValueType Url
    $TimeoutMs = Read-SetupValue -Name ProviderTimeoutMs -DefaultValue $TimeoutMs -Required -ValueType Integer
    $RetryIntervalMs = Read-SetupValue -Name ProviderRetryIntervalMs -DefaultValue $RetryIntervalMs -Required -ValueType Integer
    $AccountName = Read-SetupValue -Name ProviderAccountName -DefaultValue $AccountName -Required

    if ($Endpoint -notmatch '^https://') {
        Write-Host '  Provider endpoint is not HTTPS. The passcode leaves your Function in clear text.' -ForegroundColor Red
    }
    if ($TimeoutMs -ge 3200) {
        Write-Host "  Provider timeout is $TimeoutMs ms, at or over Microsoft's 3.2 s budget." -ForegroundColor Yellow
        Write-Host '  Safe only if you respond 2xx before calling the provider. A synchronous call will time out.'
    }
    return @{
        EPP_PROVIDER_NAME = $Name
        EPP_PROVIDER_ENDPOINT = $Endpoint
        EPP_PROVIDER_TIMEOUT_MS = "$TimeoutMs"
        EPP_PROVIDER_RETRY_INTERVAL_MS = "$RetryIntervalMs"
        EPP_PROVIDER_ACCOUNT_NAME = $AccountName
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

function Invoke-AzCommand {
    param([string[]] $Arguments, [switch] $Interactive)

    $previousBroker = [Environment]::GetEnvironmentVariable('AZURE_CORE_ENABLE_BROKER_ON_WINDOWS', 'Process')
    try {
        if ($IsWindows -and -not $UseWindowsBroker) {
            $env:AZURE_CORE_ENABLE_BROKER_ON_WINDOWS = 'false'
        }

        # Handle native exit codes ourselves, including when the caller has enabled this preference.
        $PSNativeCommandUseErrorActionPreference = $false
        if ($Interactive) {
            # Do not capture subscription-selector or sign-in prompts. Login uses --output none.
            & az @Arguments | Out-Host
            $exitCode = $LASTEXITCODE
            $lines = @()
        }
        else {
            $output = & az @Arguments 2>&1
            $exitCode = $LASTEXITCODE
            $lines = @($output | ForEach-Object { "$_" } |
                Where-Object { $_ -notmatch 'UserWarning|site-packages' })
        }
    }
    finally {
        if ($IsWindows -and -not $UseWindowsBroker) {
            [Environment]::SetEnvironmentVariable(
                'AZURE_CORE_ENABLE_BROKER_ON_WINDOWS', $previousBroker, 'Process')
        }
    }

    return [PSCustomObject]@{ ExitCode = $exitCode; Lines = $lines }
}

function Assert-AzCommandSucceeded {
    param($Result, [string[]] $Arguments)

    if ($Result.ExitCode -eq 0) { return }

    $operation = @()
    foreach ($argument in $Arguments) {
        if ($argument.StartsWith('-')) { break }
        $operation += $argument
    }
    $message = $Result.Lines -join [Environment]::NewLine
    $redact = $false
    foreach ($argument in $Arguments) {
        if ($argument.StartsWith('--')) {
            $redact = $argument -in @('--value', '--settings', '--body', '--headers',
                '--password', '--access-token', '--connection-string')
        }
        elseif ($redact -and $argument) {
            $message = $message.Replace($argument, '<redacted>')
        }
    }

    # Never include the complete command: some callers pass a private key or app settings.
    throw "az $($operation -join ' ') failed (exit $($Result.ExitCode)):`n$message"
}

function Get-AzureCliAccountResult {
    $arguments = @('account', 'show', '--output', 'json', '--only-show-errors')
    $selectedSubscription = if ($script:AzureCliContext) { $script:AzureCliContext.id } else { $SubscriptionId }
    if ($selectedSubscription) { $arguments += @('--subscription', $selectedSubscription) }
    return Invoke-AzCommand -Arguments $arguments
}

function Connect-AzureCliSession {
    param([string] $Resource)

    if ($NonInteractive) {
        throw 'Azure CLI needs interactive sign-in. Run az login for the target tenant, or rerun without -NonInteractive. MFA and tenant policies cannot be refreshed silently.'
    }

    $arguments = @('login', '--output', 'none', '--only-show-errors')
    $targetTenant = if ($script:AzureCliContext) { $script:AzureCliContext.tenantId } else { $TenantId }
    if ($targetTenant) { $arguments += @('--tenant', $targetTenant) }
    if ($Resource) { $arguments += @('--scope', "$Resource/.default") }
    Write-Host '  Azure sign-in: complete the sign-in/MFA prompt using the original provisioning account.' -ForegroundColor Yellow
    $result = Invoke-AzCommand -Arguments $arguments -Interactive
    Assert-AzCommandSucceeded -Result $result -Arguments $arguments

    if ($script:AzureCliContext) {
        $result = Get-AzureCliAccountResult
        Assert-AzCommandSucceeded -Result $result -Arguments @('account', 'show')
        $account = ($result.Lines -join "`n") | ConvertFrom-Json
        if ($account.id -ne $script:AzureCliContext.id -or
            $account.tenantId -ne $script:AzureCliContext.tenantId -or
            $account.user.type -ne $script:AzureCliContext.user.type -or
            $account.user.name -ne $script:AzureCliContext.user.name) {
            throw 'Azure sign-in changed the subscription, tenant or account. Sign in with the original provisioning account before rerunning.'
        }
        $arguments = @('account', 'set', '--subscription', $script:AzureCliContext.id)
        $result = Invoke-AzCommand -Arguments $arguments
        Assert-AzCommandSucceeded -Result $result -Arguments $arguments
    }
}

function Get-AzureCliTokenResult {
    param([ValidateSet('Arm', 'Graph', 'KeyVault')] [string] $ResourceName)

    # MSAL returns a usable cached token or refreshes it. Suppress the entire token response.
    return Invoke-AzCommand -Arguments @('account', 'get-access-token',
        '--subscription', $script:AzureCliContext.id,
        '--resource', $script:AzureCliResources[$ResourceName], '--output', 'none', '--only-show-errors')
}

function Ensure-AzureCliToken {
    param([ValidateSet('Arm', 'Graph', 'KeyVault')] [string] $ResourceName)

    $result = Get-AzureCliTokenResult -ResourceName $ResourceName
    if ($result.ExitCode -ne 0 -and (Test-AuthenticationFailure ($result.Lines -join "`n"))) {
        Connect-AzureCliSession -Resource $script:AzureCliResources[$ResourceName]
        $result = Get-AzureCliTokenResult -ResourceName $ResourceName
    }
    Assert-AzCommandSucceeded -Result $result -Arguments @('account', 'get-access-token')
}

function Assert-AzureCliTokens {
    # No recursive recovery here: stop rather than alternating Graph/ARM sign-ins indefinitely.
    foreach ($resourceName in @('Arm', 'Graph', 'KeyVault')) {
        $result = Get-AzureCliTokenResult -ResourceName $resourceName
        Assert-AzCommandSucceeded -Result $result -Arguments @('account', 'get-access-token')
    }
}

function Initialize-AzureCliAuthentication {
    $result = Get-AzureCliAccountResult
    if ($result.ExitCode -ne 0 -and
        ((Test-AuthenticationFailure ($result.Lines -join "`n")) -or
         ($result.Lines -join "`n") -match '(?i)subscription .+doesn''t exist')) {
        Connect-AzureCliSession
        $result = Get-AzureCliAccountResult
    }
    Assert-AzCommandSucceeded -Result $result -Arguments @('account', 'show')
    $account = ($result.Lines -join "`n") | ConvertFrom-Json
    if ($account.state -ne 'Enabled') { throw "Subscription '$($account.name)' is $($account.state), not Enabled." }
    if ($TenantId -and $account.tenantId -ne $TenantId) {
        throw 'The selected subscription does not belong to -TenantId. Select the intended subscription before provisioning.'
    }
    if ($account.user.type -ne 'user') {
        throw 'This script requires a user Azure CLI login to grant the signed-in user Key Vault access. Service-principal and managed-identity provisioning are not supported.'
    }
    $script:AzureCliContext = $account
    $script:GraphTenantId = $account.tenantId

    $arguments = @('account', 'set', '--subscription', $account.id)
    $result = Invoke-AzCommand -Arguments $arguments
    Assert-AzCommandSucceeded -Result $result -Arguments $arguments
    foreach ($resourceName in @('Arm', 'Graph', 'KeyVault')) {
        Ensure-AzureCliToken -ResourceName $resourceName
    }
    Assert-AzureCliTokens
    Write-Host '  Azure auth    : ARM, Microsoft Graph and Key Vault ready'
}

function Invoke-AzResult {
    param([string[]] $Arguments)

    # Directory commands use the tenant selected at initialization/sign-in, not --subscription.
    if ($script:AzureCliContext -and $Arguments[0] -ne 'ad' -and $Arguments -notcontains '--subscription') {
        $Arguments += @('--subscription', $script:AzureCliContext.id)
    }
    if ($Arguments -notcontains '--only-show-errors') { $Arguments += '--only-show-errors' }
    $result = Invoke-AzCommand -Arguments $Arguments
    $message = $result.Lines -join "`n"
    if ($result.ExitCode -ne 0 -and $script:AzureCliContext -and (Test-AuthenticationFailure $message)) {
        $resourceName = if ($message -match 'https://graph\.microsoft\.com') {
            'Graph'
        }
        elseif ($message -match 'https://management\.(core\.windows\.net|azure\.com)') {
            'Arm'
        }
        elseif ($message -match 'https://vault\.azure\.net') {
            'KeyVault'
        }
        elseif ($Arguments[0] -eq 'ad') { 'Graph' }
        elseif ($Arguments[0] -eq 'keyvault' -and $Arguments[1] -in @('secret', 'key', 'certificate')) {
            'KeyVault'
        }
        else { 'Arm' }

        Write-Host "  Azure auth    : refreshing $resourceName authentication; retrying the command once" -ForegroundColor Yellow
        Ensure-AzureCliToken -ResourceName $resourceName
        Assert-AzureCliTokens
        $result = Invoke-AzCommand -Arguments $Arguments
    }
    return $result
}

function Invoke-Az {
    # Keep this a simple function: advanced-function parameters collide with CLI flags such as -o.
    $result = Invoke-AzResult -Arguments $args
    Assert-AzCommandSucceeded -Result $result -Arguments $args
    return $result.Lines
}

function Ensure-AzRoleAssignment {
    param([string] $ObjectId, [string] $PrincipalType, [string] $Role, [string] $Scope)

    $roleId = Invoke-Az role definition list --name $Role --query '[0].id' --output tsv
    if ([string]::IsNullOrWhiteSpace($roleId)) { throw "Could not resolve role '$Role'." }
    $nextPage = "https://management.azure.com${Scope}/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01"
    do {
        # Read ARM directly, avoiding directory lookups just to display principal names.
        $page = ((Invoke-Az rest --method get --url $nextPage --output json) -join "`n") | ConvertFrom-Json
        $existing = @($page.value | Where-Object {
            $_.properties.principalId -eq $ObjectId -and $_.properties.scope -eq $Scope -and
            $_.properties.roleDefinitionId.Split('/')[-1] -eq $roleId.Split('/')[-1]
        })
        if ($existing.Count) {
            Write-Host "    $Role already present" -ForegroundColor DarkGray
            return
        }
        $nextPage = if ($page.PSObject.Properties['nextLink']) { $page.nextLink } else { $null }
    } while ($nextPage)

    Confirm-SetupAction -Action 'create role assignment' -Target "$Role -> $ObjectId" `
        -Details "Principal type: $PrincipalType; exact scope: $Scope."
    $arguments = @('role', 'assignment', 'create', '--assignee-object-id', $ObjectId,
        '--assignee-principal-type', $PrincipalType, '--role', $Role, '--scope', $Scope,
        '--output', 'none', '--only-show-errors')
    $result = Invoke-AzResult -Arguments $arguments
    if ($result.ExitCode -ne 0 -and ($result.Lines -join "`n") -match '\bRoleAssignmentExists\b') {
        Write-Host "    $Role already present" -ForegroundColor DarkGray
        return
    }
    Assert-AzCommandSucceeded -Result $result -Arguments $arguments
}

function Ensure-FunctionTelemetry {
    param([string] $FunctionName, [string] $Group, [string] $Region, [string] $Tag)

    $components = ((Invoke-Az resource list --resource-group $Group `
        --resource-type Microsoft.Insights/components --output json) -join "`n") | ConvertFrom-Json
    if (@($components | Where-Object name -eq $FunctionName).Count) { return $FunctionName }

    $stem = $FunctionName
    if ($stem.Length -gt 58) { $stem = $stem.Substring(0, 58) }
    $workspaceName = "$stem-logs"
    $workspaces = ((Invoke-Az monitor log-analytics workspace list --resource-group $Group --output json) -join "`n") |
        ConvertFrom-Json
    if (-not @($workspaces | Where-Object name -eq $workspaceName).Count) {
        Confirm-SetupAction -Action 'create Log Analytics workspace' -Target $workspaceName `
            -Details "Resource group: $Group; location: $Region; PerGB2018, 30-day retention. Ingestion charges apply."
        Invoke-Az monitor log-analytics workspace create --workspace-name $workspaceName `
            --resource-group $Group --location $Region --sku PerGB2018 --retention-time 30 --tags $Tag | Out-Null
    }
    $workspaceId = Invoke-Az monitor log-analytics workspace show --workspace-name $workspaceName `
        --resource-group $Group --query id --output tsv
    if ([string]::IsNullOrWhiteSpace($workspaceId)) { throw 'The telemetry workspace has no resource ID.' }

    $actionGroups = ((Invoke-Az resource list --resource-group $Group `
        --resource-type Microsoft.Insights/actionGroups --output json) -join "`n") | ConvertFrom-Json
    if (-not @($actionGroups | Where-Object name -eq 'Application Insights Smart Detection').Count) {
        Confirm-SetupAction -Action 'allow creation of the standard telemetry action group' `
            -Target 'Application Insights Smart Detection' `
            -Details "Azure may create this supporting resource alongside Application Insights in $Group."
    }
    Confirm-SetupAction -Action 'create Application Insights component' -Target $FunctionName `
        -Details "Resource group: $Group; location: $Region; workspace: $workspaceName. Local-key authentication is disabled."
    $propertiesFile = Join-Path ([IO.Path]::GetTempPath()) "epp-insights-$([Guid]::NewGuid()).json"
    [IO.File]::WriteAllText($propertiesFile, (@{
        Application_Type = 'web'
        WorkspaceResourceId = $workspaceId
        DisableLocalAuth = $true
    } | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    try {
        Invoke-Az resource create --resource-group $Group --name $FunctionName `
            --resource-type Microsoft.Insights/components --api-version 2020-02-02 --location $Region `
            --properties "@$propertiesFile" | Out-Null
    }
    finally { Remove-Item -LiteralPath $propertiesFile -Force -ErrorAction SilentlyContinue }
    return $FunctionName
}

function New-OrRecoverEndpointKeyVault {
    param([string] $Name, [string] $Group, [string] $Region, [string] $Tag)

    $deletedVaults = ((Invoke-Az keyvault list-deleted --output json) -join "`n") | ConvertFrom-Json
    $matchingVaults = @($deletedVaults | Where-Object name -eq $Name)
    if ($matchingVaults.Count -gt 1) { throw "More than one deleted vault matches '$Name'; resolve this before continuing." }
    if ($matchingVaults.Count -eq 1) {
        $deleted = $matchingVaults[0]
        $expectedId = "/subscriptions/$($script:AzureCliContext.id)/resourceGroups/$Group/providers/Microsoft.KeyVault/vaults/$Name"
        if ($deleted.properties.vaultId -ne $expectedId) {
            throw "Deleted vault '$Name' belongs to another resource group. Choose a different -KeyVaultName; it will not be recovered or purged automatically."
        }
        Confirm-SetupAction -Action 'recover soft-deleted Key Vault' -Target $Name `
            -Details "Original location: $($deleted.properties.location); resource group: $Group. Recovery retains its existing keys and secrets. No purge will be performed."
        Invoke-Az keyvault recover --name $Name --resource-group $Group `
            --location $deleted.properties.location | Out-Null
        Write-Host "  Key Vault     : $Name recovered"
    }
    else {
        $Region = Read-SetupValue -Name Location -DefaultValue $Region -Required
        Confirm-SetupAction -Action 'create Key Vault' -Target $Name `
            -Details "Resource group: $Group; location: $Region; Standard SKU with Azure RBAC."
        Invoke-Az keyvault create --name $Name --resource-group $Group --location $Region `
            --enable-rbac-authorization true --sku standard --tags $Tag | Out-Null
        Write-Host "  Key Vault     : $Name created"
    }
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

function Get-ProviderEntraSettings {
    param([string] $ProviderTenantId, [string] $ProviderScope)

    $ProviderTenantId = Read-SetupValue -Name ProviderTenantId -DefaultValue $ProviderTenantId -Required -ValueType Guid
    $ProviderScope = Read-SetupValue -Name ProviderScope -DefaultValue $ProviderScope -Required -ValueType Scope
    return @{
        EPP_PROVIDER_AUTH_MODE = 'ests'
        EPP_PROVIDER_TENANT_ID = $ProviderTenantId
        EPP_PROVIDER_SCOPE = $ProviderScope
    }
}

function Ensure-CyotProviderIdentity {
    param(
        [string] $FunctionName, [string] $Group, [string] $Region, [string] $Tag,
        [string] $IdentityName, $Application
    )

    if ($script:AzureCliContext.tenantId -ne $script:GraphTenantId -or
        $Application.SignInAudience -ne 'AzureADMultipleOrgs') {
        throw 'Provider federation requires a multi-tenant application and managed identity in the same customer tenant.'
    }
    if ([string]::IsNullOrWhiteSpace($IdentityName)) { $IdentityName = "$FunctionName-outbound" }
    if ($IdentityName -notmatch '^[a-zA-Z0-9_-]{3,128}$') {
        throw '-OutboundIdentityName must be 3-128 letters, digits, underscores or hyphens.'
    }

    $identities = ((Invoke-Az identity list --resource-group $Group --output json) -join "`n") | ConvertFrom-Json
    $matches = @($identities | Where-Object name -eq $IdentityName)
    if ($matches.Count -gt 1) { throw "Multiple managed identities match '$IdentityName'." }
    if (-not $matches.Count) {
        $Region = Read-SetupValue -Name Location -DefaultValue $Region -Required
        Confirm-SetupAction -Action 'create outbound user-assigned managed identity' -Target $IdentityName `
            -Details "Resource group: $Group; location: $Region. This identity will authenticate as application $($Application.AppId) to the provider."
        Invoke-Az identity create --name $IdentityName --resource-group $Group --location $Region --tags $Tag | Out-Null
    }
    $identity = ((Invoke-Az identity show --name $IdentityName --resource-group $Group --output json) -join "`n") |
        ConvertFrom-Json
    if (-not $identity.id -or -not $identity.clientId -or -not $identity.principalId -or
        $identity.tenantId -ne $script:GraphTenantId) {
        throw 'The outbound managed identity is incomplete or belongs to another tenant.'
    }

    $functionIdentity = ((Invoke-Az functionapp identity show --name $FunctionName --resource-group $Group --output json) -join "`n") |
        ConvertFrom-Json
    $userIdentities = @()
    if ($functionIdentity.PSObject.Properties['userAssignedIdentities'] -and $functionIdentity.userAssignedIdentities) {
        $userIdentities = @($functionIdentity.userAssignedIdentities.PSObject.Properties.Name)
    }
    if ($userIdentities -notcontains $identity.id) {
        Confirm-SetupAction -Action 'attach outbound managed identity to Function App' -Target $FunctionName `
            -Details "Attach $($identity.id). Retain the system-assigned identity and all existing user-assigned identities."
        $identityIds = @('[system]') + $userIdentities + @($identity.id)
        Invoke-Az functionapp identity assign --name $FunctionName --resource-group $Group --identities @identityIds | Out-Null
    }

    $issuer = "https://login.microsoftonline.com/$script:GraphTenantId/v2.0"
    $audience = 'api://AzureADTokenExchange'
    $credentialName = "cyot-$FunctionName-outbound"
    $credentials = @(Invoke-EndpointGraph {
        Get-MgApplicationFederatedIdentityCredential -ApplicationId $Application.Id -All -ErrorAction Stop
    })
    $matchingCredentials = @($credentials | Where-Object {
        $_.Issuer -ceq $issuer -and $_.Subject -ceq $identity.principalId -and
        @($_.Audiences).Count -eq 1 -and $_.Audiences[0] -ceq $audience
    })
    if (-not $matchingCredentials.Count) {
        if (@($credentials | Where-Object Name -eq $credentialName).Count) {
            throw "Federated credential '$credentialName' already exists with a different trust relationship. It will not be overwritten."
        }
        Confirm-SetupAction -Action 'create application federated identity credential' -Target "$($Application.AppId)/$credentialName" `
            -Details "Trust managed-identity principal $($identity.principalId), issuer $issuer, audience $audience. No client secret is created."
        Invoke-EndpointGraph {
            New-MgApplicationFederatedIdentityCredential -ApplicationId $Application.Id -BodyParameter @{
                Name = $credentialName
                Issuer = $issuer
                Subject = $identity.principalId
                Audiences = @($audience)
            } -ErrorAction Stop
        } | Out-Null
    }
    return @{
        EPP_OUTBOUND_CLIENT_ID = $Application.AppId
        EPP_OUTBOUND_MI_CLIENT_ID = $identity.clientId
    }
}

$stageResult = $null
$stageSucceeded = $false

try {
Initialize-SetupLogging
$guidedEndpointSelection = [string]::IsNullOrWhiteSpace($FunctionAppName) -and [string]::IsNullOrWhiteSpace($EndpointUrl)
$endpointSelection = Resolve-EndpointParameters -FunctionName $FunctionAppName -ExistingEndpoint $EndpointUrl
if ($endpointSelection.ExitRequested) {
    Write-Host 'Stage 2 exited without making changes.' -ForegroundColor Yellow
    $stageSucceeded = $true
    return
}
$FunctionAppName = $endpointSelection.FunctionAppName
$EndpointUrl = $endpointSelection.EndpointUrl
$provisionFunction = $endpointSelection.ProvisionFunction
if ($guidedEndpointSelection -and -not $NonInteractive -and -not $PSBoundParameters.ContainsKey('StartFromStep')) {
    $StartFromStep = Show-ResumeSelectionMenu
}
Write-SetupEvent -Level INFO -Message "Starting Stage 2 from step $StartFromStep. Earlier prerequisites will be verified and reconstructed."

# ---------------------------------------------------------------------------
# 1. Provision the Azure Function
# ---------------------------------------------------------------------------
# The app already exists from stage 1; only its hostname-based identifier URI must wait for the host.
if ($provisionFunction -and $StartFromStep -le 1) {
    Write-Step 'Provisioning the Azure Function'

    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw 'Azure CLI is required to provision the Function. Install it, or pass -EndpointUrl to skip provisioning.'
    }

    Initialize-AzureCliAuthentication
    $ApplicationId = Read-SetupValue -Name ApplicationId -DefaultValue $ApplicationId -Required -ValueType Guid
    Connect-EndpointGraph -Scopes @('Application.ReadWrite.All')
    $application = Get-CyotApplication -ApplicationId $ApplicationId -RequireMultiTenant
    $subscriptionName = $script:AzureCliContext.name
    $resolvedSubscriptionId = $script:AzureCliContext.id
    Write-Host "  Subscription  : $subscriptionName"

    $ResourceGroup = Read-SetupValue -Name ResourceGroup -DefaultValue $ResourceGroup -Required
    $ResourceTagName = Read-SetupValue -Name ResourceTagName -DefaultValue $ResourceTagName -Required
    $ResourceTagValue = Read-SetupValue -Name ResourceTagValue -DefaultValue $ResourceTagValue -Required
    $resourceTag = "$ResourceTagName=$ResourceTagValue"

    $groupExists = Invoke-Az group exists --name $ResourceGroup --output tsv
    if ($groupExists -eq 'false') {
        $Location = Read-SetupValue -Name Location -DefaultValue $Location -Required
        Confirm-SetupAction -Action 'create resource group' -Target $ResourceGroup -Details "Location: $Location."
        Invoke-Az group create --name $ResourceGroup --location $Location --tags $resourceTag | Out-Null
    }
    elseif ($groupExists -ne 'true') { throw "Unexpected resource-group existence response: $groupExists" }
    Write-Host "  Resource group: $ResourceGroup"

    # Derive optional resource names without prompting; only validate them when needed.
    if ([string]::IsNullOrWhiteSpace($StorageAccountName)) {
        $StorageAccountName = Get-DefaultStorageAccountName $FunctionAppName
    }
    $StorageAccountName = Read-SetupValue -Name StorageAccountName -DefaultValue $StorageAccountName -Required -ValueType StorageName
    $storageExists = (Invoke-Az storage account list --resource-group $ResourceGroup --query "[?name=='$StorageAccountName'] | length(@)" -o tsv)
    if ($storageExists -eq '0') {
        $Location = Read-SetupValue -Name Location -DefaultValue $Location -Required
        Confirm-SetupAction -Action 'create storage account' -Target $StorageAccountName `
            -Details "Resource group: $ResourceGroup; location: $Location; SKU: Standard_LRS. Storage charges apply."
        Invoke-Az storage account create `
            --name $StorageAccountName `
            --resource-group $ResourceGroup `
            --location $Location `
            --sku Standard_LRS `
            --min-tls-version TLS1_2 `
            --allow-blob-public-access false `
            --tags $resourceTag | Out-Null
        Write-Host "  Storage       : $StorageAccountName created"
    }
    else {
        Write-Host "  Storage       : $StorageAccountName exists"
    }

    $functionExists = (Invoke-Az functionapp list --resource-group $ResourceGroup --query "[?name=='$FunctionAppName'] | length(@)" -o tsv)

    if ($functionExists -eq '0') {
        $Location = Read-SetupValue -Name Location -DefaultValue $Location -Required
        $PlanType = Read-SetupValue -Name PlanType -DefaultValue $PlanType -Required `
            -ValueType Choice -Choices @('FlexConsumption', 'Premium')
        # Create telemetry explicitly so no workspace appears silently in a different resource group.
        $insightsName = Ensure-FunctionTelemetry -FunctionName $FunctionAppName `
            -Group $ResourceGroup -Region $Location -Tag $resourceTag
        if ($PlanType -eq 'FlexConsumption') {
            # Flex Consumption supports always-ready instances, which is the only way a consumption
            # style plan stays inside the 3.2 s budget. Requires Azure CLI 2.61 or later.
            # Node 24 to match the reference package. Node 20 is out of support and Node 22, though
            # still the platform default, reaches end of life in April 2027.
            Confirm-SetupAction -Action 'create Flex Consumption hosting plan' -Target "$FunctionAppName (CLI-assigned plan name)" `
                -Details "Resource group: $ResourceGroup; location: $Location. The CLI creates this together with the Function. One always-ready instance incurs charges."
            Confirm-SetupAction -Action 'create deployment storage container' -Target "$StorageAccountName (CLI-managed container)" `
                -Details 'The Function creation command creates or reuses its deployment container in this storage account.'
            Confirm-SetupAction -Action 'create Function App' -Target $FunctionAppName `
                -Details "Resource group: $ResourceGroup; location: $Location; Node 24, Flex Consumption."
            Invoke-Az functionapp create `
                --name $FunctionAppName `
                --resource-group $ResourceGroup `
                --storage-account $StorageAccountName `
                --app-insights $insightsName `
                --flexconsumption-location $Location `
                --runtime node `
                --runtime-version 24 `
                --instance-memory 2048 | Out-Null

            # Without this the first request after an idle period pays a cold start and times out.
            Invoke-Az functionapp scale config always-ready set `
                --name $FunctionAppName `
                --resource-group $ResourceGroup `
                --settings http=1 | Out-Null

            Write-Host "  Plan          : Flex Consumption, 1 always-ready instance"
        }
        else {
            $planName = "$FunctionAppName-plan"
            $plans = ((Invoke-Az functionapp plan list --resource-group $ResourceGroup --output json) -join "`n") | ConvertFrom-Json
            if (-not @($plans | Where-Object name -eq $planName).Count) {
                Confirm-SetupAction -Action 'create Premium hosting plan' -Target $planName `
                    -Details "Resource group: $ResourceGroup; location: $Location; Linux EP1. Ongoing charges apply."
                Invoke-Az functionapp plan create `
                    --name $planName `
                    --resource-group $ResourceGroup `
                    --location $Location `
                    --sku EP1 `
                    --is-linux true | Out-Null
            }
            Confirm-SetupAction -Action 'create Function runtime storage' -Target "$StorageAccountName (Function-managed content storage)" `
                -Details 'Azure creates or reuses its content share and runtime containers during Function creation.'
            Confirm-SetupAction -Action 'create Function App' -Target $FunctionAppName `
                -Details "Resource group: $ResourceGroup; Linux Node 24, Premium plan: $planName; storage: $StorageAccountName."
            Invoke-Az functionapp create `
                --name $FunctionAppName `
                --resource-group $ResourceGroup `
                --storage-account $StorageAccountName `
                --app-insights $insightsName `
                --plan $planName `
                --runtime node `
                --runtime-version 24 `
                --functions-version 4 | Out-Null

            Write-Host "  Plan          : Premium EP1, always warm"
        }

        Write-Host "  Function app  : $FunctionAppName created"
    }
    else {
        Write-Host "  Function app  : $FunctionAppName exists"
    }

    # Microsoft rejects any endpoint that is not HTTPS, so leaving the HTTP listener open only
    # invites a delivery that never happens.
    Invoke-Az functionapp update `
        --name $FunctionAppName `
        --resource-group $ResourceGroup `
        --set httpsOnly=true | Out-Null

    Invoke-Az functionapp config set `
        --name $FunctionAppName `
        --resource-group $ResourceGroup `
        --min-tls-version 1.2 | Out-Null

    # A managed identity is how the Function reaches Key Vault, and how the platform reaches storage
    # once the account keys below are removed.
    $principalId = Invoke-Az functionapp identity show --name $FunctionAppName `
        --resource-group $ResourceGroup --query principalId --output tsv
    if ([string]::IsNullOrWhiteSpace($principalId)) {
        Confirm-SetupAction -Action 'create system-assigned managed identity' -Target $FunctionAppName `
            -Details "This creates the Function's service principal in tenant $($script:AzureCliContext.tenantId)."
        $principalId = (Invoke-Az functionapp identity assign `
                --name $FunctionAppName `
                --resource-group $ResourceGroup `
                --query principalId -o tsv)
    }

    # --- Storage: managed identity instead of account keys --------------------------------------
    # A new function app is created with the storage account key embedded in AzureWebJobsStorage
    # and, on Flex Consumption, again in a second setting for the deployment container. Both are
    # replaced here so no account key is left in configuration for anyone to read or leak.
    $storageId = (Invoke-Az storage account show `
            --name $StorageAccountName `
            --resource-group $ResourceGroup `
            --query id -o tsv)

    foreach ($role in @(
            'Storage Blob Data Contributor',
            'Storage Queue Data Contributor',
            'Storage Table Data Contributor')) {

        Ensure-AzRoleAssignment -ObjectId $principalId -PrincipalType ServicePrincipal `
            -Role $role -Scope $storageId
    }

    Write-Host '  Storage roles : blob, queue and table data contributor'

    # Role assignments take time to reach the data plane. Switching over immediately produces an
    # authorization failure on the next deployment that reads like a corrupt package.
    Start-Sleep -Seconds 30

    Invoke-Az functionapp deployment config set `
        --name $FunctionAppName `
        --resource-group $ResourceGroup `
        --deployment-storage-auth-type SystemAssignedIdentity | Out-Null

    Invoke-Az functionapp config appsettings set `
        --name $FunctionAppName `
        --resource-group $ResourceGroup `
        --settings "AzureWebJobsStorage__accountName=$StorageAccountName" | Out-Null

    # Removed last. Deleting the connection strings before the identity path is in place would
    # strand the host with no way to reach its own storage.
    Invoke-Az functionapp config appsettings delete `
        --name $FunctionAppName `
        --resource-group $ResourceGroup `
        --setting-names AzureWebJobsStorage DEPLOYMENT_STORAGE_CONNECTION_STRING `
        -o none --only-show-errors | Out-Null

    Write-Host '  Storage auth  : managed identity, no account key in configuration'

    # --- Key Vault for the encryption private key ------------------------------------------------
    # The private key is the one secret that matters: it is the only thing that can open a passcode.
    # It goes in a vault and reaches the Function as a reference, so it never appears in app settings
    # where anyone with Reader on the site could read it.
    if ([string]::IsNullOrWhiteSpace($KeyVaultName)) {
        # 3-24 characters, alphanumerics and hyphens, globally unique.
        $KeyVaultName = Get-DefaultKeyVaultName $FunctionAppName
    }
    $KeyVaultName = Read-SetupValue -Name KeyVaultName -DefaultValue $KeyVaultName -Required -ValueType VaultName

    $vaultExists = (Invoke-Az keyvault list --resource-group $ResourceGroup `
            --query "[?name=='$KeyVaultName'] | length(@)" -o tsv)

    if ($vaultExists -eq '0') {
        New-OrRecoverEndpointKeyVault -Name $KeyVaultName -Group $ResourceGroup -Region $Location -Tag $resourceTag
    }
    else {
        Write-Host "  Key Vault     : $KeyVaultName exists"
    }

    $vaultId = (Invoke-Az keyvault show --name $KeyVaultName --resource-group $ResourceGroup --query id -o tsv)

    # The Function reads the secret; whoever runs this script writes it.
    Ensure-AzRoleAssignment -ObjectId $principalId -PrincipalType ServicePrincipal `
        -Role 'Key Vault Secrets User' -Scope $vaultId

    $callerObjectId = (Invoke-Az ad signed-in-user show --query id -o tsv)
    Ensure-AzRoleAssignment -ObjectId $callerObjectId -PrincipalType User `
        -Role 'Key Vault Secrets Officer' -Scope $vaultId

    Write-Host '  Key Vault RBAC: function reads secrets, you write them'

    # Read from ARM rather than 'az functionapp show'. On Flex Consumption that command returns null
    # for defaultHostName, state and hostNames while still exiting 0, so the hostname silently comes
    # back empty and the failure only shows up later as an unparseable URI.
    $defaultHostName = (Invoke-Az resource show `
            --resource-group $ResourceGroup `
            --name $FunctionAppName `
            --resource-type Microsoft.Web/sites `
            --query properties.defaultHostName -o tsv)

    if ([string]::IsNullOrWhiteSpace($defaultHostName)) {
        throw "Could not read the hostname for '$FunctionAppName'. The app may still be provisioning."
    }

    $FunctionRoute = Read-SetupValue -Name FunctionRoute -DefaultValue $FunctionRoute -Required
    $EndpointUrl = "https://$defaultHostName/$($FunctionRoute.TrimStart('/'))"

    Write-Host "  Identity      : $principalId"
    Write-Host "  Endpoint URL  : $EndpointUrl"
}
elseif ($provisionFunction) {
    Write-Step "Reconstructing Azure state before resumed step $StartFromStep"

    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw 'Azure CLI is required to resume Function configuration.'
    }
    Initialize-AzureCliAuthentication
    $ApplicationId = Read-SetupValue -Name ApplicationId -DefaultValue $ApplicationId -Required -ValueType Guid
    $resolvedSubscriptionId = $script:AzureCliContext.id
    $ResourceGroup = Read-SetupValue -Name ResourceGroup -DefaultValue $ResourceGroup -Required
    $ResourceTagName = Read-SetupValue -Name ResourceTagName -DefaultValue $ResourceTagName -Required
    $ResourceTagValue = Read-SetupValue -Name ResourceTagValue -DefaultValue $ResourceTagValue -Required
    $resourceTag = "$ResourceTagName=$ResourceTagValue"

    $groupExists = Invoke-Az group exists --name $ResourceGroup --output tsv
    if ($groupExists -ne 'true') {
        throw "Resource group '$ResourceGroup' is missing. Resume with -StartFromStep 1."
    }
    $functionExists = Invoke-Az functionapp list --resource-group $ResourceGroup --query "[?name=='$FunctionAppName'] | length(@)" -o tsv
    if ($functionExists -eq '0') {
        throw "Function app '$FunctionAppName' is missing. Resume with -StartFromStep 1."
    }

    $functionResource = ((Invoke-Az resource show --resource-group $ResourceGroup --name $FunctionAppName `
            --resource-type Microsoft.Web/sites --output json) -join "`n") | ConvertFrom-Json
    $defaultHostName = $functionResource.properties.defaultHostName
    $Location = $functionResource.location
    if ([string]::IsNullOrWhiteSpace($defaultHostName)) {
        throw "Could not reconstruct the hostname for '$FunctionAppName'. Resume with -StartFromStep 1."
    }

    $principalId = Invoke-Az functionapp identity show --name $FunctionAppName `
        --resource-group $ResourceGroup --query principalId --output tsv
    if ([string]::IsNullOrWhiteSpace($principalId)) {
        throw "Function app '$FunctionAppName' has no system-assigned identity. Resume with -StartFromStep 1."
    }

    if ([string]::IsNullOrWhiteSpace($KeyVaultName)) { $KeyVaultName = Get-DefaultKeyVaultName $FunctionAppName }
    $KeyVaultName = Read-SetupValue -Name KeyVaultName -DefaultValue $KeyVaultName -Required -ValueType VaultName
    $vaultExists = Invoke-Az keyvault list --resource-group $ResourceGroup `
        --query "[?name=='$KeyVaultName'] | length(@)" -o tsv
    if ($vaultExists -eq '0') {
        throw "Key Vault '$KeyVaultName' is missing. Resume with -StartFromStep 1."
    }

    $FunctionRoute = Read-SetupValue -Name FunctionRoute -DefaultValue $FunctionRoute -Required
    $EndpointUrl = "https://$defaultHostName/$($FunctionRoute.TrimStart('/'))"
    Write-Host "  Function app  : $FunctionAppName"
    Write-Host "  Endpoint URL  : $EndpointUrl"
    Write-Host "  Key Vault     : $KeyVaultName"
}

# ---------------------------------------------------------------------------
# 2. Validate the endpoint URL against the rules Microsoft enforces per delivery
# ---------------------------------------------------------------------------
Write-Step 'Validating the endpoint URL'

$uri = [System.Uri]::new($EndpointUrl)

if ($uri.Scheme -ne 'https') {
    throw "The endpoint must use HTTPS. Got '$($uri.Scheme)'."
}
if ($uri.IsLoopback) {
    throw 'The endpoint must not be a loopback address. Microsoft rejects these before sending.'
}
if ($uri.HostNameType -in @('IPv4', 'IPv6')) {
    throw 'The endpoint must use a hostname, not a literal IP address.'
}

$endpointHost = $uri.Host
Write-Host "  Endpoint host : $endpointHost"

# ---------------------------------------------------------------------------
# 3. Read the existing stage-1 application
# ---------------------------------------------------------------------------
Write-Step 'Connecting to Microsoft Graph'

# The SDK owns its own refreshable credentials; an Azure CLI access token is not interchangeable.
Connect-EndpointGraph
$ApplicationId = Read-SetupValue -Name ApplicationId -DefaultValue $ApplicationId -Required -ValueType Guid
$application = Get-CyotApplication -ApplicationId $ApplicationId -RequireMultiTenant
$appId = $application.AppId
$graphContext = Get-MgContext -ErrorAction Stop
$tenantId = $script:GraphTenantId
Write-Host "  Graph account : $($graphContext.Account)"
Write-Host "  Tenant        : $tenantId"

# ---------------------------------------------------------------------------
# 4. Encryption certificate
# ---------------------------------------------------------------------------
Write-Step 'Preparing the encryption certificate'

$CertificatePath = Read-SetupValue -Name CertificatePath -DefaultValue $CertificatePath -ValueType File
if ($CertificatePath) {
    $certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($CertificatePath)
    Write-Host "  Using         : $CertificatePath"
}
else {
    # Reuse a certificate this script created earlier for the same host, if one is still valid.
    # Minting a fresh certificate on every run leaves a trail of key credentials on the application
    # and orphaned private keys in the store, which makes "safe to re-run" untrue in the one place
    # it matters most.
    $subject = "CN=$endpointHost External Phone Provider Encryption"
    $certificate = Get-ChildItem Cert:\CurrentUser\My |
        Where-Object { $_.Subject -eq $subject -and $_.HasPrivateKey -and $_.NotAfter -gt (Get-Date).AddDays(30) } |
        Sort-Object NotAfter -Descending |
        Select-Object -First 1

    if ($certificate) {
        Write-Host "  Reusing       : $($certificate.Thumbprint) (expires $($certificate.NotAfter.ToString('yyyy-MM-dd')))"
    }
    elseif ($StartFromStep -gt 4) {
        throw "No reusable encryption certificate was found for '$endpointHost'. Resume with -StartFromStep 4 or supply -CertificatePath."
    }
    else {
        # RSA 2048 is the minimum Microsoft accepts. Keep the private key safe: it is the only thing
        # that can open a passcode, and Microsoft never has a copy.
        Confirm-SetupAction -Action 'create encryption certificate' -Target $subject `
            -Details "RSA 2048, one-year validity, CurrentUser\My. The public certificate will be exported alongside this script."
        $certificate = New-SelfSignedCertificate `
            -Subject $subject `
            -CertStoreLocation 'Cert:\CurrentUser\My' `
            -KeyAlgorithm RSA `
            -KeyLength 2048 `
            -KeyExportPolicy Exportable `
            -KeyUsage KeyEncipherment, DataEncipherment `
            -NotAfter (Get-Date).AddYears(1)

        $exportPath = Join-Path $PSScriptRoot "phone-provider-encryption-$endpointHost.cer"
        Export-Certificate -Cert $certificate -FilePath $exportPath -Force | Out-Null

        Write-Host "  Created       : $($certificate.Thumbprint)"
        Write-Host "  Public copy   : $exportPath"
    }
}

if ($certificate.PublicKey.Key.KeySize -lt 2048) {
    throw "The encryption key must be at least 2048 bits. Got $($certificate.PublicKey.Key.KeySize)."
}

# ---------------------------------------------------------------------------
# 5. Reuse the stage-1 registration
# ---------------------------------------------------------------------------
Write-Step 'Configuring the application from stage 1'
Write-Host "  Reusing       : $appId ($($application.DisplayName))"

# ---------------------------------------------------------------------------
# 6. Identifier URI - binds the application to the endpoint host
# ---------------------------------------------------------------------------
Write-Step 'Publishing the identifier URI'

# Host only. No port, no path. Microsoft builds this same string and asks Entra for a token against
# it, so a mismatch means no token is ever issued and nothing is delivered.
$identifierUri = "api://$endpointHost/$appId"

$existingUris = @($application.IdentifierUris)
if ($existingUris -notcontains $identifierUri) {
    if ($StartFromStep -gt 6) {
        throw "Identifier URI '$identifierUri' is missing. Resume with -StartFromStep 6."
    }
    Invoke-EndpointGraph {
        Update-MgApplication -ApplicationId $application.Id -IdentifierUris (@($existingUris) + $identifierUri) -ErrorAction Stop
    }
}

Write-Host "  Identifier URI: $identifierUri"

# ---------------------------------------------------------------------------
# 7. Key credential with usage Encrypt
# ---------------------------------------------------------------------------
Write-Step 'Publishing the encryption key'

# usage must be 'Encrypt'. A signing credential is not interchangeable, and Microsoft filters on this.
#
# An existing credential for this same certificate is reused. Publishing a second credential for a
# certificate the application already carries leaves stale keys accumulating on the registration,
# and every one of them is a key someone could later be confused by.
$certHash = $certificate.GetCertHash()
$existingCredential = @($application.KeyCredentials) |
    Where-Object { $_.CustomKeyIdentifier -and (-not (Compare-Object $_.CustomKeyIdentifier $certHash)) } |
    Select-Object -First 1

if ($existingCredential) {
    $keyId = $existingCredential.KeyId
    Write-Host "  Key id        : $keyId (already published)"
}
else {
    if ($StartFromStep -gt 7) {
        throw "The encryption certificate is not published on the application. Resume with -StartFromStep 7."
    }
    $keyId = [Guid]::NewGuid().ToString()
    Confirm-SetupAction -Action 'publish new encryption key credential' -Target "$appId / $keyId" `
        -Details "Tenant: $tenantId; certificate: $($certificate.Thumbprint). Only the public key is published."

    $keyCredential = @{
        CustomKeyIdentifier = $certHash
        DisplayName         = "external phone provider encryption $($certificate.Thumbprint)"
        Key                 = $certificate.GetRawCertData()
        KeyId               = $keyId
        Type                = 'AsymmetricX509Cert'
        Usage               = 'Encrypt'
        StartDateTime       = $certificate.NotBefore.ToUniversalTime()
        EndDateTime         = $certificate.NotAfter.ToUniversalTime()
    }

    $currentKeys = @($application.KeyCredentials | Where-Object { $_.KeyId -ne $keyId })

    Invoke-EndpointGraph {
        Update-MgApplication -ApplicationId $application.Id `
            -KeyCredentials (@($currentKeys) + $keyCredential) `
            -TokenEncryptionKeyId $keyId -ErrorAction Stop
    }

    Write-Host "  Key id        : $keyId"
}

# Nominated every time: on a reused credential this is a no-op, and on a rotation it is the step
# that actually points Microsoft at the new key.
if ($StartFromStep -gt 7 -and $application.TokenEncryptionKeyId -ne $keyId) {
    throw "The published key is not nominated as tokenEncryptionKeyId. Resume with -StartFromStep 7."
}
if ($StartFromStep -le 7) {
    Invoke-EndpointGraph {
        Update-MgApplication -ApplicationId $application.Id -TokenEncryptionKeyId $keyId -ErrorAction Stop
    }
}
Write-Host '  Nominated as tokenEncryptionKeyId'

# ---------------------------------------------------------------------------
# 8. Service principals
# ---------------------------------------------------------------------------
Write-Step 'Creating service principals'

$endpointSp = if ($StartFromStep -le 8) {
    Ensure-CyotEndpointServicePrincipal -ApplicationId $appId
}
else {
    Invoke-EndpointGraph { Get-MgServicePrincipal -Filter "appId eq '$appId'" -ErrorAction Stop } | Select-Object -First 1
}
if (-not $endpointSp) { throw "The endpoint service principal is missing. Resume with -StartFromStep 8." }
Write-Host "  Endpoint SP   : $($endpointSp.Id)"

# Microsoft's application is normally provisioned on first use. Creating it now turns a first-call
# failure into a setup-time one, which is easier to diagnose. Nothing is granted to it.
$microsoftSp = Invoke-EndpointGraph {
    Get-MgServicePrincipal -Filter "appId eq '$MicrosoftPhoneProviderAppId'" -ErrorAction Stop
} |
    Select-Object -First 1

if (-not $microsoftSp) {
    if ($StartFromStep -gt 8) {
        throw "The Microsoft phone-provider service principal is missing. Resume with -StartFromStep 8."
    }
    Confirm-SetupAction -Action 'create Microsoft service principal in this tenant' -Target $MicrosoftPhoneProviderAppId `
        -Details "Tenant: $tenantId. No application permissions are granted by this action."
    $microsoftSp = Invoke-EndpointGraph {
        New-MgServicePrincipal -AppId $MicrosoftPhoneProviderAppId -ErrorAction Stop
    }
    Write-Host '  Microsoft SP  : created'
}
else {
    Write-Host '  Microsoft SP  : exists'
}

# ---------------------------------------------------------------------------
# 9. Secure the Function, tell it what to accept, and deploy the code
# ---------------------------------------------------------------------------
# Deferred to here because none of it can be known until the application exists: the audience is
# built from the hostname and the application id, so the Function has to be created bare in step 1
# and secured on a second pass once the registration is in place.
if ($provisionFunction -and $StartFromStep -le 9) {
    Write-Step 'Storing the private key in Key Vault'

    # PKCS#8 is the form crypto.createPrivateKey and most libraries read without coaxing. Base64 on
    # top of it so the PEM's newlines survive being carried as a secret value and then as an
    # environment variable.
    $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($certificate)
    if (-not $rsa) { throw 'The certificate carries no RSA private key.' }

    $pemBuilder = [System.Text.StringBuilder]::new()
    [void]$pemBuilder.AppendLine('-----BEGIN PRIVATE KEY-----')
    [void]$pemBuilder.AppendLine([Convert]::ToBase64String($rsa.ExportPkcs8PrivateKey(), [Base64FormattingOptions]::InsertLineBreaks))
    [void]$pemBuilder.AppendLine('-----END PRIVATE KEY-----')

    $secretValue = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($pemBuilder.ToString()))
    $secretName = 'phone-provider-decryption-key'
    Confirm-SetupAction -Action 'create a Key Vault secret version' -Target "$KeyVaultName/$secretName" `
        -Details 'Stores the encryption private key. An existing secret will receive a new version; its value is never displayed.'

    # Role assignments on a new vault take time to reach the data plane, and the first write is what
    # discovers that. Retried rather than failed, because the alternative is a script that works only
    # on the second run.
    $secretId = $null
    $secretArguments = @('keyvault', 'secret', 'set',
        '--vault-name', $KeyVaultName, '--name', $secretName, '--value', $secretValue,
        '--query', 'id', '--output', 'tsv', '--only-show-errors')
    foreach ($attempt in 1..6) {
        $secretResult = Invoke-AzResult -Arguments $secretArguments
        if ($secretResult.ExitCode -eq 0) {
            $secretId = ($secretResult.Lines -join '').Trim()
            if (-not $secretId) { throw 'Key Vault returned success without a secret ID.' }
            break
        }

        if ($attempt -eq 6 -or ($secretResult.Lines -join "`n") -notmatch
            'ForbiddenByRbac|Caller is not authorized to perform action on resource') {
            Assert-AzCommandSucceeded -Result $secretResult -Arguments $secretArguments
        }
        Write-Host "  Key Vault RBAC: waiting for the secret-write permission (attempt $attempt/6)" -ForegroundColor DarkGray
        Start-Sleep -Seconds 15
    }

    # Versionless, so rotating the key does not require touching the app setting.
    $secretUri = ($secretId -replace '/[^/]+$', '')
    Write-Host "  Secret        : $secretName"
    Write-Host "  Reference     : $secretUri"

    Write-Step 'Configuring and deploying the Function'

    # A reused application may have been created in the portal, which pins v2. Read what is actually
    # there rather than assuming, because the token version decides both aud and iss, and a validator
    # configured for the wrong one rejects every delivery.
    $tokenVersion = 1
    if ($application.PSObject.Properties.Name -contains 'Api' -and $application.Api -and
        $application.Api.RequestedAccessTokenVersion) {
        $tokenVersion = [int]$application.Api.RequestedAccessTokenVersion
    }

    if ($tokenVersion -eq 2) {
        $issuer = "https://login.microsoftonline.com/$tenantId/v2.0"
        $expectedAudience = $appId
    }
    else {
        $issuer = "https://sts.windows.net/$tenantId/"
        $expectedAudience = $identifierUri
    }

    Write-Host "  Token version : v$tokenVersion"
    Write-Host "  Expected aud  : $expectedAudience"

    # Everything the Function needs, in one write. The provider values reach here from three
    # different places -- the selection, the security store and the customer -- but they are all
    # ordinary app settings by the time the Function reads them.
    #
    # The key is the exception: it is a Key Vault reference the platform resolves with the managed
    # identity, so the private key itself is never stored here.
    $appSettings = @{
        EPP_EXPECTED_AUDIENCE  = $expectedAudience
        EPP_EXPECTED_ISSUER    = $issuer
        EPP_EXPECTED_CLIENT_ID = $MicrosoftPhoneProviderAppId
        EPP_TENANT_ID          = $tenantId
        EPP_ENCRYPTION_KEY_ID  = $keyId
        EPP_DECRYPTION_KEY_PEM = "@Microsoft.KeyVault(SecretUri=$secretUri)"
    }

    # An omitted int parameter defaults to 0 in PowerShell; distinguish it from a supplied 0.
    $providerSettings = Get-ProviderAppSettings -Name $ProviderName -Endpoint $ProviderEndpoint `
        -TimeoutMs $(if ($PSBoundParameters.ContainsKey('ProviderTimeoutMs')) { $ProviderTimeoutMs } else { $null }) `
        -RetryIntervalMs $(if ($PSBoundParameters.ContainsKey('ProviderRetryIntervalMs')) { $ProviderRetryIntervalMs } else { $null }) `
        -AccountName $ProviderAccountName
    foreach ($setting in $providerSettings.Keys) { $appSettings[$setting] = $providerSettings[$setting] }
    $providerEntraSettings = Get-ProviderEntraSettings -ProviderTenantId $ProviderTenantId -ProviderScope $ProviderScope
    $outboundSettings = Ensure-CyotProviderIdentity -FunctionName $FunctionAppName -Group $ResourceGroup `
        -Region $Location -Tag $resourceTag -IdentityName $OutboundIdentityName -Application $application
    foreach ($setting in $providerEntraSettings.Keys) { $appSettings[$setting] = $providerEntraSettings[$setting] }
    foreach ($setting in $outboundSettings.Keys) { $appSettings[$setting] = $outboundSettings[$setting] }
    Write-Host '  Provider auth : Entra token exchange via a user-assigned managed identity; no client secret'
    Write-Host '  The deployed package must read EPP_OUTBOUND_MI_CLIENT_ID explicitly; do not set AZURE_CLIENT_ID globally.' -ForegroundColor Yellow

    # --- Application Insights without a usable ingestion key -------------------------------------
    # The connection string cannot be removed -- it carries the ingestion endpoints -- but the
    # instrumentation key inside it stops being a credential once local auth is off and telemetry
    # has to be published with an Entra token.
    $insightsArguments = @('resource', 'show', '--resource-group', $ResourceGroup, '--name', $FunctionAppName,
        '--resource-type', 'Microsoft.Insights/components', '--query', 'id', '--output', 'tsv', '--only-show-errors')
    $insightsResult = Invoke-AzResult -Arguments $insightsArguments
    if ($insightsResult.ExitCode -ne 0 -and ($insightsResult.Lines -join "`n") -notmatch '\bResourceNotFound\b') {
        Assert-AzCommandSucceeded -Result $insightsResult -Arguments $insightsArguments
    }

    if ($insightsResult.ExitCode -eq 0) {
        $insightsId = ($insightsResult.Lines -join '').Trim()
        if (-not $insightsId) { throw 'Application Insights lookup returned success without a resource ID.' }
        Ensure-AzRoleAssignment -ObjectId $principalId -PrincipalType ServicePrincipal `
            -Role 'Monitoring Metrics Publisher' -Scope $insightsId

        Invoke-Az rest --method patch --url "${insightsId}?api-version=2020-02-02" `
            --body '{\"properties\":{\"DisableLocalAuth\":true}}' `
            --headers 'Content-Type=application/json' -o none --only-show-errors | Out-Null

        $appSettings['APPLICATIONINSIGHTS_AUTHENTICATION_STRING'] = 'Authorization=AAD'
        Write-Host '  App Insights  : Entra auth, ingestion key disabled'
    }

    $written = Set-FunctionAppSettings -Name $FunctionAppName -ResourceGroup $ResourceGroup `
        -SubscriptionId $resolvedSubscriptionId -Settings $appSettings

    Write-Host "  App settings  : $($appSettings.Count) applied, $written total"

    if (-not $NoEasyAuth) {
        # A newly created app starts on auth v1, and every v2 command refuses to run until it is
        # upgraded -- including the one below. The upgrade is a no-op on an app already on v2, so it
        # is unconditional apart from the check that keeps the log honest.
        $authVersion = (Invoke-Az webapp auth config-version show `
                --name $FunctionAppName `
                --resource-group $ResourceGroup `
                --query configVersion -o tsv)

        if ($authVersion -ne 'v2') {
            Invoke-Az webapp auth config-version upgrade `
                --name $FunctionAppName `
                --resource-group $ResourceGroup | Out-Null

            Write-Host "  Auth config   : upgraded $authVersion -> v2"
        }

        # allowedApplications is the part that matters and the part that is easy to leave out.
        #
        # Because assignment is not required on the endpoint service principal, any application in
        # this tenant can ask Entra for a token audienced to this endpoint and will get one. Easy
        # Auth on its own only proves the token is real and meant for this resource, so without an
        # allowed-caller list any internal application could post forged passcodes. Pinning the
        # caller to Microsoft's first-party application is what closes that.
        $authSettings = @{
            platform          = @{
                enabled        = $true
                runtimeVersion = '~1'
            }
            globalValidation  = @{
                requireAuthentication = $true

                # Must not be RedirectToLoginPage. A 302 carrying an HTML sign-in page is not a 2xx,
                # so Microsoft would record a failed delivery and re-send over native telephony.
                unauthenticatedClientAction = 'Return401'
            }
            identityProviders = @{
                azureActiveDirectory = @{
                    enabled      = $true
                    registration = @{
                        openIdIssuer = $issuer
                        clientId     = $appId
                    }
                    validation   = @{
                        allowedAudiences           = @($expectedAudience)
                        defaultAuthorizationPolicy = @{
                            allowedApplications = @($MicrosoftPhoneProviderAppId)
                        }
                    }
                }
            }

            # Nothing here is a sign-in, so there is no token worth storing and no reason to pay for
            # the storage round trip on a path with a 3.2 s budget.
            login             = @{
                tokenStore = @{ enabled = $false }
            }
        }

        # Written without a byte order mark: the Azure CLI reads @file as UTF-8 and a BOM makes the
        # JSON parse fail with an unhelpful error.
        $authFile = Join-Path ([System.IO.Path]::GetTempPath()) "epp-auth-$([Guid]::NewGuid()).json"
        [System.IO.File]::WriteAllText(
            $authFile,
            ($authSettings | ConvertTo-Json -Depth 10),
            [System.Text.UTF8Encoding]::new($false))

        try {
            # az webapp auth, not az functionapp auth. There is no functionapp equivalent, and the
            # microsoft update subcommand cannot express allowedApplications, so the whole v2
            # settings document is written at once.
            Invoke-Az webapp auth set `
                --name $FunctionAppName `
                --resource-group $ResourceGroup `
                --body "@$authFile" | Out-Null
        }
        finally {
            Remove-Item $authFile -Force -ErrorAction SilentlyContinue
        }

        Write-Host '  Easy Auth     : enabled, 401 on anything not from Microsoft'
        Write-Host '  Your function trigger must use AuthorizationLevel.Anonymous.' -ForegroundColor Yellow
        Write-Host '  Easy Auth is the gate; a function key would only add a secret to the endpoint URL.'
    }
    else {
        Write-Host '  Easy Auth     : skipped, validate the bearer token in your own code' -ForegroundColor Yellow
    }

    # Resolve where the package comes from. A local file wins, then an explicit URL, then the
    # reference package Microsoft publishes — skipped while that is still a placeholder.
    $packageToDeploy = $null
    $downloadedPackage = $null

    if ($ZipPath) {
        if (-not (Test-Path -LiteralPath $ZipPath -PathType Leaf)) {
            throw "Zip package not found: $ZipPath"
        }

        $packageToDeploy = (Resolve-Path -LiteralPath $ZipPath).Path
    }
    else {
        # A local file wins, then an explicit URL, then the published reference package. The last of
        # those is skipped while it is still a placeholder, so an unreleased build provisions
        # everything and simply leaves the Function without code rather than failing on a bad host.
        $sourceUrl = if ($ZipUrl) {
            Read-SetupValue -Name ZipUrl -DefaultValue $ZipUrl -ValueType HttpsUrl -Secret
        }
        elseif ($ReferencePackageUrl -notmatch '[<>]') {
            $ReferencePackageUrl
        }
        else {
            $null
        }

        if ($sourceUrl) {
            # Zip deploy pushes a local file. Flex Consumption does not honour
            # WEBSITE_RUN_FROM_PACKAGE against a URL, so fetching the package here and pushing it is
            # the one path that behaves the same on every plan.
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $previousProgress = $ProgressPreference
            $ProgressPreference = 'SilentlyContinue'

            $downloadedPackage = Join-Path ([System.IO.Path]::GetTempPath()) "epp-package-$([Guid]::NewGuid()).zip"

            # A blob URL usually carries a SAS token. Printing it whole would put a live credential in
            # the console and in any transcript, so the query string is masked.
            Write-Host "  Package       : $($sourceUrl -replace '\?.*$', '?<sas redacted>')"

            try {
                Invoke-WebRequest -Uri $sourceUrl -OutFile $downloadedPackage -UseBasicParsing
            }
            catch {
                throw "Could not download the package. Check the URL and that its SAS token has not expired.`n$($_.Exception.Message)"
            }
            finally {
                $ProgressPreference = $previousProgress
            }

            $packageToDeploy = $downloadedPackage
        }
    }

    if ($packageToDeploy) {
        try {
            Confirm-SetupAction -Action 'deploy the Function package' -Target $FunctionAppName `
                -Details 'This updates the Function code and writes its deployment package to storage.'
            Invoke-Az functionapp deployment source config-zip `
                --name $FunctionAppName `
                --resource-group $ResourceGroup `
                --src $packageToDeploy | Out-Null

            Write-Host '  Deployed      : package pushed'
        }
        finally {
            if ($downloadedPackage) {
                Remove-Item $downloadedPackage -Force -ErrorAction SilentlyContinue
            }
        }
    }
    else {
        Write-Host '  No package supplied. Deploy your code before requesting enablement.' -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------------------
# 10. Tag everything
# ---------------------------------------------------------------------------
# Done as a sweep rather than only at create time. 'az functionapp create' brings up an App Service
# plan and an Application Insights component of its own accord, and neither takes a tag from this
# script, so tagging only what is created explicitly leaves resources the portal will not find.
# Incremental, so any tags a customer already applies are left alone.
if ($provisionFunction -and $StartFromStep -le 10) {
    Write-Step 'Tagging resources'

    Invoke-Az tag update `
        --resource-id "/subscriptions/$resolvedSubscriptionId/resourceGroups/$ResourceGroup" `
        --operation Merge --tags $resourceTag --output none | Out-Null
    $resourceIds = @(Invoke-Az resource list --resource-group $ResourceGroup --query "[].id" -o tsv)

    foreach ($resourceId in $resourceIds) {
        if ([string]::IsNullOrWhiteSpace($resourceId)) { continue }

        $tagArguments = @('resource', 'tag', '--ids', $resourceId, '--tags', $resourceTag,
            '--is-incremental', '--output', 'none', '--only-show-errors')
        $tagResult = Invoke-AzResult -Arguments $tagArguments
        if ($tagResult.ExitCode -ne 0) {
            if (Test-AuthenticationFailure ($tagResult.Lines -join "`n")) {
                Assert-AzCommandSucceeded -Result $tagResult -Arguments $tagArguments
            }
            # Some resource types reject tagging. Not worth failing a provisioning run over.
            Write-Warning "Could not tag $($resourceId.Split('/')[-1]): $($tagResult.Lines -join ' ')"
        }
    }

    Write-Host "  Tag           : $ResourceTagName = $ResourceTagValue"
    Write-Host "  Applied to    : $($resourceIds.Count) resources and the resource group"
}

# ---------------------------------------------------------------------------
# 11. Summary
# ---------------------------------------------------------------------------
Write-Step 'Stage 2 complete: save these values for policy activation'

$stageResult = [PSCustomObject]@{
    Stage           = 2
    TenantId        = $tenantId
    EndpointUrl     = $EndpointUrl
    ApplicationId   = $appId
    IdentifierUri   = $identifierUri
    EncryptionKeyId = $keyId
    CertThumbprint  = $certificate.Thumbprint
}

if ($provisionFunction) {
    Write-Host "Private key is in Key Vault '$KeyVaultName' as 'phone-provider-decryption-key'." -ForegroundColor DarkGray
    Write-Host 'No secret is stored in app settings; the Function resolves it with its managed identity.' -ForegroundColor DarkGray
    Write-Host ''
}

Write-Host 'Before requesting enablement, confirm your endpoint:' -ForegroundColor Yellow
Write-Host "  1. rejects any caller that is not $MicrosoftPhoneProviderAppId (Easy Auth, or your own code)"
Write-Host '  2. decrypts the JWE using the private key named by kid'
Write-Host '  3. returns 2xx with the SAME nonce it decrypted'
Write-Host '  4. reads voice passcodes digit by digit'
Write-Host '  5. responds within 3.2 seconds, delivering asynchronously'
Write-Host 'CYOT policy has not been enabled. Check its live Graph schema in the separate policy-activation stage.' -ForegroundColor Yellow
Write-SetupEvent -Level INFO -Message 'Stage 2 completed successfully. CYOT policy remains disabled pending stage 3.'
$stageSucceeded = $true
}
catch {
    Write-SetupFailure -ErrorRecord $_
    if ($script:EventLogPath) {
        Write-SetupEvent -Level WARN -Message "After correcting the failure, rerun with the same parameters and -StartFromStep $StartFromStep. Choose an earlier step if the error reports a missing prerequisite."
    }
    throw
}
finally {
    if (-not $stageSucceeded -and $script:EventLogPath) {
        Write-SetupEvent -Level WARN -Message 'Stage 2 ended before successful completion. Review the event log and transcript.'
    }
    if ($script:TranscriptStarted) {
        Stop-Transcript | Out-Null
        $script:TranscriptStarted = $false
    }
}

if ($script:EventLogPath) {
    Write-Host "Event log : $script:EventLogPath" -ForegroundColor DarkGray
    Write-Host "Transcript: $script:TranscriptPath" -ForegroundColor DarkGray
}
$stageResult