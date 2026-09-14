#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$OutputPath = (Join-Path $PSScriptRoot 'artifacts/epp-python-source.zip')
)

$ErrorActionPreference = 'Stop'
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
    if (-not (Test-Path -LiteralPath (Join-Path $stage 'src/dispatch.py'))) { throw 'Missing Python application source.' }
    $zip = Join-Path $temporary 'app.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($stage, $zip)
    New-Item -ItemType Directory -Path (Split-Path $archive) -Force | Out-Null
    [IO.File]::Move($zip, $archive)
    Write-Host 'Python source ZIP created. Deploy with Azure remote build to install Linux dependencies; not ready for direct run-from-package.'
    Get-Item -LiteralPath $archive | Select-Object FullName, Length
} finally {
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
}