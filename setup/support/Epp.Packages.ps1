function Get-EppPackageRelease {
    param([string] $SourceRepository, [string] $Tag, [string] $TagPrefix)

    $tagPattern = '^' + [regex]::Escape($TagPrefix) + '[0-9]+-[0-9]+$'
    $headers = @{
        'User-Agent' = 'EPP-Setup'
        Accept = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
    }
    $uri = if ($Tag) {
        "https://api.github.com/repos/$SourceRepository/releases/tags/$([Uri]::EscapeDataString($Tag))"
    }
    else {
        "https://api.github.com/repos/$SourceRepository/releases?per_page=100"
    }
    try {
        $response = Invoke-RestMethod -Uri $uri -Headers $headers -TimeoutSec 60
    }
    catch {
        $description = if ($Tag) { "package release '$Tag'" } else { 'stable package releases' }
        throw "Could not resolve the $description in '$SourceRepository': $($_.Exception.Message)"
    }
    $release = if ($Tag) {
        $response
    }
    else {
        @($response) | Where-Object {
            -not $_.draft -and -not $_.prerelease -and [string]$_.tag_name -cmatch $tagPattern
        } | Select-Object -First 1
    }
    if (-not $release) {
        throw "No stable CI package release matching '$TagPrefix<run>-<attempt>' was found in '$SourceRepository'."
    }
    $resolvedTag = [string]$release.tag_name
    if ($release.draft -or $release.prerelease -or $resolvedTag -cnotmatch $tagPattern) {
        throw "GitHub release '$resolvedTag' is not a stable CI package release matching '$TagPrefix<run>-<attempt>'."
    }
    return $release
}

function Get-EppLanguage {
    param(
        [string] $AssetDirectory, [string] $Language, [string] $SourceRepository,
        [string] $PackageReleaseTag, [switch] $NonInteractive
    )

    $catalog = Read-EppJson (Join-Path $AssetDirectory 'packages/catalog.json')
    if ($catalog['schemaVersion'] -ne 2 -or -not $catalog['packages'] -or
        [string]$catalog['releaseTagPrefix'] -cnotmatch '^[A-Za-z0-9][A-Za-z0-9.-]*-$') {
        throw 'Unsupported or empty language package catalog.'
    }
    $tagPrefix = [string]$catalog['releaseTagPrefix']
    $strategies = @{ javascript = 'ready'; dotnet = 'dotnet-publish'; python = 'remote-build' }
    $seen = @{}
    $entries = @($catalog['packages'])
    foreach ($entry in $entries) {
        if ($entry -isnot [Collections.IDictionary] -or -not $strategies.ContainsKey([string]$entry['id']) -or
            $seen.ContainsKey($entry['id']) -or $entry['buildStrategy'] -cne $strategies[$entry['id']] -or
            -not $entry['displayName'] -or $entry['displayName'] -match '[\x00-\x1f]' -or
            [string]$entry['assetName'] -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_.-]*\.zip$') {
            throw 'Language catalog contains an invalid, unsupported, or duplicate entry.'
        }
        $seen[$entry['id']] = $true
    }
    $entry = Select-EppOption -Entries $entries -Name Language -PromptName Platform `
        -Value $Language -NonInteractive:$NonInteractive
    $release = Get-EppPackageRelease -SourceRepository $SourceRepository -Tag $PackageReleaseTag -TagPrefix $tagPrefix
    $releaseTag = [string]$release.tag_name
    $releaseBaseUrl = "https://github.com/$SourceRepository/releases/download/$releaseTag"
    $assetName = [string]$entry['assetName']
    $assets = @($release.assets)
    foreach ($requiredAsset in @($assetName, 'SHA256SUMS.txt')) {
        if (@($assets | Where-Object { $_.name -ceq $requiredAsset }).Count -ne 1) {
            throw "Release '$releaseTag' must contain exactly one '$requiredAsset' asset."
        }
    }
    $url = Read-EppInput -Name PackageUrl -Value "$releaseBaseUrl/$assetName" -Kind PackageUrl `
        -SourceRepository $SourceRepository -NonInteractive
    return [pscustomobject]@{
        Id = $entry['id']; DisplayName = $entry['displayName']; Url = $url
        ChecksumsUrl = "$releaseBaseUrl/SHA256SUMS.txt"; ReleaseTag = $releaseTag
        BuildStrategy = $entry['buildStrategy']
    }
}

function Get-EppPublishedChecksum {
    param([string] $Text, [string] $FileName)

    $matches = @()
    foreach ($line in ($Text.TrimStart([char]0xfeff) -split '\r?\n')) {
        $match = [regex]::Match($line, '^([0-9a-fA-F]{64})[ \t]+\*?(.+?)[ \t]*$')
        if ($match.Success -and $match.Groups[2].Value -ceq $FileName) {
            $matches += $match.Groups[1].Value.ToLowerInvariant()
        }
    }
    if ($matches.Count -ne 1) { throw "The release checksum file must contain exactly one SHA-256 entry for '$FileName'." }
    return $matches[0]
}

