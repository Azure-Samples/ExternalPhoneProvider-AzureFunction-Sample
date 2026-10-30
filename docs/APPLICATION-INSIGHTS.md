# Application Insights

[Documentation](README.md) | [Monitoring queries](MONITORING.md) | [Log fields](LOGGING.md)

Use this guide to understand collection and diagnose missing telemetry.
Guided setup connects the Function App to Application Insights and a Log Analytics workspace.

## Collection

The **Functions host** records invocation telemetry. The **language worker** executes the
handler and writes application logs. Check both layers when investigating missing records.

| Runtime | Checked-in configuration | Check after deployment |
| --- | --- | --- |
| [JavaScript](../javascript/host.json) | Host Application Insights collection; requests excluded from sampling | JSON service events in traces and the available dependency coverage |
| [C#](../dotnet/host.json) | Host OpenTelemetry mode; application events use `ILogger` | Worker-log collection, scope fields, dependencies, and exceptions |
| [Python](../python/host.json) | Host Application Insights collection; requests excluded from sampling | Application traces and which structured logging properties are preserved |

Collection depends on runtime configuration, exporters, filters, and sampling.
Verify the [deployed log format](MONITORING.md#runtime-log-formats) before creating event-based alerts.

For instrumentation changes, follow the
[Azure Functions OpenTelemetry guidance](https://learn.microsoft.com/azure/azure-functions/opentelemetry-howto)
for the selected runtime.

<a id="signals-tables-and-metrics-are-different-things"></a>
## Signals and tables

Run this repository's queries in the linked **Log Analytics workspace**, where Application
Insights uses the following table names:

| Signal | Table | Interpretation |
| --- | --- | --- |
| HTTP requests | `AppRequests` | Invocation duration, result code, success, role, and operation |
| Application logs | `AppTraces` | Messages, severity, and exported properties |
| Instrumented outbound calls | `AppDependencies` | Dependency coverage depends on the active runtime pipeline |
| Captured exceptions | `AppExceptions` | Handled failures can instead appear as sanitized application logs |

Easy Auth can reject a request before invocation. HTTP success and provider acceptance are
separate from recipient delivery. Microsoft Entra ID sign-in logs are another
[data source](SIGN-IN-MONITORING.md).

See the [Application Insights data model](https://learn.microsoft.com/azure/azure-monitor/app/data-model-complete)
and [Functions monitoring reference](https://learn.microsoft.com/azure/azure-functions/monitor-functions-reference).

<a id="single-region-configuration"></a>
## Single region

1. On the Function App, confirm `APPLICATIONINSIGHTS_CONNECTION_STRING` selects the intended
   Application Insights resource.
2. On Application Insights, confirm the linked workspace.
3. Check the Function identity's ingestion access.
4. Review the host and worker log levels, exporters, and sampling.
5. Run an authorized evaluation, allow for ingestion delay, and query `AppRequests` and `AppTraces`.
6. Validate the provider path separately with a controlled live request.

### Ingestion identity

The setup template configures:

- `APPLICATIONINSIGHTS_AUTHENTICATION_STRING=Authorization=AAD`.
- The Function's system-assigned managed identity.
- **Monitoring Metrics Publisher** on the Application Insights resource.
- `DisableLocalAuth: true`.

The connection string selects the destination; managed identity authenticates ingestion.
The outbound provider identity is separate.

For missing data, check the destination, role assignment and propagation, exporter, filters,
sampling, DNS, and network access. Workspace query access is separate from ingestion access.

See [Functions collection configuration](https://learn.microsoft.com/azure/azure-functions/configure-monitoring)
and [Microsoft Entra-authenticated ingestion](https://learn.microsoft.com/azure/azure-monitor/app/azure-ad-authentication).

## Multiple deployments

Record each Function App, Application Insights component, workspace, runtime, and owner.
Validate collection independently for every deployment.
Use explicit resource and role filters in [cross-workspace queries](MONITORING.md#multiple-deployments).

## Coverage checks

Run these in the linked workspace after an authorized request.

### Requests

```kusto
AppRequests
| where TimeGenerated > ago(1h)
| summarize StoredRows = count(),
    RepresentedRequests = sum(tolong(coalesce(ItemCount, 1))),
    Latest = max(TimeGenerated)
    by _ResourceId, AppRoleName, Name, ResultCode, Success
| order by Latest desc
```

### Dependencies

```kusto
AppDependencies
| where TimeGenerated > ago(1h)
| summarize StoredRows = count(), Latest = max(TimeGenerated)
    by _ResourceId, AppRoleName, DependencyType, Success
| order by Latest desc
```

### Logs

```kusto
AppTraces
| where TimeGenerated > ago(1h)
| summarize StoredRows = count(), Latest = max(TimeGenerated)
    by _ResourceId, AppRoleName, SeverityLevel
| order by Latest desc
```

An empty result is not proof of health. Check scope, time range, expected traffic, access,
filters, and ingestion. `ItemCount` represents the sampling weight when supplied.

## Privacy and retention

Keep phone numbers, OTPs, bodies, encrypted payloads, nonces, tokens, credentials, private keys,
and raw provider responses out of telemetry. Review automatically captured URLs and exception text.

Restrict query and export access. Set retention and daily caps deliberately; reaching a cap can
create a monitoring gap. Use the [monitoring guide](MONITORING.md#collection-and-data-quality)
for ongoing collection checks.
