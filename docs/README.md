# Documentation by task

[Sample overview and architecture](../README.md)

**First deployment:** follow [Get started](GETTING-STARTED.md). Confirm supported access and
Microsoft's approved testing and activation process first. Build the endpoint in a separate
nonproduction environment, validate it, and then complete policy activation.

## Table of Contents

- [Understand the sample](#understand-the-sample)
- [Deploy and validate](#deploy-and-validate)
- [Operate](#operate)
- [Develop](#develop)
- [Advanced topics](#advanced-topics)
- [Get help](#get-help)

## Understand the sample

- **Architecture and implementation choices:** [Technical reference](../TECHNICAL.md)
- **Requests, responses, settings, and required behavior:** [HTTP contract](CONTRACT.md)
- **Runtime events and safe diagnostic fields:** [Application log reference](LOGGING.md)
- **Security and production planning:** [Production-readiness considerations](CONTRACT.md#production-limitations)

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
- **Production planning:** [Readiness considerations](CONTRACT.md#production-limitations)

<a id="optional-designs"></a>
## Advanced topics

Use these guides after validating a single-region endpoint. Each one includes implementation,
validation, operations, and rollback guidance.

- **Route across regions:** [Multi-region Front Door design](FRONTDOOR.md)
- **Add provider fallback:** [Multi-provider implementation](MULTI-PROVIDER-IMPLEMENTATION.md)

## Get help

For access, approved testing, or activation, use the
[provider/Microsoft support route](ONBOARDING.md#before-purchasing-or-deploying).
For setup or runtime problems, start with the [troubleshooting routes](../setup/docs/Troubleshooting.md).
Keep credentials, phone data, and raw payloads out of support requests; use
[safe diagnostic evidence](../setup/docs/Troubleshooting.md#after-deployment-triage).
