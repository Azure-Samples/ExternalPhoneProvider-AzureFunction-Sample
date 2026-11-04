function Get-EppPackageRelease {
    param([string] $SourceRepository, [string] $Tag, [string] $TagPrefix,
        [ValidateSet('javascript', 'dotnet', 'python')][string] $Language)

    $tagShape = "$TagPrefix<run>-<attempt>-$Language"
    $tagPattern = '^' + [regex]::Escape($TagPrefix) + '[0-9]+-[0-9]+-' + $Language + '\z'
    if ($Tag -and $Tag -cnotmatch $tagPattern) {
        throw "Package release tag '$Tag' must match '$tagShape' for the selected language."
    }
    $headers = @{
        'User-Agent' = 'EPP-Setup'
        Accept = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
    }
    $page = 1
    do {
        $uri = if ($Tag) {
            "https://api.github.com/repos/$SourceRepository/releases/tags/$([Uri]::EscapeDataString($Tag))"
        }
        else {
            "https://api.github.com/repos/$SourceRepository/releases?per_page=100&page=$page"
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
        $page++
    } while (-not $Tag -and -not $release -and @($response).Count -eq 100)
    if (-not $release) {
        throw "No stable CI package release matching '$tagShape' was found in '$SourceRepository'."
    }
    $resolvedTag = [string]$release.tag_name
    if ($release.draft -or $release.prerelease -or $resolvedTag -cnotmatch $tagPattern -or ($Tag -and $resolvedTag -cne $Tag)) {
        throw "GitHub release '$resolvedTag' is not the requested stable CI package release matching '$tagShape'."
    }
    return $release
}

function Get-EppLanguage {
    param(
        [string] $AssetDirectory, [string] $Language = 'javascript', [string] $SourceRepository,
        [string] $PackageReleaseTag, [switch] $NonInteractive
    )

    $catalog = Read-EppJson (Join-Path $AssetDirectory 'packages/catalog.json')
    if ($catalog['schemaVersion'] -ne 3 -or -not $catalog['packages'] -or
        [string]$catalog['releaseTagPrefix'] -cnotmatch '^[A-Za-z0-9][A-Za-z0-9.-]*-$') {
        throw 'Unsupported or empty language package catalog.'
    }
    $tagPrefix = [string]$catalog['releaseTagPrefix']
    $strategies = @{ javascript = 'ready'; dotnet = 'ready'; python = 'ready' }
    $seen = @{}
    $entries = @($catalog['packages'])
    foreach ($entry in $entries) {
        if ($entry -isnot [Collections.IDictionary] -or -not $strategies.ContainsKey([string]$entry['id']) -or
            $seen.ContainsKey($entry['id']) -or $entry['buildStrategy'] -cne $strategies[$entry['id']] -or
            -not $entry['displayName'] -or $entry['displayName'] -match '[\x00-\x1f]' -or
            $entry['assetName'] -cne 'released-package.zip') {
            throw 'Language catalog contains an invalid, unsupported, or duplicate entry.'
        }
        $seen[$entry['id']] = $true
    }
    if ([string]::IsNullOrWhiteSpace($Language)) { throw 'Language must not be empty. Use javascript, csharp, or python.' }
    $languageId = switch ($Language.ToLowerInvariant()) {
        { $_ -in @('csharp', 'c#', 'dotnet', '.net') } { 'dotnet'; break }
        { $_ -in @('javascript', 'node.js') } { 'javascript'; break }
        'python' { 'python'; break }
        default { throw "Unsupported language '$Language'. Use javascript, csharp, or python." }
    }
    $entry = $entries | Where-Object { $_['id'] -ceq $languageId } | Select-Object -First 1
    if (-not $entry) { throw "The package catalog does not contain the selected language '$Language'." }
    $release = Get-EppPackageRelease -SourceRepository $SourceRepository -Tag $PackageReleaseTag -TagPrefix $tagPrefix -Language $languageId
    $releaseTag = [string]$release.tag_name
    $releaseBaseUrl = "https://github.com/$SourceRepository/releases/download/$releaseTag"
    $assetName = [string]$entry['assetName']
    $assets = @($release.assets)
    foreach ($requiredAsset in @($assetName, 'SHA256SUMS.txt')) {
        if (@($assets | Where-Object { $_.name -ceq $requiredAsset }).Count -ne 1) {
            throw "Release '$releaseTag' must contain exactly one '$requiredAsset' asset."
        }
    }
    if ($assets.Count -ne 2) { throw "Release '$releaseTag' must contain only '$assetName' and 'SHA256SUMS.txt' assets." }
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
            'javascript' {
                $required += 'package.json'
                if ($Kind -eq 'ready') { $required += @('src/functions/SendOtp.js', 'node_modules/@azure/functions/package.json') }
            }
            'dotnet' {
                if ($Kind -eq 'source') { $required += 'dotnet.csproj' }
                else { $required += @('worker.config.json', 'functions.metadata', 'dotnet.dll', 'dotnet.runtimeconfig.json') }
            }
            'python' {
                $required += @('function_app.py', 'requirements.txt', 'src/jwe.py', 'src/provider.py')
                if ($Kind -eq 'ready') { $required += '.python_packages/lib/site-packages/azure/functions/__init__.py' }
            }
        }
        foreach ($file in $required) {
            if (@($names | Where-Object { $_ -ceq $file }).Count -ne 1) {
                throw "The $Language $Kind ZIP must contain exactly one '$file' at its required deployment path."
            }
        }
        if ($Language -eq 'dotnet' -and $Kind -eq 'ready' -and -not @($names | Where-Object { $_ -cmatch '^\.azurefunctions/[^/]+\.dll$' }).Count) {
            throw 'The .NET publish output contains no Azure Functions extension assemblies.'
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
    if ($Selection.BuildStrategy -ne 'ready') { throw 'Select a release containing the selected language deployment ZIPs.' }
    Assert-EppArchive -Path $sourcePath -Language $Selection.Id -Kind ready
    $path = $sourcePath
    return [pscustomobject]@{
        Path = $path
        SourceSha256 = $expected
        Sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        RequiresRemoteBuild = $false
    }
}
