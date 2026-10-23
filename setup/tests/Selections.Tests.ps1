#Requires -Version 7.0
param([string] $ModulePath = (Split-Path -Parent $PSScriptRoot))

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$module = Import-Module (Join-Path $ModulePath 'support\Epp.Setup.psm1') -Force -PassThru
$directory = Join-Path ([IO.Path]::GetTempPath()) "epp-selection-tests-$([Guid]::NewGuid().ToString('N'))"
try {
    & $module {
        param($Directory, $ModulePath)

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
        $script:AppId = '11111111-1111-1111-1111-111111111111'
        $script:ObjectId = '22222222-2222-2222-2222-222222222222'
        function script:New-TestInputs {
            return @{ TenantId = $script:Tenant; SubscriptionId = $script:Subscription; ServicePlan = 'FC1' }
        }
        function script:New-TestApplication([string] $Name = 'EPP endpoint', [string] $Id = $script:AppId) {
            return [pscustomobject]@{
                Id = $script:ObjectId; AppId = $Id; DisplayName = $Name
                SignInAudience = 'AzureADMyOrg'; AdditionalProperties = @{}
            }
        }
        function script:New-TestRegion(
            [string] $Id, [string] $Category = 'Recommended', [string] $Type = 'Physical',
            [string] $Geography = 'United States', [string] $GeographyGroup = 'US'
        ) {
            return @{
                name = $Id; displayName = $Id.ToUpperInvariant()
                metadata = @{ regionCategory = $Category; regionType = $Type; geography = $Geography; geographyGroup = $GeographyGroup }
            }
        }
        $script:Calls = [Collections.Generic.List[string]]::new()
        $script:Messages = [Collections.Generic.List[string]]::new()
        $script:Warnings = [Collections.Generic.List[string]]::new()
        $script:Prompts = [Collections.Generic.List[string]]::new()
        $script:Answers = [Collections.Generic.Queue[string]]::new()
        $script:AzureForces = [Collections.Generic.List[bool]]::new()
        $script:GraphForces = [Collections.Generic.List[bool]]::new()
        $script:DiscoveryCalls = [Collections.Generic.List[string]]::new()
        function script:Reset-TestState([string[]] $Answers = @()) {
            $script:Calls.Clear(); $script:Messages.Clear(); $script:Warnings.Clear(); $script:Prompts.Clear(); $script:Answers.Clear()
            $script:AzureForces.Clear(); $script:GraphForces.Clear()
            $script:DiscoveryCalls.Clear()
            $script:DiscoveryMetadata = [pscustomobject]@{
                issuer = "https://login.microsoftonline.com/$script:Tenant/v2.0"
                tenant_region_scope = 'NA'
            }
            $script:DiscoveryError = ''
            foreach ($answer in $Answers) { $script:Answers.Enqueue($answer) }
            $script:Graph = [pscustomobject]@{
                TenantId = $script:Tenant; Authentication = 'AzureCli'
            }
            $script:Applications = @(New-TestApplication)
            $script:RegionsJson = @{ value = @(
                (New-TestRegion westus2), (New-TestRegion centralus), (New-TestRegion eastus2 Other),
                (New-TestRegion global Other Logical)
            ) } | ConvertTo-Json -Depth 8
            $script:GraphError = ''; $script:RegionError = ''; $script:CliAvailable = $true
            $script:LastFilter = ''; $script:PreflightInputs = $null
        }
        function script:Write-Host {
            param([Parameter(ValueFromPipeline)] $Object, $ForegroundColor, [switch] $NoNewline)
            process { $script:Messages.Add([string]$Object) }
        }
        function script:Write-Warning {
            [CmdletBinding()]
            param([string] $Message)
            $script:Warnings.Add($Message)
        }
        function script:Read-Host {
            param($Prompt)
            $script:Prompts.Add($Prompt)
            Assert ($script:Answers.Count -gt 0) "Unexpected prompt: $Prompt"
            return $script:Answers.Dequeue()
        }
        function script:Get-Command {
            param($Name, $ErrorAction)
            Assert ($Name -eq 'az') "Unexpected command lookup: $Name"
            if ($script:CliAvailable) { return @{ Name = 'az' } }
        }
        function script:Connect-EppGraphAccount {
            param($Inputs, [switch] $NonInteractive, [switch] $ForceAuthentication)
            Assert ($Inputs.TenantId -ceq $script:Tenant) 'Authenticate Graph to the selected tenant.'
            $script:Calls.Add('graph:connect'); $script:GraphForces.Add([bool]$ForceAuthentication)
            $Inputs.AzureSelectionAuthenticated = $true
            return @{ Context = $script:Graph; Operator = @{ Id = $script:Tenant; Account = 'operator@contoso.test' } }
        }
        function script:Get-EppApplication { param($Inputs, $ClientId, $ObjectId); throw 'preflight-after-authentication' }
        function script:Invoke-EppGraphRequest {
            param($Inputs, $Path, $Query, $Method, $Body)
            if ($Inputs.TenantId -cne $script:Graph.TenantId) { throw 'CLI directory no longer matches the selected tenant.' }
            Assert ($Path -ceq '/v1.0/applications') 'Use the application collection for picker queries.'
            $script:Calls.Add('graph:applications'); $script:LastFilter = $Query['$filter']
            Assert ($Query['$top'] -ceq '50') 'Do not enumerate an entire large tenant.'
            Assert ($Query['$select'] -ceq 'appId,displayName,signInAudience') 'Request only application selection metadata, not credentials.'
            if ($script:GraphError) { throw $script:GraphError }
            return @{ value = @($script:Applications) }
        }
        function script:Connect-EppAzureAccount {
            param($Inputs, [switch] $NonInteractive, [switch] $ForceAuthentication)
            Assert ($Inputs.TenantId -ceq $script:Tenant -and $Inputs.SubscriptionId -ceq $script:Subscription) 'Validate the exact selected Azure context.'
            $script:Calls.Add('azure:connect'); $script:AzureForces.Add([bool]$ForceAuthentication)
            return @{ id = $Inputs.SubscriptionId; tenantId = $Inputs.TenantId }
        }
        function script:Get-EppArmOperatorObjectId { param($Inputs); return $script:Tenant }
        function script:Invoke-EppAz {
            param([Parameter(ValueFromRemainingArguments)][string[]] $Arguments)
            $command = $Arguments -join ' '
            if ($command -eq 'version --output json') { return '{"azure-cli":"2.60.0"}' }
            if ($command -eq 'bicep version --output none') { return '' }
            $expected = "rest --method get --url https://management.azure.com/subscriptions/$script:Subscription/locations?api-version=2022-12-01 --subscription $script:Subscription --output json"
            Assert ($command -ceq $expected) "Unexpected Azure call (no network allowed): $command"
            $script:Calls.Add('azure:regions')
            if ($script:RegionError) { throw $script:RegionError }
            return $script:RegionsJson
        }
        function script:Invoke-WebRequest { throw 'Unexpected download.' }
        function script:Invoke-RestMethod {
            param($Uri, $TimeoutSec, $MaximumRedirection)
            Assert ($Uri -ceq "https://login.microsoftonline.com/$script:Tenant/v2.0/.well-known/openid-configuration") 'Read only the selected tenant discovery document.'
            Assert ($TimeoutSec -eq 60 -and $MaximumRedirection -eq 0) 'Bound discovery and do not follow redirects.'
            $script:DiscoveryCalls.Add($Uri)
            if ($script:DiscoveryError) { throw $script:DiscoveryError }
            return ,$script:DiscoveryMetadata
        }

        $options = @(@{ id = 'first'; displayName = 'Alpha' }, @{ id = 'second'; displayName = 'Beta' })
        foreach ($blank in @('', '  ')) {
            Reset-TestState @($blank)
            Assert ((Select-EppOption -Entries $options -Name Choice -DefaultValue second -AllowCancel).id -ceq 'second') 'Enter must select the specified default, not always the first entry.'
            Assert ($script:Prompts[0] -ceq 'Choice number or name [2]' -and
                $script:Messages -contains '  [2] Beta (default)' -and $script:Messages -contains '  [0] Cancel') 'Mark the default and keep cancellation explicit.'
            Reset-TestState @($blank)
            Assert ((Read-EppInput -Name Prefix -Kind Prefix -DefaultValue epp -AllowCancel) -ceq 'epp') 'A text-input default must also take precedence over blank-input cancellation.'
        }
        Reset-TestState @('', 'first')
        Assert ((Select-EppOption -Entries $options -Name Choice -AllowCancel).id -ceq 'first' -and
            $script:Warnings.Count -eq 1) 'When no default is supplied, require a choice rather than canceling.'
        Reset-TestState @('', 'prefix')
        Assert ((Read-EppInput -Name Search -AllowCancel) -ceq 'prefix' -and $script:Warnings.Count -eq 1) 'Required text without a known default must reprompt on Enter.'
        Reset-TestState
        Assert-Throws { Select-EppOption -Entries $options -Name Choice -DefaultValue invalid } 'Unknown default'
        Assert-Throws { Select-EppOption -Entries $options -Name Choice -DefaultValue first -NonInteractive } 'Choice is required'
        Assert ((Select-EppOption -Entries $options -Name Choice -Value second -DefaultValue first -NonInteractive).id -ceq 'second') 'Explicit and unattended inputs must not be replaced by interactive defaults.'
        Assert ($script:Prompts.Count -eq 0) 'Invalid defaults and unattended inputs must not prompt.'

        foreach ($scope in @('EU', 'NA', 'AS', 'OC', 'AF', 'SA', 'AN', 'JPR', 'WW')) {
            Reset-TestState
            $script:DiscoveryMetadata.tenant_region_scope = $scope.ToLowerInvariant()
            Assert ((Get-EppTenantRegionScope -TenantId $script:Tenant) -ceq $scope) 'Read and normalize the actual tenant scope without a country-to-scope mapping.'
            $expectedRoute = if ($scope -eq 'EU') { 'eu' } else { 'global' }
            Assert ((Resolve-EppEndpointRegion -TenantRegionScope $scope) -ceq $expectedRoute) 'Only EU tenants select the EU provider route.'
            Assert ((Resolve-EppEndpointRegion -TenantRegionScope $scope -EndpointRegion $expectedRoute.ToUpperInvariant()) -ceq $expectedRoute) 'Accept matching explicit routes case-insensitively.'
            $wrongRoute = if ($scope -eq 'EU') { 'global' } else { 'eu' }
            Assert-Throws { Resolve-EppEndpointRegion -TenantRegionScope $scope -EndpointRegion $wrongRoute } 'incompatible with tenant replication scope'
            Assert ($script:Prompts.Count -eq 0) 'Tenant scope and provider routing must not prompt.'
        }
        Reset-TestState
        Assert-Throws { Get-EppTenantRegionScope -TenantId invalid } 'nonempty GUID'
        Assert ($script:DiscoveryCalls.Count -eq 0) 'Validate tenant IDs before discovery.'
        Assert-Throws { Resolve-EppEndpointRegion -TenantRegionScope EU -EndpointRegion invalid } 'Unknown EndpointRegion'
        Assert-Throws { Resolve-EppEndpointRegion -TenantRegionScope '' } 'must be determined'
        foreach ($invalidScope in @('', ' ', "EU`n", @('EU', 'NA'), 1)) {
            Reset-TestState
            $script:DiscoveryMetadata.tenant_region_scope = $invalidScope
            Assert-Throws { Get-EppTenantRegionScope -TenantId $script:Tenant } 'valid tenant replication scope'
        }
        foreach ($metadata in @($null, @(), @([pscustomobject]@{ tenant_region_scope = 'EU' }))) {
            Reset-TestState
            $script:DiscoveryMetadata = $metadata
            Assert-Throws { Get-EppTenantRegionScope -TenantId $script:Tenant } 'invalid tenant discovery metadata'
        }
        Reset-TestState
        $script:DiscoveryMetadata = [pscustomobject]@{ issuer = "https://login.microsoftonline.com/$script:Tenant/v2.0" }
        Assert-Throws { Get-EppTenantRegionScope -TenantId $script:Tenant } 'valid tenant replication scope'
        foreach ($issuer in @("https://login.microsoftonline.com/$script:Subscription/v2.0", "https://login.microsoftonline.us/$script:Tenant/v2.0", '')) {
            Reset-TestState
            $script:DiscoveryMetadata.issuer = $issuer
            Assert-Throws { Get-EppTenantRegionScope -TenantId $script:Tenant } 'selected tenant in the Azure public cloud'
        }
        Reset-TestState
        $script:DiscoveryError = 'tenant discovery unavailable'
        Assert-Throws { Get-EppTenantRegionScope -TenantId $script:Tenant } 'tenant discovery unavailable'

        foreach ($noninteractive in @($false, $true)) {
            Reset-TestState
            $inputs = New-TestInputs
            Assert ((Select-EppApplication -Inputs $inputs -ApplicationId $script:AppId -NonInteractive:$noninteractive) -ceq $script:AppId) 'Explicit client IDs must bypass discovery.'
            Assert ((Select-EppLocation -Inputs $inputs -Location westus2 -NonInteractive:$noninteractive) -ceq 'westus2') 'Explicit locations must bypass discovery.'
            Assert ($script:Calls.Count -eq 0 -and $script:Prompts.Count -eq 0) 'Explicit inputs must not trigger lookup authentication or queries.'
        }
        Reset-TestState
        Assert-Throws { Select-EppApplication -Inputs (New-TestInputs) -NonInteractive } 'ApplicationId is required'
        Assert-Throws { Select-EppLocation -Inputs (New-TestInputs) -NonInteractive } 'Location is required'
        Assert-Throws { Select-EppApplication -Inputs (New-TestInputs) -ApplicationId invalid } 'Invalid -ApplicationId'
        Assert-Throws { Select-EppLocation -Inputs (New-TestInputs) -Location 'West US 2' } 'Invalid -Location'
        Assert ($script:Calls.Count -eq 0 -and $script:Prompts.Count -eq 0) 'Invalid/unattended inputs must never infer a value or sign in.'

        Reset-TestState @('1')
        $inputs = New-TestInputs
        $selected = Select-EppApplication -Inputs $inputs -ForceAuthentication
        Assert ($selected -ceq $script:AppId -and $selected -cne $script:ObjectId) 'Return the client ID, never the directory object ID.'
        $text = $script:Messages -join "`n"
        Assert ($text.Contains("EPP endpoint [$script:AppId]") -and -not $text.Contains($script:ObjectId)) 'Display the application name and client ID only.'
        Assert ($inputs.AzureSelectionAuthenticated -and $script:GraphForces[0]) 'Graph discovery must reuse the selected CLI session.'
        Assert ($script:Prompts.Count -eq 1) 'Even a single application requires an explicit selection.'
        Assert ($text.Contains('up to 50') -and $text.Contains('dedicated EPP')) 'Disclose the list limit and dedicated-application requirement.'
        Reset-TestState @('search', "O'Reilly", $script:AppId)
        $null = Select-EppApplication -Inputs (New-TestInputs)
        Assert ($script:LastFilter -ceq "startswith(displayName,'O''Reilly')") 'Escape apostrophes inside the Graph prefix filter.'
        Assert ($script:GraphForces.Count -eq 1) 'Searching must not force another Graph sign-in.'
        Reset-TestState @('refresh', $script:AppId)
        $null = Select-EppApplication -Inputs (New-TestInputs)
        Assert (@($script:Calls | Where-Object { $_ -eq 'graph:applications' }).Count -eq 2) 'Refresh must rerun the application query.'
        Reset-TestState @('manual', $script:AppId)
        $script:Applications = @()
        Assert ((Select-EppApplication -Inputs (New-TestInputs)) -ceq $script:AppId) 'Manual client-ID entry must work when no applications are listed.'
        Assert ($script:Warnings.Count -eq 1) 'Disclose an empty application result.'
        Reset-TestState @('manual', 'not-a-guid', $script:AppId)
        Assert ((Select-EppApplication -Inputs (New-TestInputs)) -ceq $script:AppId -and $script:Warnings.Count -eq 1) 'Validate and reprompt malformed manual client IDs.'

        Reset-TestState
        $consumer = New-TestApplication 'Consumer'; $consumer.SignInAudience = 'AzureADandPersonalMicrosoftAccount'
        $agent = New-TestApplication 'Agent'; $agent.AdditionalProperties['@odata.type'] = '#microsoft.graph.agentIdentityBlueprint'
        $script:Applications = @((New-TestApplication), $consumer, $agent)
        Assert (@(Get-EppApplicationOptions -Inputs (New-TestInputs)).Count -eq 1) 'Exclude incompatible audiences and agent identity blueprints.'
        $script:Graph.TenantId = $script:Subscription
        $before = $script:Calls.Count
        Assert-Throws { Get-EppApplicationOptions -Inputs (New-TestInputs) } 'no longer matches'
        Assert ($script:Calls.Count -eq $before) 'Never list apps in a different Graph tenant.'
        Reset-TestState
        $script:Applications = @((New-TestApplication), (New-TestApplication))
        Assert-Throws { Get-EppApplicationOptions -Inputs (New-TestInputs) } 'duplicate application client IDs'
        Reset-TestState
        $script:Applications = @(New-TestApplication "bad`nname")
        Assert-Throws { Get-EppApplicationOptions -Inputs (New-TestInputs) } 'invalid application display name'
        Reset-TestState
        $script:Applications = @(1..51 | ForEach-Object { New-TestApplication })
        Assert-Throws { Get-EppApplicationOptions -Inputs (New-TestInputs) } 'selection limit'
        Reset-TestState
        $script:GraphError = 'application lookup denied'
        Assert-Throws { Select-EppApplication -Inputs (New-TestInputs) } 'application lookup denied'
        foreach ($answers in @(@(''), @('  '), @('manual', ''))) {
            Reset-TestState $answers
            Assert ((Select-EppApplication -Inputs (New-TestInputs)) -ceq 'create') 'Blank application selection or manual client-ID input must default to creating a new app.'
        }
        Reset-TestState @('')
        $script:Applications = @()
        Assert ((Select-EppApplication -Inputs (New-TestInputs)) -ceq 'create' -and
            $script:Prompts[0] -ceq 'Application number or name [4]') 'The create default must follow the menu entry even when no existing apps are listed.'
        foreach ($answers in @(@('0'), @('Cancel'), @('manual', 'Cancel'), @('search', 'Cancel'))) {
            Reset-TestState $answers
            Assert ($null -eq (Select-EppApplication -Inputs (New-TestInputs))) 'Application picker/manual/search cancellation must stop setup.'
        }

        Reset-TestState @('')
        $inputs = New-TestInputs
        Assert ((Select-EppLocation -Inputs $inputs -ForceAuthentication) -ceq 'westus2') 'Enter chooses the first available recommended region.'
        Assert ($script:Prompts[0] -ceq 'Azure region number or name [1]') 'Show the region default in the prompt.'
        $text = $script:Messages -join "`n"
        Assert ($text.Contains('WESTUS2 (westus2) - Azure recommended') -and -not $text.Contains('EASTUS2 (eastus2)')) 'The shortlist must use live Recommended classification, not hardcoded claims.'
        Assert ($text.Contains('not a latency/cost ranking') -and $text.Contains('quota')) 'Do not imply a recommendation guarantees capacity or price.'
        Assert ($inputs.AzureSelectionAuthenticated -and $script:AzureForces[0]) 'Reuse successful forced Azure authentication at preflight.'
        Reset-TestState @('all', 'eastus2')
        Assert ((Select-EppLocation -Inputs (New-TestInputs)) -ceq 'eastus2') 'Allow other physical subscription regions through the all-regions view.'
        Assert (-not ($script:Messages -join "`n").Contains('GLOBAL (global)')) 'Logical locations must not be offered.'
        Reset-TestState @('all', '')
        Assert ((Select-EppLocation -Inputs (New-TestInputs)) -ceq 'centralus') 'The all-regions view must default to its own first displayed region, not the shortlist default.'
        Reset-TestState @('all', 'shortlist', 'westus2')
        Assert ((Select-EppLocation -Inputs (New-TestInputs)) -ceq 'westus2') 'Return from all regions to the recommended shortlist.'
        $euRegions = @(
            (New-TestRegion westeurope -Geography Europe -GeographyGroup Europe),
            (New-TestRegion northeurope -Geography Europe -GeographyGroup Europe),
            (New-TestRegion francecentral -Geography France -GeographyGroup Europe),
            (New-TestRegion norwayeast -Geography Norway -GeographyGroup Europe),
            (New-TestRegion switzerlandnorth -Geography Switzerland -GeographyGroup Europe),
            (New-TestRegion belgiumcentral -Geography Belgium -GeographyGroup Europe),
            (New-TestRegion uksouth -Geography 'United Kingdom' -GeographyGroup Europe),
            (New-TestRegion eastus),
            (New-TestRegion unclassified -Geography '' -GeographyGroup Europe),
            (New-TestRegion franceother Other -Geography France -GeographyGroup Europe)
        )
        Reset-TestState @('')
        $inputs = New-TestInputs; $inputs.TenantRegionScope = 'EU'
        $script:RegionsJson = @{ value = $euRegions } | ConvertTo-Json -Depth 8
        Assert ((Select-EppLocation -Inputs $inputs) -ceq 'westeurope') 'The EU default must come from the filtered EU Data Boundary shortlist.'
        $text = $script:Messages -join "`n"
        foreach ($region in @('WESTEUROPE', 'NORTHEUROPE', 'FRANCECENTRAL', 'NORWAYEAST', 'SWITZERLANDNORTH', 'BELGIUMCENTRAL')) {
            Assert ($text.Contains($region)) 'Use live EU/EFTA geography metadata, including new region names.'
        }
        foreach ($region in @('UKSOUTH', 'EASTUS', 'UNCLASSIFIED', 'FRANCEOTHER')) {
            Assert (-not $text.Contains($region)) 'Never recommend non-EUDB, unverified, or non-Recommended locations to EU tenants.'
        }
        Assert ($text.Contains('Recommended Azure regions within the EU Data Boundary:') -and $script:Warnings.Count -eq 0) 'Label EU recommendations without warning for an in-boundary selection.'
        foreach ($answers in @(@('all', 'uksouth'), @('manual', 'eastus'))) {
            Reset-TestState $answers
            $script:RegionsJson = @{ value = $euRegions } | ConvertTo-Json -Depth 8
            $selected = Select-EppLocation -Inputs $inputs
            Assert ($selected -ceq $answers[-1] -and $script:Warnings.Count -eq 1) 'Allow explicit out-of-boundary selections with one warning and no extra approval.'
            Assert ($script:Warnings[0].Contains('outside the EU Data Boundary')) 'Explain the boundary mismatch.'
        }
        foreach ($location in @('westeurope', 'eastus', 'unclassified', 'customregion5')) {
            Reset-TestState
            $script:RegionsJson = @{ value = $euRegions } | ConvertTo-Json -Depth 8
            Assert ((Select-EppLocation -Inputs $inputs -Location $location -NonInteractive) -ceq $location) 'Preserve explicit EU-tenant locations, including unattended overrides.'
            Assert ($script:Prompts.Count -eq 0) 'An explicit location must never prompt.'
            if ($location -eq 'westeurope') { Assert ($script:Warnings.Count -eq 0) 'An in-boundary parameter needs no warning.' }
            else {
                Assert ($script:Warnings.Count -eq 1) 'An out-of-boundary or unverifiable parameter must warn.'
                if ($location -in @('unclassified', 'customregion5')) {
                    Assert ($script:Warnings[0].Contains('could not be verified')) 'Do not claim unknown geography is known to be outside the boundary.'
                }
            }
        }
        Reset-TestState @('manual', 'eastus')
        $null = Select-EppLocation -Inputs $inputs
        Assert ($script:Warnings[0].Contains('no recommended regions with verified EU Data Boundary geography')) 'An empty EU shortlist must not silently fall back to global recommendations.'
        Assert (@($script:Messages | Where-Object { $_ -match ' - Azure recommended(?: \(default\))?$' }).Count -eq 0) 'Do not present global regions as EU recommendations.'
        Reset-TestState @('', 'Cancel')
        $null = Select-EppLocation -Inputs $inputs
        Assert ($script:Prompts.Count -eq 2 -and $script:Warnings[0].Contains('no recommended regions')) 'An empty EU shortlist defaults to showing all regions, not silently selecting a global region.'
        foreach ($scope in @('NA', 'AS', 'OC', 'AF', 'SA', 'AN', 'JPR', 'WW')) {
            Reset-TestState @('westus2')
            $inputs = New-TestInputs; $inputs.TenantRegionScope = $scope
            Assert ((Select-EppLocation -Inputs $inputs) -ceq 'westus2') 'Keep non-EU recommendations unchanged.'
            Assert ($script:Warnings.Count -eq 0 -and -not ($script:Messages -join "`n").Contains('EU Data Boundary')) 'Do not add geographic warnings or filtering for non-EU tenants.'
            Reset-TestState
            Assert ((Select-EppLocation -Inputs $inputs -Location westus2 -NonInteractive) -ceq 'westus2' -and $script:Calls.Count -eq 0) 'Non-EU explicit locations must still bypass region discovery.'
        }
        Reset-TestState @('manual', 'customregion5')
        Assert ((Select-EppLocation -Inputs (New-TestInputs)) -ceq 'customregion5') 'Allow a typed canonical region for later existing availability validation.'
        Reset-TestState @('manual', '')
        Assert ((Select-EppLocation -Inputs (New-TestInputs)) -ceq 'westus2') 'Manual region entry must show and accept the same available region default.'
        Reset-TestState @('manual', 'West US 2', 'westus2')
        Assert ((Select-EppLocation -Inputs (New-TestInputs)) -ceq 'westus2' -and $script:Warnings.Count -eq 1) 'Validate and reprompt malformed manual locations.'
        foreach ($regions in @(@(), @((New-TestRegion eastus2 Other)), @((New-TestRegion westus2)))) {
            Reset-TestState @('manual', 'westus2')
            $script:RegionsJson = @{ value = @($regions) } | ConvertTo-Json -Depth 8
            Assert ((Select-EppLocation -Inputs (New-TestInputs)) -ceq 'westus2') 'Manual entry must remain available for empty, nonrecommended, and single-region catalogs.'
        }
        Reset-TestState @('0')
        $many = @('eastus','westus2','centralus','westeurope','northeurope','southeastasia','australiaeast','japaneast','canadacentral','southafricanorth') |
            ForEach-Object { New-TestRegion $_ }
        $script:RegionsJson = @{ value = @($many) } | ConvertTo-Json -Depth 8
        $null = Select-EppLocation -Inputs (New-TestInputs)
        Assert (@($script:Messages | Where-Object { $_ -match ' - Azure recommended(?: \(default\))?$' }).Count -eq 8) 'Bound the common recommendation shortlist to eight regions.'
        foreach ($response in @('[]', '{"value":null}', '{"value":[{}]}')) {
            Reset-TestState
            $script:RegionsJson = $response
            Assert-Throws { Get-EppRegionOptions -Inputs (New-TestInputs) } 'invalid .*response|invalid region metadata'
        }
        Reset-TestState
        $script:RegionsJson = @{ value = @((New-TestRegion westus2), (New-TestRegion westus2)) } | ConvertTo-Json -Depth 8
        Assert-Throws { Get-EppRegionOptions -Inputs (New-TestInputs) } 'invalid or duplicate region'
        foreach ($field in @('regionType', 'regionCategory', 'geography')) {
            Reset-TestState
            $invalid = New-TestRegion westus2
            $invalid.metadata[$field] = @{}
            $script:RegionsJson = @{ value = @($invalid) } | ConvertTo-Json -Depth 8
            Assert-Throws { Get-EppRegionOptions -Inputs (New-TestInputs) } 'invalid region classification'
        }
        Reset-TestState
        $script:RegionError = 'location lookup denied'
        Assert-Throws { Select-EppLocation -Inputs (New-TestInputs) } 'location lookup denied'
        Reset-TestState
        $script:CliAvailable = $false
        Assert-Throws { Select-EppLocation -Inputs (New-TestInputs) } 'Azure CLI is not installed'
        Assert ($script:Calls.Count -eq 0) 'Missing Azure CLI must fail before attempting authentication.'
        foreach ($answers in @(@('0'), @('Cancel'), @('manual', 'Cancel'))) {
            Reset-TestState $answers
            Assert ($null -eq (Select-EppLocation -Inputs (New-TestInputs))) 'Region picker/manual cancellation must stop setup.'
        }

        $originalPreflight = ${function:Connect-EppContext}
        foreach ($azureDone in @($false, $true)) {
            foreach ($graphDone in @($false, $true)) {
                Reset-TestState
                $inputs = New-TestInputs
                $inputs.ApplicationId = $script:AppId
                $inputs.AzureSelectionAuthenticated = $azureDone
                Assert-Throws { & $originalPreflight -Inputs $inputs -Names @{} -ForceAuthentication } '^preflight-after-authentication$'
                Assert ($script:AzureForces[0] -eq (-not $azureDone) -and -not $script:GraphForces[0]) 'Only Azure CLI can be explicitly reauthenticated; Graph reuses that session.'
            }
        }
        function script:Get-EppLanguage {
            param($AssetDirectory, $Language, $SourceRepository, $PackageReleaseTag, [switch] $NonInteractive)
            return @{
                Id = 'javascript'; DisplayName = 'JavaScript'; BuildStrategy = 'ready'
                Url = 'https://github.com/Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample/releases/download/epp-packages-1-1/epp-javascript.zip'
                ReleaseTag = 'epp-packages-1-1'
            }
        }
        function script:Connect-EppContext {
            param($Inputs, $Names, [switch] $NonInteractive, [switch] $InstallPrerequisites, [switch] $ForceAuthentication)
            $script:PreflightInputs = @{} + $Inputs
            throw 'selection-preflight-boundary'
        }
        $setup = @{
            TenantId = $script:Tenant; SubscriptionId = $script:Subscription
            Provider = 'soprano'; EndpointRegion = 'global'; Language = 'javascript'; ServicePlan = 'FC1'
            ResourcePrefix = 'unit'; OutputDirectory = $Directory
            AssetDirectory = $ModulePath
            SourceBaseUri = "https://raw.githubusercontent.com/Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample/$('a' * 40)/setup"
        }
        Reset-TestState @($script:AppId, 'westus2')
        Assert-Throws { Invoke-EppSetup @setup -ForceAuthentication } '^selection-preflight-boundary$'
        Assert (($script:Prompts -join ',') -ceq 'Application number or name [5],Azure region number or name [1]') 'Use application and region selection with displayed defaults.'
        Assert ($script:PreflightInputs.ApplicationId -ceq $script:AppId -and $script:PreflightInputs.Location -ceq 'westus2') 'Forward selected values to the existing preflight and deployment inputs.'
        Assert ($script:PreflightInputs.TenantRegionScope -ceq 'NA' -and $script:DiscoveryCalls.Count -eq 1) 'Discover and preserve tenant scope before selecting a location.'
        Assert ($script:PreflightInputs.AzureSelectionAuthenticated) 'Pass the shared CLI authentication state.'
        Reset-TestState @('0')
        Assert ($null -eq (Invoke-EppSetup @setup)) 'Application cancellation must return no success object.'
        Assert ($null -eq $script:PreflightInputs -and $script:AzureForces.Count -eq 0) 'Cancel before region discovery and deployment preflight.'
        Reset-TestState @($script:AppId, '0')
        Assert ($null -eq (Invoke-EppSetup @setup) -and $null -eq $script:PreflightInputs) 'Region cancellation must stop before deployment preflight.'
        Reset-TestState
        Assert-Throws { Invoke-EppSetup @setup -NonInteractive -ApproveDeployment } 'ApplicationId is required'
        Assert-Throws { Invoke-EppSetup @setup -ApplicationId $script:AppId -NonInteractive -ApproveDeployment } 'Location is required'
        Assert ($script:Calls.Count -eq 0) 'Unattended missing inputs must not trigger discovery or authentication.'
        Assert ($script:DiscoveryCalls.Count -eq 0) 'Reject missing unattended IDs/locations before tenant discovery.'
        Reset-TestState
        $script:DiscoveryMetadata.tenant_region_scope = 'EU'
        Assert-Throws { Invoke-EppSetup @setup -ApplicationId $script:AppId -Location westeurope -NonInteractive } 'incompatible with tenant replication scope'
        Assert ($script:Calls.Count -eq 0 -and $null -eq $script:PreflightInputs) 'Reject a conflicting provider route before Azure lookup or preflight.'
        Assert (-not (Test-Path -LiteralPath $Directory)) 'Selection must not produce deployment output.'
    } $directory $ModulePath
    Write-Host 'Application/client-ID selection, scoped Graph search, recommended/manual regions, cancellation, authentication reuse, and unattended checks passed.'
}
finally {
    Remove-Module -ModuleInfo $module -Force
    if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force }
}
