# CYOT Azure DevOps pipeline

[azure-pipelines-cyot.yml](azure-pipelines-cyot.yml) validates and packages all three CYOT runtimes.
A manual, approved run deploys one selected package to its existing development Function App.
SAS Synthetics owns authenticated encrypted evaluation monitoring after deployment.

Use [e2e-config.sample.json](e2e-config.sample.json) as the placeholder schema for tenant,
subscription, caller, planned resource group, and target inventory. Keep real environment IDs in
the restricted Azure DevOps variable group or queue-time inventory, not this public repository.
The sample remains fail-closed with `ready: false` and `REQUIRED` values.

[provision-e2e.ps1](provision-e2e.ps1) is the idempotent Azure bootstrap for the shared resource
group and deployment managed identity. It validates the active tenant/subscription before mutation
and supports PowerShell `-WhatIf`. It does not create endpoint app registrations or Function Apps.

## Configure the pipeline

1. Create an Azure Pipeline from this GitHub repository and select
   `/pipelines/azure-pipelines-cyot.yml`.
2. Authorize the pipeline's GitHub connection for this repository.
3. Create or select an Azure DevOps environment named `cyote2e-test`.
4. Add approval, branch control for `refs/heads/main`, and an exclusive lock to that environment.
5. Create the Azure Resource Manager service connection `cyote2e-deployment-v2` with workload identity
   federation backed by a dedicated user-assigned managed identity. Scope that identity to the
   development resource group when possible. Authorize only this pipeline. On the service
   connection itself, add branch control for `refs/heads/main` and approval. Add a required-template
   check only after this pipeline has been migrated to the approved governed template. Environment
   checks alone do not prevent modified YAML from referencing the service connection from another stage.
6. Configure the `ExternalPhoneProvider-e2e-config` variable group described below and authorize
   only this pipeline. Restrict queue-time variable creation and overrides in the ADO project.
7. Queue a build-only run first. Then queue a manual run with `deployDevelopment: true`, choose one
   `deploymentLanguage`, and provide the reviewed inventory for all three existing Function Apps.

Automatic and pull-request runs validate and package only. Deployment requires a manual run from
`main`, the `deployDevelopment` opt-in, and environment approval.

## Identities used

| Operation | Identity | Access |
| --- | --- | --- |
| Build and unit tests | No Azure identity | Source and package feeds only |
| Azure preflight and Function deployment | Dedicated user-assigned managed identity through the `cyote2e-deployment-v2` workload-identity service connection | Read the development resource group, plans, Function Apps, and auth configuration; deploy the selected package to its Function App |
| Anonymous deployment smoke check | No endpoint identity | Calls the selected endpoint without a token and requires HTTP `401` |
| Authenticated encrypted evaluation | SAS Synthetics invokes SAS through the approved CYOT first-party caller | SAS requests the CYOT endpoint audience and sends `mode: 2`; no Azure management access |
| Function runtime | Function system-assigned and outbound user-assigned managed identities | Storage, Key Vault, telemetry, and provider OAuth as configured by setup |

The Azure Pipelines agent does not receive a reusable managed-identity credential or client secret.
Azure DevOps exchanges its short-lived job token for the dedicated deployment managed identity by
workload identity federation. The Azure CLI preflight and deployment use that service connection.
The Phase 1 deployment uses One Deploy, then synchronizes triggers and verifies
that the expected CYOT function registered (`SendOtp` for JavaScript/.NET or `send_otp` for Python).
Do not reuse the Function runtime identity or the SAS CYOT first-party endpoint caller for deployment.

Reader alone is insufficient. Grant a reviewed resource-group custom role or equivalent built-in
roles that include the required `Microsoft.Web/sites` read, configuration read, deployment,
restart/sync-trigger, and function-list actions, plus read access to the hosting plans. Do not grant
Owner, User Access Administrator, role-assignment write, Microsoft Graph, or Key Vault secret-value
access. Keep the scope on the development resource group or the three Function Apps.

## Variable group

The fixed `ExternalPhoneProvider-e2e-config` variable group needs only:

| Variable | Purpose |
| --- | --- |
| `CyotTenantId` | Expected development tenant ID |
| `CyotSubscriptionId` | Expected development subscription ID |
| `CyotCallerClientId` | Approved SAS CYOT first-party application client ID from the private service configuration. This is not the deployment identity or a separate pipeline test caller. Mark it secret to prevent accidental display even though an application ID is not an authentication credential. |
| `CyotE2EReady` | Keep `false` until the E2E subscription, resource group, all three target inventories, service connection, and approvals are verified. Change to `true` only as the final enablement step. |

