# Application Insights for the External Phone Provider

Application Insights helps you see which requests ran, how long they took, and what the Function
reported along the way. It does **not** confirm that an SMS or voice call reached the recipient.

**Looking for your logs?** Start with the [monitoring guide](MONITORING.md). It shows how to find
the resources from your deployment summary, run queries, and create alerts.

This reference explains how collection works for **JavaScript, .NET isolated, and Python**,
what each signal means, and why data may be missing. Start with
[single-region configuration](#single-region-configuration) to check a guided deployment;
use the remaining sections for runtime differences or a multi-region design.
You do not need Azure Front Door for Function telemetry.

These instructions do not deploy resources or enable extra instrumentation, alerts, or availability
tests. Use the [setup guide](../setup/docs/README.md) for deployment and the
[approved test handoff](ONBOARDING.md#validate-the-deployed-endpoint) to generate test traffic.

## How telemetry reaches Application Insights

There are two execution processes to consider: the **Functions host**, which dispatches
invocations, and the **language worker**, which runs the endpoint code.

1. The host records invocation telemetry. With the standard Functions logging pipeline,
   application logs are forwarded from the worker to the host for export.
2. A worker can instead have its own SDK or OpenTelemetry instrumentation and exporter.
   That pipeline requires language-specific initialization, authentication, filtering, and
   sampling; configuring the host alone does not configure every worker signal.
3. The exporter sends telemetry to the Application Insights ingestion endpoint. The
   Application Insights resource identifies the application and its linked Log Analytics
   workspace stores the log records.
4. Application Insights views and Azure Monitor Logs queries use those records. Correlation
   identifiers can connect requests, dependencies, and logs when instrumentation propagates
   the context. Background work does not necessarily belong to a request.

In OpenTelemetry terminology, a distributed trace contains spans. In Application Insights,
server spans generally appear as **requests**, client spans as **dependencies**, and
application log messages as **traces**. The `traces` table is not a list of all distributed
tracing spans.

### What the checked-in sample configures

The [deployment template](../setup/infra/resources.bicep) defines a workspace-based Application
Insights resource, the Function's connection and authentication settings, and a role assignment
for ingestion. It also defines a **separate** Function diagnostic setting that sends `allLogs`
and `AllMetrics` to the workspace. Diagnostic settings do not install worker instrumentation
and do not mean every Azure resource or every dependency is being observed.

| Implementation | Checked-in behavior | What not to assume |
| --- | --- | --- |
| [.NET isolated](../dotnet/host.json) | The host selects `telemetryMode: OpenTelemetry`. The [project](../dotnet/dotnet.csproj) references the Functions worker OpenTelemetry integration, hosting extensions, and Azure Monitor exporter. | [Program.cs](../dotnet/Program.cs) does not explicitly register `AddOpenTelemetry().UseFunctionsWorkerDefaults().UseAzureMonitorExporter()`. Package references alone do not activate that direct worker export pipeline. Do not claim complete worker logs, dependencies, or exceptions from the host setting. |
| [JavaScript](../javascript/host.json) | Uses standard host Application Insights settings with sampling enabled and `Request` excluded from sampling. | The [package manifest](../javascript/package.json) does not include a direct Application Insights/OpenTelemetry exporter. Host integration is not proof that all outbound Node.js HTTP calls are traced. |
| [Python](../python/host.json) | Uses standard host Application Insights settings with sampling enabled and `Request` excluded from sampling. | The [requirements](../python/requirements.txt) do not include an Azure Monitor/OpenTelemetry exporter. A Python log message or `requests` call is not automatically a structured custom event or a dependency span. |

These are source defaults, not an inventory of a running deployment. Deployed package versions,
application-setting overrides, runtime versions, and log filters can change the result. The
guided setup can publish a released package rather than the current source.

The endpoint emits application events such as `request_received`, `provider_response_processed`,
`request_failed`, `request_completed`, and `credential_refresh_failed` through language logging
APIs. These are **log events**, not a promise of rows in `customEvents`. .NET uses structured
`ILogger` events, JavaScript uses its logging helper, and Python uses logging records with extra
fields. Message formatting, property names/casing, and preservation of extra fields depend on
the logging/export path. Inspect the actual schema before sharing one event-field query across
languages.

When adding direct worker instrumentation in a future code change, follow the
[Functions OpenTelemetry guidance](https://learn.microsoft.com/en-us/azure/azure-functions/opentelemetry-howto)
for the selected language. Initialize the exporter and required instrumentations, configure
its credential, and verify correlation and duplicate suppression. Do not simply copy another
language's host settings. Other Azure Functions languages are outside this repository's sample;
use the corresponding language tab in the Microsoft guidance for their support requirements.

## Signals, tables, and metrics are different things

The following table maps **Application Insights Logs** names to **Log Analytics workspace**
names. Table availability and contents depend on what was actually emitted and ingested.

| Signal | Application Insights / workspace table | Interpretation and limits |
| --- | --- | --- |
| Invocations and HTTP request outcomes | `requests` / `AppRequests` | Name, duration, result code, success, role, and operation context. Requests rejected before the Function executes may not appear. A successful invocation does not prove delivery of an SMS or call. |
| Application and runtime logs | `traces` / `AppTraces` | Messages, severity, and available properties. Log filters or sampling can remove them; error-level text is not necessarily exception telemetry. |
| Outbound dependencies | `dependencies` / `AppDependencies` | Duration, target, type, and outcome for instrumented calls. HTTP, Key Vault, and credential calls are not guaranteed to be covered by every worker/runtime/library combination. Cached operations may make no remote call. |
| Recorded exceptions | `exceptions` / `AppExceptions` | Exceptions captured and exported by the active pipeline. Caught errors converted into sanitized logs or HTTP responses need not generate exception rows. |
| Emitted numeric measurements | `customMetrics` / `AppMetrics` | Custom instrumentation and, where supported, host aggregation measurements. Do not assume the classic host aggregator or custom metrics exist in every OpenTelemetry configuration. |
| Explicit custom events | `customEvents` / `AppEvents` | Requires an event-emitting instrumentation path. Giving a log an event name does not by itself populate this table. |
| Synthetic availability results | `availabilityResults` / `AppAvailabilityResults` | Requires configured tests or custom availability telemetry. Deploying Application Insights does not create these checks. |
| Performance counters | `performanceCounters` / `AppPerformanceCounters` | Depends on OS, hosting model, SDK, and enabled collection. Not a guaranteed source of Function CPU or memory data. |

**Application Insights metrics** include request rates, failures, and durations derived from
application telemetry. Standard preaggregated metrics and log-based calculations can have
different sampling behavior and dimensions; a chart and a raw row count need not match.

**Azure resource metrics** come from the platform and are queried under the relevant resource
in Azure Monitor Metrics. Function execution/instance/memory metrics depend on the hosting plan;
FC1 and EP1 do not expose identical sets. Key Vault has its own request/latency signals, Storage
has transaction/availability/latency signals, and optional Front Door has edge/origin signals.
These are not automatically Application Insights dependencies or custom metrics.

Resource logs are another independent source. Depending on the resource and diagnostic setting's
destination mode, exported logs use resource-specific tables or `AzureDiagnostics`; supported
exported metrics can appear in `AzureMetrics`. Not every platform metric or dimension is
exportable through diagnostic settings. Check the resource's supported categories and the
workspace schema rather than assuming a table exists. Azure Activity Log and Resource Health
provide additional control-plane and platform-health context, not application delivery outcomes.

See the [Application Insights data model](https://learn.microsoft.com/en-us/azure/azure-monitor/app/data-model-complete)
and [Functions monitoring reference](https://learn.microsoft.com/en-us/azure/azure-functions/monitor-functions-reference)
for table definitions and plan-specific metrics.

## Single-region configuration

For one regional deployment, keep the relationship explicit: **one Function App sends application
telemetry to its selected Application Insights resource, backed by a Log Analytics workspace**.
The guided template creates that relationship. Separate production and test telemetry, and select
resource/workspace locations according to residency, access, retention, and cost requirements.

Review the following in the portal without assuming that resource creation proves ingestion:

1. On the Function App, identify the deployed language/package and the effective
   `APPLICATIONINSIGHTS_CONNECTION_STRING` destination. Prefer the connection string over the
   legacy instrumentation-key setting. Do not paste its value into issues or shared screenshots.
2. On Application Insights, verify the linked workspace and authenticated-ingestion configuration.
   Verify the Function identity's scoped publisher role, not just the deployer's permissions.
3. Check the appropriate host and worker configuration described above, including effective
   log levels and sampling. Independent worker exporters require their own configuration.
4. Use an authorized, non-delivering evaluation request from the supported onboarding procedure,
   then inspect its request/log telemetry after allowing for ingestion delay. A `401` or `403`
   is not a successful evaluation and may have been rejected before invocation.
5. Separately validate provider acceptance and actual recipient delivery through an approved,
   controlled live test. Evaluation skips the provider send; it cannot validate that dependency
   path. Background credential refresh may run independently during either test.

Do not weaken Easy Auth or send periodic OTPs just to populate telemetry. A generic unauthenticated
URL probe does not validate the endpoint's authenticated, encrypted EPP contract.

### Identity and ingestion

The current template sets `APPLICATIONINSIGHTS_AUTHENTICATION_STRING` to `Authorization=AAD`,
uses the Function App's **system-assigned managed identity**, assigns **Monitoring Metrics
Publisher** at the Application Insights resource, and sets `DisableLocalAuth: true`.
Despite its name, that role authorizes publishing application telemetry, not only metrics.
The connection string still selects the destination; it is not an Entra access token.

The user-assigned identity used for outbound provider authentication is a separate concern.
If an operator deliberately selects a user-assigned identity for ingestion, the documented host
setting is `ClientId=<identity-client-id>;Authorization=AAD`; that identity must be attached to
the app and authorized at the destination. Do not substitute the provider application ID.

Direct worker exporters must use a supported credential configuration. Do not assume that a
host authentication setting configures a manually added SDK. Local development also cannot use
an Azure-hosted managed identity by merely copying the settings. Follow the SDK's documented
local credential support against a nonproduction destination; do not enable local/key-based
ingestion on production to make a local test work.

Missing data can result from a wrong destination, unsupported/uninitialized exporter, missing
role assignment, role propagation delay, identity mismatch, or blocked DNS/network access to
ingestion endpoints. Reader/query permissions are separate from ingestion permissions.
See [Functions collection configuration](https://learn.microsoft.com/en-us/azure/azure-functions/configure-monitoring)
and [Entra-authenticated ingestion](https://learn.microsoft.com/en-us/azure/azure-monitor/app/azure-ad-authentication).

## Multi-region configuration

Each region has its own Function App and identity. Configure and validate **every regional
origin independently**, even if traffic normally enters through one public URL. Application
Insights does not provide routing or failover.

Choose the telemetry layout explicitly; adding a second Function region does not automatically
replicate or reconfigure an existing telemetry destination:

| Layout | Configuration and tradeoff |
| --- | --- |
| Application Insights and workspace per region | Repeating the single-region setup produces distinct destinations. Point each Function to its regional component and authorize its identity there. Queries must include each workspace; retention/access are managed separately. Application failover does not guarantee regional telemetry remains queryable. |
| Application Insights per region, shared workspace | Each Function still targets its own component; components link to one approved workspace. Workspace queries can group by component resource ID. Retention, access, residency, and ingestion availability now share that workspace's boundary. This is an operator-selected design, not an automatic setup-script option. |
| Shared Application Insights component | Both Functions target the same component, with both identities granted ingestion access. Configure distinct, stable role names consistently in host and worker telemetry and verify them. Without a reliable role/region dimension, records cannot be separated by origin. Shared ingestion and quotas are also shared dependencies. |

Maintain an inventory mapping Function App, deployment region, Application Insights component,
workspace, and role name. A workspace's location or a telemetry item's client geography is **not**
proof of the Function's execution region. `AppRoleInstance` identifies an instance, not a stable
regional label. In a shared component, use verified role naming or an explicitly emitted region
property; do not expect Azure resource tags to become telemetry properties automatically.

For separate workspaces, use
[cross-workspace queries](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/cross-workspace-query)
with explicit `workspace("<workspace-resource-id>").AppRequests` references and a region label
for each source before the union. The placeholders must be replaced by authorized operators,
and the query identity needs access to all sources. Group by origin before aggregating so a
healthy region cannot hide a failing one. Check each region's latest telemetry, including idle
or standby regions; no traffic and broken collection can both look like an empty result.

If Front Door is used, inspect its platform metrics and diagnostic logs separately. An edge or
WAF rejection, origin-connectivity failure, or health-probe result is not necessarily a Function
request. Front Door origin health is not evidence of provider authentication or message delivery.
The [optional Front Door guide](FRONTDOOR.md) describes that topology.

## Read-only queries to establish what is present

Run these examples from the **linked Log Analytics workspace's Logs** view. They use workspace
table/column names (`TimeGenerated`, `AppRoleName`, `OperationId`, `Properties`), not the
Application Insights aliases (`timestamp`, `cloud_RoleName`, `operation_Id`, `customDimensions`).
Choose the correct resource scope and time window. These examples are not alert definitions.

Start with request outcomes, keeping application components and roles separate:

```kusto
AppRequests
| where TimeGenerated > ago(1h)
| summarize StoredRows = count(),
    RepresentedRequests = sum(ItemCount),
    Latest = max(TimeGenerated)
    by _ResourceId, AppRoleName, Name, ResultCode, Success
| order by Latest desc
```

`ItemCount` is the sampling weight when supplied by the pipeline. The weighted sum estimates
represented requests; it does not restore discarded records or prove complete ingestion. If
weights are absent, investigate the exporter rather than treating an empty sum as zero traffic.
Do not add classic and OpenTelemetry duplicates or multiple diagnostic copies into one count.

Discover which dependency types have actually been collected:

```kusto
AppDependencies
| where TimeGenerated > ago(1h)
| summarize StoredRows = count(), Latest = max(TimeGenerated)
    by _ResourceId, AppRoleName, DependencyType, Success
| order by Latest desc
```

Inspect log coverage by role and severity without returning message bodies or custom properties:

```kusto
AppTraces
| where TimeGenerated > ago(1h)
| summarize StoredRows = count(), Latest = max(TimeGenerated)
    by _ResourceId, AppRoleName, SeverityLevel
| order by Latest desc
```

An absent table means this query cannot run in that scope; it does not mean a healthy zero.
Empty results require checking time range, workspace/component scope, traffic, filters,
sampling, and ingestion. These fresh examples have not been executed against a live workspace
as part of this documentation change. Inspect request `OperationId` locally in the portal when
correlating an authorized test with its related logs/dependencies; request IDs, invocation IDs,
and application correlation IDs are not interchangeable.

## Sampling, privacy, and collection limits

- **Sampling is pipeline-specific.** JavaScript and Python exclude requests from their host
  sampling configuration, not exceptions or every other signal. This does not protect against
  log filtering, export failures, ingestion caps, or retention expiry. .NET's OpenTelemetry
  host mode must not be described as using the same classic sampling settings. Align host and
  worker sampling deliberately and validate correlation after any instrumentation change.
- **Log filters affect visibility.** In the classic host pipeline, raising `Host.Results` above
  `Information` can remove successful invocation records; worker filters are independent when
  logs bypass the host. An empty Failures view can reflect missing collection, not healthy code.
- **Telemetry is not an exactly-once record.** Buffering, batching, cold starts, process
  termination, network failures, throttling, daily caps, and retention affect what is available.
  Ingestion has latency; Live Metrics is not a durable substitute for stored telemetry.
- **Keep sensitive content out of every pipeline.** Do not log phone numbers, OTPs, message
  bodies, encrypted request bodies, evaluation nonces, authorization headers, tokens, API keys,
  private keys, or provider response bodies. Review automatically captured URLs, query strings,
  dependency attributes, and exception text as well as application logs. Sanitized application
  logging does not sanitize a newly added auto-instrumentation library.
- **Control access and cost.** Restrict query/export access, set an appropriate retention policy,
  and review ingestion volume before enabling verbose logs or additional instrumentation.
  Separate environment data; use aggregates rather than customer records in shared reports.
- **Know the boundary.** Host success, HTTP success, provider acceptance, and recipient delivery
  are different outcomes. Handled failures need not be exceptions; credential refresh can
  occur without an invocation; an idle or scaled-to-zero app may emit nothing. Platform health,
  external provider status, and independently designed availability tests supply different
  evidence. None is created merely by connecting Application Insights.
