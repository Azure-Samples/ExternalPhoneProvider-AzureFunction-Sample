# Multi-region resiliency

[Documentation](README.md) | [Single-region deployment](GETTING-STARTED.md) | [Monitoring](MONITORING.md)

Deploy the endpoint in two Azure regions to support recovery when one region becomes unavailable.
**Azure Front Door** is the routing service that provides one public HTTPS URL and directs requests
to the regional Function Apps. Each regional Function App is called an **origin** in Front Door.

This guide uses two active regions, Linux Premium hosting, and the same provider in both regions.
Start with a validated [single-region endpoint](GETTING-STARTED.md).

## Architecture

![One Front Door endpoint routes to two regional Functions, each with Easy Auth, a matching encryption certificate, its own OAuth identity, and regional monitoring](images/multi-region-architecture.png)

[Open the full-size diagram](images/multi-region-architecture.svg).
Front Door routes each request to an eligible origin. Each regional Function authenticates the
same caller, decrypts with the same RSA key, and obtains its own provider OAuth token.

## 1. Plan the regions and capacity

1. Choose two regions that meet your availability, residency, and provider requirements.
2. Check regional availability and quota for Premium hosting, storage, Key Vault, and monitoring.
3. Size each region to handle the **full peak workload** when the other region is unavailable.
   For a normally balanced two-region deployment, this means at least twice its usual share,
   plus capacity for bursts.
4. Budget for both regional deployments, Front Door, telemetry, and provider traffic.
5. Agree on latency, recovery, error-rate, and cost thresholds before testing.

Record the application client ID, token issuer and audience, authorized Microsoft caller,
encryption certificate, package version, and provider configuration. Use the same values across
both regions except for region-specific resources and identities.

## 2. Prepare the regional Function Apps

