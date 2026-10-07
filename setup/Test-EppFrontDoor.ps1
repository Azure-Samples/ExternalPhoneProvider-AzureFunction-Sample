#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][Security.SecureString]$AccessToken
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$state = Get-Content -LiteralPath (Join-Path $OutputDirectory 'frontdoor-state.json') -Raw | ConvertFrom-Json
$endpoint = [uri]$state.endpointUrl
if ($endpoint.Scheme -ne 'https' -or $endpoint.Host -notmatch '^[a-z0-9.-]+\.azurefd\.net$' -or
    $endpoint.AbsolutePath -cne '/api/SendOtp' -or $endpoint.Query -or $endpoint.Fragment -or $endpoint.UserInfo) {
    throw 'State does not identify an HTTPS Front Door SendOtp endpoint.'
}
$certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new(
    [IO.File]::ReadAllBytes((Join-Path $OutputDirectory 'encryption-public.cer')))
$rsa = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey($certificate)
$records = [Collections.Generic.List[object]]::new()
$client = $null
function Encode([byte[]]$Bytes) { [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+','-').Replace('/','_') }
try {
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(30)
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($AccessToken)
    try { $token = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
    foreach ($mode in @('missing-token','invalid-token','evaluation-1','evaluation-2','evaluation-3')) {
        $nonce = [guid]::NewGuid().ToString('N')
        $correlation = [guid]::NewGuid().ToString()
        $header = Encode ([Text.Encoding]::UTF8.GetBytes('{"alg":"RSA-OAEP-256","enc":"A256GCM"}'))
        $key = [Security.Cryptography.RandomNumberGenerator]::GetBytes(32)
        $iv = [Security.Cryptography.RandomNumberGenerator]::GetBytes(12)
        $plain = [Text.Encoding]::UTF8.GetBytes((@{ nonce = $nonce; phoneNumber = '+15555550100'; message = 'Synthetic evaluation only' } | ConvertTo-Json -Compress))
        $encrypted = [byte[]]::new($plain.Length)
        $tag = [byte[]]::new(16)
        $aes = [Security.Cryptography.AesGcm]::new($key, 16)
        try {
            $aes.Encrypt($iv, $plain, $encrypted, $tag, [Text.Encoding]::ASCII.GetBytes($header))
            $wrapped = $rsa.Encrypt($key, [Security.Cryptography.RSAEncryptionPadding]::OaepSHA256)
        } finally { $aes.Dispose(); [Array]::Clear($key, 0, $key.Length) }
        $body = @{
            type = 'microsoft.mfa.otpDeliver.v1'; mode = 2; channel = 1; ttlSeconds = 60
            correlationId = $correlation
            encryptedDeliveryContext = (@($header, (Encode $wrapped), (Encode $iv), (Encode $encrypted), (Encode $tag)) -join '.')
        } | ConvertTo-Json -Compress
        $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post, $endpoint)
        try {
            $request.Content = [Net.Http.StringContent]::new($body, [Text.Encoding]::UTF8, 'application/json')
            if ($mode -ne 'missing-token') {
                $bearer = if ($mode -eq 'invalid-token') { 'invalid' } else { $token }
                $request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $bearer)
            }
            $response = $client.SendAsync($request).GetAwaiter().GetResult()
            try {
                $status = [int]$response.StatusCode
                $passed = $status -in @(401,403)
                if ($mode -like 'evaluation-*') {
                    $passed = $false
                    if ($status -eq 200) {
                        $result = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json
                        $passed = $result.nonce -ceq $nonce -and $result.correlationId -ceq $correlation
                    }
                }
                $records.Add(@{ check = $mode; httpStatus = $status; passed = $passed; correlationId = $correlation })
                Write-Host "$mode HTTP $status; passed=$passed"
            } finally { $response.Dispose() }
        } finally { $request.Dispose() }
    }
    $records | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'evaluation-results.json') -Encoding utf8NoBOM
    if (@($records | Where-Object { -not $_.passed }).Count) { throw 'Front Door evaluation/authentication checks failed. No live messages were sent.' }
    Write-Host 'Evaluation passed from this caller. This does not prove every origin, failover timing, or live provider delivery.'
}
finally {
    $token = $null
    if ($client) { $client.Dispose() }
    $rsa.Dispose()
    $certificate.Dispose()
}
