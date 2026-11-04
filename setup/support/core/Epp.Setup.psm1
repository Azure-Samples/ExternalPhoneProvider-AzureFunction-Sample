#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:MicrosoftPhoneProviderAppId = '25ec60fa-f18d-41a4-b398-50044c90ce13'
$script:MicrosoftGraphAppId = '00000003-0000-0000-c000-000000000000'
$script:MicrosoftGraphApplicationReadAllRoleId = '9a5d68dd-52b0-4cc2-bd40-abcf44ac3a30'
$script:EppInvokeAppRoleId = 'ddf32018-9212-41c7-b73c-f5dfe73a2f24'
$script:EppInvokeAppRoleValue = 'Epp.Invoke'
$script:EppCertificateName = 'phone-provider-encryption'
$script:EppCertificateSubject = 'CN=ExternalPhoneProvider'
$script:KeyVaultSecretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'
. (Join-Path $PSScriptRoot 'Epp.Input.ps1')
. (Join-Path $PSScriptRoot 'Epp.Azure.ps1')
. (Join-Path $PSScriptRoot 'Epp.Graph.ps1')
. (Join-Path $PSScriptRoot '..' 'deployment' 'Epp.Packages.ps1')
. (Join-Path $PSScriptRoot '..' 'planning' 'Epp.Selection.ps1')
. (Join-Path $PSScriptRoot '..' 'planning' 'Epp.Providers.ps1')
. (Join-Path $PSScriptRoot '..' 'planning' 'Epp.Preflight.ps1')
. (Join-Path $PSScriptRoot '..' 'planning' 'Epp.Presentation.ps1')
. (Join-Path $PSScriptRoot '..' 'deployment' 'Epp.Certificates.ps1')
. (Join-Path $PSScriptRoot '..' '..' 'Epp.Application.ps1')
. (Join-Path $PSScriptRoot '..' 'deployment' 'Epp.Deployment.ps1')
. (Join-Path $PSScriptRoot '..' '..' 'Epp.Arm.ps1')
. (Join-Path $PSScriptRoot '..' '..' 'Epp.PostArm.ps1')