Provision each region through your Azure deployment process. Use the
[infrastructure configuration](../setup/infra/resources.bicep) and
[custom deployment checklist](ONBOARDING.md#custom-deployment) as references.

1. Create a Function App, Premium plan, storage account, Key Vault, outbound managed identity,
   Application Insights resource, and Log Analytics workspace in each region.
2. Give resources unique names and keep public ingress closed during configuration.
3. Deploy the same runtime and package to both Functions. Keep package storage private and use
   managed identity for access.
4. Configure the same application client ID, issuer, audience, and approved caller allowlist
   in Easy Auth. Require HTTPS and authentication for `/api/SendOtp`.
5. Configure the same provider and channel URLs. Set each region's
   `EPP_OUTBOUND_MI_CLIENT_ID` to its own outbound identity.
6. Add federation for each outbound identity and complete
   [provider OAuth authorization](ONBOARDING.md#complete-provider-authentication).
7. Verify telemetry independently for each regional Function.

Manage the shared application's identifier URI, permissions, certificates, and federation
centrally. Preserve the existing configuration when adding a region.
Each region should use its own storage and vault so that the surviving Function can start
without depending on the unavailable region.

## 3. Use the same encryption certificate in both regions

Microsoft Entra ID must be able to encrypt a request that either Function can decrypt.
Use the same encryption certificate and corresponding RSA private key in both regional vaults.

1. Transfer the certificate through your approved secure process.
   [Key Vault certificate backup and restore](https://learn.microsoft.com/azure/key-vault/general/backup)
   transfers an encrypted backup and requires the **same subscription and Azure geography**.
   Review another secure transfer approach if your regions fall outside those boundaries.
2. Grant each Function's system-assigned identity secret-read access to its regional certificate.
3. Set `EPP_DECRYPTION_KEY_PEM` to that certificate's **versioned PEM backing-secret reference**.
   Use the secret identifier returned by Key Vault; certificate and secret versions can differ.
4. Verify that both regional certificates match the registered public certificate and that each
   Function's Key Vault reference resolves successfully.

For a backup/restore transfer within the supported boundaries, open the source vault's
**Certificates**, select the certificate, and choose **Download Backup**. In the destination vault,
open **Certificates** > **Restore Backup** and select that encrypted backup. Keep the backup in
restricted storage, confirm the restored certificate and backing secret, and handle the backup
according to your organization's retention policy.

Keep private keys out of source, logs, and support material. Restored certificates are independent
copies: coordinate [renewal](../setup/docs/README.md#encryption-certificate-lifecycle), application
registration changes, and Function references across all regions.

## 4. Add a readiness endpoint

Create a dedicated route such as `/api/health/ready` for Front Door health probes.

| Requirement | Behavior |
| --- | --- |
| Methods | Support HTTPS `HEAD` and `GET`; return no body for `HEAD`. |
| Ready | Return `200` when the handler is running and its configured decryption key is usable. |
| Not ready | Return a generic `503`. |
| Side effects | Keep the check non-delivering: do not send an OTP or call the phone provider. |
| Response | Use `Cache-Control: no-store`; exclude keys, credentials, and configuration details. |
| Access | Set Easy Auth's `globalValidation.excludedPaths` to only this exact readiness path and retain the origin access restrictions in Step 6. |

Keep `/api/SendOtp` protected. Front Door probes do not carry the authorized Microsoft caller's
token, so a probe against SendOtp would test rejection rather than readiness.
Front Door considers only `200` healthy. See [health probes](https://learn.microsoft.com/azure/frontdoor/health-probes).

## 5. Configure Front Door

In the Azure portal, create a **Front Door Standard or Premium** profile, one endpoint, and an
origin group. Add both regional Function Apps as origins.

Use these starting settings and tune them during validation:

| Setting | Value |
| --- | --- |
| Origin hostname and host header | The corresponding Function App's default hostname |
| Origin protocol | HTTPS on port 443, with certificate-name validation enabled |
| Priority | `1` for both origins |
| Weight | Equal weights, such as `1000` for each origin |
| Session affinity | Disabled |
| Health probe | HTTPS `HEAD` to the readiness route |
| Probe interval | 30 seconds |
| Sample size / required successes | 4 / 3 |
| Additional latency | 50 milliseconds |
| Route paths | `/api/SendOtp` and the readiness route |
| Client and forwarding protocols | HTTPS only |
| Caching | Disabled |

Associate the route with the endpoint's domain and origin group. Preserve the original
`Authorization` header and encrypted request body. Set the origin response timeout within
the agreed end-to-end request budget.

In **Front Door manager**, open the endpoint, add the route, select its domain and origin group,
and save. Under **Origin groups** > **your group** > **Origins**, confirm that both regional
Function hostnames are enabled. Leave origin managed-identity authentication disabled on this
route so Front Door preserves the Microsoft caller's `Authorization` header.

The public URL is `https://<front-door-host>/api/SendOtp`. The token audience remains the
configured endpoint application audience.

Front Door selects origins using health, priority, latency, and weight. Equal weights do not
guarantee an exact traffic split. See [routing methods](https://learn.microsoft.com/azure/frontdoor/routing-methods).

## 6. Restrict access to each origin

On each Function App, configure access restrictions under **Networking**:

1. Add an allow rule for the **`AzureFrontDoor.Backend` service tag**.
2. On that rule, require **`X-Azure-FDID`** to match your profile's **Front Door ID**.
3. Set unmatched requests to **Deny**.
4. Confirm Easy Auth still requires the approved Microsoft caller for SendOtp.
5. Enable the ingress needed by Front Door after reviewing the rules.

Use the service tag and profile-ID condition together. A header alone can be spoofed, and the
service tag alone also allows other Front Door profiles.
Preserve deployment-access protections separately from the public application route.
See [origin security](https://learn.microsoft.com/azure/frontdoor/origin-security).

## 7. Validate the shared endpoint

Use an authorized caller and controlled test data.

| Check | Expected result |
| --- | --- |
| Direct Function access, including a forged Front Door ID header | Rejected by the origin access restrictions |
| Missing, invalid, or unauthorized caller token through Front Door | Rejected |
| Valid encrypted evaluation through Front Door | Matching nonce and correlated regional telemetry |
| Evaluation served by each origin | Both origins decrypt successfully with the same registered certificate |
| Controlled live SMS and voice tests | Provider acceptance and separately confirmed recipient delivery |

In the test environment, temporarily prioritize one origin at a time to verify both through
Front Door, then restore equal priorities.

Readiness and evaluation cover different parts of the path. Verify provider authorization and
delivery through the controlled live checks.

## 8. Test regional recovery

Run recovery tests in a nonproduction environment with an agreed stop time, abort thresholds,
and restoration owner.

1. Confirm both origins are healthy and serving authorized evaluation requests.
2. Keep evaluation traffic bounded and record request times, status, latency, and serving region.
3. Stop one test Function while leaving its Front Door origin **enabled**. This exercises
   health-based routing rather than manually removing the origin.
4. Confirm traffic reaches the surviving region within your recovery target. Record failures
   and timeouts during the transition.
5. Restore the Function and confirm both regions are healthy and serving again.
6. Repeat in the other direction.

Before each test, save the routing, access rules, package version, and certificate references.
Record the fault time, first failed probe, client failures, and first successful request in the
surviving region. Restore the original state when the test ends or an abort threshold is reached,
even if the test runner fails. Wait for both origins to stabilize before testing the other direction.

Validate full peak capacity in each surviving region. Evaluation load covers authentication,
decryption, and routing; use a provider-approved non-delivering test system to exercise credential
acquisition and provider latency under load. Also test startup with the other region's storage
and vault unavailable so that cached keys or tokens do not hide cross-region dependencies.

Front Door can route to all origins when every origin is unhealthy. Keep authentication and
request validation effective independently of probe health. Measure recovery rather than assuming
zero downtime, and investigate uncertain live-send outcomes before retrying.

## 9. Activate, operate, and roll back

After validation and recovery tests pass, follow the
[activation procedure](../setup/docs/README.md#activate-the-endpoint) using the Front Door URL
and the endpoint application client ID. Save the previous policy, preserve unrelated settings,
and read back the change.

Monitor each Function, its dependencies, and Front Door's origin health, latency, and response
status. Use [cross-workspace queries](MONITORING.md#multiple-deployments) to keep regional results
visible.

Retain the previous policy, package, authentication settings, access rules, and certificate
references. If rolling back to a direct Function URL, restore its approved direct-access rules
while keeping Easy Auth enabled, then update policy and validate delivery.
Retire extra resources only after traffic has moved and retention requirements are met.
