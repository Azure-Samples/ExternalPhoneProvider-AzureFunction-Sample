#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $SampleRoot,
    [Parameter(Mandatory)][string] $SasRoot,
    [Parameter(Mandatory)][string] $OutputPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Read-RequiredFile([string] $Root, [string] $RelativePath) {
    $path = Join-Path $Root $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required contract file is missing: $path"
    }
    return Get-Content -LiteralPath $path -Raw
}

function Assert-Match([string] $Text, [string] $Pattern, [string] $Description) {
    if ($Text -notmatch $Pattern) {
        throw "CYOT contract mismatch: $Description"
    }
}

$sample = (Resolve-Path -LiteralPath $SampleRoot).Path
$sas = (Resolve-Path -LiteralPath $SasRoot).Path

$sasEnvelope = Read-RequiredFile $sas 'src/Common/Microsoft.Identity.MFA.SAS.Common.OutboundDependencies/Cyot/CyotEndpointDataModel/SendCyotOtpRequest.cs'
$sasConstants = Read-RequiredFile $sas 'src/Common/Microsoft.Identity.MFA.SAS.Common.OutboundDependencies/Cyot/CyotEndpointConstants.cs'
$sasMode = Read-RequiredFile $sas 'src/Common/Microsoft.Identity.MFA.SAS.Common.OutboundDependencies/Cyot/CyotEndpointDataModel/CyotDeliveryMode.cs'
$sasChannel = Read-RequiredFile $sas 'src/Common/Microsoft.Identity.MFA.SAS.Common.OutboundDependencies/Cyot/CyotEndpointDataModel/CyotChannel.cs'
$sasSettings = Read-RequiredFile $sas 'src/Common/Microsoft.Identity.MFA.SAS.Common.Configuration/settings.ini'

$javascript = Read-RequiredFile $sample 'javascript/src/functions/entraPayload.js'
$dotnet = Read-RequiredFile $sample 'dotnet/Src/EntraSendOtpPayload.cs'
$python = Read-RequiredFile $sample 'python/src/models.py'
$contractFixture = Read-RequiredFile $sample 'tests/fixtures/contract.json'
$pipeline = Read-RequiredFile $sample 'ado/cyot-integration/azure-pipelines.yml'
$pipelineTemplate = Read-RequiredFile $sample 'ado/cyot-integration/templates/validate-and-package.yml'

Assert-Match $pipeline '(?ms)^trigger:\s*.*?branches:\s*.*?include:\s*\r?\n\s*- main' 'GitHub main merge trigger is missing.'
Assert-Match $pipeline '(?m)^pr:\s*none\s*$' 'Unmerged GitHub PR runs must remain disabled.'
Assert-Match $pipeline '(?m)^\s*name:\s*One/AAD-MFA-StrongAuthenticationService\s*$' 'SAS repository resource is missing.'
Assert-Match $pipeline '(?m)^\s*ref:\s*refs/heads/main\s*$' 'SAS repository is not pinned to main.'
Assert-Match $pipeline '(?ms)^\s*- repository:\s*sas\s*.*?trigger:\s*.*?branches:\s*.*?include:\s*\r?\n\s*- main' 'SAS main trigger is missing.'
Assert-Match $pipelineTemplate '(?m)^\s*- stage:\s*ValidateAndPackage\s*$' 'Validation and package stage is missing.'

$envelopeType = [regex]::Match($sasConstants, 'EnvelopeType\s*=\s*"([^"]+)"').Groups[1].Value
if ($envelopeType -cne 'microsoft.mfa.otpDeliver.v1') {
    throw "Unexpected SAS envelope type: '$envelopeType'."
}

$callerClientId = [regex]::Match(
    $sasSettings,
    '(?m)^Logic\.Cyot\.OneP\.ApplicationId=([0-9a-fA-F-]{36})\s*$').Groups[1].Value
if ($callerClientId -notmatch '^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$') {
    throw 'SAS Logic.Cyot.OneP.ApplicationId is missing or invalid.'
}

