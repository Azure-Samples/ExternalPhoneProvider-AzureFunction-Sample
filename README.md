# External Phone Provider Azure Function Sample

Connect Microsoft Entra ID to a phone provider for SMS and voice one-time passwords.
Guided setup deploys **one regional endpoint** using JavaScript, C#, or Python.

Start in a separate nonproduction environment and review [requirements](#requirements).

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

- JavaScript, C#, and Python implementations of one [HTTP and trust contract](docs/CONTRACT.md).
- Guided Azure deployment with Easy Auth, Key Vault, and monitoring.
- No-send evaluation for authentication and decryption checks.
- Provider-neutral [phone-service integration](docs/BRING-YOUR-OWN-PROVIDER.md).

## Requirements

- Confirm [provider access and Microsoft's approved test and activation process](docs/GETTING-STARTED.md#1-get-ready).
- Prepare a nonproduction tenant, subscription, app registration, and unique resource prefix.
- Check [roles, permissions, tools, regional availability, and quota](setup/docs/README.md#prerequisites-for-step-2).
- Plan for Azure, telemetry, and provider charges; the [cost estimate](docs/COST-CALCULATOR.md) is not a bill.
- Keep Easy Auth enabled for the approved Microsoft caller.

## Architecture

![Microsoft Entra ID sends an encrypted request through Easy Auth to a Function, which uses Key Vault and calls the phone provider](docs/images/single-region-architecture.png)

*Easy Auth checks the Microsoft caller before the Function decrypts the request.
Live success confirms provider acceptance; confirm delivery separately. Evaluation sends nothing.
See [architecture details](TECHNICAL.md#single-region-architecture).
[Open the full-size diagram](docs/images/single-region-architecture.png).*

## Get started

Follow the **[five-step setup guide](docs/GETTING-STARTED.md)** in order:

1. <a id="1-get-ready"></a>[Get ready](docs/GETTING-STARTED.md#1-get-ready): confirm access, approvals, permissions, and budget.
2. <a id="2-register-your-application"></a>[Register the app](docs/GETTING-STARTED.md#2-register-your-application): save the tenant and client IDs.
3. <a id="3-run-guided-setup"></a>[Deploy](docs/GETTING-STARTED.md#3-run-guided-setup): choose the provider, runtime, and plan.
4. <a id="4-connect-your-provider-and-test"></a>[Connect and test](docs/GETTING-STARTED.md#4-connect-your-provider-and-test): configure provider access and run approved checks.
5. <a id="5-activate-and-hand-over"></a>[Activate and hand over](docs/GETTING-STARTED.md#5-activate-and-hand-over): activate after validation and assign owners.

Before live use, review [production readiness](docs/CONTRACT.md#production-limitations).

<a id="find-more-detail"></a>
## Guidance

### Deploy and configure

- [Five-step setup](docs/GETTING-STARTED.md)
- [Configuration and validation](docs/ONBOARDING.md)
- [Setup reference](setup/docs/README.md)
- [Troubleshooting](setup/docs/Troubleshooting.md)

### Operate

- [Function monitoring and alerts](docs/MONITORING.md)
- [Application Insights collection](docs/APPLICATION-INSIGHTS.md)
- [Microsoft Entra ID monitoring](docs/SIGN-IN-MONITORING.md)
- [Certificate renewal and rollback](setup/docs/README.md#encryption-certificate-lifecycle)
- [Provider cost estimate](docs/COST-CALCULATOR.md)

### Develop

- Runtime guides: [JavaScript](javascript/README.md), [C#](dotnet/README.md), [Python](python/README.md)
- [Architecture and settings](TECHNICAL.md)
- [HTTP contract](docs/CONTRACT.md)
- [Log schema](docs/LOGGING.md)
- [Phone-service integration](docs/BRING-YOUR-OWN-PROVIDER.md)

<a id="optional-designs"></a>
### Advanced topics

- [Multi-region routing](docs/FRONTDOOR.md)
- [Provider fallback](docs/MULTI-PROVIDER-IMPLEMENTATION.md)

## Getting help

- [Provider access, testing, and activation](docs/ONBOARDING.md#before-purchasing-or-deploying)
- [Setup and endpoint troubleshooting](setup/docs/Troubleshooting.md)
- [Repository issues](https://github.com/Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample/issues)

Keep credentials, phone data, OTPs, encrypted bodies, and raw provider responses out of issues
and support requests. See the [complete documentation index](docs/README.md).
