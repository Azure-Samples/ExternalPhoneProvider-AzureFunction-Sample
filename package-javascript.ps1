#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$OutputPath = (Join-Path $PSScriptRoot 'artifacts/epp-javascript.zip')
)

$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot 'javascript'
$archive = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
if (Test-Path -LiteralPath $archive) { throw "Output already exists: $archive. Choose another -OutputPath." }
$npm = (Get-Command $(if ($IsWindows) { 'npm.cmd' } else { 'npm' }) -ErrorAction Stop).Source
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('epp-javascript-' + [guid]::NewGuid().ToString('N'))
$stage = Join-Path $temporary 'app'

try {
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    foreach ($name in @('host.json', 'package.json', 'package-lock.json')) {
        Copy-Item -LiteralPath (Join-Path $source $name) -Destination $stage
    }
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $source 'src/functions') -Recurse -File -Filter '*.js') {
        $relative = [IO.Path]::GetRelativePath($source, $file.FullName)
        if ($relative -match '(^|[\\/])(tests?|node_modules)([\\/]|$)' -or $file.Name -match '\.(test|spec)\.js$') { continue }
        $destination = Join-Path $stage $relative
        New-Item -ItemType Directory -Path (Split-Path $destination) -Force | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $destination
    }
    if (-not (Test-Path -LiteralPath (Join-Path $stage 'src/functions/SendOtp.js'))) { throw 'Missing JavaScript function entry point.' }
    Push-Location $stage
    try {
        & $npm ci --omit=dev --ignore-scripts --no-audit --no-fund
        if ($LASTEXITCODE -ne 0) { throw 'Production dependency installation failed; no ZIP created.' }
    } finally { Pop-Location }
    if (-not (Test-Path -LiteralPath (Join-Path $stage 'node_modules/@azure/functions/package.json'))) {
        throw 'Missing Azure Functions runtime dependency.'
    }
    $zip = Join-Path $temporary 'app.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($stage, $zip)
    New-Item -ItemType Directory -Path (Split-Path $archive) -Force | Out-Null
    [IO.File]::Move($zip, $archive)
    Get-Item -LiteralPath $archive | Select-Object FullName, Length
} finally {
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
}