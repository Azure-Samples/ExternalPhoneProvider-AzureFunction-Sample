# CYOT pipeline onboarding

[deploy-cyot-e2e.yml](deploy-cyot-e2e.yml) builds and tests all three Function runtimes,
with a separate manual, approved deployment and encrypted HTTP evaluation stage.
No environment-specific tenant, subscription or caller application IDs are included in
these pipeline files. Offline tests use explicitly synthetic identifiers.

## Trigger after PR merge

In your Azure DevOps project, create a pipeline with **GitHub** as its source, select
`Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample`, and choose the existing YAML
file `/pipelines/deploy-cyot-e2e.yml`. Keep its default branch on `main` and authorize the
Azure Pipelines GitHub integration for this repository. This file is an Azure Pipelines
definition, not a GitHub Actions workflow. It extends 1ES Pipeline Templates and requires
an authorized 1ES template connection and agent pool; it is not standalone hosted-agent YAML.

The explicit CI trigger runs on updates to this repository's `main`, including completed
PR merges. Direct pushes also trigger CI if GitHub branch protection permits them: require
reviewed PRs and restrict direct pushes on GitHub. With batching enabled, merges arriving
while a run is active can be combined into the next run. `pr: none` disables this pipeline's
GitHub PR-validation trigger; existing GitHub Actions validation remains unchanged.

These are updates to the EPP GitHub repository, not merges in an internal mirror. CI uses
Azure Pipelines' `Build.SourceVersion` to fetch the exact triggering commit from the fixed
public repository and verifies the fetched SHA. It never resolves a later moving `main`.
The default `sourceCommit: triggeringCommit` verifies the GitHub provider and repository
name; it is rejected when this YAML is instead registered against an Azure Repos mirror.
An automatic CI run cannot override that commit or enable deployment.

**Before enabling automatic runs**, replace the `REQUIRED` defaults for `templateConnection`,
`poolName`, and `poolImage` with approved nonsecret values and authorize those resources.
CI cannot answer parameter prompts or use an unconfigured pool/template connection.
Do not enable a UI trigger override that disables the YAML trigger.

Automatic runs are build-only: `deployAndTest` defaults to `false`, and the Azure stage
is omitted along with its protected variable group. A deployment requires a manual run
from reviewed GitHub `main`, `deployAndTest: true`, and a full lowercase 40-character
`sourceCommit`. The `triggeringCommit` shortcut is rejected for deployment. Approval and
an exclusive-lock check must exist on the selected ADO Environment; YAML does not create them.

## Build inputs

| Parameter | Value |
| --- | --- |
| `sourceCommit` | `triggeringCommit` for build-only, or an explicit reviewed full SHA for manual runs |
| `templateConnection` | Approved read-only connection to `1ESPipelineTemplates/1ESPipelineTemplates` |
| `poolName` | Approved clean Linux x64 1ES pool |
| `poolImage` | Approved image with PowerShell 7.4+, Git, Python 3.11 tool cache, and an Az installation supported by AzurePowerShell@5 |
| `deployAndTest` | Leave `false` for CI; explicit manual opt-in for Azure work |

The build uses .NET 8, Node.js 22, and Python 3.11. It executes nonempty unit suites,
rejects failures/skips, and packages all three implementations from the same SHA.
Python dependencies are packaged as Linux x64 wheels. The artifact contains only
`dotnet.zip`, `javascript.zip`, `python.zip`, and `source.json` with source/build/hash provenance.
Dependency restores and tests execute public source: use reviewed source and isolated,
unprivileged agents without deployment identities, extra secrets, or cached credentials.

## Minimal protected variable group

Create `cyot-e2e-config` in ADO Library. Enter values directly there and select the lock
icon for each. Follow your organization's protected-resource guidance and authorize
only the intended pipeline; do not grant open access or unreviewed queue-time overrides.

| Variable | Value |
| --- | --- |
| `CyotTenantId` | Approved test tenant ID |
| `CyotSubscriptionId` | Approved test subscription ID |
| `CyotCallerClientId` | Application client ID used by the separate test-caller connection |

The group is referenced only in the opt-in deployment stage. These are identifiers,
not credentials, but secret marking masks exact log matches. Missing/invalid/zero IDs
fail preflight with a fixed error. Expected IDs remain independent of the current
connection, so wrong-tenant/subscription/caller checks are not removed.

Do not substitute a user object ID, the Function's endpoint application ID, Microsoft's
SAS first-party application, or the provider's outbound identity for the test caller.
This PR does not create the caller, variable group, service connections, or permissions.

## Deployment inputs

