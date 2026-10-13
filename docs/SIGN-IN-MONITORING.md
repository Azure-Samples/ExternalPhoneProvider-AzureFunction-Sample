# Monitor Microsoft Entra sign-ins

Use this guide to find out why sign-ins fail, spot changes in traffic, and notify your team
when something needs attention. It covers **tenant identity monitoring**, separate
from [Function monitoring](MONITORING.md) and [Application Insights](APPLICATION-INSIGHTS.md).
EPP setup does **not** configure tenant log export, Workbooks, action groups, or sign-in alerts.
This guide does not deploy anything or change authentication policy.

Each section links to Microsoft's existing queries and portal instructions, so you can
start there and adapt them to your tenant rather than copy another set of examples.
Choose alert thresholds from your own traffic. Portal labels can vary.
The two Microsoft screenshots below are unaltered public documentation examples, not your
tenant or evidence of a configured EPP integration. Used with permission from Microsoft.
Their [source and license notices](images/sign-in-monitoring/NOTICE.txt) accompany the files.

1. Start with [the right tenant and access](#1-choose-the-tenant-and-permissions).
2. [Configure export](#2-export-the-required-log-categories) and
   [confirm actual records](#3-confirm-arrival-and-schema).
3. [Choose a query and measure your baseline](#4-establish-the-baseline) before
   [configuring notifications](#5-create-actionable-log-search-alerts).
4. [Build a Workbook for your team](#6-build-a-sign-in-workbook), then
   [plan investigation and handover](#7-triage-privacy-retention-and-costs).

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
3. Open **Entra ID > Monitoring & health > Sign-in logs** and select an existing sign-in
   you're authorized to inspect for the application you want to monitor. In **Basic info**, check
   **Application**, **Application ID**, **Resource**, the outcome, and time. The
   [illustrated activity-details guide](https://learn.microsoft.com/en-us/entra/identity/monitoring-health/concept-sign-in-log-activity-details#basic-info)
   explains these fields. Record the application's **client ID**, not its Object ID.
   It is not necessarily the endpoint `applicationId` in the EPP deployment summary.
   Note the displayed time zone; use UTC when comparing it with other logs.
4. Choose the destination **subscription, resource group, workspace, and region** with
   your Azure administrator and the people responsible for privacy and costs. An existing
   workspace may be suitable; check before creating another one. You can choose to keep
   Entra and Function logs together, but EPP setup does not make that connection for you.
5. For a **workforce tenant**, check the
   [integration prerequisites](https://learn.microsoft.com/en-us/entra/identity/monitoring-health/howto-integrate-activity-logs-with-azure-monitor-logs#prerequisites).
   General diagnostic settings require at least **Security Administrator** in the Entra
   tenant, an Azure subscription, a prepared Log Analytics workspace, and appropriate
   Azure access to the destination. If you still need a workspace, ask your Azure administrator
   to follow the [workspace creation instructions](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/quick-create-workspace).
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
   It does not grant Azure log access. Ask your Azure administrator to review
   [workspace/table permissions](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/manage-access)
   and grant appropriately scoped query access, such as **Log Analytics Reader**.
   Try opening the workspace's **Logs** with the account you'll use to investigate sign-ins.
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
10. Before continuing, keep a private note of the **tenant and type, app client ID, and
    workspace resource ID**. Agree who will maintain queries, configure alerts, and respond
    to security concerns. Resolve any missing access or workspace approval before exporting logs.

## 2. Export the required log categories

### Prepare the external-tenant access path

1. If monitoring a **workforce tenant**, skip this subsection. If an external tenant is
   already integrated, check its destination and access with the administrator rather than
   rerunning setup. Otherwise, open **Entra ID > Monitoring & health > Diagnostic settings**
   in the external tenant and select **Start set up**.
2. Follow the official
   [wizard screenshots and instructions](https://learn.microsoft.com/en-us/entra/external-id/customers/how-to-azure-monitor#set-up-the-azure-lighthouse-configuration-in-the-wizard).
   Sign in to the **workforce tenant** for the approved subscription. Select the subscription
   and resource group, specify the workspace name and region, and select **Next**.
3. In **Select user access**, choose the external-tenant users/groups who need access and
   the documented Azure roles agreed with your administrator. Review the delegation carefully.
   The wizard's roles are not a grant of all alert-management or role-assignment permissions.
4. At **Review and create**, confirm destination, region, users/groups, roles, and charges.
   Select **Create** only after approval. Wait for confirmation, select **Done**, and
   continue to diagnostic settings. Keep the destination identifiers with your setup notes.

### Select and save the export

1. In the **source tenant's** Entra admin center, open **Entra ID > Monitoring & health >
   Diagnostic settings**. If you need help finding the screen, see
   [access diagnostic settings](https://learn.microsoft.com/en-us/entra/identity/monitoring-health/howto-configure-diagnostic-settings#how-to-access-diagnostic-settings).
   Check existing settings first, and speak to whoever maintains them before making changes.

   ![Microsoft Entra admin center showing Monitoring and health, Diagnostic settings, and Add diagnostic setting highlighted](images/sign-in-monitoring/diagnostic-settings-start.png)

   *Official Microsoft Entra admin center example from
   [Microsoft's diagnostic-settings instructions](https://learn.microsoft.com/en-us/entra/identity/monitoring-health/howto-configure-diagnostic-settings#how-to-access-diagnostic-settings).
   Used with permission from Microsoft. This is not your tenant; menus and categories vary.
   Follow the numbered navigation above, not the example's breadcrumb. Visible risk categories
   do not establish that those features are available or licensed in an external tenant.*

2. Select **Add diagnostic setting**, or edit an existing setting if its maintainer has agreed.
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
   use the access set up above. Check the destination against your setup notes.
   The [illustrated export instructions](https://learn.microsoft.com/en-us/entra/identity/monitoring-health/howto-integrate-activity-logs-with-azure-monitor-logs#send-logs-to-azure-monitor)
   show the category and destination controls.
6. Select **Save**, reopen the setting, and confirm its **selected categories and destination**.
   Note when you enabled export and who maintains it. This setting belongs to Entra,
   not the Function App; Function diagnostic settings/Application Insights do not perform
   this export. Do not expect a backfill of all historical portal sign-ins.
7. Check that the setting still points to the right workspace and includes the sign-in
   category you selected, without changing another integration. Next, check for records:
   saving the setting alone doesn't tell you whether logs have arrived.

## 3. Confirm arrival and schema

1. Open **Azure portal > Log Analytics workspaces > your destination workspace > Logs**.
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
   records and use only an account authorized to read them; a preview can contain
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
   for `AADTenantId` and `AppId`, then enter/select the IDs you checked above. See the illustrated
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
8. Check which timestamps you're comparing before choosing alert windows. `CreatedDateTime`
   is sign-in initiation time in UTC; `TimeGenerated` is the timestamp used for workspace time filters.
   Work with whoever maintains your queries to use the
   [ingestion-latency reference](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/data-ingestion-time)
   and [standard-column timing guidance](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/log-standard-columns#_timereceived-column)
   to measure arrival delay against **SigninLogs**, with your tenant/app scope. Those references
   are generic, not a ready-made Entra latency monitor. Note the measured delay and any
   missing timestamps; do not confuse ingestion time with authentication or delivery latency.
9. You should now be able to find records for the right tenant and app, understand their
   fields, and allow for arrival delay. If the table can't be found, investigate collection
   and access rather than treating that as a healthy result. If the table exists but your
   app has no records, compare with **Entra > Sign-in logs** and ask the workspace administrator
   to check transformations and ingestion limits before you build alerts.

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
   with whoever maintains your queries. Its current queries use **AuditLogs**, not `SigninLogs`
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
5. Compare a few report entries with the corresponding portal records. The methods and
   outcomes should agree; use the report to understand authentication, not to prove delivery.

## 4. Establish the baseline

1. Open the official [SigninLogs query collection](https://learn.microsoft.com/en-us/azure/azure-monitor/reference/queries/signinlogs).
   Choose the relevant named query rather than copying an unrelated tutorial's table:
   **Failed Signin reasons** for result-code distribution, **Failed login Count** for
   failure counts by resource, or **Signin Locations** for successful/failed counts by location.
   You'll need to set your app, tenant, time window, and alert thresholds in these examples.
2. In your workspace's **Logs**, switch to **KQL mode**. Copy the selected query from its
   official source into the editor. Alternatively, use the **Queries** pane if that query
   is available there. Filter to your `AADTenantId` and `AppId` **before summarizing**,
   following the [filtering tutorial](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/log-analytics-tutorial#apply-multiple-query-filters).
   If you're new to KQL, ask someone familiar with it to review the edits. Don't read tenant-wide
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
6. Keep the query and your findings together: what it counts, how it groups results,
   normal and peak traffic, common non-success codes, missing data, and arrival delay.
   Distinct users, sign-in records, and authentication steps are different measures;
   several records can belong to one authentication sequence.
7. With the team receiving alerts, decide what change is worth a notification and what
   they would investigate. Base thresholds on this traffic, including a minimum volume
   for rate rules and allowances for quiet hours and maintenance. There isn't one useful
   threshold for every app. The official count queries don't automatically calculate a
   failure rate, detect source-IP abuse, or check collection freshness.
8. Select **Save > Save as query**, following
   [saving Azure Monitor queries](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/save-query).
   Enter the name and select the approved subscription/query pack; review the proposed default
   pack before creating a new resource. Saving requires **Log Analytics Contributor**;
   if you only have read access, ask someone with that permission to save it.
   Share its location with a teammate who has log access and check that they can reopen
   it with the same filters and result columns before you use it in a rule.

## 5. Create actionable log search alerts

### A. Elevated non-success rate

1. Begin with [Failed Signin reasons](https://learn.microsoft.com/en-us/azure/azure-monitor/reference/queries/signinlogs#failed-signin-reasons)
   to review **which result codes changed**. Use a reviewed failure-count rule first if that
   meets the requirement; this official query is not a complete failure-rate alert.
2. If you need a **rate** rule, work with your query maintainer to return
   failures and the corresponding total for the **same tenant, app, population, and window**,
   with agreed handling of unknown codes and minimum traffic. Review healthy/empty windows
   and denominator coverage before choosing the alert's numeric percentage column.
3. Note any excluded codes and monitor them separately. Route these alerts to the team
   troubleshooting authentication; a change in non-success rate alone doesn't identify
   a phone-provider outage.

### B. Unusual sign-in volume

1. Review the [authentication Workbook template](https://github.com/microsoft/external-id-azure-monitor/blob/main/templates/authenticationsWorkbookDeployment.json)
   for existing sign-in traffic visualizations and query definitions. Treat it as source to
   review, **not** an instruction to deploy the entire template.
2. Choose a traffic query with your query maintainer and check that it returns
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
2. If an IP-based rule would help, ask your security team to review which `IPAddress`,
   `UserId`, and `ResultType` values are actually present and choose the grouping and
   threshold for your tenant/app. Check unknown users, absent IPs, approximate distinct counts,
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

1. The person creating the rule needs **read access to the workspace**, **write access to
   the rule's resource group**, and **read access to the action group**. Check the
   [official alert prerequisites](https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/alerts-create-log-alert-rule#prerequisites).
   Creating an action group or assigning roles needs separate permissions.
   External-tenant operators must use approved Azure RBAC in the subscription-owning
   workforce tenant; Entra roles or Lighthouse delegation alone do not grant every operation.
2. Open **Azure portal > Monitor > Alerts > Create > Alert rule**. On **Scope**, choose
   your destination **Log Analytics workspace** and select **Apply**, not the Function App or
   app registration. Compare with the
   [illustrated scope screen](https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/alerts-create-log-alert-rule#configure-the-scope-of-the-alert-rule).
3. On **Condition**, select **Custom log search**. Paste the **saved, app-scoped query**
   selected above. Select **Run**, inspect **Preview**, then **Continue Editing Alert**.
   Use the [illustrated condition/measurement instructions](https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/alerts-create-log-alert-rule#configure-alert-rule-conditions).
   Use a scheduled **log search alert**, not an Azure Activity Log alert. Check the workspace's
   **Tables** settings for the table plan; confirm the selected plan supports the query/rule.
4. Set **Measurement** to match what the query returns. For unsummarized matching event rows,
   use **Table rows** with **Total** to count those rows. For an official summarized query
   such as **Failed Signin reasons**, use **Calculation of a numeric column**, select its
   count column (`Count` in that source query), and choose the aggregation/grouping
   that matches your objective.
   Summing count groups is different from taking the maximum group; agree which is intended.
   A rate query requires the reviewed numeric rate column. Do not count summary rows
   as failures or assume the wizard's automatically detected measurement is correct.
5. On **Alert logic**, start with **Static** and the threshold you chose from your baseline.
   Set the **Operator** and **Threshold value**, checking the units against the query output.
   Only use a returned-row/greater-than-zero condition when the query itself
   deliberately returns **qualifying incidents**, not an unconditional summary. Do not
   apply that setting blindly to Microsoft's count examples.
6. Set **Aggregation granularity (window size)** and **Frequency of evaluation** from the
   observation window, normal ingestion delay, response needs, and budget.
   Keep these settings in your team's rule notes. A frequent evaluation is not proof of
   fresh data; overlapping windows can observe the same records repeatedly.
7. In **Advanced options**, review **Override query time range** and any query time filter
   together. Ensure the rule scans the data required by its approved calculation, including
   any deliberately delayed observation window. Alert queries scan at most **48 hours**;
   a longer baseline query is not automatically a valid scheduled rule. One-minute evaluation
   has extra query restrictions, including `ingestion_time()`; consult the official reference
   before selecting it. A time picker used during exploration is not a stored rule setting.
8. With your response team, set **Number of violations to trigger the alert**. If using
   several violating evaluations, check the query's required datetime output and evaluation period
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
12. Choose the **Identity** that will run the query. A **system-assigned managed
    identity** has no permissions initially: create the rule with **Enable upon creation**
    cleared, then ask your Azure administrator to grant that identity reader/query access to the
    workspace through **Workspace > Access control (IAM)**. Allow role propagation before
    enabling it. If using a **user-assigned identity**, authorize it before selection.
    For **None**, record that query permissions follow the last editor. Check linked-storage
    policy requirements and identity restrictions in the official reference before choosing.
13. Review **Automatically resolve alerts** for stateful behavior and **Mute actions**
    where appropriate. Resolution timing depends on evaluation frequency; it is not immediate.
    Make sure the receiving team knows when repeated notifications will be suppressed.
14. Select **Review + create** only after checking scope, query, measured units, time settings,
    permissions, actions, and costs. Keep the initial rule disabled until its identity and
    [validation checks](#validate-without-generating-provider-sends) are ready. To change it,
    use **Monitor > Alerts > Alert rules > selected rule > Edit**.

### Monitor ingestion separately

1. Decide who will check log collection as well as who responds to sign-in alerts.
   Quiet alerts can mean broken export, not healthy authentication. Review the
   [log-alert guidance on missing data](https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/alerts-types#log-alerts)
   before designing a freshness rule.
2. Work out when the app normally has traffic, including quiet hours and
   maintenance. Compare **Entra > Sign-in logs** with the workspace after the measured delay.
   No user activity and stopped collection can look identical; do not enable staleness paging
   for an idle app without a documented expectation.
3. Work with your query maintainer to adapt the
   [ingestion-time/latency guidance](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/data-ingestion-time)
   into a separate app-scoped freshness check. Test what happens with **no matching rows,
   missing ingestion time, and stale latest arrival**. The linked
   reference is not a preconfigured Entra no-data alert. Do not hide an unresolved table or
   query error behind an empty-success fallback.
4. Create a separate rule using the same portal workflow, with its own freshness measure,
   threshold, lookback, frequency, action group, and owner. Match its **Override query time
   range** to the freshness calculation, not blindly to the aggregation window. Confirm
   frequency supports the query; ingestion-time functions are restricted at one-minute frequency.
5. Check **Monitor > Alerts > Alert rules**, the selected rule's health/errors and associated
   alerts, and the workspace's collection settings. Permission/query failures must be resolved
   separately from a stale-data incident. Inspect transformations, ingestion limits, and service
   health with your workspace administrator; missing evidence doesn't mean less abuse.

### Validate without generating provider sends

1. Open the selected action group and use **Test**, following the official
   [action-group testing instructions](https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/action-groups#test-an-action-group-in-the-azure-portal).
   Save the group first. Choose the test's alert type and approved notification/action
   receivers, then select **Test** and keep the test page open until **Success** or **Failed**
   appears. On failure, use **View details**, resolve the error, save, and retest.
   Confirm the intended recipients actually receive it, including verification and
   spam-filter checks; access to read a group alone does not grant test permission.
   This tests notification routing, not log export or query evaluation.
2. Run the saved, app-scoped query against existing records you're authorized to inspect.
   Compare it with the associated Entra sign-ins. Check a healthy window, a qualifying window, an empty scope,
   and known ingestion delay. Confirm output shape/units agree with the rule's Measurement.
3. For an end-to-end check, create a **temporary nonproduction rule** with a restricted
   test action group. Use existing records within its lookback and an approved temporary
   condition that they satisfy. If changing the query time filter, update the rule's
   **Override query time range** consistently and stay within the alert scan limit.
   Do not lower a production threshold or route a test to production incident automation.
4. Authorize the test rule's evaluation identity and enable it. Observe a scheduled
   evaluation and notification in **Monitor > Alerts**. Keep the rule name, UTC time,
   measured value, and recipients so your team can check the result. A successful query
   under your own identity does not prove the rule identity can read the workspace.
5. Verify resolution when the test condition clears, allowing for stateful resolution timing.
   Disable/delete the temporary rule and remove temporary overrides. Reopen the intended
   rule to confirm its approved query, threshold, time settings, recipients, and enablement.
6. If records are insufficient, use only an approved **non-phone test sign-in flow** in a
   test tenant/app. Do not induce repeated wrong OTPs, alter production policy, bypass Easy Auth,
   or send live OTPs just to populate a report. An EPP evaluation does not validate delivery
   and is not guaranteed to create `SigninLogs` records.
7. Before enabling production notifications, check that logs arrive, the saved query works,
   the rule can read the workspace, and the right people receive the alert. Remove any
   leftover test settings. These checks need to happen in your environment; this guide
   hasn't run Azure/Kusto queries or created or tested your rules.

## 6. Build a sign-in Workbook

1. Open the [Microsoft External ID monitoring repository](https://github.com/microsoft/external-id-azure-monitor)
   and review its setup instructions. Inspect the relevant
   [authentication](https://github.com/microsoft/external-id-azure-monitor/blob/main/templates/authenticationsWorkbookDeployment.json),
   [MFA](https://github.com/microsoft/external-id-azure-monitor/blob/main/templates/mfaWorkbookDeployment.json),
   or [user-behavior](https://github.com/microsoft/external-id-azure-monitor/blob/main/templates/userBehaviourWorkbookDeployment.json)
   template for existing queries and visualizations. Do not select **Deploy to Azure**
   just to view a query; templates can create resources/delegation and require separate approval.
   In the GitHub file view, inspect the workbook's **serializedData** and its query definitions
   with your query maintainer. These files are ARM deployment templates, not text to paste in full
   into Logs; extract/review only the needed query or use an already-approved deployed Workbook.
2. Check each chosen query's tables, tenant features, workspace/app filters, time settings,
   personal-data fields, and units against your actual records. A template named
   [risk detection](https://github.com/microsoft/external-id-azure-monitor/blob/main/templates/riskDetectionWorkbookDeployment.json)
   does not make ID Protection available in an external tenant.
3. In **Azure portal > Monitor > Workbooks**, select **New** or an empty template and enter
   **Edit** mode. Follow the
   [illustrated Workbook authoring guide](https://learn.microsoft.com/en-us/azure/azure-monitor/visualize/workbooks-create-workbook).
   Select **Add > Add query**, choose **Logs (Analytics)** and the verified workspace,
   then use the query you reviewed and saved.
4. Select a **Visualization** matching the output, then **Run Query**. Use counts/result-code
   grids for breakdowns and a time chart only for a query with the appropriate time-series
   output. Check actual scope/time/units before selecting **Done editing**; the
   [Add queries instructions](https://learn.microsoft.com/en-us/azure/azure-monitor/visualize/workbooks-create-workbook#add-queries)
   show the relevant controls.
5. Add a short explanation of which tenant/app the view covers, what it counts, how long
   logs take to arrive, what missing data means, and who to contact. Label sign-in records
   and authentication steps distinctly; an empty chart is not a healthy result.
   Include the separately reviewed freshness view.
6. If adding app/workspace/time parameters, bind them into **every relevant query** and
   verify that changing them changes the data as intended. A Workbook selector does not
   override a hard-coded filter automatically. Keep detailed IP/user-level views restricted.
7. Select **Save** and choose the approved subscription, resource group, location, and name.
   Ask a teammate with log access to open it and check the filters. Sharing a Workbook
   does not grant access to the underlying logs. Workbooks visualize data; they do **not**
   create the scheduled alerts above or prove those alerts are enabled.

## 7. Triage, privacy, retention, and costs

1. When notified, open **Monitor > Alerts > selected alert** and confirm rule name,
   workspace, tenant/app scope, UTC window, measured value, and rule/collection health.
   Open the approved saved query for that period, then inspect the related Entra sign-in's
   **Basic info**, **Authentication Details**, and applicable policy results.
2. Review changed result codes with your identity-support team. Separate user
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
8. Put the setup notes somewhere your team can find them without exposing them publicly.
   Include the tenant/app, workspace and export setting, saved queries, normal traffic and
   arrival delay, Workbook, alert identity/settings, action group, and test results.
   Name the contacts for collection, identity support, security, privacy, retention, and costs,
   along with escalation and maintenance arrangements.
9. Walk a teammate through opening the queries and Workbook, checking rule health,
   receiving a test notification, and investigating an alert. They shouldn't need to send
   an OTP or change authentication policy to do this. Remove any remaining temporary test
   settings before handing over.
