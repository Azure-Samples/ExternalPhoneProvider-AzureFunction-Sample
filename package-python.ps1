#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$OutputPath = (Join-Path $PSScriptRoot 'artifacts/epp-python.zip')
)

$ErrorActionPreference = 'Stop'
if (-not $IsLinux) { throw 'Build the Python deployment package on Linux for the Azure Functions Python 3.11 runtime.' }
python -c "import sys; assert sys.version_info[:2] == (3, 11), 'Python 3.11 is required'"
if ($LASTEXITCODE -ne 0) { throw 'Python 3.11 is required to build the deployment package.' }
$source = Join-Path $PSScriptRoot 'python'
$archive = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
if (Test-Path -LiteralPath $archive) { throw "Output already exists: $archive. Choose another -OutputPath." }
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('epp-python-' + [guid]::NewGuid().ToString('N'))
$stage = Join-Path $temporary 'app'

try {
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    foreach ($name in @('host.json', 'function_app.py', 'requirements.txt')) {
        Copy-Item -LiteralPath (Join-Path $source $name) -Destination $stage
    }
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $source 'src') -Recurse -File -Filter '*.py') {
        $relative = [IO.Path]::GetRelativePath($source, $file.FullName)
        if ($relative -match '(^|[\\/])(tests?|__pycache__|\.venv|venv)([\\/]|$)') { continue }
        $destination = Join-Path $stage $relative
        New-Item -ItemType Directory -Path (Split-Path $destination) -Force | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $destination
    }
    foreach ($name in @('function_app.py', 'src/jwe.py', 'src/provider.py')) {
        if (-not (Test-Path -LiteralPath (Join-Path $stage $name))) {
            throw "Missing Python application source: $name."
        }
    }
    $dependencies = Join-Path $stage '.python_packages/lib/site-packages'
    python -m pip install --requirement (Join-Path $source 'requirements.txt') --target $dependencies `
        --platform manylinux2014_x86_64 --implementation cp --python-version 3.11 --only-binary=:all: --no-compile
    if ($LASTEXITCODE -ne 0) { throw 'Installing Azure-compatible Linux Python dependencies failed.' }
    if (-not (Test-Path -LiteralPath (Join-Path $dependencies 'azure/functions/__init__.py'))) {
        throw 'Missing packaged Azure Functions Python dependency.'
    }
    $zip = Join-Path $temporary 'app.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($stage, $zip)
    New-Item -ItemType Directory -Path (Split-Path $archive) -Force | Out-Null
    [IO.File]::Move($zip, $archive)
    Write-Host 'Python 3.11 Linux x64 ZIP created with bundled dependencies.'
    Get-Item -LiteralPath $archive | Select-Object FullName, Length
} finally {
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
}