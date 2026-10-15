# Documentation

[Sample overview and architecture](../README.md)

**New deployment? Start with [Get started](GETTING-STARTED.md).** Confirm supported access and
Microsoft's approved test/activation procedure before spending or deploying. Use a dedicated
nonproduction environment; deployment does not activate policy.

## Deploy and validate

| Task | Guide |
| --- | --- |
| Register an app, deploy, test, and hand over | [Five-step setup](GETTING-STARTED.md) |
| Find IDs and complete provider authentication | [Configuration and validation](ONBOARDING.md) |
| Check permissions, script choices, or deployment output | [Setup reference](../setup/docs/README.md) |
| Resolve a setup or endpoint failure | [Troubleshooting](../setup/docs/Troubleshooting.md) |
| Estimate SMS/voice provider charges | [Cost estimate](COST-CALCULATOR.md); not a billing report |

## Operate

- [Find Function logs and create alerts](MONITORING.md); [diagnose collection](APPLICATION-INSIGHTS.md).
- [Investigate Microsoft Entra ID sign-ins and configure identity alerts](SIGN-IN-MONITORING.md).
- [Renew encryption certificates](../setup/docs/README.md#encryption-certificate-lifecycle) and
  [roll back or decommission](../setup/docs/README.md#rollback-and-decommissioning).

## Develop

- Local setup and source: [JavaScript](../javascript/README.md), [C#](../dotnet/README.md), [Python](../python/README.md).
- [Settings and packages](../TECHNICAL.md), [HTTP contract](CONTRACT.md), and [application log schema](LOGGING.md).
- [Implement the provider-neutral BYOT interface](BRING-YOUR-OWN-PROVIDER.md).
- [Review sample limitations](CONTRACT.md#production-limitations) before production use.

## Optional designs

[Multi-region Front Door](FRONTDOOR.md) and [primary-to-secondary provider fallback](MULTI-PROVIDER-IMPLEMENTATION.md)
require separate implementation and validation. Neither is enabled by guided setup.

## Get help

For access, approved testing, or activation, use the
[provider/Microsoft support route](ONBOARDING.md#before-purchasing-or-deploying).
For setup or runtime problems, start with the [troubleshooting routes](../setup/docs/Troubleshooting.md).
Keep credentials, phone data, and raw payloads out of support requests; use
[safe diagnostic evidence](../setup/docs/Troubleshooting.md#after-deployment-triage).
