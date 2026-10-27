# Monitor the endpoint

<a id="monitoring-setup-and-sample-queries"></a>

[Documentation](README.md) | [Application Insights](APPLICATION-INSIGHTS.md) | [Log fields](LOGGING.md) | [Troubleshooting](../setup/docs/Troubleshooting.md#after-deployment-triage)

Guided setup creates Application Insights and Log Analytics. Confirm telemetry, review failures
and latency, and add alerts.

| Task | Start here |
| --- | --- |
| Confirm data is arriving | [Open the resources](#open-the-monitoring-resources) |
| Review requests, failures, and latency | [Function requests](#function-requests) |
| Review evaluation and provider outcomes | [Application events](#application-events) |
| Find Python or .NET log fields | [Runtime log formats](#runtime-log-formats) |
| Monitor several regions | [Multiple regions](#multiple-regions) |
| Create notifications | [Alerts](#alerts) |
| Diagnose missing data | [Collection and data quality](#collection-and-data-quality) |
| Monitor Microsoft Entra ID sign-ins | [Sign-in monitoring](SIGN-IN-MONITORING.md) |

Run these queries only after an [authorized test](ONBOARDING.md#validate-the-deployed-endpoint).
Keep phone numbers, OTPs, request bodies, credentials, tokens, nonces, and raw provider responses
out of queries, alerts, exports, and screenshots.

<a id="1-record-the-deployment-and-confirm-telemetry"></a>
<a id="find-the-linked-resources-in-the-portal"></a>
## Open the monitoring resources

1. Open the Function App from the deployment summary.
2. Select **Monitoring > Application Insights**, then open the linked resource.

    ![CYOT-CONSTO Function App Monitoring menu with the consto Application Insights resource link](images/onboarding/monitoring-link.png)

3. On the Application Insights **Overview**, open **Logs workspace**.
4. In the workspace, select **Logs** and use **KQL mode**.

    ![CYOT-CONSTO Application Insights Overview showing the consto resource group and Logs workspace while identifiers and connection details remain hidden](images/onboarding/monitoring-workspace.png)

    *Nonproduction resource names and the subscription display name remain visible. Subscription and
    application IDs, the instrumentation key, and the connection string remain hidden.*

Record the Function App, Application Insights resource, workspace, runtime, region, deployment
version, owner, and expected traffic or test schedule. Use one row per regional origin.

Connection strings and resource identifiers are private operational data. Grant read access only
to the required workspace. Application telemetry uses `AppRequests`, `AppTraces`, and related
tables. Function platform logs and resource diagnostics can use other tables. See
[telemetry tables](APPLICATION-INSIGHTS.md#signals-tables-and-metrics-are-different-things).

### Discover the deployed role and request name

Run this after an authorized request:

```kusto
AppRequests
| where TimeGenerated >= ago(24h)
| summarize StoredRows = count(), LastSeen = max(TimeGenerated)
    by _ResourceId, AppRoleName, Name
| order by LastSeen desc
```

Copy the observed `AppRoleName`, `_ResourceId`, and request `Name` into later queries. Do not assume
that every deployment records the operation as `SendOtp`.

<a id="run-a-first-query-and-read-the-results"></a>
### First check

```kusto
AppRequests
| where TimeGenerated >= ago(48h)
| where AppRoleName == "<function-role-name>" and Name == "SendOtp"
| summarize StoredRows = count() by ResultCode, Success
| order by ResultCode asc
```

![CYOT-CONSTO workspace Logs in KQL mode with a query scoped to the consto Function App and one aggregate result row](images/onboarding/logs-query-results.png)

`StoredRows` counts stored telemetry, not delivered messages. Sampling can change the count.
Evaluation and live calls can both return `200`. No rows means no matching data in this scope and time range. It does not prove health.

<a id="2-single-region-function-queries"></a>
## Function requests

### Requests, failures, and latency

```kusto
AppRequests
| where TimeGenerated >= ago(1h)
| where _ResourceId =~ "<application-insights-resource-id>"
| where AppRoleName == "<function-role-name>" and Name == "SendOtp"
| extend Weight = tolong(coalesce(ItemCount, 1))
| summarize Requests = sum(Weight),
    Failed = sumif(Weight, Success == false),
    UnknownOutcome = sumif(Weight, isnull(Success)),
    P50Ms = percentilew(DurationMs, Weight, 50),
    P95Ms = percentilew(DurationMs, Weight, 95),
    P99Ms = percentilew(DurationMs, Weight, 99)
    by bin(TimeGenerated, 5m)
| extend FailurePct = 100.0 * Failed / Requests
| order by TimeGenerated asc
```

`ItemCount` weights sampled records. Empty buckets mean no data. `Success` is an HTTP request
outcome, not confirmation that a recipient received an SMS or call.

### Failure status

```kusto
AppRequests
| where TimeGenerated >= ago(1h)
| where _ResourceId =~ "<application-insights-resource-id>"
| where AppRoleName == "<function-role-name>" and Name == "SendOtp"
| where Success == false
| summarize Failed = sum(tolong(coalesce(ItemCount, 1)))
    by ResultCode, bin(TimeGenerated, 5m)
| order by TimeGenerated asc
```

Investigate application `4xx` separately from provider or host `5xx`. Easy Auth can reject
request before the Function runs, so some `401` or `403` responses may not create an
`AppRequests` row or application event.

<a id="4-javascript-service-event-queries"></a>
## Application events

The JavaScript runtime writes JSON service events to `AppTraces.Message`. Confirm the format in
your deployment before using these queries. Python and .NET use different formats.

<a id="separate-evaluated-accepted-and-failed-completions"></a>
### Evaluation and delivery outcomes

```kusto
AppTraces
| where TimeGenerated >= ago(1h)
| where _ResourceId =~ "<application-insights-resource-id>"
    and AppRoleName == "<function-role-name>"
| extend Event = parse_json(Message)
| where tostring(Event.logType) == "service"
    and tostring(Event.eventName) == "request_completed"
| extend Result = tostring(Event.result),
    Evaluation = case(tobool(Event.evaluation) == true, "evaluation",
                      tobool(Event.evaluation) == false, "live", "unclassified")
| summarize EstimatedEvents = sum(tolong(coalesce(ItemCount, 1)))
    by Result, Evaluation, bin(TimeGenerated, 5m)
| order by TimeGenerated asc
```

Current completion results are `evaluated`, `accepted`, or `failed`. `accepted` means provider
acceptance, not recipient delivery.

### Request and credential failures

```kusto
AppTraces
| where TimeGenerated >= ago(1h)
| where _ResourceId =~ "<application-insights-resource-id>"
    and AppRoleName == "<function-role-name>"
| extend Event = parse_json(Message)
| where tostring(Event.logType) == "service"
| where tostring(Event.eventName) in
    ("request_failed", "unexpected_error")
| summarize EstimatedEvents = sum(tolong(coalesce(ItemCount, 1)))
    by EventName = tostring(Event.eventName),
       FailureStage = tostring(Event.failureStage),
       FailureReason = tostring(Event.failureReason),
       bin(TimeGenerated, 5m)
| order by TimeGenerated asc
```

Credential acquisition failures have `failureStage=provider_credentials` and
`failureReason=credential_unavailable` on the failing request. There is no background refresher
or idle credential-health signal. A successful evaluation does not prove provider credentials work;
validate that path separately through an approved live test.

The preceding `provider_credential_resolution_failed` event includes a safe `aadstsCode`
(`AadstsCode` in .NET). See [credential diagnostics](LOGGING.md#credential-diagnostics).
Do not count it and `request_failed` as two failed requests or enable raw SDK/body logging.

<a id="runtime-specific-log-discovery"></a>
## Runtime log formats

| Runtime | Completion event | What to verify |
| --- | --- | --- |
| JavaScript | JSON `request_completed` service event | Parse `Message` and use camelCase fields such as `httpStatus` and `result`. |
| Python | Message `OTP request completed` with logging extras | Check whether `event_name`, `result`, and `httpStatus` appear in `Properties`. |
| .NET | Event `request_completed` (1401), message starts with `Request completed: HTTP` | Check whether `Result`, `HttpStatus`, `ElapsedMs`, and request scope fields appear in `Properties`. |

Discover property names without returning message bodies:

```kusto
AppTraces
| where TimeGenerated >= ago(1h)
| where _ResourceId =~ "<application-insights-resource-id>"
    and AppRoleName == "<function-role-name>"
| mv-expand PropertyName = bag_keys(Properties)
| summarize StoredRows = count() by PropertyName = tostring(PropertyName)
| order by StoredRows desc
```

Exporter configuration can rename or remove structured properties. Validate one controlled
nonproduction invocation before creating an alert. See the [log field reference](LOGGING.md) for
event order, identifiers, and safe fields.

<a id="3-multiple-regions-and-cross-workspace-queries"></a>
## Multiple regions

If regions share a workspace, query `AppRequests` once and group by `_ResourceId` and
`AppRoleName`. For separate workspaces, use explicit references and label each branch:

```kusto
union
    (workspace("<workspace-a-id>").AppRequests
     | where TimeGenerated >= ago(1h)
     | where _ResourceId =~ "<insights-a-resource-id>"
         and AppRoleName == "<role-a>" and Name == "SendOtp"
     | extend Region = "region-a"),
    (workspace("<workspace-b-id>").AppRequests
     | where TimeGenerated >= ago(1h)
     | where _ResourceId =~ "<insights-b-resource-id>"
         and AppRoleName == "<role-b>" and Name == "SendOtp"
     | extend Region = "region-b")
| extend Weight = tolong(coalesce(ItemCount, 1))
| summarize Requests = sum(Weight),
    Failed = sumif(Weight, Success == false),
    UnknownOutcome = sumif(Weight, isnull(Success)),
    P95Ms = percentilew(DurationMs, Weight, 95),
    P99Ms = percentilew(DurationMs, Weight, 99)
    by Region, _ResourceId, AppRoleName, bin(TimeGenerated, 5m)
| extend FailurePct = 100.0 * Failed / Requests
| order by TimeGenerated asc, Region asc
```

Do not average regional percentages or percentiles. Keep inaccessible workspaces and query errors
visible. A healthy region must not hide another region's missing data or failures.

### Missing telemetry

Use an explicit expected inventory when each listed origin should receive requests:

```kusto
let Expected = datatable(Region:string, Component:string, Role:string)
[
    "region-a", "<insights-a-resource-id>", "<role-a>",
    "region-b", "<insights-b-resource-id>", "<role-b>"
]
| extend Component = tolower(Component);
let Observed =
    union workspace("<workspace-a-id>").AppRequests,
          workspace("<workspace-b-id>").AppRequests
    | where TimeGenerated between (ago(20m) .. ago(5m))
    | where Name == "SendOtp"
    | summarize StoredRows = count(), LastSeen = max(TimeGenerated)
        by Component = tolower(_ResourceId), Role = AppRoleName;
Expected
| join kind=leftouter Observed on Component, Role
| extend StoredRows = coalesce(StoredRows, tolong(0))
| extend MissingTelemetry = StoredRows == 0
| project Region, Component, Role, StoredRows, LastSeen, MissingTelemetry
```

For an alert, append `| where MissingTelemetry` and trigger when table rows are greater than zero.
Run this query only when traffic or an authorized scheduled test is expected. Idle or standby
origins can have no request rows.

## Alerts

1. In **Azure Monitor > Alerts > Action groups**, create the notification route and test it.
2. Create one rule per clear operational condition.
3. Preview the query over healthy, failing, and empty periods.
4. Test firing, notification, and resolution in nonproduction.
5. Record the owner, severity, threshold, maintenance process, and runbook.

| Starting alert | Scope and condition |
| --- | --- |
| Request failures | Five-minute `AppRequests` summary with a minimum request count and a threshold based on normal traffic. |
| High latency | Five-minute request summary with a reviewed p95 threshold and minimum request count. |
| JavaScript credential failures | `request_failed` events with `failureStage=provider_credentials` over a 15-minute window. |
| Missing regional telemetry | Expected-inventory query filtered to `MissingTelemetry`. |
| Certificate or credential renewal | Independent inventory reminder and the approved renewal runbook. |

Use **Custom log search** for KQL rules and verify the rule identity can read every workspace.
Use Function metrics only after confirming that the signal exists on the deployed FC1 or EP1 plan.
Tune all sample thresholds to measured traffic and costs.

<a id="certificate-credential-and-cost-ownership"></a>
### Operational ownership

Assign owners for certificate renewal, provider credentials, alert routing, telemetry retention,
and cost. Follow the [certificate lifecycle runbook](../setup/docs/README.md#encryption-certificate-lifecycle).
A new Key Vault certificate version does not update the Function's pinned reference or the
Microsoft Entra ID registration automatically.

Guided setup does not create action groups, alerts, Workbooks, availability tests, or certificate
contacts. Cost budgets notify but do not stop spending.

## Workbook

<a id="6-build-a-shared-operations-workbook"></a>

Create a Workbook only after verifying the queries. Include:

- request volume, failure percentage, and p95/p99 latency
- expected origins and last-seen status
- validated runtime completion and credential events
- current alerts, deployment version, and owners

Bind every panel to the selected time and resource scope. Do not show an empty panel as healthy.
Workbook readers still need access to the underlying data.

<a id="7-availability-authenticated-functions-and-fc1"></a>
## Availability

Keep `SendOtp` protected by Easy Auth. An unauthenticated `401` or `403` confirms rejection, not
endpoint availability.

The supported end-to-end check uses an authorized caller, a valid encrypted evaluation request,
and nonce verification without recording the nonce. Evaluation does not test provider acceptance
or delivery. Live checks need separate approval, controlled recipients, and cost limits.

FC1 can scale to zero. Idle periods can have no request logs, and the first authorized
request can include cold-start latency. Frequent probes can change both cost and observed latency.

<a id="8-optional-azure-front-door-layer"></a>
<a id="8-regional-edge-monitoring-with-azure-front-door"></a>
## Front Door

For the [multi-region design](FRONTDOOR.md), monitor Front Door separately from the Functions:

- health-probe status and origin health percentage
- origin latency and edge response status
- WAF or access-log rejections
- each regional Function, dependency, and telemetry source

Origin health does not prove caller authentication, provider access, or delivery. Keep origin
access restrictions and Easy Auth enabled while investigating routing.

<a id="9-sampling-ingestion-gaps-privacy-and-validation"></a>
## Collection and data quality

- **Missing data is not success.** Check resource scope, role name, table, time range, access,
  ingestion delay, filters, sampling, caps, retention, and exporter configuration.
- **Sampling changes counts.** Use `ItemCount` where available. Weighted totals remain estimates.
- **Pipelines differ.** Host requests, worker logs, resource metrics, diagnostics, and Microsoft
  Entra ID sign-ins are separate data sources.
- **Protect customer data.** Do not collect phone numbers, OTPs, bodies, encrypted payloads,
  tokens, credentials, private keys, nonces, or raw provider responses.
- **Test the monitor.** Validate the query, rule identity, action group, notification, resolution,
  and missing-data behavior in nonproduction.

For pipeline setup and missing-ingestion checks, use
[Application Insights](APPLICATION-INSIGHTS.md). For endpoint failures, use
[troubleshooting](../setup/docs/Troubleshooting.md#after-deployment-triage).

[action-groups]: https://learn.microsoft.com/azure/azure-monitor/alerts/action-groups
[log-alerts]: https://learn.microsoft.com/azure/azure-monitor/alerts/alerts-create-log-alert-rule
[workbooks]: https://learn.microsoft.com/azure/azure-monitor/visualize/workbooks-overview
