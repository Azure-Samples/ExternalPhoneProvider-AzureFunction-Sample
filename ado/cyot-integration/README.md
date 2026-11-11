# CYOT GitHub merge and SAS integration pipeline

This folder contains a separate Azure DevOps pipeline for cross-repository CYOT validation. It does
not replace or share a YAML entry point with the Phase 1 deployment pipeline proposed in
[GitHub PR #90](https://github.com/Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample/pull/90).
Keeping the entry point, template, and contract script here prevents the two pipeline definitions
from being confused during Azure DevOps registration.

## Pipeline entry point

Register this path in Azure DevOps:

`/ado/cyot-integration/azure-pipelines.yml`

The pipeline does not deploy Azure resources or change CYOT policy. It validates the integration
contract, runs all three runtime test suites, compiles and tests Bicep, builds all runtime ZIPs, and
publishes immutable packages with sample and SAS commit provenance.

## Trigger behavior

The pipeline starts for either source:

1. **Reviewed GitHub PR merged into `main`**
   - The self-repository CI trigger watches `main` and CYOT-relevant sample paths.
   - `pr: none` prevents this Azure Pipeline from running for unmerged GitHub PR heads.
   - GitHub branch protection must prohibit direct pushes to `main`; Azure Pipelines cannot
     distinguish a reviewed merge from an unprotected direct push after both become a `main` push.
2. **SAS `main` changes**
   - The `sas` Azure Repos resource watches `One/AAD-MFA-StrongAuthenticationService` on `main`.
   - Azure repository resource triggers do not support path filters, so every SAS `main` update
     intentionally runs the integration contract and sample suites.

## Azure DevOps setup

1. Create a pipeline backed by the GitHub sample repository.
2. Select **Existing Azure Pipelines YAML file** and enter
   `/ado/cyot-integration/azure-pipelines.yml`.
3. Authorize the GitHub service connection to read the sample repository.
4. Grant the pipeline build identity read access to the Azure Repos repository
   `One/AAD-MFA-StrongAuthenticationService`.
5. Authorize the `sas` repository resource when Azure DevOps requests permission on the first run.
6. Keep GitHub `main` protected with required PR approval and required checks.
7. Do not grant an Azure Resource Manager service connection. This pipeline performs no deployment.

The pipeline assumes it is registered in the `msazure/One` Azure DevOps project. If it is registered
in a different project, update the repository resource name and grant explicit cross-project read
permission.

## Contract gates

[Test-CyotContract.ps1](Test-CyotContract.ps1) fails the build if SAS and the sample disagree on:

- Envelope type `microsoft.mfa.otpDeliver.v1`
- Cleartext envelope field names
- SMS and voice numeric channel values
- Live and evaluation numeric mode values
- Correlation header names
- SAS CYOT first-party caller application ID shape
- JavaScript, .NET, and Python envelope parsing
- Shared invalid-version and invalid-mode fixtures

The evidence artifact records both Git commits and the current value of
`Logic.Cyot.OneP.ApplicationId`. That identifier is integrity-sensitive but is not a credential.

## Outputs

| Artifact | Contents |
| --- | --- |
| `cyot-contract` | Cross-repository contract evidence and exact sample/SAS commits |
| `cyot-runtime-packages` | JavaScript, .NET, and Python deployment ZIPs plus SHA-256 manifest |

Deployment, policy activation, authenticated evaluation, and rollback remain separate approved
operations. A successful package pipeline does not prove endpoint readiness or recipient delivery.
