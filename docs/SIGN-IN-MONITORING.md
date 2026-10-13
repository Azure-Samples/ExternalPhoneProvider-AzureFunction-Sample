# Monitor Microsoft Entra sign-ins

Use Microsoft Entra sign-in logs to investigate authentication failures, understand traffic,
and notify operators about unusual activity. This is **tenant identity monitoring**, separate
from the [Function monitoring guide](MONITORING.md) and [Application Insights](APPLICATION-INSIGHTS.md).
Guided EPP setup does **not** export Entra logs or create the Workbooks, action groups, or alerts
described here. These instructions are customer configuration guidance, not a deployed monitor.

Start by [choosing the tenant and permissions](#1-choose-the-tenant-and-permissions), then
[exporting logs](#2-export-the-required-log-categories), [checking actual records](#3-confirm-arrival-and-schema),
and [creating alerts](#5-create-actionable-log-search-alerts). A
[Workbook](#6-build-a-sign-in-workbook) provides a shared investigation view.

## What these logs can and cannot tell you

Sign-in logs describe authentication to an application: result codes, authentication steps,
Conditional Access outcomes, and available identity/network context. They do **not** provide a
guaranteed CYOT/EPP provider identifier, delivery mode, provider billing total, or a reliable
count of SMS or voice sends. Do not infer provider usage from an authentication method named `SMS` or `Voice`,
or from `AuthenticationRequirement == "multiFactorAuthentication"`.

A failed sign-in can mean an invalid password, an interrupted challenge, user cancellation,
a policy rejection, or another authentication failure. It does not by itself identify a phone
provider outage. A successful sign-in does not prove the EPP Function was called, which provider
was used, or that an OTP reached a recipient; an existing token claim can satisfy authentication.
Several records can describe one authentication sequence, including successive MFA outcomes.
The queries below count **stored log rows**, not unique customers, completed sessions, or sends.

Use Function request/log telemetry for endpoint execution and provider acceptance; use the
provider's approved delivery reports and billing controls for delivery, send volume, and costs.
Evaluation and live EPP requests can both return HTTP 200. `SigninLogs` has no EPP `evaluation`
field, and an endpoint evaluation is not guaranteed to produce a user sign-in row.

## 1. Choose the tenant and permissions

Identify the tenant where the **user authentication** occurs, not merely the tenant/subscription
hosting the Function. Record its tenant ID, tenant type, intended customer-facing application's
client ID(s), destination workspace resource ID, and monitoring/security owners privately.
The application's `SigninLogs.AppId` is **not necessarily** the dedicated endpoint application's
`applicationId` in the EPP deployment summary. Confirm it against a real sign-in record.

There are different setup paths:

- **Workforce tenant**, including B2B guests: follow the
  [global Entra-to-Azure Monitor integration](https://learn.microsoft.com/en-us/entra/identity/monitoring-health/howto-integrate-activity-logs-with-azure-monitor-logs).
  Configure general diagnostic settings as at least **Security Administrator**, with an Azure
  subscription, a Log Analytics workspace, and the necessary Azure permissions on the destination.
- **External tenant** for consumer/business-customer apps: follow
  [Azure Monitor in external tenants](https://learn.microsoft.com/en-us/entra/external-id/customers/how-to-azure-monitor).
  An external tenant cannot have an associated Azure subscription. Its setup wizard authenticates
  the subscription in a **workforce tenant** and configures the Azure Lighthouse access path.
  The documented prerequisites include Azure RBAC **Owner** on that subscription and
  **Security Administrator or Application Administrator** in the external tenant.
  Users selected to configure diagnostic settings still need at least **Security Administrator**.
  Review the wizard's delegation, selected users/groups, workspace, region, and costs before
  approving it; do not move the EPP subscription or change tenant/policy settings to imitate
  the workforce instructions.

Entra roles and Azure RBAC are separate. **Reports Reader** is the least privileged Entra role
for reading activity logs in the admin center; it does not grant workspace access. Grant
investigators appropriately scoped log-query access, such as **Log Analytics Reader**, using
[workspace/table access controls](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/manage-access).
Saving or sharing a Workbook does not grant access to its underlying logs.

Current [monitoring licensing guidance](https://learn.microsoft.com/en-us/entra/fundamentals/licensing#microsoft-entra-monitoring-and-health)
lists sign-in and audit logs for Entra ID Free as well as P1/P2. Do not confuse that with
premium report, Graph API, risk, or Workbook-template entitlements; confirm requirements for
each feature and tenant type before purchasing or enabling it. Azure ingestion, retention,
querying, alert evaluation, and notifications can incur separate charges.

**Risk is optional and tenant-dependent.** The current
[external-tenant feature comparison](https://learn.microsoft.com/en-us/entra/external-id/customers/concept-supported-features-customers)
lists **Microsoft Entra ID Protection as unavailable in external tenants**. Do not apply
workforce P2 risk-detection promises to that tenant. In supported workforce tenants, full
[ID Protection](https://learn.microsoft.com/en-us/entra/id-protection/overview-identity-protection)
risk capabilities require P2 (or an applicable entitlement). The `SigninLogs` schema documents
`RiskLevelDuringSignIn`, `RiskLevelAggregated`, `RiskState`, and `RiskDetail`, but some values are
`hidden` without the required entitlement. Empty, `none`, or `hidden` is not a clearance of fraud.
Check current product availability and actual records before using risk fields.

## 2. Export the required log categories

For a workforce tenant, or after completing the external-tenant monitoring wizard:

1. In the **Microsoft Entra admin center**, switch to the tenant being monitored.
2. Open **Entra ID > Monitoring & health > Diagnostic settings**. Review existing settings
   first to avoid unintended duplicate destinations or changing someone else's integration.
3. Select **Add diagnostic setting** (or deliberately edit the approved setting) and name it.
4. Select the **SignInLogs** category for interactive user sign-ins. Add **AuditLogs** if you
   also need directory-change investigations. Select only additional categories justified by
   your operational needs and available in this tenant.
5. Under **Destination details**, select **Send to Log Analytics workspace**, then choose
   the approved subscription/workspace. In an external tenant, use the workspace/access path
   established by the external-tenant instructions.
6. Select **Save**, then read back the categories and destination. Record the owner and date.

The [streaming category reference](https://learn.microsoft.com/en-us/entra/identity/monitoring-health/concept-diagnostic-settings-logs-options)
distinguishes these sources; category labels and workspace table names are not identical:

| Selected log category | Workspace table | Intended use |
| --- | --- | --- |
| SignInLogs | [SigninLogs](https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables/signinlogs) | Interactive user authentication; primary source for the examples below. |
| Non-interactive user sign-ins | [AADNonInteractiveUserSignInLogs](https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables/aadnoninteractiveusersigninlogs) | Token/client activity on behalf of users; keep its baseline separate. |
| Service principal sign-ins | [AADServicePrincipalSignInLogs](https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables/aadserviceprincipalsigninlogs) | Application/workload authentication, not end-user OTP outcomes. |
| Managed identity sign-ins | [AADManagedIdentitySignInLogs](https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables/aadmanagedidentitysigninlogs) | Managed identity authentication, not end-user OTP outcomes. |
| AuditLogs | [AuditLogs](https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables/auditlogs) | Directory changes; not a replacement for sign-in outcomes. |

The external-tenant [Microsoft samples](https://github.com/microsoft/external-id-azure-monitor)
also query `SigninLogs` for authentication reporting. That is not a guarantee every workforce
category, premium report, or populated field exists in an external tenant. Check the category
picker and the workspace's actual tables; do not union unavailable tables or substitute
`AuditLogs` for a missing `SigninLogs` feed. Provider-side OAuth logs may be in the provider's
tenant and require its administrator's assistance.

The Function's diagnostic setting is a **different setting on a different resource**.
Creating Application Insights or enabling Function logs does not export Entra activity.
Export is not a backfill of all historical portal logs.

## 3. Confirm arrival and schema

Open **Azure portal > Log Analytics workspaces > your destination > Logs**, then use **KQL mode**.
Choose an appropriate time range and confirm `SigninLogs` in the table browser. Do not run
these examples from the Application Insights application-table context (`requests`, `traces`).

Initial arrival is not immediate: Microsoft's external-tenant samples describe about 45 minutes,
while the [general diagnostic-setting guidance](https://learn.microsoft.com/en-us/entra/identity/monitoring-health/howto-configure-diagnostic-settings)
allows up to three days for initial logs. These are setup allowances, not a steady-state latency
SLA. After initial arrival, measure normal delays before enabling paging alerts.

Run these two queries separately:

```kusto
SigninLogs
| getschema
```

```kusto
SigninLogs
| where TimeGenerated >= ago(24h)
| summarize StoredRows = count(), LatestLogTime = max(TimeGenerated)
    by AADTenantId, AppId, AppDisplayName, IsInteractive, Category
| order by LatestLogTime desc
```

If the table is unresolved, fix collection/destination/access first; do not mask it with an
empty fallback. If it exists but returns no rows, compare the correct tenant's **Monitoring
& health > Sign-in logs** with the workspace, export start time, selected category, time range,
and expected application traffic. An empty result is not evidence that authentication is healthy.
Inspect any collection transformations that could remove needed rows or columns.

The remaining queries require the verified
[SigninLogs schema](https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables/signinlogs).
Replace `<sign-in-tenant-id>` with the observed `AADTenantId` and `<customer-app-client-id>`
with the observed application's **client ID**, not an Object ID, display name, or provider API ID.
Use one app per initial alert rule; add further app IDs only after validating each scope.
`AADTenantId` identifies the source directory; do not substitute the workspace's tenant.

Inspect a bounded set of records without returning user names, phone/sign-in identifiers,
IP addresses, or the entire authentication details payload:

```kusto
SigninLogs
| where TimeGenerated >= ago(24h)
| where AADTenantId =~ "<sign-in-tenant-id>" and AppId =~ "<customer-app-client-id>"
| project TimeGenerated, CreatedDateTime, Id, CorrelationId, ResultType,
    AuthenticationRequirement, ConditionalAccessStatus
| top 20 by TimeGenerated desc
```

`ResultType` is a **string**: `"0"` is success; populated nonzero values are sign-in
error/result codes, not Function or provider HTTP statuses. Keep empty codes as unknown.
Review individual codes with the
[sign-in troubleshooting guidance](https://learn.microsoft.com/en-us/entra/identity/monitoring-health/howto-troubleshoot-sign-in-errors)
and the portal's Basic info and Authentication Details tabs. Do not label every nonzero code
as an incorrect OTP or a provider failure.

`CreatedDateTime` is the sign-in initiation time (UTC); `TimeGenerated` is the log timestamp
used by these workspace queries; `ingestion_time()` estimates when the record reached the
workspace. They are not interchangeable. Updates/multiple MFA records and late arrival can
change counts. `CorrelationId` is client-influenced and is not guaranteed to be accurate or unique.

Measure log-to-ingestion delay before choosing an alert buffer:

```kusto
SigninLogs
| where TimeGenerated >= ago(24h)
| where AADTenantId =~ "<sign-in-tenant-id>" and AppId =~ "<customer-app-client-id>"
| extend IngestedAt = ingestion_time()
| extend LogToIngestMinutes = datetime_diff("second", IngestedAt, TimeGenerated) / 60.0
| summarize StoredRows = count(), MissingIngestionTime = countif(isnull(IngestedAt)),
    P95LogToIngestMinutes = percentile(LogToIngestMinutes, 95),
    LatestIngestedAt = max(IngestedAt)
```

This measures the timestamps present in stored rows, not a delivery or authentication latency
SLA. Investigate missing or negative timing values and compare with sign-in initiation time;
do not assume the example ten-minute buffer covers every delay.

### Inspect authentication steps safely

`AuthenticationDetails` is documented as a **string** containing step details. Parse it before
expanding; the same pattern also accepts an already-dynamic array. Check coverage first:

```kusto
SigninLogs
| where TimeGenerated >= ago(24h)
| where AADTenantId =~ "<sign-in-tenant-id>" and AppId =~ "<customer-app-client-id>"
| extend Steps = parse_json(tostring(AuthenticationDetails))
| summarize StoredRows = count(),
    RowsWithStepArray = countif(gettype(Steps) == "array"),
    RowsWithoutStepArray = countif(gettype(Steps) != "array")
```

For rows with arrays, summarize the observed methods and nullable step outcomes:

```kusto
SigninLogs
| where TimeGenerated >= ago(24h)
| where AADTenantId =~ "<sign-in-tenant-id>" and AppId =~ "<customer-app-client-id>"
| extend Steps = parse_json(tostring(AuthenticationDetails))
| where gettype(Steps) == "array"
| mv-expand Step = Steps
| extend Method = tostring(Step.authenticationMethod),
    Requirement = tostring(Step.authenticationStepRequirement),
    StepSucceeded = tobool(Step.succeeded)
| summarize AuthenticationStepRows = count() by Method, Requirement, StepSucceeded
| order by AuthenticationStepRows desc
```

Missing/invalid JSON, empty arrays, and missing step properties do not establish success or
failure. Array expansion counts steps, not sign-ins. Confirm property names and population in
your actual records (the [authentication detail reference](https://learn.microsoft.com/en-us/graph/api/resources/authenticationdetail?view=graph-rest-beta)
describes the nested shape; this guide does not call the beta API). The
[sign-in activity details](https://learn.microsoft.com/en-us/entra/identity/monitoring-health/concept-sign-in-log-activity-details)
explain that token claims can satisfy a step without a new challenge. Do not project
`authenticationMethodDetail` in a shared report: it can contain personal information.
Method/step success is neither provider attribution nor delivery confirmation.

## 4. Establish the baseline

Use at least a representative business cycle, including peaks, releases, and planned tests.
This seven-day exploration query is **not an alert query**:

```kusto
SigninLogs
| where TimeGenerated >= ago(7d)
| where AADTenantId =~ "<sign-in-tenant-id>" and AppId =~ "<customer-app-client-id>"
| summarize StoredRows = count(),
    Successful = countif(ResultType == "0"),
    NonSuccess = countif(isnotempty(ResultType) and ResultType != "0"),
    Unknown = countif(isempty(ResultType))
    by bin(TimeGenerated, 20m)
| extend NonSuccessPct = 100.0 * NonSuccess / StoredRows
| order by TimeGenerated asc
```

Empty buckets are no data, not a measured zero or 100% availability. Separate normal
interrupt/challenge codes from final failures during investigation; a broad non-success
baseline is useful for changes but not an authentication completion SLA. Review the result-code
distribution before adding any exclusions; document exclusions and monitor them separately.

## 5. Create actionable log search alerts

Use **scheduled log search alerts**, not Azure Activity Log alerts, for these queries.
Start with an **Analytics-plan** table; other table plans have different query/alert capabilities.
The following thresholds are illustrations, not recommended fraud limits or service commitments.
Tune them from the scoped baseline and begin with notification-only, low-severity rules.

### A. Elevated non-success rate

This returns one qualifying app row only when at least 50 stored rows, at least 20 non-success
rows, and at least 20% non-success occur in a **20-minute log-time window ending 10 minutes ago**:

```kusto
SigninLogs
| where TimeGenerated >= ago(30m) and TimeGenerated < ago(10m)
| where AADTenantId =~ "<sign-in-tenant-id>" and AppId =~ "<customer-app-client-id>"
| summarize StoredRows = count(),
    NonSuccess = countif(isnotempty(ResultType) and ResultType != "0"),
    Unknown = countif(isempty(ResultType)) by AppId
| extend NonSuccessPct = 100.0 * NonSuccess / StoredRows
| where StoredRows >= 50 and NonSuccess >= 20 and NonSuccessPct >= 20.0
| project AppId, StoredRows, NonSuccess, Unknown, NonSuccessPct
```

The buffer allows some ingestion delay; it does not guarantee complete data. Events delayed
beyond the lookback can be missed. Overlapping evaluations can observe the same event repeatedly.
Adjust both buffer and lookback together if measured delay requires it.

### B. Unusual sign-in volume

Using the same lagged window, return an app row at **200 or more stored rows**:

```kusto
SigninLogs
| where TimeGenerated >= ago(30m) and TimeGenerated < ago(10m)
| where AADTenantId =~ "<sign-in-tenant-id>" and AppId =~ "<customer-app-client-id>"
| summarize StoredRows = count() by AppId
| where StoredRows >= 200
```

A spike is a reason to investigate: campaigns, a release, retries, or a shared client can also
increase traffic. This is not an OTP-send, SMS-pumping, or provider-spend detector.

### C. Potential abuse from a source IP

For restricted security triage, find **30 or more non-success rows across approximately five
or more known user IDs** from one source IP in that same window:

```kusto
SigninLogs
| where TimeGenerated >= ago(30m) and TimeGenerated < ago(10m)
| where AADTenantId =~ "<sign-in-tenant-id>" and AppId =~ "<customer-app-client-id>"
| where isnotempty(ResultType) and ResultType != "0"
| where isnotempty(IPAddress) and isnotempty(UserId)
| summarize NonSuccess = count(),
    KnownUsersApprox = dcount(UserId) by AppId, IPAddress
| where NonSuccess >= 30 and KnownUsersApprox >= 5
```

Only rows with known user IDs are counted here. This heuristic can miss unknown-user attacks
and distributed attacks; `dcount` is approximate.
NAT, VPNs, mobile networks, and shared proxies can produce false positives. IP geolocation is
not proof of a person's physical location. Restrict IP-bearing results and notifications to
the security team. Do not automate blocking, disable an account/provider, or change
authentication policy solely on this heuristic.

Where workforce ID Protection is supported and licensed, separately review populated
`RiskLevelDuringSignIn`/`RiskLevelAggregated` and `RiskState` in the official risk reports.
Risk findings can arrive asynchronously. `RiskyUsers` and `UserRiskEvents` are separate export
categories, not automatically enabled by selecting `SignInLogs`. Do not reinterpret a volume
threshold as a Microsoft risk detection or a confirmed fraud report.

### Configure the rule in the portal

Follow the [log search alert rule reference](https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/alerts-create-log-alert-rule):

1. In **Azure portal > Monitor > Alerts > Create > Alert rule**, select the **destination
   Log Analytics workspace** as Scope, not the Function or customer app registration.
2. On **Condition**, choose **Custom log search**, paste one complete query above with real
   scope values, and select **Run**. Review the results/preview, then continue editing the alert.
3. Explicitly set **Measure: Table rows**, **Aggregation type: Total**, and **Aggregation
   granularity (window size): 30 minutes**. These queries already apply numeric thresholds
   in KQL: a returned row means the condition qualifies. Set a **Static** threshold,
   **Operator: Greater than**, **Threshold value: 0**, and **Frequency of evaluation:
   5 minutes**. Under Advanced options, set **Override query time range: 30 minutes**;
   use a single violating evaluation to trigger. Do not count the one summary row as
   50 sign-ins or set the portal row threshold to 50/200.
4. Leave **Split by dimensions** unset initially. With one scoped app, this raises a
   workspace-level incident if any row qualifies. Include app/scope and a restricted query
   link in the runbook. Splitting by IP/user/correlation ID can create high-cardinality
   alert instances, costs, and personal data in notifications.
5. On **Actions**, select or create an **action group** for the responsible operators
   (a separate restricted group for security triage). Configure approved email/push or incident
   routing and any required recipient verification. See
   [action group configuration](https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/action-groups).
   Use the action group's **Test** facility and verify receipt; that tests
   notification routing, not this query, ingestion, or a live sign-in.
6. On **Details**, choose the subscription/resource group, a recognizable rule name,
   initial severity such as **Sev 3**, and a description containing tenant/app scope,
   thresholds, owner, and runbook. Configure **Automatically resolve alerts** for a stateful
   rule to limit repeated notifications while a condition persists; resolution is not immediate.
7. Choose an approved evaluation identity. A system-assigned managed identity starts with
   no access: after creating the rule **disabled**, grant its identity log-reader access at
   this workspace, allow propagation, then enable after validation. If using no managed
   identity, permissions follow the last editor; review this dependency explicitly.
8. **Review + create** only after reviewing access and costs. Inspect rule health/query
   errors and **Alerts** after enabling. A successful interactive query under your identity
   does not establish access under the rule's identity.

Rule creation requires read access to the target, write access to the rule's resource group,
and read access to the selected action group; creating that group or assigning roles needs
separate appropriate Azure permissions. Cross-tenant operators should create/manage the rule
in the subscription-owning workforce tenant with approved Azure RBAC, not assume the
external-tenant delegation grants every alert/role-assignment permission.

### Monitor ingestion separately

Failure/volume rules can appear quiet when collection is broken. For a scope that is expected
to have regular user sign-ins, this query returns a row if nothing has been ingested in an hour,
including when the selected scope has no rows in the last day:

```kusto
SigninLogs
| where TimeGenerated >= ago(24h)
| where AADTenantId =~ "<sign-in-tenant-id>" and AppId =~ "<customer-app-client-id>"
| summarize LastIngested = max(ingestion_time()), StoredRows = count()
| where StoredRows == 0 or isnull(LastIngested) or LastIngested < ago(60m)
| project Monitor = "Sign-in feed needs investigation", LastIngested, StoredRows
```

Use a separate rule with **Table rows / Total > 0**, **30-minute granularity**,
**15-minute evaluation frequency**, and **Override query time range: 24 hours**. The one-hour
staleness threshold is in KQL. Do not shorten that override to the aggregation window.
Avoid one-minute frequency: `ingestion_time()` is not supported by that frequency's optimization.
An unresolved table/query or access failure is a rule-health problem, not a stale-data row.
No sign-ins during quiet hours and broken ingestion look alike; enable this only with a
documented traffic expectation and maintenance schedule. Null ingestion time is also
investigative, not proof of an outage. Compare with portal sign-ins, diagnostic settings,
workspace access, transformations, service health, and ingestion limits.

### Validate without generating provider sends

First validate scopes and counts against existing approved records; allow for ingestion delay.
Review healthy/empty windows as well as qualifying windows. For a temporary **nonproduction**
rule, select a known existing window **within the rule's query lookback** and lower the KQL
threshold so its existing rows qualify. If testing an older window, change the query's time
filter and portal query-time override together (log search alerts scan at most 48 hours);
keep the test action group restricted. Verify the scheduled evaluation, notification,
incident context, and later resolution, then restore/delete the temporary rule and restore
production thresholds. Do not leave a test override active.

If there are no suitable records, use the organization's approved **non-phone** test sign-in
flow in a test tenant/app and record its UTC time/IDs. Do not induce repeated wrong OTPs,
change production policy, bypass Easy Auth, or send live OTPs to populate a chart.
An EPP evaluation can validate parts of Function telemetry but cannot validate provider
delivery or guarantee a `SigninLogs` row. No query here has been executed against a customer
tenant by this documentation; operators must confirm live schema, data, and rule behavior.

## 6. Build a sign-in Workbook

In **Azure portal > Monitor > Workbooks**, select **New**, enter **Edit** mode, and **Add query**.
Choose **Logs (Analytics)** as the data source and the verified destination workspace.
Add the baseline query as a time chart and separate result-code/step summaries as grids.
Label counts as stored sign-in/step rows and include collection freshness and unknown-code
coverage so an empty chart is not read as healthy.

Save to an approved subscription/resource group, naming the monitored tenant/app scope.
If introducing workspace, tenant, app, or time-range parameters, bind them into every query
and test their effects; these examples have explicit literals/time filters, so a UI time
selector does not automatically change all query lookbacks. Keep IP/user-level investigation
views restricted. See [Workbook authoring](https://learn.microsoft.com/en-us/azure/azure-monitor/visualize/workbooks-create-workbook).

The [Microsoft External ID workbook samples](https://github.com/microsoft/external-id-azure-monitor)
provide authentication, MFA, user-behavior, and risk-oriented starting points. Review their
source, deployment/access changes, queries, tenant feature requirements, and privacy before
importing any template; a sample named "risk detection" does not make ID Protection available
in an external tenant. This repository does not deploy those templates. A Workbook visualizes
data; it does not create the scheduled alert rules above.

## 7. Triage, privacy, retention, and costs

On an alert, the owner should confirm workspace/rule health, tenant/app scope, UTC window,
and result-code distribution first. Inspect the relevant sign-in's **Basic info**,
**Authentication Details**, and applicable policy results in the Entra admin center.
Separate user mistakes/interruptions and policy changes from infrastructure failures or
potential abuse; escalate suspected compromise to the organization's security response process.

If phone delivery is implicated, follow the runtime-specific
[Function log discovery](MONITORING.md#runtime-specific-log-discovery). Compare timestamp,
verified request context, failure stage, and provider outcome with the provider's restricted
records. The sample logs sanitized envelope/header correlation identifiers, but
`SigninLogs.CorrelationId`, Function `OperationId`, request IDs, and provider references are
**not guaranteed equal**. Prove any association in an approved trace before using a join;
absence of a match is not proof that the Function/provider was never called. Fallback can
complete authentication through another path. Neither a sign-in success nor provider
acceptance establishes handset receipt.

Logs can contain user IDs, names, IP addresses, locations, device information, and phone
identifiers. Use minimum necessary fields, scoped Azure RBAC/table access, restricted
Workbooks/action groups, and approved residency/retention. Do not export full records to public
issues or put tokens, OTPs, message bodies, or credentials in alerts. Diagnostic export
normally selects categories, **not app IDs**: query filters restrict analysis but do not
reduce all tenant-wide ingestion or establish an access boundary.

Review [retention configuration](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/data-retention-configure)
and [log costs](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/cost-logs) separately
from Entra portal retention and provider billing. Confirm the effective table plan, analytics
retention, longer-term retention, ingestion/query volumes, alert frequency/dimensions, and
notification charges. Daily caps or transformations can remove the evidence an alert needs;
monitor those gaps rather than interpreting them as reduced abuse. App IDs and aggregate
counts are preferable to high-cardinality personal dimensions.

Handover is complete only after the customer verifies export arrival, scoped queries,
rule-identity access, alert/action-group behavior, freshness checks, and named operational,
security, privacy, retention, and cost owners. Keep validation evidence privately. These
heuristics support human investigation; they do not authorize automated blocking or policy changes.
