# Application Insights

<a id="application-insights-for-the-external-phone-provider"></a>

[Documentation](README.md) | [Monitoring](MONITORING.md) | [Log fields](LOGGING.md)

For missing or incomplete telemetry, start here. For routine queries and alerts, see
[Monitor the endpoint](MONITORING.md).

| Task | Go to |
| --- | --- |
| Understand where records come from | [Collection](#collection) |
| Choose the correct table | [Signals and tables](#signals-and-tables) |
| Check one deployment | [Single region](#single-region) |
| Check several regions | [Multiple regions](#multiple-regions) |
| Diagnose missing data | [Coverage checks](#coverage-checks) |
| Review privacy and sampling | [Limits](#limits) |

Function telemetry covers execution, timing, and logs. Microsoft Entra ID sign-ins and provider
delivery use separate data.

<a id="how-telemetry-reaches-application-insights"></a>
## Collection

The **Functions host** records invocation telemetry. The **language worker** runs the endpoint and
writes application logs. A worker exporter needs its own initialization, authentication, filters,
and sampling.

Application Insights stores data in its linked Log Analytics workspace. Correlation can connect
requests, dependencies, exceptions, and traces when the active pipeline exports them.

### Repository defaults

| Runtime | Checked-in configuration | Verify after deployment |
| --- | --- | --- |
| [.NET](../dotnet/host.json) | Host uses `telemetryMode: OpenTelemetry`. The project references Functions OpenTelemetry and Azure Monitor packages. | `Program.cs` does not register a separate worker exporter. Confirm which worker logs, dependencies, and exceptions are present. |
| [JavaScript](../javascript/host.json) | Standard host Application Insights settings. Requests are excluded from sampling. | There is no direct Application Insights or OpenTelemetry exporter in the package manifest. Confirm outbound dependency coverage. |
| [Python](../python/host.json) | Standard host Application Insights settings. Requests are excluded from sampling. | There is no Azure Monitor or OpenTelemetry exporter in requirements. Confirm structured properties and dependencies. |

These are source defaults, not guarantees. Runtime versions, packages, settings, filters, and
sampling affect collected data.

Application events are logs, not guaranteed `customEvents`. Verify the
[runtime format](MONITORING.md#runtime-log-formats) before saving queries.

For additional worker instrumentation, follow the
[Azure Functions OpenTelemetry guidance](https://learn.microsoft.com/azure/azure-functions/opentelemetry-howto)
for the selected language. Check correlation and duplicate records after any change.

<a id="signals-tables-and-metrics-are-different-things"></a>
## Signals and tables

| Signal | Workspace table | Notes |
| --- | --- | --- |
| HTTP requests | `AppRequests` | Includes duration, result code, success, role, and operation. Easy Auth can reject before invocation. HTTP success does not prove delivery. |
| Application logs | `AppTraces` | Includes messages, severity, and exported properties. Filters and sampling can remove records. |
| Outbound calls | `AppDependencies` | Includes only instrumented dependencies. Coverage differs by runtime and library. |
| Exceptions | `AppExceptions` | Includes captured and exported exceptions. Handled failures may appear only as sanitized logs or HTTP responses. |
| Custom metrics | `AppMetrics` | Requires emitted measurements and a working export path. |
| Custom events | `AppEvents` | Requires explicit event telemetry. A named log does not automatically become an event. |
| Availability results | `AppAvailabilityResults` | Requires an availability test or custom telemetry. Guided setup does not create tests. |

Application Insights metrics, workspace logs, Azure resource metrics, resource logs, Activity Log,
and Resource Health are different sources. A chart and a log query can use different sampling,
dimensions, and retention. Check the resource's supported metrics and diagnostic categories before
building an alert.

See the [Application Insights data model](https://learn.microsoft.com/azure/azure-monitor/app/data-model-complete)
and [Functions monitoring reference](https://learn.microsoft.com/azure/azure-functions/monitor-functions-reference).

<a id="single-region-configuration"></a>
## Single region

Guided setup connects one Function App to one Application Insights resource backed by a Log
Analytics workspace.

Check these items:

1. **Destination:** On the Function App, confirm `APPLICATIONINSIGHTS_CONNECTION_STRING` points
   to the intended resource. Do not copy it into issues or screenshots.
2. **Workspace:** On Application Insights, confirm the linked workspace.
3. **Ingestion authentication:** Confirm authenticated ingestion and the Function identity's
   scoped publisher role.
4. **Runtime settings:** Review the selected runtime's host and worker configuration, log levels,
   and sampling.
5. **Authorized request:** Run a non-delivering evaluation through the supported test process,
   allow for ingestion delay, then check `AppRequests` and `AppTraces`.
6. **Live path:** Validate provider acceptance and recipient delivery separately through an
   approved controlled test.

A `401` or `403` can be rejected before the Function runs. Evaluation does not acquire provider
credentials or contact the provider. There is no background credential refresher.

<a id="identity-and-ingestion"></a>
### Ingestion identity

The template configures:

- `APPLICATIONINSIGHTS_AUTHENTICATION_STRING=Authorization=AAD`
- the Function App's system-assigned managed identity
- **Monitoring Metrics Publisher** on the Application Insights resource
- `DisableLocalAuth: true`

The connection string selects the destination. The managed identity authenticates ingestion.
The outbound provider identity is separate.

If you intentionally use a user-assigned ingestion identity, set
`ClientId=<identity-client-id>;Authorization=AAD`, attach that identity to the app, and grant it
access to the destination. Do not use the provider application ID.

Missing data can result from the wrong destination, missing roles, identity mismatch, role
propagation, an inactive exporter, filters, sampling, DNS, or network access. Query and ingestion
access are separate.

See [Functions collection configuration](https://learn.microsoft.com/azure/azure-functions/configure-monitoring)
and [Microsoft Entra-authenticated ingestion](https://learn.microsoft.com/azure/azure-monitor/app/azure-ad-authentication).

<a id="multi-region-configuration"></a>
## Multiple regions

Each region has its own Function App and identity. Validate telemetry for every origin.
Application Insights does not route traffic or implement regional recovery.

| Layout | Use |
| --- | --- |
| Application Insights and workspace per region | Strong regional separation. Queries and access must include each workspace. |
| Application Insights per region with a shared workspace | Separate components with one query destination. Retention, access, and ingestion share the workspace boundary. |
| One shared Application Insights component | Requires distinct stable role names and ingestion access for every identity. Shared quotas and ingestion become common dependencies. |

Keep an inventory of Function App, region, Application Insights component, workspace, role name,
runtime, and owner. Workspace location and client geography do not prove execution region.

Use explicit sources and regional labels in
[multi-region queries](MONITORING.md#multiple-regions). Monitor Front Door edge and origin signals
separately from Function telemetry.

<a id="read-only-queries-to-establish-what-is-present"></a>
## Coverage checks

Run these in the linked Log Analytics workspace.

### Requests

```kusto
AppRequests
| where TimeGenerated > ago(1h)
| summarize StoredRows = count(),
    RepresentedRequests = sum(ItemCount),
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

An absent table, query error, or empty result does not mean zero failures. Check scope, time range,
traffic, access, filters, sampling, and ingestion. When present, `ItemCount` is a sampling weight.
It does not recover discarded records.

<a id="sampling-privacy-and-collection-limits"></a>
## Limits

- **Sampling and filters:** JavaScript and Python exclude host requests from sampling, not every
  signal. .NET OpenTelemetry mode does not use the same classic settings.
- **Delivery:** Host success, HTTP success, provider acceptance, and recipient delivery are
  different outcomes.
- **Completeness:** Buffering, cold starts, process exits, network failures, throttling, caps,
  retention, and exporter configuration affect stored telemetry.
- **Privacy:** Do not collect phone numbers, OTPs, request bodies, encrypted payloads, nonces,
  tokens, credentials, private keys, or raw provider responses. Review auto-captured URLs,
  query strings, dependency fields, and exception text.
- **Access and cost:** Restrict query and export access. Set retention and daily caps deliberately.
  A cap can create a monitoring blind spot.

Next: use the [monitoring tasks and queries](MONITORING.md) or the
[endpoint troubleshooting guide](../setup/docs/Troubleshooting.md#after-deployment-triage).
