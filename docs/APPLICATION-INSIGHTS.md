# Application Insights

<a id="application-insights-for-the-external-phone-provider"></a>

[Documentation](README.md) | [Monitoring walkthrough](MONITORING.md) | [Log schema](LOGGING.md)

For logs and alerts, use the [monitoring walkthrough](MONITORING.md).
For missing or incomplete telemetry, use
[single-region configuration](#single-region-configuration). This page covers JavaScript,
.NET isolated, and Python.

Function telemetry shows execution, timing, and logs. Confirm recipient delivery through the
provider's supported delivery evidence. [Microsoft Entra ID sign-in monitoring](SIGN-IN-MONITORING.md)
uses a separate tenant export pipeline for identity activity.

This page assumes the endpoint is already deployed. Use the [setup guide](GETTING-STARTED.md)
first, then follow the [approved test handoff](ONBOARDING.md#validate-the-deployed-endpoint).

Sections: [collection pipelines](#how-telemetry-reaches-application-insights),
[signals and tables](#signals-tables-and-metrics-are-different-things),
[single-region checks](#single-region-configuration), [ingestion identity](#identity-and-ingestion),
[multi-region layout](#multi-region-configuration), [coverage queries](#read-only-queries-to-establish-what-is-present),
or [sampling/privacy limits](#sampling-privacy-and-collection-limits).

## How telemetry reaches Application Insights

The **Functions host** dispatches invocations and records their telemetry; the **language worker**
runs endpoint code. Standard worker logs pass through the host. A direct worker SDK/OpenTelemetry
exporter instead needs its own initialization, authentication, filtering, and sampling.
Host configuration alone does not configure every worker signal.

Exporters send data to Application Insights; its linked Log Analytics workspace stores records
for views and queries. Propagated correlation context connects requests, dependencies, and logs.
Background work need not belong to a request.

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

[Application events](LOGGING.md#event-sequence) are **logs**, not guaranteed `customEvents`.
Use [runtime-specific discovery](MONITORING.md#runtime-specific-log-discovery) before sharing queries:
exporters can change formatting, casing, and which properties survive.

To add direct worker instrumentation, follow the
[Functions OpenTelemetry guidance](https://learn.microsoft.com/en-us/azure/azure-functions/opentelemetry-howto)
for the selected language. Initialize the exporter, instrumentation, and credentials, then verify
correlation and duplicate suppression. Use the settings for that runtime. For languages outside
this sample, check the matching Microsoft support tab.

<a id="signals-tables-and-metrics-are-different-things"></a>
## Telemetry signals and tables

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
has transaction/availability/latency signals, and Front Door adds edge/origin signals.
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

Keep Easy Auth and the approved delivery flow intact while validating telemetry. Use an authorized
evaluation request for the authenticated, encrypted EPP path rather than generating periodic OTPs
or relying on a generic unauthenticated URL probe.

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

Use the [cross-workspace queries and missing-origin check](MONITORING.md#3-multiple-regions-and-cross-workspace-queries)
with explicit sources, authorized access to each, and per-origin grouping. Check idle/standby
origins too: no traffic and broken collection can both look empty.

For the [Front Door multi-region design](FRONTDOOR.md), inspect
[edge metrics and logs separately](MONITORING.md#8-optional-azure-front-door-layer).
Edge/WAF rejections, origin-connectivity failures, and probes need not appear as Function requests.
Origin health does not prove provider authentication or delivery.

<a id="read-only-queries-to-establish-what-is-present"></a>
## Telemetry coverage queries

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
