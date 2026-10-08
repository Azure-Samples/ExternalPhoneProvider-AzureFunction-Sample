# Optional multi-region onboarding with Azure Front Door

Use Azure Front Door when you want **one public EPP URL backed by Function Apps in multiple regions**.
You configure this option manually. For a single region, start with the
[main onboarding guide](../README.md).

**We don't provide a Front Door deployment script.** The guided setup creates one regional endpoint,
not the multi-region setup described here. This guide covers what you need to configure and test.
Failover can still interrupt requests.

## Scope and observed behavior

We tested an isolated JavaScript deployment with Front Door Standard, two and three regional
origins, a shared encryption certificate, and a separate readiness handler that sends no messages.
The tests covered encrypted evaluation requests, rejection of invalid callers, direct-origin
access restrictions, and stopping and restarting individual Functions.

**The readiness handler used in testing is not part of the released sample.** You must implement
and validate the [readiness contract below](#3-provide-a-non-delivering-readiness-endpoint) before
enabling multi-origin health probes. There is no app setting that adds this endpoint to a release ZIP.
You can adapt the design for other runtimes, but we haven't tested it with .NET or Python.

We **did not test** live SMS/voice delivery, calls and retries from the real Entra service, a full
Azure regional outage, custom domains, WAF, Private Link, or production load. Test the features your
deployment needs before activating policy.

### Regional resiliency responsibility

For the Microsoft-configured baseline, Microsoft is responsible for defining, configuring,
documenting, and validating the standard regional-failover pattern and its exercise procedure.
Customers using that baseline should not have to design regional disaster recovery (DR) themselves.
Customers operate their deployed baseline: assign
owners, maintain regional capacity, credentials and keys, monitor it, and run approved drills.
Customers who replace the topology own the alternate regional-failover design and its validation.
Customer operation of the standard baseline does not transfer responsibility for designing that
baseline to the customer.

The two-region pattern below makes the intended baseline concrete, but today's onboarding remains
single-region and Front Door setup remains manual. The readiness-handler, regional-dependency,
capacity, real-caller, and outage-validation gaps described here remain to be addressed before
relying on this pattern for regional recovery. Recovery-time and recovery-point objectives
(RTO/RPO), tolerable request failures, latency limits, and required evidence must be defined and
approved by the deployment owners; the observed results below do not establish those targets.

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

### Two-region baseline to provision and validate

Use two independently provisioned regional stacks, A and B, at equal Front Door priority for
active-active service. Each has its own Function App and hosting capacity, private runtime/package
storage, Key Vault containing the shared decryption key and applicable provider credentials,
managed identities with local scoped access, and regional telemetry. Configure provider federation
for each regional outbound identity where required. Neither stack may require the other region's
storage, vault, or identity to serve or recover; verify startup, key resolution, and credential
refresh as well as already-warm requests.

Keep one shared Front Door public SendOtp URL and endpoint application registration, with identical
issuer, audience, authorized-caller policy, selected provider route, and encryption public-key
identity across both stacks. Replicate and renew the matching private key securely in each regional
vault using the [key coordination procedure](#coordinate-the-encryption-key). Failover must not
require changing the caller URL, trust configuration, or registered encryption certificate.
Front Door, Entra authentication, and the selected provider remain shared dependencies; regional
duplication does not add provider failover or remove those dependencies.

## 1. Plan the regional deployment

Start in a dedicated nonproduction tenant and subscription. Review the
[setup prerequisites](../setup/docs/README.md#prerequisites-for-step-2) and
[regional quota guidance](../setup/docs/Troubleshooting.md#deployment-fails-with-subscriptionisoverquotaforsku).

- Start with two regions, based on service availability, capacity, residency, and the selected
  Security Store provider's requirements. A third region adds cost and capacity, but does not
  necessarily shorten failure detection.
- Check availability of **every** required resource type, not just EP1 quota. Hosting availability
  doesn't mean Application Insights or other dependencies are available there.
- Budget for an EP1 plan and regional dependencies in each region, Front Door, and telemetry.
  Size and validate each region for the survivor workload described below, not just its normal share.
- Choose one language and verify that each origin receives the same package. Do not mix
  implementations or package versions while measuring failover.
- Record the endpoint application's client ID, validated token audience and issuer, authorized
  caller application ID, certificate/public-key identity, selected provider route, and regional owners.
- Plan manual rollout, validation, certificate renewal, monitoring, and rollback before activation.

**Do not simply rerun `Setup-Epp.ps1` in another region against the same application.** It is a
single-region setup flow and does not coordinate Front Door, shared key material, regional
registrations, or failover. Independent certificate issuance or a setup rerun can change app
configuration or disable incoming access to an existing endpoint.

### Capacity gate: each region must support the combined peak load

**EACH region must be provisioned and validated to serve the combined peak workload on its own.**
For a balanced two-region active-active baseline, this means **at least twice its normal per-region
traffic**, plus explicitly planned headroom for bursts, retries, probe traffic, and dependency
overhead. Reserve that capacity in both A and B before relying on regional failover; spare capacity
only in one direction is insufficient. Planning retry headroom does not authorize blind retries
of live sends.

Use the expected peak offered workload, not a quiet-period average or the lower throughput left
after requests time out. Equal weights do not guarantee equal routing. If normal traffic is
unequal, each region still needs the entire combined peak workload plus headroom; the less-used
region may need more than twice its usual traffic. An N-region alternative needs a documented
failure budget and measured capacity for every permitted survivor set and routing distribution.
Adding origins does not waive the double-load requirement for the balanced two-region baseline.

Record the workload mix, offered and completed request rates, concurrency, payload sizes, test
duration, per-region latency percentiles, errors/timeouts, resource saturation, and dependency
throttling. Verify hosting/subscription quotas, available warm capacity and scale-out delay,
storage and vault limits, identity/token-service capacity, and provider account/rate limits.
Autoscale maxima, provisioned instance counts, and approved quotas alone are **not capacity proof**.
Pass only against agreed latency/error and sustained-load criteria with measured evidence in
both directions. No measured production-capacity result is supplied by this guide.

Encrypted evaluation requests bypass request-path provider credential resolution and outbound
provider calls. A double-load evaluation drill proves only the exercised ingress, authentication,
decryption, and routing path, **not complete live-send capacity**. Background credential refresh
can still run independently; its presence does not prove live-path credential capacity.

The capacity gate separately requires production-representative evidence in both survivor
regions using a **non-delivering, provider-approved sandbox/stub** that exercises the live request
path, credential acquisition/refresh, and representative provider latency and quota/throttling
behavior, or separately authorized delivery validation. Document how the sandbox/stub represents
production and obtain provider capacity/quota evidence for what it cannot reproduce; an instant
success stub or bypassed credential lookup is insufficient. Evaluate cold starts, cache expiry,
and credential/key refresh so warm caches do not hide a dependency on the failed region. Keep
this separate from the evaluation-only fire-drill; do not silently enable live sends in that drill
or mark the full capacity gate passed using evaluation-only throughput.

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
- Return `200` only when the handler is running and the configured RSA decryption key is usable.
  Return a generic `503` when not ready.
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
- Run the [regional failover fire-drill](#6-regional-failover-fire-drill) in both directions, with
  agreed acceptance criteria and evidence for the [capacity gate](#capacity-gate-each-region-must-support-the-combined-peak-load).
- Separately test approved live SMS/voice delivery and caller behavior with the provider and EPP
  onboarding owner. Evaluation does not prove either.

Once these checks pass, have an **Authentication Policy Administrator** follow the
[supported activation procedure](../setup/docs/README.md#step-3---manually-validate-and-activate-policy),
using the Front Door SendOtp URL and endpoint application client ID. Save the previous policy first,
preserve unrelated properties, and read the policy back to confirm the change. This step is manual.

### Test scenarios to plan and record

Use this checklist to agree what you will test and what counts as a pass. **These are proposed
tests, not a report that they have all been run.** The historical JavaScript evaluation, access
rejection, and individual app-stop/restart tests are described in
[scope and observed behavior](#scope-and-observed-behavior) and
[observed failover results](#observed-failover-results-and-limitations). Those results do not prove
double-load capacity, complete dependency isolation, or a full regional outage.

Run only in an approved, isolated nonproduction environment, with synthetic data, bounded load,
and the [fire-drill's approval, abort, and restoration safeguards](#6-regional-failover-fire-drill).
Use an authorized test harness calling the Front Door endpoint, not a real Entra/SAS sign-in flow.
**SAS evaluation can trigger native fallback; do not assume it is non-delivering.** Real-SAS and
delivery testing require separate safety approval and are not part of this checklist.
Agree load, headroom, recovery time, error/latency limits, soak duration, and restoration deadlines
before starting; do not substitute the historical measurements for your acceptance targets.

| What to test | How and where to test safely | Expected outcome / acceptance | Evidence to keep |
|---|---|---|---|
| Baseline encrypted evaluation | Send synthetic encrypted `mode: 2` requests through Front Door with both origins healthy. Confirm each origin serves requests. | Matching nonce checked locally, no delivery, and agreed baseline error/latency limits met. | Offered/completed rates, latency/errors, safe correlation IDs and serving region; no nonce values or request bodies. |
| Bad caller credentials, unauthorized callers, and direct-origin access | From the test harness, try missing/invalid/wrong-audience tokens, an unauthorized app, and direct-origin requests including a spoofed `X-Azure-FDID`. Send valid evaluations before and after. | Invalid calls are rejected while valid evaluations still work. Authentication and ingress restrictions remain enabled. | Response status and sanitized access diagnostics identifying the rejection; successful surrounding evaluations. |
| Failover from A to B | Follow the fire-drill: isolate only approved test origin A while leaving it **enabled in Front Door**. Keep B healthy and evaluation traffic bounded. | Health-based rerouting to B meets agreed recovery and transition-error limits, without changing the public URL, trust, or encryption key. | Fault/probe/client timestamps, every failure/timeout, and B's request/health signals. |
| Failover from B to A | After A is fully restored and stable, repeat with B isolated but **enabled in Front Door**. | A meets the same agreed criteria; a one-direction pass is insufficient. | The same evidence, identifying A as the survivor and confirming B's subsequent restoration. |
| Sustained survivor capacity | In each direction, maintain the [combined peak offered load plus planned headroom](#capacity-gate-each-region-must-support-the-combined-peak-load) for the agreed soak. | **Each region handles at least double its normal share in the balanced two-region case, plus headroom**, within agreed error/latency and dependency limits. Evaluation proves only the exercised path. | Offered/completed rates, concurrency, latency percentiles, errors/timeouts, saturation/throttling, quotas and available capacity per region. |
| Restart, cold start, and credential refresh without the failed region | In a separately approved dependency-isolation test environment, make the failed region's storage/vault paths unavailable and start or restart the survivor stack. Exercise key resolution and credential refresh using the non-delivering provider setup below. Do not add a second fault to the basic fire-drill. | The survivor starts and serves using its own dependencies; warm caches do not hide cross-region access. Missing failed-region telemetry is not treated as success. | Dependency configuration/access evidence, startup/key/credential-refresh results, client outcomes and timestamps captured outside the failed region. |
| Complete live-path capacity and provider credential failures | Separately use a provider-approved, production-representative **non-delivering sandbox/stub** exercising credential acquisition/refresh and provider latency/quota behavior. Test valid and invalid/expired test credentials without production accounts or recipients. | Both survivor regions meet the capacity criteria on this path; credential failures are surfaced, not reported as successful sends. Evaluation-only throughput cannot pass this test. | Credential/provider timing, failures/throttling, load results, and provider capacity/quota evidence for behavior the sandbox/stub cannot reproduce. |
| Restoration and conservative failback | Restore the original approved state even after a failed test. Verify the restored origin's own readiness and successful evaluations, then observe traffic returning for the agreed window. | Both origins are healthy and serving within agreed limits, with original security settings intact, before any next fault. | Restoration confirmation, origin-specific readiness/request evidence and failback latency/errors. |
| Interrupted-controller recovery | Verify the independent restoration timer or backup operator before fault injection. In an approved drill, interrupt the controller while the independent safeguard remains available. | The fault is removed by the agreed deadline without relying on the interrupted controller; unsafe load stops and unresolved recovery is escalated. | Interruption/restoration timestamps, safeguard or backup-operator actions, and both origins' final state. |

For every row, record **pass, fail, or not tested**, the approved target, observed outcome, and
evidence location. Assign an owner and retest date to gaps. A successful routing test is useful,
but is not a substitute for the separate capacity and dependency tests.

## 6. Regional failover fire-drill

This runbook is for an approved, dedicated nonproduction deployment. It exercises health-based
rerouting; it is not permission to disrupt production or a claim of a full Azure regional-outage
test. Define numeric pass/abort thresholds and durations before starting, rather than adopting the
observed failover timings below as an SLA.

1. **Assign ownership and approve the boundary.** Name a drill lead, change approver, regional
   resource owners, load/telemetry observer, and restoration owner with a backup. Record the exact
   tenant, subscription, Front Door profile, origin group, Function Apps, target region, change
   window, maximum isolation duration, and restoration actions. Confirm no production policy or
   real users depend on these resources. Approve only one isolated test origin at a time.
2. **Prepare bounded, non-delivering traffic and independent recovery.** Use an authorized test
   caller to send synthetic encrypted `mode: 2` evaluation requests through the shared URL; never
   use real OTPs, real recipient data, or live-send mode. Check nonce matches locally, not in shared
   logs. Set hard rate, concurrency, request-timeout, total-duration, and cost limits. Place the
   controller and evidence capture outside the target region. Test restoration access and arrange
   an independent deadline-triggered restoration mechanism or backup operator; the load controller
   must not be the only way to end the outage.
3. **Establish the baseline and acceptance gates.** Save the approved origin/routing, authentication,
   ingress, package, key-reference, and regional-dependency configuration. Complete the security and
   evaluation checks in section 5. Confirm both origins are healthy and actually serving, using
   origin-specific diagnostics rather than only the shared readiness URL. Agree the offered peak
   rate plus headroom, minimum survivor soak duration, detection/recovery target, allowed failures
   and timeouts, latency percentiles, resource/dependency limits, and failback observation window.
   Include abort thresholds for an unhealthy survivor, unexpected delivery, security drift, lost
   observability, or an approaching isolation deadline. Capture steady-state evidence from every
   region and the client before injecting a fault.
4. **Isolate ONE approved origin; leave it enabled in Front Door.** After confirming it is serving
   traffic, apply the approved reversible fault, for example stopping that test Function App.
   Timestamp the fault request and platform confirmation separately. Keep the other origin healthy
   and unchanged. Do not disable the target in Front Door: manual disabling tests control-plane
   removal, not health-probe outage detection. Never disable authentication, exempt SendOtp from
   Easy Auth, or weaken ingress to make the drill pass. Front Door can route across all origins
   when all probes fail; probe state is not a security boundary.
5. **Observe detection and sustained survivor load.** Maintain the bounded combined-peak evaluation
   load plus planned headroom through Front Door, without exceeding the approved test ceiling.
   Capture client attempts, completed requests, every failed response and transport error, latency,
   safe correlation IDs, and timestamps alongside Front Door probe/access diagnostics and every
   region's routing, Function, storage, vault, identity, and telemetry signals. Do not treat missing
   regional telemetry as zero errors or use delayed health-percentage graphs to time recovery.
   Verify the surviving region sustains the required offered rate and agreed criteria for the
   full soak period, not merely one successful request. Label this as evaluation-path capacity,
   not full live-send capacity; the separate provider/credential evidence required by the capacity
   gate remains necessary. Record failures during detection even if later requests succeed;
   retries must not hide first-attempt errors.
6. **Restore unconditionally, including on abort.** Stop fault injection and restore the target
   at the deadline or any abort threshold, or when the soak completes. Stop synthetic load if
   unsafe. Put restoration in the controller's guaranteed cleanup path and retain the independent
   safeguard for controller interruption or loss. Restore the saved approved state even when
   assertions fail; escalate immediately to the restoration owner if restoration cannot be
   confirmed. Do not start another fault or declare success while an origin remains impaired.
7. **Fail back conservatively, then reverse the direction.** Verify the restored origin's own
   dependencies, key/credential resolution, readiness, and successful encrypted evaluations.
   Expect Front Door to resume routing when its health criteria are met; watch both origins as
   traffic returns and avoid immediately changing weights or driving a new surge. Require stable
   health, latency, errors, and capacity through the agreed observation window. Confirm all
   resources and routing are restored before repeating the same exercise with the other region
   isolated. Both directions must meet the evaluation-drill criteria; the full survivor-capacity
   gate additionally requires the separate production-representative live-path evidence above.
8. **Record the outcome and gaps.** Retain sanitized configuration/package identifiers, approvals,
   workload and limits, expected versus observed routing, fault/probe/client/recovery timestamps,
   rates, latency/errors, capacity/dependency evidence, aborts, and restoration confirmation.
   Record pass/fail against each agreed criterion, including unmet or unmeasured gates, with
   follow-up owners and repeat-test dates. Never attach keys, bearer tokens, request bodies, OTPs,
   or nonce values. Repeat after material topology, package, authentication, key, provider, or
   capacity changes and at the operator-approved cadence.

### What this drill does not prove

Stopping a Function App simulates one application origin becoming unavailable. It does **not**
simulate the loss of an Azure region's storage, vault, identity access, network paths, control
plane, or telemetry, nor prove the surviving stack can start or refresh credentials without them.
The regional-resiliency validation plan must separately validate loss of regional dependencies and telemetry,
using approved nonproduction fault scenarios and capturing evidence outside the affected region.
Include dependency refresh/startup and restoration behavior; a warm app-stop success alone leaves
these regional-outage gaps open. Record any scenario that cannot be safely exercised as an
unvalidated limitation requiring deployment-owner review, not a passing regional-outage test.

Evaluation also does not prove real Entra caller deadlines/retries, provider acceptance, or handset
delivery. Validate those separately with the provider and onboarding owner. Neither this runbook
nor Front Door makes retries automatically safe or guarantees zero downtime.

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

## References

- [Front Door routing methods](https://learn.microsoft.com/azure/frontdoor/routing-methods)
- [Health probes and all-origins-unhealthy behavior](https://learn.microsoft.com/azure/frontdoor/health-probes)
- [Origin security and caller-header considerations](https://learn.microsoft.com/azure/frontdoor/origin-security)
- [Front Door caching](https://learn.microsoft.com/azure/frontdoor/front-door-caching)
- [Key Vault backup/restore constraints](https://learn.microsoft.com/azure/key-vault/general/backup)
