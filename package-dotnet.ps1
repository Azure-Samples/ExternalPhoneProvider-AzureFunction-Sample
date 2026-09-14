#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$OutputPath = (Join-Path $PSScriptRoot 'artifacts/epp-dotnet.zip')
)

$ErrorActionPreference = 'Stop'
$project = Join-Path $PSScriptRoot 'dotnet/dotnet.csproj'
$archive = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
if (Test-Path -LiteralPath $archive) { throw "Output already exists: $archive. Choose another -OutputPath." }
$dotnet = (Get-Command dotnet -ErrorAction Stop).Source
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('epp-dotnet-' + [guid]::NewGuid().ToString('N'))
$stage = Join-Path $temporary 'app'

try {
    & $dotnet publish $project --configuration Release --output $stage --verbosity minimal
    if ($LASTEXITCODE -ne 0) { throw '.NET publish failed; no ZIP created.' }
    foreach ($name in @('host.json', 'functions.metadata', 'worker.config.json', 'dotnet.dll', '.azurefunctions')) {
        if (-not (Test-Path -LiteralPath (Join-Path $stage $name))) { throw "Missing published runtime file: $name" }
    }
    $unsafe = @(Get-ChildItem -LiteralPath $stage -Recurse -Force -File | Where-Object {
        $_.Name -like 'local.settings*' -or $_.Name -like '.env*' -or
        $_.Extension -in @('.pem', '.pfx', '.p12', '.key', '.publishsettings', '.pubxml') -or
        [IO.Path]::GetRelativePath($stage, $_.FullName) -match '(^|[\\/])(tests?|scripts)([\\/]|$)'
    })
    if ($unsafe.Count) { throw 'Local settings, credentials, or test files found in publish output; no ZIP created.' }
    $zip = Join-Path $temporary 'app.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($stage, $zip)
    New-Item -ItemType Directory -Path (Split-Path $archive) -Force | Out-Null
    [IO.File]::Move($zip, $archive)
    Get-Item -LiteralPath $archive | Select-Object FullName, Length
} finally {
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
}