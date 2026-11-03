# CYOT Azure DevOps pipeline

[azure-pipelines-cyot.yml](azure-pipelines-cyot.yml) validates and packages all three CYOT runtimes.
A manual, approved run can deploy the packages to three existing development Function Apps.
SAS Synthetics owns authenticated encrypted evaluation monitoring after deployment.

## Configure the pipeline

1. Create an Azure Pipeline from this GitHub repository and select
   `/pipelines/azure-pipelines-cyot.yml`.
2. Authorize the pipeline's GitHub connection for this repository.
3. Create or select an Azure DevOps environment named `cyote2e-test`.
4. Add approval, branch control for `refs/heads/main`, and an exclusive lock to that environment.
5. Create the Azure Resource Manager service connection `cyote2e-deployment` with workload identity
   federation backed by a dedicated user-assigned managed identity. Scope that identity to the
   development resource group when possible. Authorize only this pipeline.
6. Configure the `ExternalPhoneProvider-e2e-config` variable group described below and authorize
   only this pipeline. Restrict queue-time variable creation and overrides in the ADO project.
7. Queue a build-only run first. Then queue a manual run with `deployDevelopment: true` and provide
   the three existing Function App names.

Automatic and pull-request runs validate and package only. Deployment requires a manual run from
`main`, the `deployDevelopment` opt-in, and environment approval.

## Identities used

| Operation | Identity | Access |
| --- | --- | --- |
| Build and unit tests | No Azure identity | Source and package feeds only |
| Azure preflight and Function deployment | Dedicated user-assigned managed identity through the `cyote2e-deployment` workload-identity service connection | Read the development resource group, plans, Function Apps, and auth configuration; deploy packages to the three Function Apps |
| Anonymous deployment smoke check | No endpoint identity | Calls each endpoint without a token and requires HTTP `401` |
| Authenticated encrypted evaluation | Existing SAS Synthetics caller | Requests the CYOT endpoint audience and sends `mode: 2`; no Azure management access |
| Function runtime | Function system-assigned and outbound user-assigned managed identities | Storage, Key Vault, telemetry, and provider OAuth as configured by setup |

The Azure Pipelines agent does not receive a reusable managed-identity credential or client secret.
Azure DevOps exchanges its short-lived job token for the dedicated deployment managed identity by
workload identity federation. `AzureFunctionApp@2` and the Azure CLI preflight use that service
connection. Do not reuse the Function runtime identity or the SAS Synthetics caller for deployment.

## Review of the shown variable group

The identifiers shown are the right kinds of values, but the group needs these changes before use:

| Current item | Action |
| --- | --- |
| `CyotCallerClientId` | The value has the right format, but it was not found or was not readable in the current tenant context. Verify that it is the application client ID used by the approved SAS Synthetics caller and that it appears in each endpoint's Easy Auth `allowedApplications`. |
| `CyotSubscriptionId` | The subscription is enabled and its tenant matches `CyotTenantId`, but it does not contain the configured resource group. Confirm that this is the intended development subscription. |
| `CyotTenantId` | The tenant matches the configured subscription. Also confirm that the deployment service connection and endpoint issuer use it. |
| `resourceGroup` | Keep after verification. The value in the screenshot was not found through the current Azure context, so check the spelling, subscription, tenant, and whether the group has been created. |
| `environmentName` | Remove from the group or set it. It is blank in the screenshot. The YAML uses the protected environment parameter `cyote2e-test` instead. |
| `deploymentConnection` | Remove from the group. Service connections are protected Azure DevOps resources and should be selected by the YAML parameter, not a runtime variable. |
| `callerConnection` | Remove from the group for this pipeline. SAS Synthetics owns the caller identity and encrypted evaluation. The deployment pipeline does not acquire SAS caller tokens. |
| Group name and description | Prefer `cyot-e2e-config` and a CYOT description. The supplied YAML defaults to the existing `ExternalPhoneProvider-e2e-config` name so it works before a rename. |

The variable group only needs:

| Variable | Purpose |
| --- | --- |
| `CyotTenantId` | Expected development tenant ID |
| `CyotSubscriptionId` | Expected development subscription ID |
| `CyotCallerClientId` | Approved SAS Synthetics caller application client ID |
| `resourceGroup` | Existing resource group containing the three development Function Apps |

These are integrity-sensitive identifiers rather than credentials. Nonsecret variables do not gain
secret-variable protection merely by being in a variable group. Authorize only this pipeline,
restrict queue-time overrides, scope the service connection independently, and do not print the
values. Key Vault linking is not required for these four values.

## Queue-time parameters

| Parameter | Default | Use |
| --- | --- | --- |
| `deployDevelopment` | `false` | Set to `true` only for an approved manual deployment. |
| `targets` | Three `REQUIRED` inventories | Supply one distinct JavaScript, C#, and Python app with its endpoint application ID, exact audience, Azure region (for example `westus2`), and reviewed `FC1` or `EP1` plan. |

The service connection, environment, and variable-group names are fixed in YAML so a queue-time
parameter cannot substitute a less-protected resource. Any rename requires a reviewed YAML change.

All three target apps must be Linux Function Apps created by the guided setup. Preflight compares
their setup tags, language runtime, endpoint application ID, audience, hosting-plan SKU, and full
Easy Auth trust policy with the reviewed target inventory. The pipeline does not create applications,
certificates, Easy Auth, role assignments, or Function Apps. Complete that privileged bootstrap
separately.

## SAS Synthetics handoff

After deployment, update the existing SAS Synthetics configuration in
`AD-MFA-StrongAuthenticationServices`. Do not copy the synthetic harness into this repository.
For each runtime, provide the reviewed CYOT endpoint URL ending in `/api/SendOtp`, endpoint audience,
matching public encryption certificate/key, and safe runtime/region labels.

SAS Synthetics should reuse its existing caller, authentication flow, encrypted `mode: 2` request,
response validation, schedule, and alert routing. It must never use live mode or a real recipient.

## What the pipeline verifies

- Current .NET 10, Node.js 22, and Python 3.11 tests pass. Node.js 20 is retained only as a source
   compatibility check; deployed JavaScript apps must use Node.js 22.
- Setup tests pass on Windows and Linux, and Bicep compilation passes.
- The three packages are built once and published with a release manifest and SHA-256 digests.
- Existing archive validation, required-entry checks, prohibited-file checks, and packaged Python
   imports pass before publication.
- The service connection tenant and subscription match the configured variable group.
- The resource group and exact three Linux Function Apps exist, require HTTPS, and match their setup
   tags, language runtimes, application IDs, and FC1 or EP1 plan.
- Easy Auth requires HTTPS and authentication and has the exact expected client ID, issuer,
   audience, and SAS Synthetics caller allowlist.
- The downloaded package digests match the build manifest before deployment.
- Deployed endpoints reject an anonymous request with HTTP `401`.

An authenticated encrypted evaluation is intentionally left to SAS Synthetics. Until its
deployment-correlated evaluation succeeds, the pipeline proves package deployment and the anonymous
authentication boundary, not application readiness.

## Phase 1 limits

This first pipeline does not yet generate an SBOM, sign provenance, run organization-specific
security scanners, deploy infrastructure, run Bicep what-if, or block on SAS Synthetics. Add those
controls through the approved governed template and SAS integration before treating the full plan
as complete. GitHub checks on the pull request do not validate Azure Pipelines template expansion,
protected-resource authorization, or a real FC1/EP1 deployment.