function Invoke-EppDeployment {
    param(
        [hashtable] $Inputs, [Collections.IDictionary] $Names, $ProviderConfiguration, $Context,
        [string] $AssetDirectory, [string] $WorkingDirectory, $Package, [string] $OutputDirectory
    )

    $ConfirmPreference = 'None'
    $armState = $null
    try {
        Write-Host "`nStage 1/3: Prepare the endpoint application" -ForegroundColor Cyan
        $applicationState = Initialize-EppApplication -Inputs $Inputs -Names $Names -ProviderConfiguration $ProviderConfiguration `
            -Context $Context -OutputDirectory $OutputDirectory
        Write-Host "`nStage 2/3: Deploy resources and Function code through ARM" -ForegroundColor Cyan
        $armState = Invoke-EppArmDeployment -Inputs $Inputs -ApplicationState $applicationState -ProviderConfiguration $ProviderConfiguration `
            -Context $Context -AssetDirectory $AssetDirectory -WorkingDirectory $WorkingDirectory -Package $Package -OutputDirectory $OutputDirectory
        Write-Host "`nStage 3/3: Complete application trust and verify the endpoint" -ForegroundColor Cyan
        return Complete-EppConfiguration -Inputs $Inputs -ArmState $armState -ProviderConfiguration $ProviderConfiguration `
            -Context $Context -AssetDirectory $AssetDirectory -WorkingDirectory $WorkingDirectory -OutputDirectory $OutputDirectory
    }
    finally { if ($armState) { $armState.Issued.Certificate.Dispose() } }
}

function Invoke-EppSetup {
    <#
    .SYNOPSIS
        Configure and deploy one External Phone Provider endpoint in Azure.
    .DESCRIPTION
        Uses commit-pinned infrastructure, provider profiles, and setup helpers downloaded by
        Setup-Epp.ps1. Downloads and verifies the selected Function ZIP from a stable GitHub release.
        Each language ZIP contains the application and its production dependencies.
        Azure CLI and its Bicep component are required. The Bicep component can be installed
        after confirmation. Interactive setup can create a dedicated app
        registration after deployment approval. Policy activation remains manual.
        Review the complete plan before approving resource or tenant changes.
        Microsoft Graph calls reuse the existing Azure CLI user session through az ad and az rest.
        No Microsoft Graph PowerShell SDK or separate Graph sign-in is required.
        Interactive setup discovers cached Azure CLI accounts before asking for other settings.
        Choose a tenant and subscription, or explicitly refresh/sign in when the list is incomplete.
        Enter accepts the displayed default; 0 or Cancel cancels where offered.
        Provider selection has no default, and final deployment approval defaults to No.
    .PARAMETER TenantId
        Customer tenant ID. When omitted interactively, select from cached Azure subscriptions,
        or resolve it from an explicitly supplied subscription. Required in noninteractive mode.
        The interactive default is the current CLI tenant, or the first eligible tenant.
    .PARAMETER SubscriptionId
        Azure subscription ID. When omitted interactively, select an enabled user subscription
        in the chosen tenant. Required in noninteractive mode.
        Defaults to the current CLI subscription in that tenant, or its first eligible subscription.
    .PARAMETER ApplicationId
        Existing application client ID. When omitted interactively, use the current CLI tenant
        to choose/search an app registration, enter its client ID, or plan a new application.
        Enter at the picker or manual client-ID prompt defaults to creating a new application.
        The new application display name defaults to EPP Application when Enter is pressed.
        A new application is created only after final deployment approval. Required in noninteractive mode.
    .PARAMETER Provider
        Provider name, never a numbered selection. When omitted interactively, read the app's
        allowed-tenants configuration: enter a name if none match, confirm one match, or choose
        by name among multiple matches. New applications show supported providers alphabetically.
        Blank provider-name input prompts again; there is no default provider.
        Explicit input confirms the choice; required unattended.
    .PARAMETER Location
        Azure region name. When omitted interactively, choose an Azure-recommended shortlist,
        show all physical regions returned for the subscription, or enter the name manually.
        Enter accepts the first region in the displayed list.
        EU tenants receive EU Data Boundary recommendations; explicit out-of-boundary choices warn.
        Recommendations do not guarantee plan availability or quota. Required noninteractively.
    .PARAMETER EndpointRegion
        Optional eu/global provider route assertion. Setup detects the tenant replication scope
        and rejects a conflicting value. Omit to use the detected route.
    .PARAMETER Language
        JavaScript by default, without a prompt. Use csharp or python to select another language.
        The legacy dotnet value remains supported for C#.
    .PARAMETER ResourcePrefix
        Interactive resource-name prefix, defaulting to epp on Enter. Required noninteractively.
    .PARAMETER PackageReleaseTag
        Latest stable package release by default. Supply an epp-packages-<run>-<attempt>-<language> tag
        to pin a reviewed Function release.
    .PARAMETER OutputDirectory
        Destination for deployment summaries and public certificates.
    .PARAMETER CertificateAction
        Create when no encryption certificate is registered, Reuse a selected certificate,
        or Replace all registered encryption certificates after explicit approval.
        Interactive selection defaults to Replace when encryption certificates exist.
        Unattended runs with existing certificates still require an explicit action.
    .PARAMETER EncryptionKeyId
        App-registration key ID to keep when reusing a certificate. Required for unattended reuse.
    .PARAMETER KeyVaultCertificateId
        Versioned Key Vault certificate URL for reuse, not a public certificate or secret value.
    .PARAMETER KeyVaultSubscriptionId
        Subscription containing the reused certificate. Defaults to the deployment subscription.
    .PARAMETER ForceAuthentication
        Explicitly request a new Azure CLI device-code sign-in. Omit in Cloud Shell to reuse
        its existing login. Graph always uses the resulting CLI session, never a separate SDK login.
    .PARAMETER InstallPrerequisites
        Install the Azure CLI Bicep component if it is missing. The Graph SDK is not required.
    .PARAMETER PassThru
        Return the structured deployment summary. By default, only the ordered human-readable
        result is displayed, ending with Next steps; the summary JSON is always saved.
    .PARAMETER NonInteractive
        Require mandatory settings and existing user authentication. Language defaults to JavaScript
        and provider routing is detected from the tenant. Does not approve deployment.
    .PARAMETER ApproveDeployment
        Authorize the displayed deployment plan without another prompt. This changes Azure
        resources and application configuration; it is not a preview.
    .EXAMPLE
        Invoke-EppSetup
    .EXAMPLE
        Invoke-EppSetup -ForceAuthentication -ServicePlan FC1 -Language javascript
    .OUTPUTS
        System.Management.Automation.PSCustomObject
        With PassThru, the completed deployment summary. Cancellation returns no object.
    #>
    [CmdletBinding()]
    param(
        [string] $TenantId, [string] $SubscriptionId, [string] $ApplicationId, [string] $Location,
        [string] $Provider, [string] $EndpointRegion,
        [string] $ResourcePrefix,
        [string] $Language = 'javascript',
        [string] $PackageReleaseTag,
        [string] $ServicePlan,
        [ValidateSet('Create', 'Reuse', 'Replace')]
        [string] $CertificateAction,
        [string] $EncryptionKeyId, [string] $KeyVaultCertificateId, [string] $KeyVaultSubscriptionId,
        [string] $OutputDirectory = (Join-Path (Get-Location).Path 'epp-output'),
        [string] $AssetDirectory, [string] $SourceBaseUri,
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$')]
        [string] $SourceRepository = 'Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample',
        [switch] $NonInteractive, [switch] $InstallPrerequisites,
        [switch] $ForceAuthentication, [switch] $ApproveDeployment, [switch] $PassThru
    )

    if ($NonInteractive -and $ForceAuthentication) {
        throw '-ForceAuthentication requires interactive device-code sign-in and cannot be combined with -NonInteractive.'
    }
    if ($NonInteractive) { $ProgressPreference = 'SilentlyContinue' }
    if (-not (Test-Path -LiteralPath $AssetDirectory -PathType Container)) {
        throw 'Setup assets are missing. Run Setup-Epp.ps1 instead of invoking the temporary helper directly.'
    }
    $sourcePattern = '^https://raw\.githubusercontent\.com/' + [regex]::Escape($SourceRepository) + '/(?<revision>[0-9a-fA-F]{40})/setup$'
    if ($SourceBaseUri -cnotmatch $sourcePattern) {
        throw 'Setup assets must come from one commit-pinned source repository.'
    }
    $sourceRevision = $Matches.revision.ToLowerInvariant()
    $OutputDirectory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
    $assetPrefix = $AssetDirectory.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if ($OutputDirectory.Equals($AssetDirectory, [StringComparison]::OrdinalIgnoreCase) -or
        $OutputDirectory.StartsWith($assetPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw '-OutputDirectory must be outside the temporary setup download directory.'
    }
    $workingDirectory = Join-Path ([IO.Path]::GetTempPath()) "epp-setup-$([Guid]::NewGuid().ToString('N'))"
    try {
        New-Item -ItemType Directory -Path $workingDirectory | Out-Null
        Write-Host "`nExternal Phone Provider (EPP) setup" -ForegroundColor Cyan
        Write-Host 'Connect Microsoft Entra ID to your phone provider for SMS and voice one-time passwords.'
        $azureContext = Select-EppAzureContext -TenantId $TenantId -SubscriptionId $SubscriptionId -NonInteractive:$NonInteractive
        if (-not $azureContext) {
            Write-Host 'Cancelled. No Azure resources or application credentials were changed.' -ForegroundColor Yellow
            return
        }
        Write-Host "`nEnter remaining customer settings. Supplied values will not be requested again."
        $inputs = @{
            SourceBaseUri = $SourceBaseUri
            SourceRevision = $sourceRevision
            TenantId = $azureContext.TenantId
            SubscriptionId = $azureContext.SubscriptionId
        }
        $inputs.ApplicationId = Select-EppApplication -Inputs $inputs -ApplicationId $ApplicationId -NonInteractive:$NonInteractive `
            -InstallPrerequisites:$InstallPrerequisites -ForceAuthentication:$ForceAuthentication
        if (-not $inputs.ApplicationId) {
            Write-Host 'Cancelled. No Azure resources or application credentials were changed.' -ForegroundColor Yellow
            return
        }
        if ($inputs.ApplicationId -ceq 'create') {
            $inputs.ApplicationId = $null
            $inputs.NewApplicationDisplayName = Read-EppInput -Name ApplicationDisplayName -Kind ApplicationName `
                -PromptName 'New application display name' -DefaultValue 'EPP Application'
        }
        if (-not [string]::IsNullOrWhiteSpace($Location) -or $NonInteractive) {
            $Location = Read-EppInput -Name Location -Value $Location -Kind Location -NonInteractive
        }
        $inputs.TenantRegionScope = Get-EppTenantRegionScope -TenantId $inputs.TenantId
        $endpointRegion = Resolve-EppEndpointRegion -TenantRegionScope $inputs.TenantRegionScope -EndpointRegion $EndpointRegion
        Write-Host "Tenant replication scope: $($inputs.TenantRegionScope)"
        Write-Host "Provider route: $(if ($endpointRegion -eq 'eu') { 'EU' } else { 'Global' })"
        $inputs.Location = Select-EppLocation -Inputs $inputs -Location $Location -NonInteractive:$NonInteractive `
            -ForceAuthentication:$ForceAuthentication
        if (-not $inputs.Location) {
            Write-Host 'Cancelled. No Azure resources or application credentials were changed.' -ForegroundColor Yellow
            return
        }
        if (-not $NonInteractive -and [string]::IsNullOrWhiteSpace($Provider)) {
            $null = Connect-EppGraphAccount -Inputs $inputs -ForceAuthentication:$ForceAuthentication
        }
        $providerName = Resolve-EppApplicationProvider -Inputs $inputs -AssetDirectory $assetDirectory -Provider $Provider -NonInteractive:$NonInteractive
        if (-not $providerName) {
            Write-Host 'Cancelled. No Azure resources or application credentials were changed.' -ForegroundColor Yellow
            return
        }
        $providerConfiguration = Get-EppProvider -AssetDirectory $assetDirectory -Provider $providerName `
            -EndpointRegion $endpointRegion -NonInteractive:$NonInteractive
        $inputs.ProviderAuthentication = $providerConfiguration.AuthenticationMode
        $inputs.ProviderTenantId = $providerConfiguration.TenantId
        $inputs.AccessTokenScopeTenant = $providerConfiguration.AccessTokenScopeTenant
        $selection = Get-EppLanguage -AssetDirectory $assetDirectory -Language $Language -SourceRepository $SourceRepository `
            -PackageReleaseTag $PackageReleaseTag -NonInteractive:$NonInteractive
        $inputs.Language = $selection.Id
        $inputs.Platform = $selection.DisplayName
        Write-Host "Programming language: $($selection.DisplayName)"
        $inputs.PackageFile = ([Uri]$selection.Url).Segments[-1]
        $inputs.BuildStrategy = $selection.BuildStrategy
        $plan = Get-EppServicePlan -ServicePlan $ServicePlan -NonInteractive:$NonInteractive
        $inputs.ServicePlan = $plan.id
        $inputs.ResourcePrefix = Read-EppInput ResourcePrefix $ResourcePrefix -Kind Prefix `
            -PromptName 'Resource name prefix' -DefaultValue 'epp' -NonInteractive:$NonInteractive
        $names = Get-EppResourceNames -SubscriptionId $inputs.SubscriptionId -ApplicationId $inputs.ApplicationId `
            -ResourcePrefix $inputs.ResourcePrefix -PendingApplication:([bool]$inputs['NewApplicationDisplayName'])

        Write-Host "`nChecking prerequisites and the selected Azure context (no resource changes)..." -ForegroundColor Cyan
        $context = Connect-EppContext -Inputs $inputs -Names $names -NonInteractive:$NonInteractive `
            -InstallPrerequisites:$InstallPrerequisites -ForceAuthentication:$ForceAuthentication
        $context.CertificatePlan = Get-EppCertificatePlan -Inputs $inputs -Names $names -Application $context.Application `
            -CertificateAction $CertificateAction -EncryptionKeyId $EncryptionKeyId -KeyVaultCertificateId $KeyVaultCertificateId `
            -KeyVaultSubscriptionId $KeyVaultSubscriptionId -NonInteractive:$NonInteractive
        if (-not $context.CertificatePlan) {
            Write-Host 'Cancelled. No Azure resources or application credentials were changed.' -ForegroundColor Yellow
            return
        }
        $package = Get-EppPackage -Selection $selection -Directory $workingDirectory
        $inputs.PackageSha256 = $package.Sha256
        $inputs.SourcePackageSha256 = $package.SourceSha256
        $inputs.PackageUrl = $selection.Url
        $inputs.PackageReleaseTag = $selection.ReleaseTag
        foreach ($template in @('main', 'ingress')) {
            Invoke-EppAz bicep build --file (Join-Path $assetDirectory "infra/$template.bicep") `
                --outfile (Join-Path $assetDirectory "$template.json") | Out-Null
        }
        Show-EppPlan -Inputs $inputs -Names $names -ProviderConfiguration $providerConfiguration -Context $context
        if (-not (Confirm-EppDeployment -NonInteractive:$NonInteractive -ApproveDeployment:$ApproveDeployment)) {
            Write-Host 'Cancelled. No Azure resources or app registrations were changed.' -ForegroundColor Yellow
            return
        }
        try {
            $result = Invoke-EppDeployment -Inputs $inputs -Names $names -ProviderConfiguration $providerConfiguration -Context $context `
                -AssetDirectory $assetDirectory -WorkingDirectory $workingDirectory -Package $package -OutputDirectory $OutputDirectory
            if ($PassThru) { return $result }
        }
        catch {
            Write-Warning 'Deployment did not complete. Previously created app registrations and Azure resources are left in place; no rollback or policy activation was attempted. Correct the reported failure and rerun with the same inputs and prefix.'
            if ($inputs['NewApplicationDisplayName']) {
                if ($inputs.ApplicationId) {
                    Write-Warning "Reuse the created app with -ApplicationId '$($inputs.ApplicationId)' -ResourcePrefix '$($inputs.ResourcePrefix)'. Do not create another app for this deployment."
                }
                else {
                    Write-Warning "If app creation was attempted, check the selected tenant for '$($inputs.NewApplicationDisplayName)' before retrying; a failed response does not prove that no app was created."
                }
            }
            throw
        }
    }
    finally {
        try {
            if (Test-Path -LiteralPath $workingDirectory) {
                Remove-Item -LiteralPath $workingDirectory -Recurse -Force -ErrorAction Stop
            }
        }
        catch { Write-Warning "Could not remove temporary setup files at '$workingDirectory': $($_.Exception.Message)" -WarningAction Continue }
    }
}

Export-ModuleMember -Function Invoke-EppSetup
