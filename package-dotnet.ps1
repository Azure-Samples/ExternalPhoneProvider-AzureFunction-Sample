#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$OutputPath = (Join-Path $PSScriptRoot 'artifacts/dotnet/released-package.zip')
)

$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot 'dotnet'
$archive = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
if (Test-Path -LiteralPath $archive) { throw "Output already exists: $archive. Choose another -OutputPath." }
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('epp-dotnet-' + [guid]::NewGuid().ToString('N'))
$stage = Join-Path $temporary 'app'

try {
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    dotnet publish (Join-Path $source 'dotnet.csproj') --configuration Release --runtime linux-x64 `
        --self-contained false -p:UseAppHost=false --output $stage --nologo
    if ($LASTEXITCODE -ne 0) { throw '.NET publish failed.' }
    foreach ($name in @('host.json', 'dotnet.dll', 'functions.metadata', 'worker.config.json', '.azurefunctions')) {
        if (-not (Test-Path -LiteralPath (Join-Path $stage $name))) { throw "Missing .NET publish output: $name." }
    }
    $zip = Join-Path $temporary 'app.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($stage, $zip)
    New-Item -ItemType Directory -Path (Split-Path $archive) -Force | Out-Null
    [IO.File]::Move($zip, $archive)
    Write-Host 'Framework-dependent .NET 10 Linux x64 ZIP created.'
    Get-Item -LiteralPath $archive | Select-Object FullName, Length
} finally {
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
}