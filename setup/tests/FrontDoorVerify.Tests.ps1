#Requires -Version 7.4
$ErrorActionPreference = 'Stop'
$path = Join-Path $PSScriptRoot '../Test-EppFrontDoor.ps1'
$errors = $null; $tokens = $null
[Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors) | Out-Null
if ($errors.Count) { throw ($errors.Message -join '; ') }
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('fd-verify-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $temporary | Out-Null
$token = ConvertTo-SecureString 'test-token' -AsPlainText -Force
try {
    foreach ($url in @('http://test.azurefd.net/api/SendOtp','https://example.com/api/SendOtp',
        'https://test.azurefd.net/api/SendOtp?redirect=elsewhere','https://user@test.azurefd.net/api/SendOtp')) {
        @{ endpointUrl = $url } | ConvertTo-Json | Set-Content (Join-Path $temporary 'frontdoor-state.json')
        $rejected = $false
        try { & $path -OutputDirectory $temporary -AccessToken $token } catch { $rejected = $true }
        if (-not $rejected) { throw 'Invalid verification endpoint was not rejected.' }
    }
    Write-Host 'PASS: verifier rejects non-HTTPS, unrelated, credential-bearing, and query-bearing endpoints before token use.'
} finally {
    $token.Dispose()
    Remove-Item -LiteralPath (Join-Path $temporary 'frontdoor-state.json')
    Remove-Item -LiteralPath $temporary
}
