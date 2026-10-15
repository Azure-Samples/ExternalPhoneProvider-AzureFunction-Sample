# External Phone Provider Azure Function Sample

Use this sample to connect Microsoft Entra ID to a phone provider for SMS and voice one-time
passwords. Guided setup deploys **one endpoint in one Azure region** and publishes the selected
JavaScript, C#, or Python package.

**Start in a separate nonproduction environment.** This keeps testing away from live resources
while supporting evaluation, implementation planning, and production preparation. Review
[requirements](#requirements) before deployment.

## Table of Contents

- [Features](#features)
- [Requirements](#requirements)
- [Architecture](#architecture)
- [Get started](#get-started)
- [Guidance](#guidance)
  - [Deploy and configure](#deploy-and-configure)
  - [Operate](#operate)
  - [Develop](#develop)
  - [Advanced topics](#advanced-topics)
- [Getting help](#getting-help)

## Features

- One Azure Function endpoint that accepts Microsoft Entra ID SMS and voice requests and calls the configured provider.
- JavaScript, C#, and Python implementations of the same [HTTP and trust contract](docs/CONTRACT.md).
- Guided setup for Azure resources, package verification, publication, and Easy Auth configuration.
- Evaluation requests that authenticate and decrypt without sending a message to the provider.
- Monitoring guidance for Function requests, runtime events, Microsoft Entra ID sign-ins, and telemetry collection.
- A provider-neutral [bring-your-own-telephony integration path](docs/BRING-YOUR-OWN-PROVIDER.md).

## Requirements

Before deploying:

- Confirm [supported provider access and Microsoft's approved testing and activation procedure](docs/GETTING-STARTED.md#1-get-ready).
  These define the supported path for setup, validation, and activation.
- Prepare a separate test environment with a nonproduction tenant and subscription, a new
  application registration, and a unique resource prefix.
- Check the required [administrator roles, Azure permissions, tools, regional availability, and quota](setup/docs/README.md#prerequisites-for-step-2).
- Plan for Azure resource, telemetry, and provider charges. Use the [provider cost estimate](docs/COST-CALCULATOR.md) as planning input, not a billing report.
- Keep Easy Auth enabled from deployment through live operation so every request is checked
  against the approved Microsoft caller.

## Architecture

![Microsoft Entra ID sends an encrypted request through Easy Auth to a Function, which uses Key Vault and calls the phone provider](docs/images/single-region-architecture.png)

*Easy Auth checks the Microsoft caller, and the Function decrypts the request.
For live requests, success confirms provider acceptance; confirm delivery separately. Evaluation
sends nothing. Region, credentials, caching, and telemetry are illustrative: see
[architecture details](TECHNICAL.md#single-region-architecture).
[Open the full-size diagram](docs/images/single-region-architecture.png).*

## Get started

Follow the **[five-step setup guide](docs/GETTING-STARTED.md)** in order:

1. <a id="1-get-ready"></a>[Get ready](docs/GETTING-STARTED.md#1-get-ready): confirm access, approvals, permissions, tools, and budget.
2. <a id="2-register-your-application"></a>[Register your application](docs/GETTING-STARTED.md#2-register-your-application): save the tenant and application client IDs.
3. <a id="3-run-guided-setup"></a>[Run guided setup](docs/GETTING-STARTED.md#3-run-guided-setup): choose a provider and runtime, then review the deployment plan before approving.
4. <a id="4-connect-your-provider-and-test"></a>[Connect and test](docs/GETTING-STARTED.md#4-connect-your-provider-and-test): configure provider authentication, then complete approved evaluation and live checks for each intended channel.
5. <a id="5-activate-and-hand-over"></a>[Activate and hand over](docs/GETTING-STARTED.md#5-activate-and-hand-over): have the policy administrator activate only after validation; assign monitoring, renewal, and rollback owners.

After validation, your policy administrator can activate the endpoint through the approved
procedure. Review the [production-readiness considerations](docs/CONTRACT.md#production-limitations)
as you plan the live service.

<a id="find-more-detail"></a>
## Guidance

### Deploy and configure

- [Five-step setup](docs/GETTING-STARTED.md) for a first deployment.
- [Customer configuration and validation](docs/ONBOARDING.md) for IDs, provider authentication, testing, and activation.
- [Setup reference](setup/docs/README.md) for permissions, hosting plans, certificate choices, unattended use, renewal, and rollback.
- [Troubleshooting](setup/docs/Troubleshooting.md) for symptom-led checks and safe recovery.

### Operate

- [Function monitoring and alerts](docs/MONITORING.md)
- [Application Insights collection diagnostics](docs/APPLICATION-INSIGHTS.md)
- [Microsoft Entra ID sign-in monitoring](docs/SIGN-IN-MONITORING.md)
- [Certificate renewal](setup/docs/README.md#encryption-certificate-lifecycle) and [rollback](setup/docs/README.md#rollback-and-decommissioning)
- [SMS and voice cost estimation](docs/COST-CALCULATOR.md)

### Develop

- Runtime guides: [JavaScript](javascript/README.md), [C#](dotnet/README.md), and [Python](python/README.md)
- [Architecture, settings, and packages](TECHNICAL.md)
- [HTTP, status, configuration, and runtime contract](docs/CONTRACT.md)
- [Application log events and safe fields](docs/LOGGING.md)
- [Provider-neutral BYOT integration](docs/BRING-YOUR-OWN-PROVIDER.md)

<a id="optional-designs"></a>
### Advanced topics

- [Multi-region routing with Azure Front Door](docs/FRONTDOOR.md)
- [Conservative primary-to-secondary provider fallback](docs/MULTI-PROVIDER-IMPLEMENTATION.md)

Use these guides after validating the single-region endpoint. They cover regional routing,
provider fallback, capacity, validation, operations, and rollback.

## Getting help

- For provider access, approved testing, or activation, use the
  [provider and Microsoft support route](docs/ONBOARDING.md#before-purchasing-or-deploying).
- For setup or endpoint failures, start with [troubleshooting](setup/docs/Troubleshooting.md).
- For repository problems, use [GitHub issues](https://github.com/Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample/issues).

Keep credentials, phone data, OTPs, encrypted bodies, and raw provider responses out of issues
and support requests. See the [complete documentation index](docs/README.md).