$requiredEnvelopeFields = @(
    'type',
    'tenantId',
    'correlationId',
    'channel',
    'mode',
    'ttlSeconds',
    'encryptionKeyId',
    'encryptedDeliveryContext'
)
foreach ($field in $requiredEnvelopeFields) {
    Assert-Match $sasEnvelope ([regex]::Escape("JsonPropertyName(`"$field`")")) "SAS envelope no longer declares '$field'."
}

Assert-Match $sasMode '(?s)Live\s*=\s*1.*Evaluation\s*=\s*2' 'SAS delivery mode values changed.'
Assert-Match $sasChannel '(?s)Sms\s*=\s*1.*Voice\s*=\s*2' 'SAS channel values changed.'
Assert-Match $sasConstants 'CorrelationIdHeader\s*=\s*"x-ms-correlation-id"' 'SAS correlation header changed.'
Assert-Match $sasConstants 'ClientRequestIdHeader\s*=\s*"x-ms-client-request-id"' 'SAS client-request header changed.'

$runtimeChecks = @(
    @{ Name = 'javascript'; Text = $javascript; Type = [regex]::Escape($envelopeType); Live = 'LIVE:\s*1'; Evaluation = 'EVALUATION:\s*2'; Sms = 'SMS:\s*1'; Voice = 'VOICE:\s*2' },
    @{ Name = 'dotnet'; Text = $dotnet; Type = [regex]::Escape($envelopeType); Live = 'Live\s*=\s*1'; Evaluation = 'Evaluation\s*=\s*2'; Sms = 'Sms\s*=\s*1'; Voice = 'Voice\s*=\s*2' },
    @{ Name = 'python'; Text = $python; Type = [regex]::Escape($envelopeType); Live = 'MODE_LIVE\s*=\s*1'; Evaluation = 'MODE_EVALUATION\s*=\s*2'; Sms = 'CHANNEL_BY_CODE\s*=\s*\{1:\s*"sms"'; Voice = '2:\s*"voice"' }
)
foreach ($runtime in $runtimeChecks) {
    Assert-Match $runtime.Text $runtime.Type "$($runtime.Name) envelope type differs from SAS."
    Assert-Match $runtime.Text $runtime.Live "$($runtime.Name) live mode differs from SAS."
    Assert-Match $runtime.Text $runtime.Evaluation "$($runtime.Name) evaluation mode differs from SAS."
    Assert-Match $runtime.Text $runtime.Sms "$($runtime.Name) SMS channel differs from SAS."
    Assert-Match $runtime.Text $runtime.Voice "$($runtime.Name) voice channel differs from SAS."
    foreach ($field in @('tenantId', 'correlationId', 'ttlSeconds', 'encryptedDeliveryContext')) {
        Assert-Match $runtime.Text ([regex]::Escape($field)) "$($runtime.Name) does not consume '$field'."
    }
}

$fixture = $contractFixture | ConvertFrom-Json -Depth 100
if (-not @($fixture.badRequests | Where-Object name -eq 'wrong version').Count) {
    throw 'Shared contract fixtures do not test an unsupported envelope version.'
}
if (-not @($fixture.badRequests | Where-Object name -eq 'null mode').Count) {
    throw 'Shared contract fixtures do not test an invalid delivery mode.'
}

$sampleCommit = (& git -C $sample rev-parse HEAD).Trim()
$sasCommit = (& git -C $sas rev-parse HEAD).Trim()
if ($sampleCommit -notmatch '^[0-9a-f]{40}$' -or $sasCommit -notmatch '^[0-9a-f]{40}$') {
    throw 'Unable to resolve checked-out repository commits.'
}

$result = [ordered]@{
    validatedAtUtc = [DateTime]::UtcNow.ToString('o')
    sampleCommit = $sampleCommit
    sasCommit = $sasCommit
    envelopeType = $envelopeType
    sasCallerClientId = $callerClientId.ToLowerInvariant()
    endpointPath = '/api/SendOtp'
    channels = [ordered]@{ sms = 1; voice = 2 }
    modes = [ordered]@{ live = 1; evaluation = 2 }
    cleartextFields = $requiredEnvelopeFields
    runtimes = @('javascript', 'dotnet', 'python')
}

$parent = Split-Path -Parent $OutputPath
if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
$result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $OutputPath -Encoding utf8NoBOM
Write-Host "CYOT contract matches SAS commit $sasCommit and sample commit $sampleCommit."
Write-Host "SAS endpoint caller client ID: $($result.sasCallerClientId)"
