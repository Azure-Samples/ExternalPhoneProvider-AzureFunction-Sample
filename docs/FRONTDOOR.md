# Optional multi-region onboarding with Azure Front Door

Use Azure Front Door when you want **one public EPP URL backed by Function Apps in multiple regions**.
You can expand a supported JavaScript deployment with the [PowerShell setup below](#scripted-javascript-expansion),
or follow the manual steps for other configurations. For a single region, start with the
[main onboarding guide](../README.md).

The original `Setup-Epp.ps1` still creates one regional endpoint. The separate
[Setup-EppFrontDoor.ps1](../setup/Setup-EppFrontDoor.ps1) creates new regional copies behind Front Door
and leaves the source endpoint and authentication policy unchanged. Failover can still interrupt requests.

## Scripted JavaScript expansion

Run this script from a reviewed repository checkout, not as a standalone downloaded file. It uses
[frontdoor-regions.bicep](../setup/infra/frontdoor-regions.bicep) to call the existing
[regional Function module](../setup/infra/resources.bicep) for each new region. The same module
continues to serve the single-region setup when no Front Door configuration is passed.

### Supported source and prerequisites

- PowerShell **7.4+**, Azure CLI with Bicep installed, and an Azure user account signed into the
  source subscription and tenant. The new setup does not install tools or change your CLI default.
- An existing **Linux JavaScript EP1** EPP Function using private Blob run-from-package with
  system-assigned managed-identity access. Remote-build, FC1, Python, and .NET sources are rejected.
- Enforced HTTPS Easy Auth, an issuer in the selected tenant, a **v2 application-ID audience**,
  and a nonempty authorized-caller list. Additional principal/claim restrictions are rejected
  instead of silently dropped.
- A current, enabled, exportable RSA PEM certificate named `phone-provider-encryption`. The source
  Function must use its latest version-pinned backing secret, with more than 30 days of validity.
  The script does not rotate or register a new key.
- Permission to read the source app configuration and package, back up its certificate, and
  deploy the new resources and scoped role assignments. API-key cloning also needs permission to
  back up the provider's named secrets. No Microsoft Graph or policy permissions are granted.
- Two or three distinct target regions in the **same subscription and Azure geography as the source
  vault**, with suitable EP1 quota and availability for all dependencies.
- For provider-enabled expansion, a supported API-key setup profile and provider secrets in the
  source certificate vault. OAuth provider federation is **not automated** by this first version.
  For OAuth sources or sources with no provider, use `-EvaluationOnly` explicitly to validate
  infrastructure without configuring a provider. This cannot send live messages successfully.

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
    -OutputDirectory .\setup\frontdoor-output `
    -EvaluationOnly
```

Replace the placeholders and choose regions that meet your requirements. The prefix must be 3-10
lowercase letters/digits, starting with a letter. Read-only source inspection and package download
happen before approval. Review the source, target groups, package hash, provider mode, and charges.
Type `Yes` to proceed, or use both `-NonInteractive -ApproveDeployment` for an explicitly approved
unattended run.

The script:

1. Creates a separate Front Door Standard profile and two or three **new** regional deployments.
   The source is a configuration/package/key source, not an origin in the new group.
2. Adds the reviewed, opt-in readiness handler to a copy of the source ZIP. Delivery files and
   dependencies remain unchanged. It records both source and resulting package hashes.
3. Copies the certificate using encrypted Key Vault backup/restore, pins regional secret references,
   and uploads identical package bytes to each region's private storage. API-key mode also copies
   the profile's named credential secrets. Existing incompatible copies are not overwritten.
4. Checks regional authentication, profile-pinned ingress restrictions, Function registration, and
   resolved key references before completing the route setup. It does not disable Easy Auth on SendOtp.
5. Saves `frontdoor-state.json`, a public certificate, and the reviewed package under the selected
   output directory. No plaintext private key or provider credential is written there.

The readiness endpoint and route may take time to become reachable after ARM reports success.
Our live validation initially received Front Door 404 responses before the route became available.
Do not activate policy based on deployment status alone.

### Verify and resume

The deployment ends with **authenticated validation still required**. Obtain an access token through
your approved test-caller process, using the same tenant, audience, and allowed caller as the source.
Do not substitute a Function key or your ordinary Azure management token.

```powershell
$token = Read-Host 'Approved EPP caller access token' -AsSecureString
try {
    .\setup\Test-EppFrontDoor.ps1 `
        -OutputDirectory .\setup\frontdoor-output `
        -AccessToken $token
}
finally {
    $token.Dispose()
}
```

This sends missing-token and invalid-token checks plus three encrypted evaluation requests.
It stores only sanitized outcomes and correlation IDs. It does not send SMS/voice, retry live sends,
stop origins, or prove every origin participated. Complete the
[per-origin and failover checks](#5-validate-before-manually-activating-policy) separately.

To resume an interrupted setup, use the **same source, arguments, prefix, and output directory**.
The script retains a fingerprint of the approved source/configuration and verifies its saved package.
Changes to the source package, key, or selected configuration require review rather than silent reuse.
Checkpoint writes are atomic and retain a `.previous` copy. Do not remove a checkpoint to bypass
ownership checks. If a checkpoint is damaged, inspect the previous copy and Azure resource state
before restoring it manually.

Rerunning can temporarily close **the new origins'** ingress while they are verified and republished.
Do not rerun on serving origins without a maintenance plan. On failure the script attempts to close
ingress to its new origins and reports failures to do so. It does not delete resources automatically;
they can remain billable. The original source and policy remain available for rollback.

### What was verified for this script

The JavaScript evaluation-only expansion was deployed in Central US and West US 2. Both new origins
served valid encrypted evaluations through the new Front Door, and each passed token-rejection,
malformed-envelope, and tampered-JWE checks when selected individually. Direct origin access was
denied even with a spoofed Front Door ID header. Certificate continuity, package hashes, resolved
references, and source configuration were checked.

A stalled certificate-restore client was interrupted during validation. The setup closed the new
origins, retained its checkpoint, and resumed using the same package and certificate. The restore
operation now has a bounded HTTP timeout. Source validation and encrypted-restore safeguards have
offline coverage. Provider-secret cloning, live API-key delivery, and OAuth federation were not
exercised by this evaluation-only deployment.
The older failover measurements below remain observations, not a new performance guarantee.

## Scope and observed behavior

We tested an isolated JavaScript deployment with Front Door Standard, two and three regional
origins, a shared encryption certificate, and a separate readiness handler that sends no messages.
The tests covered encrypted evaluation requests, rejection of invalid callers, direct-origin
access restrictions, and stopping and restarting individual Functions.

The JavaScript readiness handler is included in this source revision and enabled only when
`EPP_FRONT_DOOR_HEALTH_ENABLED` is exactly `true`. The expansion script inserts it into the copied
source package before enabling it. An older release ZIP might not contain the handler, so setting
the flag alone is insufficient. Manual deployments must meet the
[readiness contract below](#3-provide-a-non-delivering-readiness-endpoint).
We haven't tested an equivalent .NET or Python handler.

We **did not test** live SMS/voice delivery, calls and retries from the real Entra service, a full
Azure regional outage, custom domains, WAF, Private Link, or production load. Test the features your
deployment needs before activating policy.

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

## References

- [Front Door routing methods](https://learn.microsoft.com/azure/frontdoor/routing-methods)
- [Health probes and all-origins-unhealthy behavior](https://learn.microsoft.com/azure/frontdoor/health-probes)
- [Origin security and caller-header considerations](https://learn.microsoft.com/azure/frontdoor/origin-security)
- [Front Door caching](https://learn.microsoft.com/azure/frontdoor/front-door-caching)
- [Key Vault backup/restore constraints](https://learn.microsoft.com/azure/key-vault/general/backup)