These are integrity-sensitive identifiers rather than credentials. Mark `CyotCallerClientId`,
`CyotTenantId`, and `CyotSubscriptionId` secret to reduce accidental disclosure in Azure DevOps logs
and UI. Secret masking does not make an application ID an authentication secret and does not prevent
impersonation by itself. Authorize only this pipeline, restrict queue-time overrides, scope the
service connection independently, and do not print the values. Key Vault linking is not required.

Do not add service-connection or environment names to this group. Those protected resources are
fixed literal references in YAML and carry their own approvals and checks.

Deployment is deliberately fail-closed while `CyotE2EReady` is missing or not exactly `true`.
Build and package validation still run. This prevents a manual queue from targeting the currently
unverified subscription/resource-group values.

## Queue-time parameters

| Parameter | Default | Use |
| --- | --- | --- |
| `deployDevelopment` | `false` | Set to `true` only for an approved manual deployment. |
| `deploymentLanguage` | `javascript` | Select exactly one runtime to deploy in the approved run. Deploy the other runtimes in separate approved runs. |
| `targets` | Three `REQUIRED` inventories | Supply one distinct JavaScript, C#, and Python app with its resource group, endpoint application ID, exact audience, Azure region (for example `eastus`), and reviewed `FC1` plan. |

The service connection, environment, and variable-group names are fixed in YAML so a queue-time
parameter cannot substitute a less-protected resource. Any rename requires a reviewed YAML change.
The service connection must still carry its own approvals and checks because pipeline YAML is mutable.

All three target apps must be Linux Function Apps created by the guided setup. Preflight compares
their setup tags, language runtime, endpoint application ID, audience, hosting-plan SKU, and the
Easy Auth security-critical policy subset with the reviewed target inventory.

Phase 1 deployment supports FC1 only. EP1 guided setup uses a managed-identity private-blob
`WEBSITE_RUN_FROM_PACKAGE` model. A standard task deployment would change that publication model, so EP1
must be added later with an explicit, tested package-upload and rollback design rather than silently
using the task default.

The pipeline does not create applications, certificates, Easy Auth, role assignments, or Function
Apps. Complete that privileged bootstrap separately.

Only one runtime is deployed per approved run. This prevents a failed second or third deployment
from silently leaving a mixed three-runtime release under one pipeline result. Promote JavaScript,
C#, and Python independently and retain the prior package/deployment record for manual rollback.

## SAS Synthetics handoff

After deployment, update the approved external SAS Synthetics configuration. Do not copy the
synthetic harness into this public sample. For each runtime, provide the reviewed CYOT endpoint URL
ending in `/api/SendOtp`, endpoint audience, matching public encryption certificate/key, and safe
runtime/region labels.

SAS Synthetics should reuse the existing synthetic flow, encrypted `mode: 2` request, response
validation, schedule, and alert routing. The endpoint call itself is authenticated as the approved
SAS CYOT first-party application from the private service configuration. Easy Auth must allow that
application. It must never use live mode or a real recipient.

## What the pipeline verifies

- Current .NET 10, Node.js 22, and Python 3.11 tests pass. Node.js 20 is retained only as a source
   compatibility check; deployed JavaScript apps must use Node.js 22.
- Setup tests pass on Windows and Linux, and Bicep compilation passes.
- The three packages are built once and published with a release manifest and SHA-256 digests.
- Existing archive validation, required-entry checks, prohibited-file checks, and packaged Python
   imports pass before publication.
- The service connection tenant and subscription match the configured variable group.
- The resource group and exact three Linux Function Apps exist, require HTTPS, and match their setup
   tags, language runtimes, application IDs, and FC1 plan.
- Easy Auth requires HTTPS and authentication and has the exact expected client ID, issuer,
   audience, and SAS CYOT first-party caller allowlist.
- The downloaded package digests match the build manifest before deployment.
- The selected deployment synchronizes triggers, registers exactly one runtime-specific CYOT
   function, and rejects an anonymous request with HTTP `401`.

An authenticated encrypted evaluation is intentionally left to SAS Synthetics. Until its
deployment-correlated evaluation succeeds, the pipeline proves package deployment and the anonymous
authentication boundary, not application readiness.

## Phase 1 limits

This first pipeline does not yet generate an SBOM, sign provenance, run organization-specific
security scanners, deploy infrastructure, run Bicep what-if, support EP1 package deployment, or
block on SAS Synthetics. Add those controls through the approved governed template and SAS
integration before treating the full plan as complete. GitHub checks on the pull request do not
validate Azure Pipelines template expansion, protected-resource authorization, or a real FC1
deployment.
