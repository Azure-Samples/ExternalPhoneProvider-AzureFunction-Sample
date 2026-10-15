# Documentation by task

[Sample overview and architecture](../README.md)

**New deployment? Start with [Get started](GETTING-STARTED.md).** Confirm supported access and
Microsoft's approved test/activation procedure before spending or deploying. Use a dedicated
nonproduction environment; deployment does not activate policy.

## Table of Contents

- [Deploy and validate](#deploy-and-validate)
- [Operate](#operate)
- [Develop](#develop)
- [Optional designs](#optional-designs)
- [Get help](#get-help)

## Deploy and validate

| Task | Guide |
| --- | --- |
| Register an app, deploy, test, and hand over | [Five-step setup](GETTING-STARTED.md) |
| Find IDs and complete provider authentication | [Configuration and validation](ONBOARDING.md) |
| Check permissions, script choices, or deployment output | [Setup reference](../setup/docs/README.md) |
| Resolve a setup or endpoint failure | [Troubleshooting](../setup/docs/Troubleshooting.md) |
| Estimate SMS/voice provider charges | [Cost estimate](COST-CALCULATOR.md); not a billing report |

## Operate

- **Function logs and alerts:** [Monitoring](MONITORING.md)
- **Missing or incomplete telemetry:** [Application Insights collection](APPLICATION-INSIGHTS.md)
- **Microsoft Entra ID sign-ins and identity alerts:** [Identity monitoring](SIGN-IN-MONITORING.md)
- **Certificate renewal:** [Certificate lifecycle](../setup/docs/README.md#encryption-certificate-lifecycle)
- **Rollback or decommissioning:** [Rollback procedure](../setup/docs/README.md#rollback-and-decommissioning)

## Develop

- **Runtime development:** [JavaScript](../javascript/README.md), [C#](../dotnet/README.md), or [Python](../python/README.md)
- **Settings and packages:** [Technical reference](../TECHNICAL.md)
- **Requests and responses:** [HTTP contract](CONTRACT.md)
- **Runtime events:** [Application log schema](LOGGING.md)
- **Provider integration:** [Provider-neutral BYOT interface](BRING-YOUR-OWN-PROVIDER.md)
- **Production gaps:** [Sample limitations](CONTRACT.md#production-limitations)

## Optional designs

These designs require separate implementation and validation; guided setup enables neither.

- **Route across regions:** [Multi-region Front Door design](FRONTDOOR.md)
- **Add provider fallback:** [Multi-provider implementation](MULTI-PROVIDER-IMPLEMENTATION.md)

## Get help

For access, approved testing, or activation, use the
[provider/Microsoft support route](ONBOARDING.md#before-purchasing-or-deploying).
For setup or runtime problems, start with the [troubleshooting routes](../setup/docs/Troubleshooting.md).
Keep credentials, phone data, and raw payloads out of support requests; use
[safe diagnostic evidence](../setup/docs/Troubleshooting.md#after-deployment-triage).