| Parameter | Value |
| --- | --- |
| `deploymentConnection` | Existing federated ARM deployment connection scoped to the isolated test apps, plus required plan/configuration reads |
| `callerConnection` | Separate federated ARM connection for the test caller, authorized to obtain tokens for all three API audiences |
| `environmentName` | Existing ADO Environment with approvals, restricted access and exclusive lock |
| `resourceGroup` | Existing resource group containing all three test Function Apps |
| `targets` | Exactly three distinct existing apps, one each for `dotnet`, `javascript`, and `python` |

Each target requires `language`, `appName`, `appType`, `audience`, and `publicKeyBase64`.
Only nonsecret metadata belongs in these parameter fields. `appType` is `functionApp`
for Windows or `functionAppLinux` for Linux; Python must be Linux. An audience is the
API token resource accepted by Easy Auth, not an arbitrary guessed hostname.

`publicKeyBase64` encodes the UTF-8 public SubjectPublicKeyInfo PEM beginning with
`-----BEGIN PUBLIC KEY-----`, RSA 2048 bits or greater. It must match that app's privately
provisioned decryption key. Public keys are not credentials; base64 is not encryption.

Existing apps must use Functions v4 and the matching .NET 8 isolated, Node 22, or Python
3.11 stack. Linux requires Premium/Dedicated; this ZIP path rejects Flex and Linux
Consumption. Remote build must be off. All apps must be provider-free: `EPP_PROVIDER_NAME`
absent/empty, with a test-only `EPP_DECRYPTION_KEY_PEM` already configured securely,
preferably through a Key Vault reference. Do not point this pipeline at live-provider apps.

Require HTTPS and Easy Auth with no excluded paths, the exact approved v1 or v2 tenant
issuer, the intended audience, and the test caller in `allowedApplications`. Configure
required app-role assignments/consent separately. The caller connection must obtain
tokens for the app audiences, not merely ARM. AzurePowerShell initialization can also
require minimal ARM access; do not grant deployment rights to solve that implicitly.
Using different connection names alone does not prove their underlying identities differ;
verify their identities and permissions during onboarding.

## Validation and privacy

Preflight checks all targets and ZIP hashes before the first deployment. After deployment,
the caller performs 27 HTTP checks: nine per app covering authenticated SMS/voice evaluation,
missing/invalid tokens, tampered JWE, incomplete context, unsupported type, invalid channel,
and malformed JSON. All requests are direct Function tests; valid envelopes use `mode: 2`.
This is not a SAS-driven authentication flow and does not send through a telephony provider.

Responses must have the expected HTTP/error or exact nonce/correlation values. The readiness
loop retries only evaluation requests. It does not retry deployments or live sends.
JUnit output records check names, statuses and fixed diagnostic descriptions, not tokens,
nonces, messages, raw provider bodies or exception details.

Deployment preflight catches errors without printing raw ARM responses/app settings.
ARM and token-acquisition calls suppress warning, verbose, debug and information streams
as well as using fixed failure messages. Regression tests collect output incrementally,
including output emitted before exceptions; catching exceptions alone is not sufficient.
Verified host/audience/public-key metadata stays in an agent temporary file, is never
published as an artifact, and is removed by an always-run cleanup step. Forced agent loss
can prevent cleanup; use ephemeral agents and restrict log/artifact/agent access. Both jobs
request clean workspaces. Standard deployment tasks may still show resource names and
URLs, which must not contain secrets; masking is not a guarantee against all disclosure.
Keep debug/body tracing off, and do not add credentials to parameters, task display names,
output variables, test attachments, package files, or this guide.

Provider credentials/private keys belong in Key Vault and the Function's managed-identity
access path, not in the pipeline variable group. The pipeline performs app-setting readback
for preflight and must therefore use only isolated test apps. Restrict who may edit pipeline
code or use its protected resources: an authorized malicious task can expose available secrets.

## Offline checks

With Python 3.11+ and PowerShell 7.4+ available:

```powershell
python -m pip install PyYAML
python -m unittest discover -s pipelines/tests -p test_deploy_pipeline.py -v
```

These checks parse YAML/PowerShell, validate trigger and secret boundaries, exercise source
selection, run the actual preflight against mocked ARM responses (including privacy markers),
test token-acquisition diagnostic suppression on success and failure, and verify the
RSA/AES-GCM evaluation helpers without cloud access. The seven offline tests do not inspect
real variable-group values or certify Azure task initialization and third-party task logs.

The PR history and current files were checked for environment-specific identifiers,
invitation links, literal private keys, JWTs and common token/connection-string patterns.
This is a scoped code/content audit, not a guarantee that arbitrary future source packages,
task versions, debug settings or user-supplied parameters cannot expose information.

1ES template expansion, resource permissions, the full Linux build/package job, and live
Azure deployment still require validation in the configured ADO project. This PR does not
register/run the pipeline or grant authorization. Failed deployment/testing can leave apps
partially updated; retain approved packages and use a reviewed rollback procedure. No automatic
rollback, resource deletion, auto-merge, or branch-policy bypass is included.