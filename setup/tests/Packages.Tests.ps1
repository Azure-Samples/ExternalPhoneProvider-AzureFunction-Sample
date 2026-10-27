#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$module = Import-Module (Join-Path $PSScriptRoot '../support/Epp.Setup.psm1') -Force -PassThru
$directory = Join-Path ([IO.Path]::GetTempPath()) "epp-package-tests-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $directory | Out-Null
try {
    & $module {
        param($Directory)

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
        function script:New-TestArchive([string[]] $Names, [string] $ExtraContent = '{}') {
            $path = Join-Path $Directory "$([Guid]::NewGuid().ToString('N')).zip"
            $zip = [IO.Compression.ZipFile]::Open($path, [IO.Compression.ZipArchiveMode]::Create)
            try {
                foreach ($name in $Names) {
                    $writer = [IO.StreamWriter]::new($zip.CreateEntry($name).Open())
                    try { $writer.Write($ExtraContent) }
                    finally { $writer.Dispose() }
                }
            }
            finally { $zip.Dispose() }
            return $path
        }
        function script:Invoke-EppAz { throw 'Unexpected Azure call (no network allowed).' }
        function script:Invoke-EppDotNet { throw 'Unexpected compiler invocation while consuming a deployment ZIP.' }
        $required = @{
            javascript = @('host.json', 'package.json', 'src/functions/SendOtp.js', 'node_modules/@azure/functions/package.json')
            dotnet = @('host.json', 'worker.config.json', 'functions.metadata', 'dotnet.dll', 'dotnet.runtimeconfig.json', '.azurefunctions/Microsoft.Azure.WebJobs.Extensions.Http.dll')
            python = @('host.json', 'function_app.py', 'requirements.txt', 'src/jwe.py', 'src/provider.py', '.python_packages/lib/site-packages/azure/functions/__init__.py')
        }
        $script:Downloads = [Collections.Generic.List[string]]::new()
        $script:ChecksumText = ''
        $script:PackagePath = ''
        $script:CorruptDownload = $false
        function script:Invoke-WebRequest {
            param($Uri, $OutFile, $TimeoutSec)
            $script:Downloads.Add($Uri)
            if ($Uri.EndsWith('/SHA256SUMS.txt')) {
                Assert ($TimeoutSec -eq 60) 'Bound checksum downloads.'
                Assert ($Uri -ceq $script:ExpectedChecksumsUrl) 'Use only the selected language release checksum file.'
                Set-Content -LiteralPath $OutFile -Value $script:ChecksumText -Encoding utf8NoBOM
            }
            else {
                Assert ($Uri -ceq $script:ExpectedPackageUrl -and $TimeoutSec -eq 300) 'Download only the selected language release asset with a bounded timeout.'
                Copy-Item -LiteralPath $script:PackagePath -Destination $OutFile
                if ($script:CorruptDownload) { Add-Content -LiteralPath $OutFile -Value 'corrupted' }
            }
        }
        foreach ($language in @('javascript', 'dotnet', 'python')) {
            $script:PackagePath = New-TestArchive $required[$language]
            Assert-EppArchive -Path $script:PackagePath -Language $language -Kind ready
            foreach ($missing in $required[$language]) {
                $path = New-TestArchive @($required[$language] | Where-Object { $_ -cne $missing })
                Assert-Throws { Assert-EppArchive -Path $path -Language $language -Kind ready } 'must contain exactly one|no Azure Functions extension assemblies'
            }
            foreach ($unsafe in @('../outside.txt', '/absolute.txt', 'C:/absolute.txt', 'src\backslash.txt', 'src/../outside.txt')) {
                $path = New-TestArchive ($required[$language] + $unsafe)
                Assert-Throws { Assert-EppArchive -Path $path -Language $language -Kind ready } 'absolute or traversing'
            }
            foreach ($private in @('local.settings.json', '.env', '.env.production', 'private.pem', 'private.key', 'private.pfx', 'private.p12')) {
                $path = New-TestArchive ($required[$language] + $private)
                Assert-Throws { Assert-EppArchive -Path $path -Language $language -Kind ready } 'local settings or key material'
            }
            $duplicate = New-TestArchive ($required[$language] + 'host.json')
            Assert-Throws { Assert-EppArchive -Path $duplicate -Language $language -Kind ready } "exactly one 'host.json'"

            $hash = (Get-FileHash -LiteralPath $script:PackagePath -Algorithm SHA256).Hash.ToLowerInvariant()
            $file = 'released-package.zip'
            $script:ExpectedPackageUrl = "https://github.com/unit/epp/releases/download/epp-packages-42-1-$language/$file"
            $script:ExpectedChecksumsUrl = "https://github.com/unit/epp/releases/download/epp-packages-42-1-$language/SHA256SUMS.txt"
            $selection = @{
                Id = $language; DisplayName = $language; BuildStrategy = 'ready'; Url = $script:ExpectedPackageUrl
                ChecksumsUrl = $script:ExpectedChecksumsUrl
            }
            $script:ChecksumText = "$hash  $file"
            $script:Downloads.Clear()
            $package = Get-EppPackage -Selection $selection -Directory $Directory
            Assert ($package.RequiresRemoteBuild -eq $false -and $package.SourceSha256 -ceq $hash -and
                $package.Sha256 -ceq $hash -and $package.Path -ceq (Join-Path $Directory $file)) 'Preserve the verified deployment ZIP and its SHA-256.'
            Assert ($script:Downloads.Count -eq 2 -and $script:Downloads[0] -ceq $selection.ChecksumsUrl -and
                $script:Downloads[1] -ceq $selection.Url) 'Verify the language release checksum before consuming its asset.'
            $script:CorruptDownload = $true
            Assert-Throws { Get-EppPackage -Selection $selection -Directory $Directory } 'does not match its published SHA-256'
            $script:CorruptDownload = $false
            $script:ChecksumText = "$hash  $file`n$hash  $file"
            $script:Downloads.Clear()
            Assert-Throws { Get-EppPackage -Selection $selection -Directory $Directory } 'exactly one SHA-256 entry'
            Assert ($script:Downloads.Count -eq 1) 'Reject ambiguous checksums before downloading the ZIP.'
            $script:ChecksumText = "$('0' * 64)  $file"
            Assert-Throws { Get-EppPackage -Selection $selection -Directory $Directory } 'does not match its published SHA-256'
            $script:ChecksumText = "$hash  $file"
            $selection.BuildStrategy = if ($language -eq 'dotnet') { 'dotnet-publish' } else { 'remote-build' }
            Assert-Throws { Get-EppPackage -Selection $selection -Directory $Directory } 'deployment ZIPs'
        }
        $caBundle = '.python_packages/lib/site-packages/certifi/cacert.pem'
        $path = New-TestArchive ($required.python + $caBundle) '-----BEGIN CERTIFICATE-----'
        Assert-EppArchive -Path $path -Language python -Kind ready
        foreach ($keyType in @('PRIVATE KEY', 'RSA PRIVATE KEY', 'ENCRYPTED PRIVATE KEY')) {
            $path = New-TestArchive ($required.python + $caBundle) "-----BEGIN $keyType-----"
            Assert-Throws { Assert-EppArchive -Path $path -Language python -Kind ready } 'CA bundle contains a private key'
        }
        $path = New-TestArchive ($required.python + 'other/cacert.pem') '-----BEGIN CERTIFICATE-----'
        Assert-Throws { Assert-EppArchive -Path $path -Language python -Kind ready } 'local settings or key material'
        foreach ($text in @('', 'invalid  released-package.zip', "$('a' * 64)  other.zip", "$('a' * 64)  Released-package.zip")) {
            Assert-Throws { Get-EppPublishedChecksum -Text $text -FileName 'released-package.zip' } 'exactly one SHA-256 entry'
        }
        Assert ((Get-EppPublishedChecksum -Text "$('A' * 64) *released-package.zip" -FileName 'released-package.zip') -ceq ('a' * 64)) 'Accept standard binary checksum format and normalize its case.'
    } $directory
    Write-Host 'Package regression tests passed.'
}
finally {
    Remove-Item -LiteralPath $directory -Recurse -Force
    Remove-Module $module -Force
}
