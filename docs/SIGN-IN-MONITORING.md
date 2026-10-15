# Monitor Microsoft Entra ID sign-ins

[Documentation](README.md) | [Function monitoring](MONITORING.md)

Sign-in records explain identity activity. Monitor Function execution, provider acceptance, and
delivery through their own data sources.

| Task | Start here |
| --- | --- |
| Investigate one sign-in | [Find a sign-in](#find-a-sign-in) |
| Create ongoing alerts | [Set up monitoring](#set-up-monitoring) |
| Choose the first alerts | [Recommended monitors](#recommended-monitors) |
| Fix missing or quiet data | [Collection health](#collection-health) |
| Review fields and query design | [Query reference](#query-reference) |

## Recommended monitors

Choose exact tenant, application, service-principal, managed-identity, and resource IDs. Display
names can change and are not reliable alert filters.

### Integration sign-in failures

- **Tables:** `AADServicePrincipalSignInLogs` and `AADManagedIdentitySignInLogs`
- **Scope:** the known identity and intended resource in the source tenant
- **Notify:** repeated or unusual failures
- **Check first:** error code, last success, credentials, federation, permissions, expected
  schedule, token caching, and collection health

### Credential and permission changes

- **Table:** `AuditLogs`
- **Scope:** the integration's application and service-principal object IDs
- **Notify:** unexpected successful credential, consent, permission, trust, or service-principal
  changes
- **Check first:** actor, target, time, approved maintenance, result, and changed property names

### Repeated user sign-in failures

- **Tables:** `SigninLogs` for interactive sign-ins and
  `AADNonInteractiveUserSignInLogs` for background token or session failures
- **Scope:** the customer-facing app and source tenant
- **Notify:** recurring errors or failures above the normal baseline
- **Check first:** overall result, recent app or policy changes, and later recovery records

Keep the streams separate. A successful authentication step does not make the complete sign-in
successful. Set thresholds from representative traffic, not a universal sample value.

<a id="1-choose-your-tenant-and-access"></a>
## Find a sign-in

### 1. Choose the tenant

1. Open the [Microsoft Entra admin center](https://entra.microsoft.com).
2. In **Settings > Directories + subscriptions**, select the tenant where users sign in.
3. Record its **Tenant ID** from **Overview**.
4. Ask for **Reports Reader** to view activity logs. Workspace access is separate.

The sign-in tenant can differ from the tenant hosting the Function. External tenants use a
different export setup from workforce tenants.

<a id="2-find-one-sign-in"></a>
### 2. Review the record

1. Open **Entra ID > Monitoring & health > Sign-in logs**.
2. Filter by date and application, then open an authorized record.
3. In **Basic info**, check the application, application ID, resource, result, and time.
   Keep the application's client ID for later filters.
4. In **Authentication Details**, review each method, step result, and policy context.

![Microsoft Entra ID sign-in Activity Details with Authentication Details selected and two Previously satisfied steps marked true](images/sign-in-monitoring/sign-in-activity-details-authentication.png)

*Official Microsoft Entra ID example from
[Microsoft's activity-details instructions](https://learn.microsoft.com/en-us/entra/identity/monitoring-health/concept-sign-in-log-activity-details#authentication-details).
[Original screenshot](https://github.com/MicrosoftDocs/entra-docs/blob/927efa819a6f89a40b39b178d702b30f49b63f00/docs/identity/monitoring-health/media/concept-sign-in-log-activity-details/sign-in-activity-details-authentication.png),
Copyright (c) Microsoft Corporation. This is not your sign-in or a delivery test. Portal layout
and results can differ.*

`Previously satisfied` does not prove that a new phone challenge or provider send occurred.
Use the [sign-in error guide](https://learn.microsoft.com/en-us/entra/identity/monitoring-health/howto-troubleshoot-sign-in-errors)
for the overall result. For endpoint or provider issues, use
[Function monitoring](MONITORING.md#runtime-specific-log-discovery).

## Set up monitoring

<a id="3-export-logs-for-ongoing-monitoring"></a>
### 3. Export the required logs

For a **workforce tenant**, prepare:

- Security Administrator in Microsoft Entra ID
- an Azure subscription and Log Analytics workspace
- Azure access to configure the destination

For an **external tenant**, follow the
[External ID Azure Monitor setup](https://learn.microsoft.com/en-us/entra/external-id/customers/how-to-azure-monitor#prerequisites).
The workspace is hosted through a workforce tenant and can require Azure Lighthouse delegation.

Then:

1. In the source tenant, open **Entra ID > Monitoring & health > Diagnostic settings**.
2. Review existing settings with their owner.
3. Add or edit a setting and choose **Send to Log Analytics workspace**.
4. Select the categories needed for the monitors below.
5. Save, reopen the setting, and confirm the destination.

![Microsoft Entra admin center showing Monitoring and health, Diagnostic settings, and Add diagnostic setting highlighted](images/sign-in-monitoring/diagnostic-settings-start.png)

*Official Microsoft Entra admin center example from
[Microsoft's diagnostic-settings instructions](https://learn.microsoft.com/en-us/entra/identity/monitoring-health/howto-configure-diagnostic-settings#how-to-access-diagnostic-settings).
[Original screenshot](https://github.com/MicrosoftDocs/entra-docs/blob/927efa819a6f89a40b39b178d702b30f49b63f00/docs/identity/monitoring-health/media/howto-configure-diagnostic-settings/diagnostic-settings-start.png),
Copyright (c) Microsoft Corporation. This is not your tenant. Available categories and menus can
differ.*

| Diagnostic category | Workspace table |
| --- | --- |
| `SignInLogs` | `SigninLogs` |
| `NonInteractiveUserSignInLogs` | `AADNonInteractiveUserSignInLogs` |
| `ServicePrincipalSignInLogs` | `AADServicePrincipalSignInLogs` |
| `ManagedIdentitySignInLogs` | `AADManagedIdentitySignInLogs` |
| `AuditLogs` | `AuditLogs` |

Initial export is not immediate and does not backfill all portal history. Record the observed
arrival delay before setting alert windows.

<a id="4-check-your-data-and-choose-a-query"></a>
### 4. Confirm the data

1. Open **Log Analytics workspace > Logs**.
2. Find the selected table and preview recent records.
3. Check `AADTenantId` and `AppId` against the source tenant and application client ID.
4. Verify result types and IDs using the table schema.
5. Choose an official query from the
   [Azure Monitor query collection](https://learn.microsoft.com/en-us/azure/azure-monitor/reference/queries/signinlogs).
6. Add tenant and application filters before aggregation.
7. Run the query across normal, peak, and quiet periods, then save it with its scope and baseline.

No matching rows is not a healthy result. Check the destination, category, time range, access,
source activity, and ingestion delay.

For the first alert, the official **Failed Signin reasons** query is a useful starting point.
`ResultType` is a string in `SigninLogs`. Treat empty results separately and do not confuse
authentication codes with provider HTTP status codes.

<a id="5-create-your-first-alert"></a>
### 5. Create the alert

1. In **Azure Monitor > Alerts > Create > Alert rule**, select the workspace as the scope.
2. Choose **Custom log search**, paste the saved query, and review **Preview**.
3. Match the alert measure to the query output. A summarized query needs its numeric column.
4. Choose the window, evaluation frequency, threshold, and missing-data behavior from the
   measured baseline and ingestion delay.
5. Select or create an action group and verify every recipient.
6. Choose a query identity that can read the workspace.
7. Create the rule disabled when access must be granted after creation, then enable it after role
   propagation and testing.

Creating alerts requires workspace read access, rule write access, and access to the action group.
The operator's successful interactive query does not prove that the alert identity can read data.

<a id="6-test-then-hand-over"></a>
### 6. Test and hand over

1. Test the action group and confirm the team receives the notification.
2. Test a temporary nonproduction rule against authorized existing records.
3. Verify firing and resolution, then remove temporary settings.
4. Do not generate live OTPs, repeated wrong codes, or production policy changes to create data.
5. Record the workspace, query, rule, identity, action group, thresholds, owner, and support route.
6. Add a separate collection-health check.

Enable ongoing notifications only after these checks pass.

<a id="optional-reference"></a>
## Query reference

### IDs and results

| Need | Use |
| --- | --- |
| Source tenant | `AADTenantId` |
| Application client | `AppId` |
| Service-principal object | `ServicePrincipalId` |
| Target resource | `ResourceIdentity` or `ResourceServicePrincipalId`, after checking the table schema |
| Overall result | `ResultType`, `ResultSignature`, and `ResultDescription` |
| Audit target | `TargetResources` object IDs and types |

Do not use display names as the only scope. Standard workspace `TenantId` is not the source
directory ID. Portal field names and Log Analytics column names can differ.

### Authentication steps

`AuthenticationDetails` explains steps but does not replace the overall result. Previous token
claims can satisfy a step. Empty methods or missing step data do not prove that MFA was absent.

If you parse step arrays, count steps separately from sign-ins. Keep phone identifiers and raw
authentication details out of shared dashboards and notifications.

### Audit records

Use `ActivityDisplayName`, `ActivityDateTime`, `Result`, `ResultReason`, `InitiatedBy`, and
`TargetResources`. Match target object IDs, not the application client ID. A successful audit
result means the change completed, not that it was approved.

### Alert design

- Add scope filters before aggregation.
- Keep interactive, noninteractive, service-principal, and managed-identity streams separate.
- Align query time filters, alert windows, and evaluation frequency.
- Use a minimum traffic count for rate alerts.
- Avoid high-cardinality dimensions such as user, IP, request, or correlation IDs unless required.
- Restrict personal-data results and notifications.
- Do not automatically block users, disable accounts, or change policy from a heuristic alert.

Optional monitors such as unusual volume, source-IP patterns, and identity risk require a separate
baseline, response plan, privacy review, and applicable licensing. They are not provider delivery
or SMS-pumping signals.

<a id="monitor-ingestion-separately"></a>
## Collection health

Quiet alerts can mean quiet traffic or stopped export. Monitor collection separately:

1. Compare recent portal records with workspace records after the measured delay.
2. Check for no rows, stale arrival, query errors, and missing ingestion timestamps.
3. Review diagnostic settings, workspace access, transformations, limits, and service health.
4. Test the collection rule with healthy, empty, and delayed windows.
5. Route collection failures to an owner who can fix export or query access.

Missing evidence does not mean fewer failures.

## Privacy, licensing, and costs

- Microsoft Entra ID roles and Azure RBAC are separate.
- External tenants have different subscription and export arrangements.
- Risk and premium report features can require additional licensing and may not be available in
  external tenants.
- Sign-in records can contain personal data. Restrict workspace, alert, Workbook, export, and
  incident access.
- Set retention and budget alerts deliberately. Cost controls do not replace collection-health
  monitoring.

Counts are stored records, not unique users, sessions, challenges, sends, or delivered messages.
Use [Function monitoring](MONITORING.md) for endpoint execution and provider reports for delivery
and billing.

## References

- [Access Microsoft Entra activity logs](https://learn.microsoft.com/en-us/entra/identity/monitoring-health/howto-access-activity-logs#prerequisites)
- [Export activity logs to Azure Monitor](https://learn.microsoft.com/en-us/entra/identity/monitoring-health/howto-integrate-activity-logs-with-azure-monitor-logs)
- [Diagnostic log categories](https://learn.microsoft.com/en-us/entra/identity/monitoring-health/concept-diagnostic-settings-logs-options)
- [Sign-in logs table](https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables/signinlogs)
- [Service-principal sign-in table](https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables/aadserviceprincipalsigninlogs)
- [Managed-identity sign-in table](https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables/aadmanagedidentitysigninlogs)
- [Create a log search alert](https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/alerts-create-log-alert-rule)
- [Create and test an action group](https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/action-groups)
- [Microsoft Entra licensing](https://learn.microsoft.com/en-us/entra/fundamentals/licensing#microsoft-entra-monitoring-and-health)