function Assert-EppArchive {
    param(
        [string] $Path,
        [ValidateSet('javascript', 'dotnet', 'python')][string] $Language,
        [ValidateSet('source', 'ready')][string] $Kind
    )

    $archive = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $names = @($archive.Entries | ForEach-Object FullName)
        $required = @('host.json')
        switch ($Language) {
            'javascript' { $required += 'package.json' }
            'dotnet' {
                if ($Kind -eq 'source') { $required += 'dotnet.csproj' }
                else { $required += @('worker.config.json', 'functions.metadata') }
            }
            'python' {
                $required += @('function_app.py', 'requirements.txt')
                if ($Kind -eq 'ready') { $required += '.python_packages/lib/site-packages/azure/functions/__init__.py' }
            }
        }
        foreach ($file in $required) {
            if (@($names | Where-Object { $_ -ceq $file }).Count -ne 1) {
                throw "The $Language $Kind ZIP must contain exactly one '$file' at its required deployment path."
            }
        }
        if ($Language -eq 'dotnet' -and $Kind -eq 'ready' -and -not @($names | Where-Object { $_ -cmatch '^[^/]+\.dll$' }).Count) {
            throw 'The .NET publish output contains no application assemblies.'
        }
        if (@($names | Where-Object { $_ -match '\\|(^|/)\.\.?(/|$)|^/|^[a-zA-Z]:' }).Count) {
            throw 'The Function ZIP contains an absolute or traversing archive path.'
        }
        foreach ($entry in $archive.Entries) {
            if ($entry.FullName -match '(?i)(^|/)(local\.settings[^/]*\.json|\.env(?:\.[^/]*)?|[^/]+\.(pfx|p12|pem|key))$') {
                # Python's certifi dependency ships public CA roots, not an application private key.
                if ($Language -eq 'python' -and $Kind -eq 'ready' -and
                    $entry.FullName -ceq '.python_packages/lib/site-packages/certifi/cacert.pem') {
                    $reader = [IO.StreamReader]::new($entry.Open())
                    try {
                        if ($reader.ReadToEnd() -match '-----BEGIN [^-]*PRIVATE KEY-----') { throw 'The CA bundle contains a private key.' }
                    }
                    finally { $reader.Dispose() }
                    continue
                }
                throw 'The Function ZIP contains local settings or key material. Do not deploy this package.'
            }
        }
    }
    finally { $archive.Dispose() }
}

function Invoke-EppDotNet {
    param([Parameter(ValueFromRemainingArguments)][string[]] $Arguments)

    $PSNativeCommandUseErrorActionPreference = $false
    $output = & dotnet @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "dotnet $($Arguments[0]) failed (exit $LASTEXITCODE):`n$($output -join "`n")" }
    return $output -join "`n"
}

function Build-EppDotNetPackage {
    param([string] $SourcePath, [string] $Directory)

    if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
        throw 'The .NET language needs the .NET 8 SDK on this computer. Install it once; setup performs the build automatically.'
    }
    $versions = @((Invoke-EppDotNet --list-sdks) -split '\r?\n' | ForEach-Object {
        if ($_ -match '^(8\.\d+\.\d+)\s') { [Version]$Matches[1] }
    } | Sort-Object -Descending)
    if (-not $versions.Count) { throw 'Install the .NET 8 SDK before deploying the .NET language. No Azure resources were changed.' }
    $sourceDirectory = Join-Path $Directory 'dotnet-source'
    $publishDirectory = Join-Path $Directory 'dotnet-publish'
    [IO.Compression.ZipFile]::ExtractToDirectory($SourcePath, $sourceDirectory)
    @{ sdk = @{ version = $versions[0].ToString(); rollForward = 'latestPatch' } } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $sourceDirectory 'global.json') -Encoding utf8NoBOM
    Write-Host 'Building .NET 8 for Linux automatically...' -ForegroundColor Cyan
    Push-Location -LiteralPath $sourceDirectory
    try {
        Invoke-EppDotNet -Arguments @('publish', 'dotnet.csproj', '--configuration', 'Release', '--runtime', 'linux-x64',
            '--self-contained', 'false', '-p:UseAppHost=false', '--output', $publishDirectory, '--nologo') | Out-Null
    }
    finally { Pop-Location }
    $path = Join-Path $Directory 'dotnet-ready.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($publishDirectory, $path)
    Assert-EppArchive -Path $path -Language dotnet -Kind ready
    return $path
}

function Get-EppPackage {
    param($Selection, [string] $Directory)

    Write-Host "Downloading $($Selection.DisplayName) and verifying its published checksum automatically..." -ForegroundColor Cyan
    $checksumPath = Join-Path $Directory "$($Selection.Id)-SHA256SUMS.txt"
    Invoke-WebRequest -Uri $Selection.ChecksumsUrl -OutFile $checksumPath -TimeoutSec 60
    if ((Get-Item -LiteralPath $checksumPath).Length -gt 1MB) { throw 'The release checksum file is unexpectedly large.' }
    $fileName = ([Uri]$Selection.Url).Segments[-1]
    $expected = Get-EppPublishedChecksum -Text (Get-Content -LiteralPath $checksumPath -Raw -Encoding utf8) -FileName $fileName
    $sourcePath = Join-Path $Directory $fileName
    Invoke-WebRequest -Uri $Selection.Url -OutFile $sourcePath -TimeoutSec 300
    if ((Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash -ine $expected) {
        throw 'The downloaded Function ZIP does not match its published SHA-256. No Azure resources were changed.'
    }
    $kind = if ($Selection.BuildStrategy -eq 'ready') { 'ready' } else { 'source' }
    Assert-EppArchive -Path $sourcePath -Language $Selection.Id -Kind $kind
    $path = if ($Selection.BuildStrategy -eq 'dotnet-publish') { Build-EppDotNetPackage -SourcePath $sourcePath -Directory $Directory } else { $sourcePath }
    return [pscustomobject]@{
        Path = $path
        SourceSha256 = $expected
        Sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        RequiresRemoteBuild = $Selection.BuildStrategy -eq 'remote-build'
    }
}
