# Documentation by task

[Sample overview and architecture](../README.md)

**First deployment:** follow [Get started](GETTING-STARTED.md). Confirm access and Microsoft's
approved test and activation process before deploying in a nonproduction environment.

## Table of Contents

- [Understand the sample](#understand-the-sample)
- [Deploy and validate](#deploy-and-validate)
- [Operate](#operate)
- [Develop](#develop)
- [Advanced topics](#advanced-topics)
- [Get help](#get-help)

## Understand the sample

- [Architecture and implementation](../TECHNICAL.md)
- [HTTP contract](CONTRACT.md)
- [Log schema](LOGGING.md)
- [Production readiness](CONTRACT.md#production-limitations)

## Deploy and validate

| Task | Guide |
| --- | --- |
| Register an app, deploy, test, and hand over | [Five-step setup](GETTING-STARTED.md) |
| Find IDs and complete provider authentication | [Configuration and validation](ONBOARDING.md) |
| Check permissions, script choices, or deployment output | [Setup reference](../setup/docs/README.md) |
| Resolve a setup or endpoint failure | [Troubleshooting](../setup/docs/Troubleshooting.md) |
| Estimate SMS/voice provider charges | [Cost estimate](COST-CALCULATOR.md); not a billing report |

## Operate

- [Function logs and alerts](MONITORING.md)
- [Application Insights collection](APPLICATION-INSIGHTS.md)
- [Microsoft Entra ID monitoring](SIGN-IN-MONITORING.md)
- [Certificate renewal](../setup/docs/README.md#encryption-certificate-lifecycle)
- [Rollback and decommissioning](../setup/docs/README.md#rollback-and-decommissioning)

## Develop

- Runtimes: [JavaScript](../javascript/README.md), [C#](../dotnet/README.md), [Python](../python/README.md)
- [Settings and packages](../TECHNICAL.md)
- [HTTP contract](CONTRACT.md)
- [Log schema](LOGGING.md)
- [Phone-service integration](BRING-YOUR-OWN-PROVIDER.md)

<a id="optional-designs"></a>
## Advanced topics

- [Multi-region routing](FRONTDOOR.md)
- [Provider fallback](MULTI-PROVIDER-IMPLEMENTATION.md)

## Get help

- [Provider access, testing, and activation](ONBOARDING.md#before-purchasing-or-deploying)
- [Troubleshooting](../setup/docs/Troubleshooting.md)
- [Safe diagnostic evidence](../setup/docs/Troubleshooting.md#after-deployment-triage)
