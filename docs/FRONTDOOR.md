# Optional multi-region onboarding with Azure Front Door

Use Azure Front Door when you want **one public EPP URL backed by Function Apps in multiple regions**.
You can expand a supported JavaScript deployment with the [PowerShell setup below](#scripted-javascript-expansion),
or follow the manual steps for other configurations. For a single region, start with the
[main onboarding guide](../README.md).

The original `Setup-Epp.ps1` still creates one regional endpoint. The separate
[Setup-EppFrontDoor.ps1](../setup/Setup-EppFrontDoor.ps1) creates new regional copies behind Front Door
and leaves the source endpoint and authentication policy unchanged. Failover can still interrupt requests.

## Scripted JavaScript expansion

Run from a reviewed repository checkout. [frontdoor-regions.bicep](../setup/infra/frontdoor-regions.bicep)
reuses the existing [Function module](../setup/infra/resources.bicep); single-region defaults stay unchanged.
For operators, see [Application Insights queries](#application-insights-and-sample-queries) and
[monitoring setup](#monitoring-setup-for-operators).

### Supported source and prerequisites

| Requirement | Supported configuration |
|---|---|
| Tools | PowerShell **7.4+**, Azure CLI and Bicep, with an Azure user signed into the source tenant/subscription. Tools are not installed and the CLI default is not changed. |
| Source | **Linux JavaScript EP1**, private Blob run-from-package, system-assigned package identity. FC1, remote-build, Python, and .NET sources are rejected. |
| Caller trust | HTTPS Easy Auth, the selected tenant's issuer, a **v2 application-ID audience**, and a nonempty caller allowlist. Additional principal/claim restrictions are rejected, not dropped. |
| Certificate | Enabled, exportable RSA PEM certificate `phone-provider-encryption`. The source must pin its latest backing-secret version, with over 30 days remaining. No key rotation or registration is performed. |
| Permissions | Read source settings/package; back up its certificate and any provider secrets; deploy resources and scoped roles. No Graph or policy permissions are granted. |
| Regions | Two or three distinct regions in the **source vault's subscription and Azure geography**, with sufficient EP1 quota and all required services. |
| Provider | A supported API-key setup profile with credentials in the source certificate vault. OAuth federation is not automated. Use **`-EvaluationOnly`** for OAuth or unconfigured sources; it omits provider configuration and cannot deliver live messages. |

### Deploy

From the repository root:

```powershell
.\setup\Setup-EppFrontDoor.ps1 `
    -SubscriptionId '<subscription-id>' `
    -TenantId '<tenant-id>' `
    -SourceResourceGroup '<existing-epp-resource-group>' `
    -SourceFunctionApp '<existing-epp-function>' `
    -ResourcePrefix 'myfront' `
    -Locations @('centralus', 'westus2') `
    -EvaluationOnly
```

Replace the placeholders. The prefix must be 3-10 lowercase letters/digits, starting with a letter.
The script inspects the source and downloads its package before asking for approval. Review the plan
and charges, then type `Yes`. Unattended runs require both `-NonInteractive -ApproveDeployment`.

Setup creates Front Door Standard and **new regional copies**, leaving the source outside the origin
group. It adds opt-in readiness to a copy of the ZIP without changing delivery files or dependencies,
records both package hashes, and publishes identical bytes to private regional storage. Certificate
and API-key credentials use encrypted Key Vault backups; incompatible existing copies are not overwritten.

Before completing routes, setup checks authentication, ingress restrictions, Function registration,
and resolved key references. Outputs default to the ignored `artifacts/frontdoor` directory:
`frontdoor-state.json`, the public certificate, and the reviewed ZIP, never plaintext private keys
or provider credentials. Use `-OutputDirectory` for a different location and keep it out of source control.
Front Door initially returned 404 during our deployment's propagation. **Do not activate policy based
on ARM success alone.**

### Verify and resume

Deployment still requires **authenticated validation**. Obtain a token through your approved caller
process with the source's tenant, audience, and allowed caller, not a Function key or ARM token.

```powershell
$token = Read-Host 'Approved EPP caller access token' -AsSecureString
try {
    .\setup\Setup-EppFrontDoor.ps1 -Verify -AccessToken $token
}
finally {
    $token.Dispose()
}
```

`-Verify` tests the saved HTTPS endpoint on port 443 without changing Azure resources: two rejected-token checks and
three encrypted evaluations, with sanitized results and correlation IDs. It sends no SMS/voice,
stops no origins, and does not prove each origin participated. Run the
[per-origin and failover checks](#5-validate-before-manually-activating-policy) separately.

Resume with the **same source, arguments, prefix, and output directory**. For an earlier run, pass
its original `-OutputDirectory` explicitly rather than moving or recreating its state. Setup checks the saved
package and source/configuration fingerprint. Source changes require review. Atomic checkpoints
retain a `.previous` copy; inspect it and Azure state before recovering a damaged checkpoint.
Never delete state to bypass ownership checks.

Reruns can close **new-origin ingress** while republishing, so schedule maintenance for serving
deployments. Failures attempt to close every target origin, even if deployment failed before saving
regional outputs. Cleanup failures are reported without replacing the original deployment error.
Resources are not deleted and remain billable. The source endpoint and policy stay unchanged.

## Scope and observed behavior

We tested an isolated JavaScript deployment with Front Door Standard, two and three regional
origins, a shared encryption certificate, and a separate readiness handler that sends no messages.
The tests covered encrypted evaluation, invalid callers, direct-origin access restrictions, and
stopping and restarting individual Functions. Scripted expansion was tested in evaluation-only
mode in Central US and West US 2, including malformed/tampered requests, key/package continuity,
unchanged source settings, and resuming after an interrupted certificate restore.

The JavaScript readiness handler is included in this source revision and enabled only when
`EPP_FRONT_DOOR_HEALTH_ENABLED` is exactly `true`. The expansion script inserts it into the copied
source package before enabling it. An older release ZIP might not contain the handler, so setting
the flag alone is insufficient. Manual deployments must meet the
[readiness contract below](#3-provide-a-non-delivering-readiness-endpoint).
We haven't tested an equivalent .NET or Python handler.

We **did not test** provider-secret cloning, live SMS/voice delivery, OAuth federation, calls and
retries from the real Entra service, a full Azure regional outage, custom domains, WAF, Private Link,
or production load. Test the features your deployment needs before activating policy; the observed
failover results below are not a performance guarantee.

## Architecture: one URL, multiple origins

![Multi-region External Phone Provider architecture with Azure Front Door](images/multi-region-architecture.png)

The diagram shows the design, not the exact test deployment. Its region names are examples.
Custom domains and Premium/WAF are optional and weren't part of the Standard-tier test.
Give each Function App, storage account, and Key Vault a globally unique name. Each region also has
its own identity IDs and vault references. Keep the **provider and authentication configuration
consistent and use the same RSA key**, rather than copying every setting literally.
The SMS/voice arrows show live delivery. Evaluation returns the nonce without contacting the provider.

| Component | Purpose |
|---|---|
| Front Door profile and endpoint | Provide the single hostname used by the caller. One endpoint is sufficient for regional redundancy. |
| Route | Match `/api/SendOtp` and forward the request to the EPP origin group over HTTPS. |
| Origin group | Contain the regional Function hostnames and their health, priority, weight, and latency settings. |
| Regional origin | Run the same selected implementation and provider integration, with local storage, Key Vault, identity, and telemetry. |

The caller uses `https://<front-door-host>/api/SendOtp`, not a list of regional URLs.
Front Door chooses an origin based on health, priority, latency, and weight. Equal priorities
allow both origins to serve traffic. Equal weights do **not** guarantee a 50/50 split. Adding a third region
normally adds an **origin**, not another customer-facing endpoint.

## 1. Plan the regional deployment

Start in a dedicated nonproduction tenant and subscription. Review the
[setup prerequisites](../setup/docs/README.md#prerequisites-for-step-2) and
[regional quota guidance](../setup/docs/Troubleshooting.md#deployment-fails-with-subscriptionisoverquotaforsku).

- Start with two regions, based on service availability, capacity, residency, and the selected
  Security Store provider's requirements. A third region adds cost and capacity, but does not
  won't necessarily shorten failure detection.
- Check availability of **every** required resource type, not just EP1 quota. Hosting availability
  doesn't mean Application Insights or other dependencies are available there.
- Budget for an EP1 plan and regional dependencies in each region, Front Door, and telemetry.
  Keep enough warm capacity for the remaining origins to handle traffic during an outage.
- Choose one language and verify that each origin receives the same package. Do not mix
  implementations or package versions while measuring failover.
- Record the endpoint application's client ID, validated token audience and issuer, authorized
  caller application ID, certificate/public-key identity, selected provider route, and regional owners.
- Plan manual rollout, validation, certificate renewal, monitoring, and rollback before activation.

**Do not simply rerun `Setup-Epp.ps1` in another region against the same application.** It is a
single-region setup flow and does not coordinate Front Door, shared key material, regional
registrations, or failover. Independent certificate issuance or a setup rerun can change app
configuration or disable incoming access to an existing endpoint.

## 2. Prepare equivalent, independently provisioned origins

Create each regional Function App and its dependencies through your approved Azure process.
Keep public access disabled while setting up authentication, keys, identities, and packages.

1. Use the same endpoint application and validated issuer/audience/caller policy on every origin.
   Enable Easy Auth with `requireAuthentication=true`, `Return401`, and HTTPS required.
   Keep a nonempty `allowedApplications` list pinned to the authorized caller.
2. Retain the same [SendOtp contract](CONTRACT.md#1-http-api). Front Door must preserve the caller's
   `Authorization` header and encrypted request body. Its hostname is not automatically the token
   audience, and its profile ID is not the caller application's ID.
3. **Do not enable Front Door managed-identity origin authentication on this route.** That feature
   replaces the `Authorization` header. The original caller token must reach
   Easy Auth. Managed identity is still used by each Function for its own Azure dependencies.
4. Deploy the same package using private storage and managed-identity access. Keep SCM/basic
   publishing authentication protections in place; do not open administrative endpoints to bypass
   a deployment failure.
5. Configure the selected Security Store integration consistently in every region. Use each
   region's own credential vault and identities; complete provider consent or credential setup as
   required. If the integration uses managed-identity federation, configure trust for each regional
   outbound identity on the authorized client application; do not reuse another region's identity ID.
   Do not forward the incoming caller token to the provider.
6. Configure regional Application Insights/Log Analytics and verify ingestion. Avoid making a
   serving origin depend on another region's credential vault or package storage.

### Coordinate the encryption key

The caller must be able to encrypt once for any eligible origin. Every origin therefore needs the
**same RSA private key corresponding to the registered public certificate**. Front Door's HTTPS
certificate is separate from this JWE encryption certificate.

- Use an approved secure replication process. The test used Key Vault certificate backup/restore,
  which transfers an Azure-encrypted backup rather than a plaintext private key.
- Key Vault backup/restore is restricted to the **same subscription and Azure geography**. Do not
  assume it works across arbitrary subscriptions or geographies; obtain an approved alternative
  design if these constraints do not fit.
- Give each Function identity scoped access to its regional vault. Set `EPP_DECRYPTION_KEY_PEM`
  to the regional certificate's **versioned PEM backing-secret reference**.
- Verify that the public keys match and each region can decrypt a request. Matching vault names
  or secret-version strings alone doesn't prove this.
- Restored certificates are independent copies. They don't stay in sync automatically. Coordinate renewal
  and Entra updates across every origin using the [certificate lifecycle guidance](../setup/docs/README.md#encryption-certificate-lifecycle).
  That section explains the single-key constraints; apply the multi-region updates through an
  approved manual procedure, not independent setup reruns. The sample has one active decryption
  key; it does not implement overlapping multi-key rotation.
- Keep plaintext keys out of source, logs, tickets, and pipeline artifacts. Protect and remove
  temporary encrypted backups under your approved handling policy.

## 3. Provide a non-delivering readiness endpoint

Front Door's health probes do not carry the Entra caller token. Probing the protected `SendOtp`
endpoint would test authentication failure rather than application readiness.

Implement a separate route such as **`/api/health/ready`** with this contract:

- Support HTTPS `HEAD` and `GET`; return no response body for `HEAD`.
- Return `200` only when the handler is running and the configured RSA decryption key is at least
  2048 bits and usable with RSA-OAEP-256. Return a generic `503` when not ready.
- Do not send an OTP or call a phone provider. Do not return a nonce, keys, credentials, or detailed
  configuration. Use `Cache-Control: no-store`.
- If the route requires an Easy Auth exemption, exempt **only that exact readiness path**.
  Never exempt `/api/SendOtp`, `/api/*`, or the whole application.
- Keep the origin-level Front Door access restrictions described below on the readiness route too.

Readiness proves neither provider availability nor handset delivery. Validate those separately.
Do not point probes at a nonexistent handler, use a cached static `200`, or disable Easy Auth to
make probes succeed. Front Door treats only a `200` probe response as healthy.
If every origin is unhealthy, Front Door can still route requests across them. Keep authentication
and application failure handling effective independently of probe status.

## 4. Configure Front Door manually

In the Azure portal, create a Front Door Standard/Premium profile, an endpoint, and an origin group.
These are the **settings we tested**. Treat them as a starting point, not a performance guarantee:

| Setting | Tested value |
|---|---|
| Tier and domain | Standard, using its generated `azurefd.net` hostname |
| Origin hostnames | Each Function App's actual default hostname |
| Origin host header | That origin's Function hostname, not the Front Door hostname |
| Origin transport | HTTPS, port 443, certificate-name validation enabled |
| Origin priority and weight | Priority `1`, weight `1000` for every origin |
| Session affinity | Disabled |
| Health probe | HTTPS `HEAD` to the implemented `/api/health/ready` route |
| Probe interval | 30 seconds |
| Sample size / required successes | 4 / 3 |
| Additional latency | 50 milliseconds |
| Origin response timeout | 30 seconds; this is not the caller's OTP deadline |
| Route paths | `/api/SendOtp` and the implemented readiness path |
| Accepted/forwarding protocol | HTTPS only |
| Link to default domain | Enabled |
| Caching | Disabled |

Create the route under **Front Door manager**, associate it with the endpoint's domain, and select
the origin group. Inspect **Origin groups > your group > Origins** to see the regional backends.
You should see one public endpoint with several origins behind it.

Use the same request body and caller authorization end to end. Do not add header-replacement,
redirect, cache, or retry rules without separately validating their effect on authentication and OTP
delivery. A cached response cannot confirm a new delivery request. Front Door does not cache POST.

### Restrict each origin to this Front Door profile

Before allowing Front Door to reach the Functions, configure their access restrictions:

1. Allow the **`AzureFrontDoor.Backend` service tag** with an additional **`X-Azure-FDID`** header
   condition matching this profile's Front Door ID.
2. Set unmatched requests to **Deny**. Both the source restriction and header condition are
   required; the header alone can be spoofed.
3. Keep Easy Auth enabled for SendOtp. Restricting the network path does not authenticate the caller.
4. Open only the access needed by this public-origin design after the configuration is verified.
   A publicly resolvable hostname does not mean direct requests should be allowed.

Premium with Private Link is an alternative origin-security design, but was not tested here.
WAF policies and custom domains also need separate configuration and validation.

## 5. Validate before manually activating policy

Use an approved test caller and synthetic encrypted **evaluation** requests first. Check returned
nonces locally without writing them or request bodies to shared logs.

- Confirm all origins use matching package bytes, usable regional key references, and the intended
  Easy Auth issuer, audience, and caller restrictions.
- Direct origin requests must be denied, including requests with a spoofed `X-Azure-FDID`.
- Through Front Door, missing/invalid/wrong-audience tokens and unauthorized callers must fail.
  Send valid evaluation requests before and after testing an unauthorized caller. This confirms
  that the rejection came from access control, not a general outage.
- Valid encrypted evaluations must return the matching nonce. Malformed/tampered requests must
  not be accepted. Use safe correlation IDs and regional logs to confirm which origins handled requests.
- Send bounded continuous evaluation traffic **before, during, and after** a controlled test-origin
  outage. Keep the origin enabled in Front Door so the test checks automatic health-based routing,
  not manual removal.
- Record every failed response and transport error. Restore the origin even if testing fails, and
  verify that specific origin's readiness before testing another one. A shared readiness URL can
  succeed through a different origin.
- Correlate event timestamps, origin state, and client results. Do not use a delayed aggregate
  health-percentage graph to time recovery precisely.
- Separately test approved live SMS/voice delivery and caller behavior with the provider and EPP
  onboarding owner. Evaluation does not prove either.

Once these checks pass, have an **Authentication Policy Administrator** follow the
[supported activation procedure](../setup/docs/README.md#step-3---manually-validate-and-activate-policy),
using the Front Door SendOtp URL and endpoint application client ID. Save the previous policy first,
preserve unrelated properties, and read the policy back to confirm the change. This step is manual.

## Observed failover results and limitations

We stopped one Function App in these JavaScript tests, **not an entire Azure region**. One test
client in Central US sent encrypted evaluation requests without delivering messages. The first two
origins were in Central US and West US 2. The third was in West US 3.
We stopped the Central US Function after confirming it was serving requests. All trials used
a sample size of 4 with 3 successes required to consider an origin healthy.

| Origins | Probe interval | Failed requests in matched first 8 minutes | Sustained success after stop confirmation |
|---|---|---|---|
| 2 | 30 seconds | 32/478 (6.7%) | About 144 seconds |
| 2 | 10 seconds | 58/471 (12.3%) | About 154 seconds |
| 3 | 30 seconds | 33/462 (7.1%) | About 123 seconds |
| 3, repeat | 30 seconds | 32/460 (7.0%) | About 150 seconds |

Failures were mostly **HTTP 403**, with zero, one, two, and two transport errors respectively.
Transport errors were recorded as status `0`, which is not an HTTP status. No 5xx responses were
observed in these trials; a network or full-region outage can behave differently.

"Sustained success" means every sampled request after the last failure succeeded, with at least
30 seconds of successful traffic before we restarted the Function. We measured from when Azure
confirmed the stop, which may differ from when the Function actually stopped serving.
We aimed for one request per second, but slow responses and timeouts reduced the sample counts.
The test controller was interrupted during one three-origin trial, extending that outage while we
recovered it. To keep the comparison fair, the table uses only the first eight minutes of each outage.
We saw no failed samples before the outages or after restarting the Functions.

**This was not a complete Front Door outage, and it was not seamless failover.** Healthy origins
continued serving, but a 403 is still a failed request. A failed request is not guaranteed to be
replayed on another origin. The actual Entra caller's handling of these errors was not tested.

These trials didn't show a consistent benefit from 10-second probes or a third region.
More regions can add capacity and help tolerate additional failures, but they don't remove routing
delays, shared provider dependencies, or application faults. Faster probes generate more traffic
and can make brief problems trigger routing changes sooner. Decide how much disruption your
application can accept, then repeat the tests from your callers' locations and at your expected load.

Do not add blind retries to live sends: a timeout can occur after provider acceptance, and the sample
does not deduplicate deliveries. These results don't establish zero downtime, a production SLA,
or successful delivery to a phone.

## Operations and rollback

- Monitor each origin, Front Door health-probe/access diagnostics, authentication failures, key
  reference resolution, certificate expiry, and provider outcomes. Never log OTP bodies, private keys,
  bearer tokens, or nonce values.
- Roll out package/configuration changes deliberately and validate each region. Restore failed test
  origins and verify they are serving; `Running` alone does not prove readiness.
- Keep the reviewed pre-change policy, origin access restrictions, authentication settings, and
  certificate-version references. If rolling back to a direct Function URL, first restore its
  approved single-region access policy **while retaining Easy Auth**, otherwise Front Door-only
  restrictions will block the direct caller.
- Have the policy administrator restore the reviewed URL/app ID through the supported procedure,
  read it back, and validate delivery. Do not delete resources as a substitute for policy rollback.
- Retire extra resources only after traffic and policy rollback are confirmed. Front Door, regional
  plans, and telemetry remain billable until appropriately decommissioned; respect Key Vault purge
  protection and retention.

### Application Insights and sample queries

Setup provisions **workspace-based Application Insights and Log Analytics per region**. The Function
receives `APPLICATIONINSIGHTS_CONNECTION_STRING` and `APPLICATIONINSIGHTS_AUTHENTICATION_STRING`;
its identity receives the Monitoring Metrics Publisher role. Local/key-based ingestion is disabled.
The JavaScript handler emits the [structured service events](CONTRACT.md#application-logs), and
readiness emits `request_completed` and, on failure, `request_failed` with `functionName=FrontDoorHealth`.
No extra application logging code is needed for these events.

Open the Application Insights component's **linked Log Analytics workspace > Logs** to run the
queries below. They target JavaScript JSON messages in `AppTraces`, not Python/.NET's provider-specific
formatting. In an Application Insights resource-scoped query, the equivalent source is
`traces | project TimeGenerated=timestamp, Message=message, AppRoleName=cloud_RoleName`.
For both regions, replace the first `AppTraces` line with:

```kusto
union workspace("<first-workspace-id>").AppTraces,
      workspace("<second-workspace-id>").AppTraces
```

Both workspaces require query access. Filter by `AppRoleName` if the workspaces contain other apps.
The default host configuration samples traces, so counts below are **observed records**, not
guaranteed traffic totals. Keep Information-level application logs enabled; excluding `Request`
from sampling does not exclude these trace events. Health probes can dominate ingestion volume:
keep their charts separate from delivery traffic and review retention/sampling costs.

**Delivery/evaluation volume, failures and handler latency**

```kusto
AppTraces
| where TimeGenerated > ago(24h)
| extend e = parse_json(Message)
| where e.logType == "service" and e.functionName == "SendOtp"
| where e.eventName == "request_completed"
| summarize ObservedCompletions=count(),
            ObservedFailures=countif(toint(e.httpStatus) >= 400),
            P95HandlerMs=percentile(todouble(e.elapsedMs), 95)
    by bin(TimeGenerated, 15m), AppRoleName, Evaluation=tostring(e.evaluation)
| order by TimeGenerated desc
```

`Evaluation=true` is a non-delivering test; `false` is live mode. A blank value means the mode was
not established, for example because envelope validation failed. Handler latency is not end-to-end
Front Door latency or proof of delivery to a handset.

**Failure stages and reasons**

```kusto
AppTraces
| where TimeGenerated > ago(24h)
| extend e = parse_json(Message)
| where e.logType == "service" and e.functionName == "SendOtp"
| where e.eventName == "request_failed"
| summarize ObservedFailures=count(), LastSeen=max(TimeGenerated)
    by AppRoleName, Stage=tostring(e.failureStage),
       Reason=tostring(e.failureReason), HttpStatus=toint(e.httpStatus)
| order by ObservedFailures desc
```

**Follow one request across its service events**

```kusto
let TraceId = "<function-request-id-or-microsoft-correlation-id>";
AppTraces
| where TimeGenerated > ago(24h)
| extend e = parse_json(Message)
| where e.logType == "service"
| where tostring(e.functionRequestId) == TraceId
    or tostring(e["x-ms-correlation-id"]) == TraceId
| project TimeGenerated, AppRoleName, Event=tostring(e.eventName),
          FunctionRequestId=tostring(e.functionRequestId),
          InvocationId=tostring(e.functionInvocationId),
          HttpStatus=toint(e.httpStatus), Stage=tostring(e.failureStage),
          Reason=tostring(e.failureReason), ElapsedMs=todouble(e.elapsedMs)
| order by TimeGenerated asc
```

Use `functionRequestId` to isolate one invocation; a Microsoft correlation ID can cover multiple
attempts. Missing sampled events do not prove a stage never ran.

**Readiness by origin**

```kusto
AppTraces
| where TimeGenerated > ago(1h)
| extend e = parse_json(Message)
| where e.logType == "service" and e.functionName == "FrontDoorHealth"
| where e.eventName == "request_completed"
| summarize ObservedProbes=count(),
            NotReady=countif(toint(e.httpStatus) != 200), LastSeen=max(TimeGenerated)
    by AppRoleName, bin(TimeGenerated, 5m)
| order by TimeGenerated desc
```

No rows is **not** a healthy result: an unavailable Function cannot emit a readiness event.

**Provider outcomes for live sends**

```kusto
AppTraces
| where TimeGenerated > ago(24h)
| extend e = parse_json(Message)
| where e.logType == "service" and e.eventName == "provider_response_processed"
| summarize ObservedResponses=count(),
            P95ProviderMs=percentile(todouble(e.providerElapsedMs), 95)
    by AppRoleName, Provider=tostring(e.providerName),
       Outcome=tostring(e.providerOutcome), ProviderHttpStatus=toint(e.providerHttpStatus),
       ProviderStatus=tostring(e.providerStatus), Reason=tostring(e.failureReason)
| order by ObservedResponses desc
```

Evaluation intentionally emits no provider events. A provider HTTP 200 is not necessarily a
successful outcome; inspect the normalized outcome and reason.

If expected events are absent, check the Function's instrumentation settings, identity role,
Information-level log filters, sampling, workspace scope/time range and ingestion delay.
Front Door access/probe diagnostics are **not configured by this script**: enable the required
categories under the Front Door profile's **Diagnostic settings**, targeting a Log Analytics
workspace, when edge-level diagnostics are needed. Easy Auth and ingress rejections can happen
before the handler; investigate platform/authentication and Front Door diagnostics rather than
expecting a `request_failed` service event. Review diagnostic fields, access and retention before
enabling collection; never add OTP bodies, plaintext delivery data, keys or tokens to application logs.

### Monitoring setup for operators

The following is a starting configuration, **not an SLA or a production threshold recommendation**.
Tune it against normal traffic, ingestion delay, sampling and the on-call team's response policy.
Creating diagnostics, alerts, availability tests and notification actions can incur charges.

1. In **Azure Monitor > Action groups**, create a group for the service owners and test its
   notification delivery. Give operators appropriate read/query access to the regional workspaces;
   alert creators also need permission on the monitored resources.
2. In each regional Application Insights component, open **Logs** and run the delivery and readiness
   queries above. Save them to a shared **Workbook**; use an explicit cross-workspace union for both
   regions. Include failures by stage, latency, provider outcomes and last telemetry seen per origin.
3. On the **Front Door profile > Diagnostic settings**, enable `FrontDoorAccessLog` and
   `FrontDoorHealthProbeLog` to a chosen workspace. The script does not create this setting.
   Front Door metrics are available separately without exporting `AllMetrics` to logs.
   Review workspace retention and access: platform access logs may contain client IPs and URLs
   even though the application service events exclude delivery bodies and credentials.
4. In **Front Door > Alerts > Create alert rule**, select the metrics below, use the suggested
   dimensions to separate origins/endpoints, and attach the action group. Configure auto-resolution
   and a maintenance suppression policy appropriate for the service.
5. In **Log Analytics workspace > Alerts > Create alert rule**, select **Custom log search** and
   paste one of the alert queries below. Evaluate every 5 minutes. Each query includes its own
   lookback and returns only candidate alert rows: measure **Table rows > 0**. Split by `AppRoleName`
   for per-origin signals. Ensure the rule's query time range covers the stated lookback.
   Test the notification path and recovery in nonproduction before enabling paging.

| Signal | Example condition | Scope / caveat |
|---|---|---|
| `OriginHealthPercentage` | Average below 100% over 5 minutes | Split by `Origin` and `OriginGroup`. Expect transitional noise; use this with readiness events and absence detection. |
| `Percentage5XX` | Average above 1% over 5 minutes | Split by `Endpoint`; inspect request volume because small denominators exaggerate percentages. |
| `OriginLatency` | Average above 1000 ms over 5 minutes | Split by `Origin` and `Endpoint`; replace with a workload-derived latency budget. |
| `Percentage4XX` | Investigate a sustained rise above baseline | Includes deliberate negative tests and client/authentication failures; do not page on every 401/403. |
| Application failures / readiness | Custom log queries below | Trace sampling means these are observed failures, not complete request counts. |

An Application Insights **Availability > Standard test** can send HTTPS GET to the public
`/api/health/ready` route and expect 200, using multiple locations. For example, alert on failures
from two locations over five minutes. Do not put an EPP bearer token in the test, and do not probe
the protected SendOtp route anonymously as an availability test. A shared health URL proves neither
every origin's health nor provider delivery; retain the per-origin metric alerts.

**Observed live-delivery server failures: example log alert**

```kusto
AppTraces
| where TimeGenerated > ago(15m)
| extend e = parse_json(Message)
| where e.logType == "service" and e.functionName == "SendOtp"
| where e.eventName == "request_completed" and tobool(e.evaluation) == false
| summarize ObservedRequests=count(),
            ObservedServerFailures=countif(toint(e.httpStatus) >= 500) by AppRoleName
| extend ObservedFailurePct=100.0 * ObservedServerFailures / ObservedRequests
| where ObservedServerFailures >= 3 and ObservedFailurePct >= 5.0
```

This deliberately excludes evaluation traffic and failures before a request's mode is known.
Use the failure-stage query and Front Door diagnostics for those cases.

**Readiness failures: example log alert**

```kusto
AppTraces
| where TimeGenerated > ago(5m)
| extend e = parse_json(Message)
| where e.logType == "service" and e.functionName == "FrontDoorHealth"
| where e.eventName == "request_completed" and toint(e.httpStatus) != 200
| summarize ObservedFailures=count() by AppRoleName
| where ObservedFailures >= 3
```

**Missing per-origin telemetry: example log alert**

Replace both names below with the deployed Function names, and replace the `AppTraces` source with
the cross-workspace union when each region has its own workspace. Keep the full expected-origin
list: building it from recent events would silently omit an origin that stopped reporting.

```kusto
let Expected = datatable(AppRoleName:string)
[
    "<prefix>-0-func",
    "<prefix>-1-func"
];
let Seen =
    AppTraces
    | where TimeGenerated > ago(15m)
    | extend e = parse_json(Message)
    | where e.logType == "service" and e.functionName == "FrontDoorHealth"
    | where e.eventName == "request_completed"
    | summarize LastSeen=max(TimeGenerated) by AppRoleName;
Expected
| join kind=leftouter Seen on AppRoleName
| where isnull(LastSeen)
| project AppRoleName, LastSeen, Signal="No readiness telemetry in the last 15 minutes"
```

An absence alert can mean an outage, sampling/filtering, an ingestion problem, or a wrong query
scope/name. It is a telemetry-gap signal, not proof of an application outage. Suppress during
planned maintenance and correlate with edge health and deployment status.

**Front Door SendOtp status codes: monitoring query**

Run this in the workspace receiving the profile's diagnostics. Replace the profile resource ID.
Front Door Standard/Premium exports these logs to `AzureDiagnostics`. The status conversion handles the string
and numeric columns found in AzureDiagnostics. It does not display client IPs or full request URLs.

```kusto
let ProfileId = "/subscriptions/<subscription-id>/resourceGroups/<global-rg>/providers/Microsoft.Cdn/profiles/<profile-name>";
AzureDiagnostics
| where TimeGenerated > ago(24h)
| where _ResourceId =~ ProfileId and Category == "FrontDoorAccessLog"
| where tostring(parse_url(requestUri_s).Path) =~ "/api/SendOtp"
| extend HttpStatus=toint(coalesce(
    tostring(column_ifexists("httpStatusCode_s", "")),
    tostring(column_ifexists("httpStatusCode_d", real(null))),
    tostring(column_ifexists("httpStatus_d", real(null)))))
| summarize ObservedRequests=count() by bin(TimeGenerated, 15m), HttpStatus
| order by TimeGenerated desc
```

Use this to spot 401/403 and 5xx responses that never reached the Function handler.
A 403 alone does not identify whether Easy Auth, origin restrictions or an edge policy rejected it.
`FrontDoorHealthProbeLog` is useful for failed probe diagnostics, **not a stream of all successful
probes**; absence of those log rows does not establish health. Use `OriginHealthPercentage` for
the per-origin health trend.

**Front Door failed probes by origin**

```kusto
let ProfileId = "/subscriptions/<subscription-id>/resourceGroups/<global-rg>/providers/Microsoft.Cdn/profiles/<profile-name>";
AzureDiagnostics
| where TimeGenerated > ago(24h)
| where _ResourceId =~ ProfileId and Category == "FrontDoorHealthProbeLog"
| summarize FailedProbes=count(), LastSeen=max(TimeGenerated)
    by Origin=tostring(originName_s), Result=tostring(result_s),
       HttpStatus=toint(httpStatusCode_s)
| order by FailedProbes desc
```

Also monitor Key Vault certificate expiry (for example, a 30-day renewal warning), resolved
Function key references, subscription budgets and telemetry ingestion volume. Never test a paging
rule by disabling production authentication or sending unsolicited OTP messages.

## References

- [Front Door routing methods](https://learn.microsoft.com/azure/frontdoor/routing-methods)
- [Health probes and all-origins-unhealthy behavior](https://learn.microsoft.com/azure/frontdoor/health-probes)
- [Origin security and caller-header considerations](https://learn.microsoft.com/azure/frontdoor/origin-security)
- [Front Door caching](https://learn.microsoft.com/azure/frontdoor/front-door-caching)
- [Key Vault backup/restore constraints](https://learn.microsoft.com/azure/key-vault/general/backup)
- [Azure Functions monitoring and sampling](https://learn.microsoft.com/azure/azure-functions/configure-monitoring)
- [Front Door monitoring data reference](https://learn.microsoft.com/azure/frontdoor/monitor-front-door-reference)
- [Log search alert rules](https://learn.microsoft.com/azure/azure-monitor/alerts/alerts-create-log-alert-rule)
