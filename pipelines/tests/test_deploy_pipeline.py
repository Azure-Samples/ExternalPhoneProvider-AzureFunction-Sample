import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[2]
PIPELINE = ROOT / "pipelines" / "deploy-cyot-e2e.yml"


def scripts_in(value):
    if isinstance(value, dict):
        for key, item in value.items():
            if key in ("pwsh", "Inline") and isinstance(item, str):
                yield item
            else:
                yield from scripts_in(item)
    elif isinstance(value, list):
        for item in value:
            yield from scripts_in(item)


class PipelineTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text = PIPELINE.read_text(encoding="utf-8")
        cls.pipeline = yaml.safe_load(cls.text)
        cls.scripts = list(scripts_in(cls.pipeline))

    def powershell(self, program, stdin="", extra_env=None):
        environment = os.environ.copy()
        environment.update(extra_env or {})
        result = subprocess.run(
            ["pwsh", "-NoProfile", "-NonInteractive", "-Command", program],
            input=stdin, capture_output=True, text=True, env=environment, timeout=90,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout

    def test_main_trigger_and_manual_deployment_boundary(self):
        self.assertEqual(self.pipeline["trigger"], {
            "batch": True, "branches": {"include": ["main"]},
        })
        self.assertEqual(self.pipeline["pr"], "none")
        parameters = {item["name"]: item for item in self.pipeline["parameters"]}
        self.assertTrue(all("default" in item for item in parameters.values()))
        self.assertEqual(parameters["sourceCommit"]["default"], "triggeringCommit")
        self.assertIs(parameters["deployAndTest"]["default"], False)
        self.assertFalse({"tenantId", "subscriptionId", "callerClientId"} & parameters.keys())
        stages = self.pipeline["extends"]["parameters"]["stages"]
        deployment = stages[1]["${{ if eq(parameters.deployAndTest, true) }}"][0]
        self.assertIn("eq(variables['Build.SourceBranch'], 'refs/heads/main')", deployment["condition"])
        self.assertIn("eq(variables['Build.Reason'], 'Manual')", deployment["condition"])
        self.assertNotIn("variables", self.pipeline)
        self.assertNotIn("variables", stages[0])
        self.assertEqual(deployment["variables"], [{"group": "cyot-e2e-config"}])
        self.assertEqual(deployment["lockBehavior"], "sequential")
        build_definition = yaml.safe_dump(stages[0])
        for private_reference in ("CyotTenantId", "CyotSubscriptionId", "CyotCallerClientId", "AzurePowerShell@", "AzureFunctionApp@"):
          self.assertNotIn(private_reference, build_definition)
        outputs = stages[0]["jobs"][0]["templateContext"]["outputs"]
        self.assertEqual(outputs, [{"output": "pipelineArtifact", "artifactName": "cyot-packages",
                       "targetPath": "$(Build.ArtifactStagingDirectory)/cyot-packages"}])

    def test_identity_values_and_credentials_are_not_in_source(self):
        self.assertFalse(re.search(r"\b[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\b", self.text))
        self.assertNotRegex(self.text, r"-----BEGIN (?:RSA |EC |ENCRYPTED )?PRIVATE KEY-----")
        self.assertNotIn("$(System.AccessToken)", self.text)
        self.assertNotIn("persistCredentials: true", self.text)
        self.assertIn("EXPECTED_TENANT: $(CyotTenantId)", self.text)
        self.assertIn("EXPECTED_SUBSCRIPTION: $(CyotSubscriptionId)", self.text)
        self.assertIn("CALLER_CLIENT_ID: $(CyotCallerClientId)", self.text)
        self.assertNotIn("Write-Host $bearer", self.text)
        self.assertNotIn("Write-Host $settings", self.text)
        self.assertNotIn("Write-Host $_", self.text)
        self.assertIn("https://github.com/Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample.git", self.text)
        self.assertIn("condition: always()", self.text)

    def test_all_powershell_blocks_parse(self):
        self.assertEqual(len(self.scripts), 4)
        parser = r"""
$tokens = $null
$errors = $null
[System.Management.Automation.Language.Parser]::ParseInput(
  [Console]::In.ReadToEnd(), [ref]$tokens, [ref]$errors) | Out-Null
if ($errors.Count) { throw ($errors.Message -join '; ') }
"""
        for script in self.scripts:
            self.powershell(parser, script)

    def test_source_selection(self):
        guard = "$sourceRef = $env:SOURCE_COMMIT" + self.scripts[0].split(
            "$sourceRef = $env:SOURCE_COMMIT", 1)[1].split("$source = Join-Path", 1)[0]
        self.powershell(r"""
$guard = [scriptblock]::Create([Console]::In.ReadToEnd())
$cases = @(
  @{ source='triggeringCommit'; deploy='False'; allowed=$true },
  @{ source='triggeringCommit'; deploy='True'; allowed=$false },
  @{ source=('a' * 40); deploy='True'; allowed=$true },
  @{ source=('a' * 40); deploy='False'; allowed=$true },
  @{ source='main'; deploy='False'; allowed=$false },
  @{ source='refs/heads/main'; deploy='False'; allowed=$false },
  @{ source='--upload-pack=bad'; deploy='False'; allowed=$false },
  @{ source=('A' * 40); deploy='True'; allowed=$false },
  @{ source=''; deploy='True'; allowed=$false },
  @{ source='triggeringCommit'; deploy='False'; reason='IndividualCI'; allowed=$true },
  @{ source='triggeringCommit'; deploy='False'; reason='BatchedCI'; allowed=$true },
  @{ source=('a' * 40); deploy='False'; reason='IndividualCI'; allowed=$false },
  @{ source='triggeringCommit'; deploy='True'; reason='IndividualCI'; allowed=$false },
  @{ source='triggeringCommit'; deploy='False'; reason='IndividualCI'; branch='refs/heads/other'; allowed=$false },
  @{ source='triggeringCommit'; deploy='False'; provider='TfsGit'; allowed=$false },
  @{ source='triggeringCommit'; deploy='False'; repository='someone/fork'; allowed=$false },
  @{ source='triggeringCommit'; deploy='False'; sha='invalid'; allowed=$false }
)
foreach ($case in $cases) {
  $env:SOURCE_COMMIT = $case.source
  $env:DEPLOY_AND_TEST = $case.deploy
  $env:BUILD_REASON = $(if ($case.reason) { $case.reason } else { 'Manual' })
  $env:BUILD_SOURCEBRANCH = $(if ($case.branch) { $case.branch } else { 'refs/heads/main' })
  $env:BUILD_REPOSITORY_PROVIDER = $(if ($case.provider) { $case.provider } else { 'GitHub' })
  $env:BUILD_REPOSITORY_NAME = $(if ($case.repository) { $case.repository } else { 'Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample' })
  $env:BUILD_SOURCEVERSION = $(if ($case.sha) { $case.sha } else { 'b' * 40 })
  $accepted = $true
  try { . $guard } catch { $accepted = $false }
  if ($accepted -ne $case.allowed) { throw 'Source guard mismatch.' }
  if ($accepted) {
    $expected = $(if ($case.source -eq 'triggeringCommit') { $env:BUILD_SOURCEVERSION } else { $case.source })
    if ($sourceRef -cne $expected) { throw 'Wrong commit selected.' }
  }
}
""", guard)

    def test_preflight_and_cleanup_with_mock_arm(self):
        with tempfile.TemporaryDirectory() as temporary:
            self.powershell(r"""
$ErrorActionPreference = 'Stop'
$scripts = [Console]::In.ReadToEnd() | ConvertFrom-Json
$preflight = [scriptblock]::Create($scripts.preflight)
$cleanup = [scriptblock]::Create($scripts.cleanup)
$env:AGENT_TEMPDIRECTORY = $env:TEST_DIRECTORY
$env:PIPELINE_WORKSPACE = $env:TEST_DIRECTORY
$env:BUILD_BUILDID = '123'
$env:SOURCE_COMMIT = 'a' * 40
$env:TARGET_GROUP = 'isolated-test-group'
$artifact = Join-Path $env:TEST_DIRECTORY 'cyot-packages'
New-Item -ItemType Directory $artifact | Out-Null
$manifest = @{ commit=$env:SOURCE_COMMIT; buildId=$env:BUILD_BUILDID; packages=@{} }
$rsa = [Security.Cryptography.RSA]::Create(2048)
try { $publicKey = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($rsa.ExportSubjectPublicKeyInfoPem())) }
finally { $rsa.Dispose() }
$targets = foreach ($language in @('dotnet', 'javascript', 'python')) {
  $zip = Join-Path $artifact ($language + '.zip')
  [IO.File]::WriteAllText($zip, 'offline fixture')
  $manifest.packages[$language] = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
  @{ language=$language; appName=('unit-' + $language); appType='functionAppLinux'; audience='api://unit-test'; publicKeyBase64=$publicKey }
}
$manifest | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $artifact 'source.json')
function Get-AzContext {
  @{ Tenant=@{ Id='11111111-1111-4111-8111-111111111111' }; Subscription=@{ Id='22222222-2222-4222-8222-222222222222' } }
}
function Invoke-AzRestMethod {
  [CmdletBinding()]
  param([string]$Path, [string]$Method)
  if ($script:scenario -eq 'resource-error') {
    Write-Warning 'PRIVATE-SENTINEL'
    Write-Verbose 'PRIVATE-SENTINEL'
    Write-Debug 'PRIVATE-SENTINEL'
    Write-Information 'PRIVATE-SENTINEL'
    throw 'PRIVATE-SENTINEL'
  }
  $pathWithoutQuery = $Path.Split('?')[0]
  $language = [regex]::Match($pathWithoutQuery, '/sites/unit-([^/]+)').Groups[1].Value
  if ($pathWithoutQuery.EndsWith('/config/authsettingsV2/list')) {
    $issuer = 'https://login.microsoftonline.com/' + $env:EXPECTED_TENANT + '/v2.0'
    if ($script:scenario -eq 'valid-v1') { $issuer = 'https://sts.windows.net/' + $env:EXPECTED_TENANT + '/' }
    if ($script:scenario -eq 'bad-issuer') { $issuer = 'https://login.microsoftonline.com/extra/' + $env:EXPECTED_TENANT + '/v2.0' }
    $body = @{ properties=@{
      platform=@{ enabled=($script:scenario -ne 'no-auth') }
      globalValidation=@{ requireAuthentication=$true; unauthenticatedClientAction='Return401'; excludedPaths=@() }
      httpSettings=@{ requireHttps=($script:scenario -ne 'no-https') }
      identityProviders=@{ azureActiveDirectory=@{
        enabled=$true; registration=@{ openIdIssuer=$issuer }
        validation=@{ allowedAudiences=@('api://unit-test'); defaultAuthorizationPolicy=@{
          allowedApplications=@($(if ($script:scenario -eq 'no-allowlist') { 'other' } else { $env:CALLER_CLIENT_ID }))
        } }
      } }
    } }
  } elseif ($pathWithoutQuery.EndsWith('/config/appsettings/list')) {
    if ($Method -ne 'POST') { throw 'Incorrect settings read method.' }
    $body = @{ properties=@{
      FUNCTIONS_WORKER_RUNTIME=@{ dotnet='dotnet-isolated'; javascript='node'; python='python' }[$language]
      FUNCTIONS_EXTENSION_VERSION='~4'
      EPP_DECRYPTION_KEY_PEM='PRIVATE-SENTINEL'
      EPP_PROVIDER_NAME=$(if ($script:scenario -eq 'live-provider') { 'live' } else { '' })
      SCM_DO_BUILD_DURING_DEPLOYMENT=$(if ($script:scenario -eq 'remote-build') { 'true' } else { 'false' })
    } }
  } elseif ($pathWithoutQuery.EndsWith('/config/web')) {
    $body = @{ properties=@{ linuxFxVersion=@{ dotnet='DOTNET-ISOLATED|8.0'; javascript='NODE|22'; python='PYTHON|3.11' }[$language] } }
  } elseif ($pathWithoutQuery -eq '/mock-plan') {
    $body = @{ sku=@{ name=$(if ($script:scenario -eq 'flex') { 'FC1' } else { 'EP1' }) } }
  } elseif ($pathWithoutQuery -match '/sites/unit-(dotnet|javascript|python)$') {
    $body = @{ kind='functionapp,linux'; properties=@{
      httpsOnly=$true; serverFarmId='/mock-plan'; defaultHostName=('unit-' + $language + '.azurewebsites.net')
    } }
  } else { throw 'Unexpected ARM path.' }
  @{ StatusCode=200; Content=($body | ConvertTo-Json -Depth 12) }
}
$scenarios = @('valid-v2', 'valid-v1', 'wrong-tenant', 'missing-id', 'zero-id', 'same-connection',
  'bad-issuer', 'no-auth', 'no-https', 'no-allowlist', 'live-provider', 'flex', 'remote-build',
  'resource-error', 'invalid-key', 'bad-source', 'invalid-json', 'tampered-hash')
foreach ($script:scenario in $scenarios) {
  $env:EXPECTED_TENANT = '11111111-1111-4111-8111-111111111111'
  $env:EXPECTED_SUBSCRIPTION = '22222222-2222-4222-8222-222222222222'
  $env:CALLER_CLIENT_ID = '33333333-3333-4333-8333-333333333333'
  $env:DEPLOYMENT_CONNECTION = 'deployment'
  $env:CALLER_CONNECTION = 'caller'
  $env:SOURCE_COMMIT = 'a' * 40
  $env:TARGETS_JSON = $targets | ConvertTo-Json -Depth 5
  if ($scenario -eq 'wrong-tenant') { $env:EXPECTED_TENANT = '44444444-4444-4444-8444-444444444444' }
  if ($scenario -eq 'missing-id') { $env:CALLER_CLIENT_ID = '$(UnresolvedVariable)' }
  if ($scenario -eq 'zero-id') { $env:CALLER_CLIENT_ID = [guid]::Empty.ToString() }
  if ($scenario -eq 'same-connection') { $env:CALLER_CONNECTION = $env:DEPLOYMENT_CONNECTION }
  if ($scenario -eq 'invalid-key') { $env:TARGETS_JSON = $env:TARGETS_JSON.Replace($publicKey, 'PRIVATE-SENTINEL') }
  if ($scenario -eq 'bad-source') { $env:SOURCE_COMMIT = 'b' * 40 }
  if ($scenario -eq 'invalid-json') { $env:TARGETS_JSON = 'PRIVATE-SENTINEL' }
  if ($scenario -eq 'tampered-hash') { [IO.File]::WriteAllText((Join-Path $artifact 'dotnet.zip'), 'tampered') }
  $accepted = $true
  $message = ''
  $output = [Collections.Generic.List[object]]::new()
  try { & $preflight 3>&1 4>&1 5>&1 6>&1 | ForEach-Object { $output.Add($_) } } catch { $accepted = $false; $message = $_.Exception.Message }
  if ($accepted -ne ($scenario -in @('valid-v1', 'valid-v2'))) { throw "Preflight result mismatch: $scenario" }
  if (-not $accepted -and $message -cne 'Deployment preflight failed. Check protected identity values, target configuration, and artifact provenance. Sensitive details suppressed.') {
    throw 'Preflight failure was not sanitized.'
  }
  if (($output -join '') -match 'PRIVATE-SENTINEL') { throw 'Private data reached output.' }
  $targetFile = Join-Path $env:AGENT_TEMPDIRECTORY ('cyot-verified-targets-' + $env:BUILD_BUILDID + '.json')
  if ($accepted -and @((Get-Content $targetFile -Raw | ConvertFrom-Json)).Count -ne 3) { throw 'Verified target count mismatch.' }
  & $cleanup
  if (Test-Path $targetFile) { throw 'Target metadata retained.' }
}
""", json.dumps({"preflight": self.scripts[1], "cleanup": self.scripts[3]}),
                {"TEST_DIRECTORY": temporary})

    def test_token_acquisition_diagnostics_are_not_logged(self):
        token_line = next(line.strip() for line in self.scripts[2].splitlines()
                          if "$token = Get-AzAccessToken" in line)
        self.powershell(r"""
$ErrorActionPreference = 'Stop'
$acquire = [scriptblock]::Create([Console]::In.ReadToEnd())
$target = @{ audience='api://unit-test' }
function Get-AzAccessToken {
  [CmdletBinding()]
  param([string]$ResourceUrl)
  Write-Warning 'PRIVATE-TOKEN-MARKER'
  Write-Verbose 'PRIVATE-TOKEN-MARKER' -Verbose
  Write-Debug 'PRIVATE-TOKEN-MARKER' -Debug
  Write-Information 'PRIVATE-TOKEN-MARKER' -InformationAction Continue
  if ($script:failAcquisition) { throw 'PRIVATE-TOKEN-MARKER' }
  [pscustomobject]@{ Token='PRIVATE-TOKEN-MARKER' }
}
foreach ($script:failAcquisition in @($false, $true)) {
  $output = [Collections.Generic.List[object]]::new()
  $failed = $false
  try { & $acquire 3>&1 4>&1 5>&1 6>&1 | ForEach-Object { $output.Add($_) } }
  catch { $failed = $true }
  if ($failed -ne $script:failAcquisition) { throw 'Acquisition result changed.' }
  if (($output -join '') -match 'PRIVATE-TOKEN-MARKER') { throw 'Token diagnostics reached output.' }
}
""", token_line)

    def test_encrypted_evaluation_helpers(self):
        helpers = "function Base64Url" + self.scripts[2].split(
            "function Base64Url", 1)[1].split("$handler =", 1)[0]
        self.powershell(r"""
$ErrorActionPreference = 'Stop'
. ([scriptblock]::Create([Console]::In.ReadToEnd()))
$rsa = [Security.Cryptography.RSA]::Create(2048)
try {
  $context = @{ nonce='unit-nonce'; phoneNumber='+15555550123'; message='Synthetic evaluation 123456' }
  $jwe = Encrypt-Context $context $rsa
  $parts = $jwe.Split('.')
  if ($parts.Count -ne 5) { throw 'JWE segment count mismatch.' }
  $header = [Text.Encoding]::UTF8.GetString((Decode64 $parts[0])) | ConvertFrom-Json
  if ($header.alg -ne 'RSA-OAEP-256' -or $header.enc -ne 'A256GCM') { throw 'JWE algorithm mismatch.' }
  $key = $rsa.Decrypt((Decode64 $parts[1]), [Security.Cryptography.RSAEncryptionPadding]::OaepSHA256)
  $aes = [Security.Cryptography.AesGcm]::new($key, 16)
  try {
    $cipher = Decode64 $parts[3]
    $plain = [byte[]]::new($cipher.Length)
    $aes.Decrypt((Decode64 $parts[2]), $cipher, (Decode64 $parts[4]), $plain, [Text.Encoding]::ASCII.GetBytes($parts[0]))
    $decoded = [Text.Encoding]::UTF8.GetString($plain) | ConvertFrom-Json
    if ($decoded.nonce -cne $context.nonce -or $decoded.message -cne $context.message) { throw 'JWE round-trip failed.' }
    foreach ($channel in @(1, 2)) {
      $envelope = Envelope $jwe 'unit-correlation' $channel | ConvertFrom-Json
      if ($envelope.mode -ne 2 -or $envelope.channel -ne $channel -or $envelope.encryptedDeliveryContext -cne $jwe) { throw 'Evaluation envelope mismatch.' }
    }
  } finally { $aes.Dispose(); [Array]::Clear($key, 0, $key.Length) }
} finally { $rsa.Dispose() }
""", helpers)


if __name__ == "__main__":
    unittest.main()