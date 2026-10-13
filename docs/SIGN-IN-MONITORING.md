# Monitor Microsoft Entra sign-ins

Follow these steps to export Microsoft Entra sign-in logs, inspect authentication outcomes,
and configure customer-owned notifications. This is **tenant identity monitoring**, separate
from [Function monitoring](MONITORING.md) and [Application Insights](APPLICATION-INSIGHTS.md).
EPP setup does **not** configure tenant log export, Workbooks, action groups, or sign-in alerts.
This guide does not deploy anything or change authentication policy.

Use the linked Microsoft queries and illustrated portal instructions at the step where you
need them; no query snippets or fixed sample thresholds are duplicated here. Portal labels
can vary. The official screenshots show the controls, not resources or IDs to copy.
The two Microsoft screenshots below are unaltered public documentation examples, not your
tenant or evidence of a configured EPP integration. Used with permission from Microsoft.
Their [source and license notices](images/sign-in-monitoring/NOTICE.txt) accompany the files.

1. Complete [tenant and access checks](#1-choose-the-tenant-and-permissions).
2. [Configure export](#2-export-the-required-log-categories) and
   [confirm actual records](#3-confirm-arrival-and-schema).
3. [Choose a query and measure your baseline](#4-establish-the-baseline) before
   [configuring notifications](#5-create-actionable-log-search-alerts).
4. [Create the investigation Workbook](#6-build-a-sign-in-workbook) and complete
   [triage and handover checks](#7-triage-privacy-retention-and-costs).

## What these logs can and cannot tell you

1. Use sign-in logs to investigate authentication to an application: result codes,
   authentication steps, available policy outcomes, and identity/network context.
   Treat counts as **stored sign-in records**, not unique customers, completed sessions,
   provider sends, or delivery receipts. Several records can describe one authentication
   sequence, including successive MFA outcomes.
2. Do not attribute every failed sign-in to a phone provider. Invalid passwords,
   interrupted challenges, user cancellation, and policy rejection can all produce
   non-success results. A successful sign-in can use an existing token claim without a new
   phone challenge. Neither an SMS/Voice method label nor an MFA requirement proves EPP use.
3. Use the [Function monitoring queries](MONITORING.md#2-single-region-function-queries)
   for endpoint execution and the
   [runtime-specific log discovery](MONITORING.md#runtime-specific-log-discovery) for
   available request context and provider acceptance. Use the provider's approved delivery
   and billing reports for recipient delivery, send volumes, and charges.
4. Keep evaluation and live evidence separate. Both EPP request modes can return HTTP 200.
   `SigninLogs` has no guaranteed EPP delivery-mode, provider-attribution, phone-delivery,
   or provider-cost field. An endpoint evaluation is not guaranteed to create a user
   sign-in record. Do not interpret a sign-in chart as a delivery test.

## 1. Choose the tenant and permissions

1. Identify the tenant where **user authentication** takes place. In the
   [Microsoft Entra admin center](https://entra.microsoft.com), use **Settings >
   Directories + subscriptions** to select it, then open its **Overview** and record the
   **Tenant ID** privately. Do not assume this is the Function-hosting tenant.
2. Confirm whether this is a **workforce tenant**, including B2B guests, or an **external
   tenant** for consumer/business-customer apps. Use the
   [tenant feature comparison](https://learn.microsoft.com/en-us/entra/external-id/customers/concept-supported-features-customers)
   with your tenant administrator. The export setup and feature availability differ.
3. Open **Entra ID > Monitoring & health > Sign-in logs** and select an existing,
   approved sign-in for the application you intend to monitor. In **Basic info**, check
   **Application**, **Application ID**, **Resource**, the outcome, and time. The
   [illustrated activity-details guide](https://learn.microsoft.com/en-us/entra/identity/monitoring-health/concept-sign-in-log-activity-details#basic-info)
   explains these fields. Record the application's **client ID**, not its Object ID.
   It is not necessarily the endpoint `applicationId` in the EPP deployment summary.
   Record the displayed time zone and convert investigation times to UTC when comparing sources.
4. Choose the destination **subscription, resource group, workspace, and region** with
   the Azure operator and privacy/cost owners. Check for an existing approved destination
   before requesting another one. Keeping Entra logs with Function telemetry is an
   operator decision, not an automatic consequence of guided EPP setup.
5. For a **workforce tenant**, check the
   [integration prerequisites](https://learn.microsoft.com/en-us/entra/identity/monitoring-health/howto-integrate-activity-logs-with-azure-monitor-logs#prerequisites).
   General diagnostic settings require at least **Security Administrator** in the Entra
   tenant, an Azure subscription, a prepared Log Analytics workspace, and appropriate
   Azure access to the destination. If no workspace is approved yet, have the Azure operator
   follow the [workspace creation instructions](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/quick-create-workspace).
6. For an **external tenant**, open the
   [illustrated external-tenant setup guide](https://learn.microsoft.com/en-us/entra/external-id/customers/how-to-azure-monitor#prerequisites).
   An external tenant cannot have an associated Azure subscription. The documented setup
   uses the subscription in a **workforce tenant** and an Azure Lighthouse access path.
   Arrange Azure RBAC **Owner** on that subscription and **Security Administrator or
   Application Administrator** in the external tenant for the wizard. Users who configure
   diagnostic settings still need at least **Security Administrator**. Do not move the
   EPP subscription or change policy to imitate workforce setup.
7. Arrange read access separately. **Reports Reader** is the least privileged Entra role
   for activity-log access in the admin center; see
   [access requirements](https://learn.microsoft.com/en-us/entra/identity/monitoring-health/howto-access-activity-logs#prerequisites).
   It does not grant Azure log access. Have the access owner review
   [workspace/table permissions](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/manage-access)
   and grant appropriately scoped query access, such as **Log Analytics Reader**.
   Confirm the investigator can open the chosen workspace's **Logs** without an access error.
8. Verify licensing before selecting premium reports. Current
   [monitoring licensing guidance](https://learn.microsoft.com/en-us/entra/fundamentals/licensing#microsoft-entra-monitoring-and-health)
   lists sign-in and audit logs for Entra ID Free as well as P1/P2. That does not imply
   entitlement to every Graph API, risk report, or Workbook feature. Azure collection,
   retention, queries, alert evaluation, and notifications can incur separate charges.
9. Confirm whether risk reporting is actually available. The current
   [external-tenant comparison](https://learn.microsoft.com/en-us/entra/external-id/customers/concept-supported-features-customers#general-feature-comparison)
   lists **Microsoft Entra ID Protection as unavailable in external tenants**. In supported
   workforce tenants, full [ID Protection capabilities](https://learn.microsoft.com/en-us/entra/id-protection/overview-identity-protection#license-requirements)
   require P2 or an applicable entitlement. Do not purchase workforce P2 expecting it to
   enable external-tenant risk detections, or read empty/hidden risk values as fraud clearance.
10. Confirm this step is complete: the private inventory identifies the **source tenant
    and type, customer app client ID, destination workspace resource ID, access owners,
    query operator, alert operator, and security responder**. Stop before export if the
    scope, destination approval, or required access is unresolved.

## 2. Export the required log categories

### Prepare the external-tenant access path

1. If monitoring a **workforce tenant**, skip this subsection. If an external tenant is
   already integrated, review its existing destination/access with the owner rather than
   rerunning setup. Otherwise, open **Entra ID > Monitoring & health > Diagnostic settings**
   in the external tenant and select **Start set up**.
2. Follow the official
   [wizard screenshots and instructions](https://learn.microsoft.com/en-us/entra/external-id/customers/how-to-azure-monitor#set-up-the-azure-lighthouse-configuration-in-the-wizard).
   Sign in to the **workforce tenant** for the approved subscription. Select the subscription
   and resource group, specify the workspace name and region, and select **Next**.
3. In **Select user access**, choose only approved external-tenant users/groups and their
   documented Azure roles. Review the delegation and permissions with the access owner.
   The wizard's roles are not a grant of all alert-management or role-assignment permissions.
4. At **Review and create**, confirm destination, region, users/groups, roles, and charges.
   Select **Create** only after approval. Wait for confirmation, select **Done**, and
   proceed to diagnostic settings. Retain the destination identifiers privately.

### Select and save the export

1. In the **source tenant's** Entra admin center, open **Entra ID > Monitoring & health >
   Diagnostic settings**. For the matching illustrated screen, use
   [access diagnostic settings](https://learn.microsoft.com/en-us/entra/identity/monitoring-health/howto-configure-diagnostic-settings#how-to-access-diagnostic-settings).
   Review existing settings and their owners before adding or editing an integration.

   ![Microsoft Entra admin center showing Monitoring and health, Diagnostic settings, and Add diagnostic setting highlighted](images/sign-in-monitoring/diagnostic-settings-start.png)

   *Official Microsoft Entra admin center example from
   [Microsoft's diagnostic-settings instructions](https://learn.microsoft.com/en-us/entra/identity/monitoring-health/howto-configure-diagnostic-settings#how-to-access-diagnostic-settings).
   Used with permission from Microsoft. This is not your tenant; menus and categories vary.
   Follow the numbered navigation above, not the example's breadcrumb. Visible risk categories
   do not establish that those features are available or licensed in an external tenant.*

2. Select **Add diagnostic setting**, or deliberately edit the owner-approved setting.
   Enter a recognizable name for a new setting. Select **SignInLogs** for interactive
   user authentication. Add **AuditLogs** only if directory-change investigation is also
   required; audit events are not sign-in outcomes.
3. Use the [category descriptions](https://learn.microsoft.com/en-us/entra/identity/monitoring-health/concept-diagnostic-settings-logs-options)
   to choose any further sources. Non-interactive user, service-principal, and managed-identity
   sign-ins are separate categories and populations. They use `AADNonInteractiveUserSignInLogs`,
   `AADServicePrincipalSignInLogs`, and `AADManagedIdentitySignInLogs`, respectively.
   Keep their baselines separate from interactive `SigninLogs`. Do not select every category
   just to make a chart populate.
4. Check the category picker in **your tenant**. A category description or workforce feature
   is not a promise of data in an external tenant. Selecting **SignInLogs** does not enable
   the separate **RiskyUsers** or **UserRiskEvents** categories. Provider-side OAuth evidence
   can reside in the provider's tenant and require its administrator's assistance.
5. Under **Destination details**, select **Send to Log Analytics workspace**, then choose
   the approved **Subscription** and **Log Analytics workspace**. For an external tenant,
   use the access path established above. Compare the selection with your private inventory.
   The [illustrated export instructions](https://learn.microsoft.com/en-us/entra/identity/monitoring-health/howto-integrate-activity-logs-with-azure-monitor-logs#send-logs-to-azure-monitor)
   show the category and destination controls.
6. Select **Save**, reopen the setting, and confirm its **selected categories and destination**.
   Record the export start time and configuration owner. This setting belongs to Entra,
   not the Function App; Function diagnostic settings/Application Insights do not perform
   this export. Do not expect a backfill of all historical portal sign-ins.
7. Confirm this step is complete: the saved setting points to the intended workspace
   and includes the intended sign-in category, with no unintended changes to another
   integration. Continue to record verification rather than assuming that Save proves arrival.

## 3. Confirm arrival and schema

1. Open **Azure portal > Log Analytics workspaces > the recorded destination > Logs**.
   For an external tenant's workforce-hosted workspace, switch to the subscription-owning
   directory as necessary. Check the workspace name/query scope before running anything.
   Use the [illustrated Logs scope tutorial](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/log-analytics-tutorial#open-log-analytics).
   Its demo environment is for learning controls, **not** verification of your tenant's data.
2. Select **Tables** in the left pane and find **SigninLogs**. Expand the table to inspect
   its columns and types, following
   [View table information](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/log-analytics-tutorial#view-table-information).
   That tutorial illustrates `AppRequests`; select **SigninLogs** in your workspace instead.
   Compare the actual columns with the official
   [SigninLogs schema](https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables/signinlogs#columns).
3. In the table's controls, use **Run** to preview records, or select it through
   [Simple mode > Select a table](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/log-analytics-simple-mode#get-started-in-simple-mode).
   Choose a **Time range** that covers activity after export was saved. Limit the displayed
   records and inspect them only within the approved access boundary; a preview can contain
   personal data. Do not use the Application Insights `requests`/`traces` context for Entra logs.
4. Allow for initial export delay. The
   [Microsoft External ID monitoring repository](https://github.com/microsoft/external-id-azure-monitor)
   describes about 45 minutes after setup, while the
   [general diagnostic-setting guidance](https://learn.microsoft.com/en-us/entra/identity/monitoring-health/howto-configure-diagnostic-settings#basic-process)
   allows up to three days for initial arrival. These are setup allowances, not a steady-state
   latency SLA. If no table/records appear, compare export start time, source tenant, destination,
   category, access, and expected portal sign-ins before escalating.
5. Expand a returned row using its **chevron**, as shown in
   [Expand and sort records](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/log-analytics-tutorial#expand-and-sort-records).
   Check `AADTenantId` and `AppId` against the source tenant and application's client ID.
   Do not substitute the app's Object ID, provider API ID, or workspace ID.
   The standard `TenantId` column is the **workspace ID**, not the source Entra tenant ID.
6. To narrow exploration without writing a new query, use **Simple mode > Add > column filter**
   for `AADTenantId` and `AppId`, then enter/select your verified IDs. See the illustrated
   [column-filter instructions](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/log-analytics-simple-mode#filter-by-column).
   Apply source/app filters **before aggregation**. Switch to **KQL mode** and confirm the
   generated query contains them; a Results-grid search or column-header filter is not an
   enduring query/alert filter.
7. Check `ResultType`, `ResultDescription`, `CreatedDateTime`, and `TimeGenerated`.
   The schema defines `ResultType` as a **string**: zero indicates success, populated nonzero
   values are sign-in error/result codes, and missing/empty values need investigation.
   These are not provider/Function HTTP statuses. Review the corresponding portal record's
   **Basic info** with the
   [sign-in error troubleshooting instructions](https://learn.microsoft.com/en-us/entra/identity/monitoring-health/howto-troubleshoot-sign-in-errors).
8. Check time semantics before selecting alert windows. `CreatedDateTime` is sign-in
   initiation time in UTC; `TimeGenerated` is the log timestamp used for workspace time filters.
   Have the query operator use the existing
   [ingestion-latency reference](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/data-ingestion-time)
   and [standard-column timing guidance](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/log-standard-columns#_timereceived-column)
   to measure arrival delay against **SigninLogs**, with your tenant/app scope. Those references
   are generic, not a ready-made Entra latency monitor. Record the measured delay and any
   missing timestamps; do not confuse ingestion time with authentication or delivery latency.
9. Confirm this step is complete: actual records identify the intended source tenant/app,
   their fields/types match the reference, and the operator knows their time range and arrival
   delay. An unresolved table is a collection/access problem, not a healthy empty result.
   If a table exists but the scope is empty, compare with **Entra > Sign-in logs**, inspect
   collection transformations and ingestion limits with the owner, and resolve the gap first.

### Inspect authentication steps safely

1. For an existing relevant sign-in, open **Entra ID > Monitoring & health > Sign-in logs >
   selected record > Authentication Details**. Use the official
   [Authentication Details screenshot and explanation](https://learn.microsoft.com/en-us/entra/identity/monitoring-health/concept-sign-in-log-activity-details#authentication-details)
   to read the step sequence, method, outcome, and policy context.

   ![Microsoft Entra ID sign-in Activity Details with Authentication Details selected and two Previously satisfied steps marked true](images/sign-in-monitoring/sign-in-activity-details-authentication.png)

   *Official Microsoft Entra ID example from
   [Microsoft's sign-in activity-details instructions](https://learn.microsoft.com/en-us/entra/identity/monitoring-health/concept-sign-in-log-activity-details#authentication-details).
   Used with permission from Microsoft. This is not your sign-in or a delivery test.
   The example's Previously satisfied outcomes do not prove a new phone challenge or
   provider send. Your methods, policy results, timestamps, and portal layout can differ.*

2. Check whether the step was satisfied by an existing token claim or a previous
   authentication. A method named SMS/Voice is not a provider ID or delivery receipt.
   Keep the sign-in's overall outcome separate from an individual step's outcome.
3. For an existing shared method report, review the official
   [MFA Workbook template](https://github.com/microsoft/external-id-azure-monitor/blob/main/templates/mfaWorkbookDeployment.json)
   with the query operator. Its current queries use **AuditLogs**, not `SigninLogs`
   authentication-step arrays. They need the corresponding export and recorded audit activity;
   do not replace the table name or treat that report as the full sign-in step sequence.
   For a `SigninLogs` step report, have the operator review the actual `AuthenticationDetails`
   column separately: it is documented as a string containing step data, not a top-level
   dynamic object. An adapted query must handle the parsed array shape, empty/invalid/missing
   data, and nullable step outcomes explicitly.
4. Check the adapted report for coverage gaps and labels. Expanding an array counts
   **authentication steps**, not sign-ins. Missing steps do not establish success or failure.
   Keep `authenticationMethodDetail` and full raw payloads out of shared reports; they can
   include phone identifiers or other personal data.
5. Confirm this check is complete only after a report's displayed methods/outcomes agree
   with selected portal records, without claiming provider attribution or recipient delivery.

## 4. Establish the baseline

1. Open the official [SigninLogs query collection](https://learn.microsoft.com/en-us/azure/azure-monitor/reference/queries/signinlogs).
   Choose the relevant named query rather than copying an unrelated tutorial's table:
   **Failed Signin reasons** for result-code distribution, **Failed login Count** for
   failure counts by resource, or **Signin Locations** for successful/failed counts by location.
   The customer-facing app, source tenant, time window, and thresholds are **not preconfigured**
   for your deployment in these examples.
2. In your workspace's **Logs**, switch to **KQL mode**. Copy the selected query from its
   official source into the editor. Alternatively, use the **Queries** pane if that query
   is available there. Add your verified `AADTenantId`/`AppId` scope **before summarizing**,
   following the [filtering tutorial](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/log-analytics-tutorial#apply-multiple-query-filters).
   Have the query operator review edits if unfamiliar with KQL; do not run tenant-wide
   results as if they describe one customer app.
3. Compare the query with the **actual string type of `ResultType`**. The official collection
   includes examples with numeric-looking comparisons; the operator must ensure the chosen
   comparison matches the documented type and separately handles empty/missing codes.
   Read nonzero result codes in their authentication context, not as incorrect OTPs by default.
   The catalog also includes user names/identifiers in some outputs and a **Failed MFA challenge**
   query limited to one code. Review purpose and privacy: it is not a complete MFA/CYOT failure
   detector. Remove unnecessary personal fields before sharing a saved report.
4. Choose a representative business cycle using **Time range** and any query time filter.
   Include peak/quiet hours, releases, and approved tests. Use the illustrated
   [time-range controls](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/log-analytics-tutorial#set-the-query-time-range).
   Confirm the effective range on rerun, not just the picker label.
5. Select **Run**. Inspect **Results** and, where helpful, **Chart**. Identify the output's
   numeric count column and grouping; do not confuse the number of summary rows displayed
   with the number of sign-in records counted. The **Show** limit can cap displayed results.
   Avoid treating a truncated preview or browser-side grouping as a complete baseline.
6. Record privately the chosen source query, scoped saved version, output column/grouping,
   usual volumes, non-success codes, unknown-data coverage, peak conditions, and observed
   ingestion delay. Distinct-user, record-count, and authentication-step measures are different;
   several log records can belong to one authentication sequence.
7. Agree with the response owner which change should notify someone and what they will
   investigate. Choose thresholds from the measured baseline, with appropriate minimum
   traffic for rate rules and quiet-hour/maintenance expectations. **No universal threshold
   or prebuilt fraud verdict is supplied here.** Do not assume the official count queries
   calculate a failure percentage, detect source-IP abuse, or implement a freshness check.
8. Select **Save > Save as query**, following
   [saving Azure Monitor queries](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/save-query).
   Enter the name and select the approved subscription/query pack; review the proposed default
   pack rather than silently creating a new resource. The documented save permission is
   **Log Analytics Contributor**; an authorized saver may need to perform this step for a
   read-only investigator. Record its approved location and who can read it.
   Confirm a second authorized operator
   can reopen it and obtain the same scope and output shape before using it in a rule.

## 5. Create actionable log search alerts

### A. Elevated non-success rate

1. Begin with [Failed Signin reasons](https://learn.microsoft.com/en-us/azure/azure-monitor/reference/queries/signinlogs#failed-signin-reasons)
   to review **which result codes changed**. Use a reviewed failure-count rule first if that
   meets the requirement; this official query is not a complete failure-rate alert.
2. If a **rate** rule is needed, have the query operator adapt a saved query to return
   failures and the corresponding total for the **same tenant, app, population, and window**,
   with agreed handling of unknown codes and minimum traffic. Review healthy/empty windows
   and denominator coverage before choosing the alert's numeric percentage column.
3. Document exclusions and monitor them separately. Non-success results can include
   interruptions, cancellation, and policy rejection. Assign authentication-support triage,
   not automatic phone-provider outage classification.

### B. Unusual sign-in volume

1. Review the [authentication Workbook template](https://github.com/microsoft/external-id-azure-monitor/blob/main/templates/authenticationsWorkbookDeployment.json)
   for existing sign-in traffic visualizations and query definitions. Treat it as source to
   review, **not** an instruction to deploy the entire template.
2. Have the query operator select/adapt the relevant traffic query and verify the output is
   a record count for the intended `SigninLogs` tenant/app/time window. The official
   **User count per Application** query counts distinct users, not total sign-in records;
   do not substitute that measure without changing the monitoring objective.
3. Set a volume limit from the agreed baseline and routing capacity. Investigate campaigns,
   releases, clients, retries, and collection changes as possible causes. Sign-in volume is
   **not OTP-send volume, SMS-pumping evidence, or provider spend**.

### C. Potential abuse from a source IP

1. Use [Signin Locations](https://learn.microsoft.com/en-us/azure/azure-monitor/reference/queries/signinlogs#signin-locations)
   and the [user-behavior Workbook template](https://github.com/microsoft/external-id-azure-monitor/blob/main/templates/userBehaviourWorkbookDeployment.json)
   as investigation starting points. Neither is a ready-made source-IP fraud alert for EPP.
2. If a restricted IP-based rule is justified, have the security/query owner review actual
   `IPAddress`, `UserId`, and `ResultType` population and design the grouped query/threshold
   for the approved tenant/app. Check unknown users, absent IPs, approximate distinct counts,
   distributed attempts, and expected shared-network activity before publishing it.
3. Restrict IP-bearing results and notifications to the security team. NAT, VPNs, mobile
   networks, and proxies can cause false positives; IP geolocation does not prove a person's
   location. Do not automate blocking, disable a provider/account, or change authentication
   policy solely on a volume/IP heuristic.
4. Where licensed workforce ID Protection is supported, use its
   [risk investigation instructions](https://learn.microsoft.com/en-us/entra/id-protection/howto-identity-protection-investigate-risk)
   with the security owner. Check actual `RiskLevelDuringSignIn`, `RiskLevelAggregated`,
   `RiskState`, and `RiskDetail` where available. Findings can arrive asynchronously;
   empty, none, or hidden values do not clear fraud. Do not promise these detections
   in an external tenant because a template is named "risk detection."

### Configure the rule in the portal

1. Have the alert operator confirm **read access to the workspace**, **write access to
   the rule's resource group**, and **read access to the action group**, using the
   [official alert prerequisites](https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/alerts-create-log-alert-rule#prerequisites).
   Creating an action group or assigning roles needs separate permissions.
   External-tenant operators must use approved Azure RBAC in the subscription-owning
   workforce tenant; Entra roles or Lighthouse delegation alone do not grant every operation.
2. Open **Azure portal > Monitor > Alerts > Create > Alert rule**. On **Scope**, choose
   the verified **Log Analytics workspace** and select **Apply**, not the Function App or
   app registration. Compare with the
   [illustrated scope screen](https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/alerts-create-log-alert-rule#configure-the-scope-of-the-alert-rule).
3. On **Condition**, select **Custom log search**. Paste the approved **scoped saved query**
   selected above. Select **Run**, inspect **Preview**, then **Continue Editing Alert**.
   Use the [illustrated condition/measurement instructions](https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/alerts-create-log-alert-rule#configure-alert-rule-conditions).
   Use a scheduled **log search alert**, not an Azure Activity Log alert. Check the workspace's
   **Tables** settings for the table plan; confirm the selected plan supports the query/rule.
4. Set **Measurement** to match the verified output. For unsummarized matching event rows,
   use **Table rows** with **Total** to count those rows. For an official summarized query
   such as **Failed Signin reasons**, use **Calculation of a numeric column**, select its
   verified count column (`Count` in that source query), and choose the aggregation/grouping
   that matches your objective.
   Summing count groups is different from taking the maximum group; agree which is intended.
   A rate query requires the reviewed numeric rate column. Do not count summary rows
   as failures or assume the wizard's automatically detected measurement is correct.
5. On **Alert logic**, select **Static** for an initial baseline-derived rule. Enter the
   approved **Operator** and **Threshold value**, checking units against the query output.
   Only use a returned-row/greater-than-zero condition when the approved query itself
   deliberately returns **qualifying incidents**, not an unconditional summary. Do not
   apply that setting blindly to Microsoft's count examples.
6. Set **Aggregation granularity (window size)** and **Frequency of evaluation** from the
   recorded observation window, normal ingestion delay, response needs, and budget.
   Record the actual selected values with the rule. A frequent evaluation is not proof of
   fresh data; overlapping windows can observe the same records repeatedly.
7. In **Advanced options**, review **Override query time range** and any query time filter
   together. Ensure the rule scans the data required by its approved calculation, including
   any deliberately delayed observation window. Alert queries scan at most **48 hours**;
   a longer baseline query is not automatically a valid scheduled rule. One-minute evaluation
   has extra query restrictions, including `ingestion_time()`; consult the official reference
   before selecting it. A time picker used during exploration is not a stored rule setting.
8. Decide **Number of violations to trigger the alert** with the owner. If using several
   violating evaluations, check the query's required datetime output and evaluation period
   against the official instructions. Inspect the **Preview** for healthy and qualifying
   periods. Do not assume missing data is a healthy evaluation.
9. Leave **Split by dimensions** unset unless separate incidents are required and reviewed.
   Adding app/IP/user dimensions changes grouping, incident count, cost, and exposed data.
   Avoid volatile/high-cardinality request, correlation, and user identifiers. A workspace-scoped
   alert without dimensions is a workspace incident; document the app/scope in its runbook.
10. On **Actions**, select an approved action group or select **Create action group**.
    Follow the [illustrated action-group creation instructions](https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/action-groups#create-in-the-azure-portal).
    Confirm subscription/resource group, name, processing region, and notification recipients.
    For a new group, complete **Basics**, then **Notifications** with the approved type,
    recipient, and applicable **Common alert schema** setting. Review any **Actions**, then
    select **Review + create > Create** and return to the rule to select the saved group.
    Use approved email/push or incident routing, complete required recipient verification,
    and keep security results on a restricted route. Do not attach an automated policy-change
    action to an unvalidated heuristic.
11. On **Details**, select the **Subscription**, **Resource group**, **Region**, and agreed
    **Severity**. Enter an **Alert rule name** and **Description** identifying source tenant,
    app, measure/units, threshold rationale, window, owner, and runbook. Use
    [the illustrated Details and Identity screen](https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/alerts-create-log-alert-rule#configure-alert-rule-details).
12. Select the approved **Identity** for query evaluation. A **system-assigned managed
    identity** has no permissions initially: create the rule with **Enable upon creation**
    cleared, then have the access owner grant its identity reader/query access to the
    workspace through **Workspace > Access control (IAM)**. Allow role propagation before
    enabling it. If using a **user-assigned identity**, authorize it before selection.
    For **None**, record that query permissions follow the last editor. Check linked-storage
    policy requirements and identity restrictions in the official reference before choosing.
13. Review **Automatically resolve alerts** for stateful behavior and **Mute actions**
    where appropriate. Resolution timing depends on evaluation frequency; it is not immediate.
    Confirm the owner understands when repeated notifications will be suppressed.
14. Select **Review + create** only after checking scope, query, measured units, time settings,
    permissions, actions, and costs. Keep the initial rule disabled until its identity and
    [validation checks](#validate-without-generating-provider-sends) are ready. To change it,
    use **Monitor > Alerts > Alert rules > selected rule > Edit**.

### Monitor ingestion separately

1. Assign a collection owner independently of the failure/volume responder. Quiet alerts
   can mean broken export, not healthy authentication. Review the
   [log-alert guidance on missing data](https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/alerts-types#log-alerts)
   before designing a freshness rule.
2. Record whether the source app should have regular traffic, including quiet hours and
   maintenance. Compare **Entra > Sign-in logs** with the workspace after the measured delay.
   No user activity and stopped collection can look identical; do not enable staleness paging
   for an idle app without a documented expectation.
3. Have the query operator adapt the official
   [ingestion-time/latency guidance](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/data-ingestion-time)
   into a separate scoped freshness check. Require explicit handling of **no matching rows,
   missing ingestion time, and stale latest arrival**, and verify each case. The linked
   reference is not a preconfigured Entra no-data alert. Do not hide an unresolved table or
   query error behind an empty-success fallback.
4. Create a separate rule using the same portal workflow, with its own freshness measure,
   threshold, lookback, frequency, action group, and owner. Match its **Override query time
   range** to the freshness calculation, not blindly to the aggregation window. Confirm
   frequency supports the query; ingestion-time functions are restricted at one-minute frequency.
5. Check **Monitor > Alerts > Alert rules**, the selected rule's health/errors and associated
   alerts, and the workspace's collection settings. Permission/query failures must be resolved
   separately from a stale-data incident. Inspect transformations, ingestion limits, and service
   health with the owner; do not infer reduced abuse from missing evidence.

### Validate without generating provider sends

1. Open the selected action group and use **Test**, following the official
   [action-group testing instructions](https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/action-groups#test-an-action-group-in-the-azure-portal).
   Save the group first. Choose the test's alert type and approved notification/action
   receivers, then select **Test** and keep the test page open until **Success** or **Failed**
   appears. On failure, use **View details**, resolve the error, save, and retest.
   Confirm the intended recipients actually receive it, including verification and
   spam-filter checks; access to read a group alone does not grant test permission.
   This tests notification routing, not log export or query evaluation.
2. Run the saved scoped query against existing approved records and compare it with the
   associated Entra sign-ins. Check a healthy window, a qualifying window, an empty scope,
   and known ingestion delay. Confirm output shape/units agree with the rule's Measurement.
3. For an end-to-end check, create a **temporary nonproduction rule** with a restricted
   test action group. Use existing records within its lookback and an approved temporary
   condition that they satisfy. If changing the query time filter, update the rule's
   **Override query time range** consistently and stay within the alert scan limit.
   Do not lower a production threshold or route a test to production incident automation.
4. Authorize the test rule's evaluation identity and enable it. Observe a scheduled
   evaluation and notification in **Monitor > Alerts**; record rule name, UTC time, measured
   value, recipients, and investigation context. A successful interactive query under your
   own identity does not prove the rule identity can read the workspace.
5. Verify resolution when the test condition clears, allowing for stateful resolution timing.
   Disable/delete the temporary rule and remove temporary overrides. Reopen the intended
   rule to confirm its approved query, threshold, time settings, recipients, and enablement.
6. If records are insufficient, use only an approved **non-phone test sign-in flow** in a
   test tenant/app. Do not induce repeated wrong OTPs, alter production policy, bypass Easy Auth,
   or send live OTPs just to populate a report. An EPP evaluation does not validate delivery
   and is not guaranteed to create `SigninLogs` records.
7. Confirm validation is complete only after customer operators verify actual collection,
   saved-query behavior, scheduled identity access, notification receipt, and cleanup.
   This documentation has not executed Azure/Kusto queries or created/tested a customer's rule.

## 6. Build a sign-in Workbook

1. Open the [Microsoft External ID monitoring repository](https://github.com/microsoft/external-id-azure-monitor)
   and review its setup instructions. Inspect the relevant
   [authentication](https://github.com/microsoft/external-id-azure-monitor/blob/main/templates/authenticationsWorkbookDeployment.json),
   [MFA](https://github.com/microsoft/external-id-azure-monitor/blob/main/templates/mfaWorkbookDeployment.json),
   or [user-behavior](https://github.com/microsoft/external-id-azure-monitor/blob/main/templates/userBehaviourWorkbookDeployment.json)
   template for existing queries and visualizations. Do not select **Deploy to Azure**
   just to view a query; templates can create resources/delegation and require separate approval.
   In the GitHub file view, inspect the workbook's **serializedData** and its query definitions
   with the query operator. These files are ARM deployment templates, not text to paste in full
   into Logs; extract/review only the needed query or use an already-approved deployed Workbook.
2. Check each chosen query's tables, tenant features, workspace/app filters, time settings,
   personal-data fields, and units against your actual records. A template named
   [risk detection](https://github.com/microsoft/external-id-azure-monitor/blob/main/templates/riskDetectionWorkbookDeployment.json)
   does not make ID Protection available in an external tenant.
3. In **Azure portal > Monitor > Workbooks**, select **New** or an empty template and enter
   **Edit** mode. Follow the
   [illustrated Workbook authoring guide](https://learn.microsoft.com/en-us/azure/azure-monitor/visualize/workbooks-create-workbook).
   Select **Add > Add query**, choose **Logs (Analytics)** and the verified workspace,
   then use the approved saved/query-source content.
4. Select a **Visualization** matching the output, then **Run Query**. Use counts/result-code
   grids for breakdowns and a time chart only for a query with the appropriate time-series
   output. Check actual scope/time/units before selecting **Done editing**; the
   [Add queries instructions](https://learn.microsoft.com/en-us/azure/azure-monitor/visualize/workbooks-create-workbook#add-queries)
   show the relevant controls.
5. Add text identifying source tenant/app, intended measure, arrival-delay expectations,
   unknown/missing-data interpretation, and response owner. Label stored sign-in records
   and authentication steps distinctly; an empty chart is not a healthy result.
   Include the separately reviewed freshness view.
6. If adding app/workspace/time parameters, bind them into **every relevant query** and
   verify that changing them changes the data as intended. A Workbook selector does not
   override a hard-coded filter automatically. Keep detailed IP/user-level views restricted.
7. Select **Save** and choose the approved subscription, resource group, location, and name.
   Have another authorized operator open it and verify access and scope. Sharing a Workbook
   does not grant access to the underlying logs. Workbooks visualize data; they do **not**
   create the scheduled alerts above or prove those alerts are enabled.

## 7. Triage, privacy, retention, and costs

1. When notified, open **Monitor > Alerts > selected alert** and confirm rule name,
   workspace, tenant/app scope, UTC window, measured value, and rule/collection health.
   Open the approved saved query for that period, then inspect the related Entra sign-in's
   **Basic info**, **Authentication Details**, and applicable policy results.
2. Review changed result codes with the identity-support owner. Separate user
   mistakes/interruptions, application releases, and policy changes from infrastructure
   failures or potential abuse. Escalate suspected compromise through the organization's
   security response process; a heuristic notification is not a confirmed fraud verdict.
3. If phone delivery is implicated, follow the existing
   [runtime-specific Function queries](MONITORING.md#runtime-specific-log-discovery).
   Compare UTC time, verified request context, failure stage, and provider outcome with
   restricted provider records. `SigninLogs.CorrelationId`, Function `OperationId`,
   request IDs, and provider references are **not guaranteed equal**. Prove any association
   in an approved trace before using a join. An absent match does not prove no Function call;
   fallback can also complete authentication through another path.
4. Keep personal data in approved systems. User IDs/names, IP/location/device details,
   sign-in identifiers, and authentication details can be sensitive. Review workspace/table
   access, Workbook sharing, and action-group recipients. Do not export raw records to public
   issues or put OTPs, message bodies, tokens, or credentials in alerts. Query filters are
   **not an access-control boundary**.
5. In **Log Analytics workspace > Tables**, select the relevant table and review its
   table plan, **analytics retention**, and **total retention** with the privacy/retention
   owner. Follow [retention configuration](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/data-retention-configure).
   Confirm the setting actually saved and allows the required investigation period.
   Entra portal retention and workspace retention are different.
6. Review **workspace Usage and estimated costs** and **Azure Cost Management > Cost analysis**
   for the approved subscription/resource scope, using the
   [log-cost guidance](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/cost-logs).
   Diagnostic export selects categories, not an app-specific stream: app query filters
   do not remove tenant-wide ingestion charges. Include retention, queries, alert frequency,
   dimension count, notifications, and any separately enabled services in budget review.
7. Inspect caps and transformations with the collection owner. They can remove evidence
   needed by a rule. Verify changes do not silently remove required fields/populations and
   update collection-health checks. Provider sending/billing remains a separate cost source.
8. Complete a restricted handover record with source tenant/app, workspace/export setting,
   saved queries, measured baseline/delay, Workbook, alert rule/identity, action group,
   thresholds/time settings, validation evidence, and collection/identity/security owners.
   Assign privacy, retention, and cost-review owners plus escalation/maintenance procedures.
9. Have the receiving operator confirm they can reopen the queries and Workbook, inspect
   rule health, receive an approved notification, and follow triage without generating
   provider sends or changing policy. Leave no temporary test overrides active. Handover
   is complete only after these **customer-side checks**, not merely publication of this guide.
