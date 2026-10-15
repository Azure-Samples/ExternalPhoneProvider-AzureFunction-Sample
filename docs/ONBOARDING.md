# Customer configuration and validation

[Documentation](README.md) | [First deployment](GETTING-STARTED.md) | [Troubleshooting](../setup/docs/Troubleshooting.md)

**After guided setup:** complete [provider authentication](#complete-provider-authentication),
then [endpoint validation](#validate-the-deployed-endpoint). Azure and code are already deployed;
no local settings, Core Tools, or second deployment is needed.

| Task | Go to |
| --- | --- |
| Confirm access before spending | [Eligibility and approved procedures](#before-purchasing-or-deploying) |
| Find or check setup values | [Inputs](#inputs-you-supply-to-setup), [setup-managed values](#values-setup-configures-for-you) |
| Connect the provider | [Credential names and handoff](#complete-provider-authentication) |
| Test and activate | [Acceptance checks](#validate-the-deployed-endpoint), [operations handover](#activate-operate-and-retire) |
| Build a custom package | [Optional local/manual path](#optional-local-development-and-manual-deployment) |

## Before purchasing or deploying

Open [Microsoft Security Store](https://securitystore.microsoft.com/private-solutions) and review
the intended provider offer. Confirm account activation, sender registration, supported countries,
channel, pricing, and access to the provider's **EPP integration**, not just its general messaging API.
An offer purchase does not deploy Azure resources, enable a Microsoft tenant feature, or install
a missing adapter.

![Cropped examples of phone-provider offer cards in Microsoft Security Store](images/onboarding/security-store-providers.png)

*These are sample cards, not recommendations or a complete provider list. Offers, preview
labels, pricing, and access can change. A store listing does not mean the setup script supports
that integration; check [guided provider support](#provider-credential-names).*

Have your tenant administrator confirm the supported EPP onboarding/activation procedure with
Microsoft and the provider **before incurring deployment costs**. This repository does not define
tenant eligibility, licensing, preview enrollment, or a self-service activation entitlement.
The allowed-tenants preview used by setup must also be available in the customer tenant. If an
offer, preview, authorized test caller, or activation procedure is unavailable, stop at that gate
and use the offer's available support route or your organization's Microsoft support channel.
Do not assume that being an Azure subscription owner grants access to these features.

Assign an **onboarding owner** in your organization to coordinate tenant/policy, Azure, and
provider administrators with Microsoft support. Obtain approved test and policy-change procedures
before deployment; the repository supplies no named onboarding contact.

Review [production limitations](CONTRACT.md#production-limitations): no durable queue, automatic
send retries, deduplication, or whole-invocation deadline; one manually renewed decryption key.
Acceptance is not delivery, timeout fallback can duplicate sends, and setup is not certification.

## Values and ownership

### Inputs you supply to setup

Replace placeholders with values from the named portal pages, not values copied from another tenant.
The [complete noninteractive example](../setup/docs/README.md#noninteractive-example) uses these
same parameters. No parameter accepts a provider API key or private key.

| Input | Where to find or decide it | Where to set it / required for |
|---|---|---|
| Customer tenant ID | Microsoft Entra admin center > Overview > Tenant ID; must contain the dedicated app and the Azure identities. | `-TenantId`; all deployments. Not the provider tenant ID. |
| Azure subscription ID | Azure portal > Subscriptions > selected subscription > Overview. Confirm its directory is the customer tenant. | `-SubscriptionId`; all deployments. Not a tenant ID. |
| Endpoint application client ID | Entra > App registrations > the dedicated app > Overview > Application (client) ID. Select the registration by this ID, not just its display name. | `-ApplicationId`; all deployments. **Not** the app Object ID or Enterprise application's Object ID. |
| Azure region | Subscription's available Linux FC1/EP1 regions and quota, plus your organization's requirements. | `-Location`, for example `westus2`; all deployments. |
| Provider | Provider's approved account integration: guided catalog supports `telesign` or `soprano`. The endpoint accepts both SMS and voice, selected by each request. | `-Provider`; all deployments. No channel selection is needed in setup. |
| Provider route label | Provider-confirmed Global/EU selection; see the caveat below. | `-EndpointRegion global` or `eu`; all deployments. The prompt calls this **Tenant scope**. |
| Language / hosting | One of `javascript`, `dotnet`, `python`; FC1 or EP1 after reviewing billing and cold starts. | `-Language`, `-ServicePlan`; all deployments. |
| Resource prefix | A unique deployment label, 2-8 lowercase letters/digits, starting with a letter. | `-ResourcePrefix`; all deployments. Keep it with your inventory for reruns. |
| Encryption certificate choice | Setup lists the application's encryption key IDs, thumbprints, and validity. Use the saved `encryptionKeyId` or the app manifest's `keyCredentials` to identify the credential to keep. | `-CertificateAction Reuse` or `Replace` when certificates already exist. Unattended reuse also requires `-EncryptionKeyId` and `-KeyVaultCertificateId`. See [certificate selection](../setup/docs/README.md#encryption-certificate-selection). |
| Existing certificate location | Azure portal > Key Vault > Certificates > certificate > exact version > Certificate Identifier. Use the `/certificates/` URL, not Show Secret Value. | `-KeyVaultCertificateId`; reuse only. Add `-KeyVaultSubscriptionId` when that vault is in a different subscription in the same customer tenant. |
| Output directory / versions | A private local folder; optionally a reviewed source commit and published release tag. | `-OutputDirectory`, `-SourceRef`, `-PackageReleaseTag`; optional. Keep launcher and support source aligned. |

**Global/EU is routing metadata, not Azure placement or a residency guarantee.**
[Telesign](../setup/providers/telesign.json) and [Soprano](../setup/providers/soprano.json) currently
use identical Global/EU URLs; Soprano also shares its app ID/scope. Confirm provider processing
locations for messages, credentials, logs, and personal data; choose Azure/telemetry locations separately.

**One guided deployment has one provider and accepts both SMS and voice.** Enabling the second
channel does not require another setup run; validate and activate each intended channel separately.
The resource-name suffix uses the subscription ID, app client ID, and prefix, not the provider or
Azure region. Changing provider/region with the same identifiers can reconfigure the existing
endpoint rather than add another one. For an independent provider/region deployment, use a distinct
prefix and a new dedicated app, then validate it before changing policy. Reusing an existing
app requires an explicit certificate reuse/replacement decision before deployment. A different
prefix does not authorize key rotation or isolate other endpoints sharing the same app registration.
The [manual Front Door design](FRONTDOOR.md) requires coordinated same-key regional origins,
not independent setup runs.

### Values setup configures for you

<a id="setup-script-compatibility"></a>
Review the deployment plan, then retain `deployment-*.json` and the public certificate in
`epp-output` (or your chosen directory). Compare the saved `tenantId`, `subscriptionId`,
`applicationId`, `resources`, `provider`, `endpointRegion`, `providerSmsEndpoint`, and
`providerVoiceEndpoint` with the approved plan.
The [setup output guide](../setup/docs/README.md#read-the-deployment-summary) explains the remaining
fields. `policyChanged: false` is expected, not a failed deployment.

Inspect cloud settings in **Azure portal > Function App > Settings > Environment variables**.
They are setup-managed; do not recreate them from the local sample or bulk-copy another app's
settings. Do not export all settings into a ticket. Changes can restart the worker, and reruns
can restore setup-managed values.

| Value or setting | Source / verification | Customer action |
|---|---|---|
| `EPP_PROVIDER_NAME`, `EPP_PROVIDER_ENDPOINT_REGION`, `EPP_PROVIDER_AUTH_MODE` | Selected profile: Telesign `apiKey`, Soprano `oauth`. | Compare with approved provider/region. |
| `EPP_PROVIDER_SMS_ENDPOINT`, `EPP_PROVIDER_VOICE_ENDPOINT` | Complete SMS and voice URLs from the selected regional profile; they may differ. Setup writes both, and each request's `channel` selects one. | Have the provider confirm account access for each intended channel. Do not append another API path or substitute an arbitrary test URL. |
| `EPP_PROVIDER_TENANT_ID` | Profile's provider directory; also appears as `providerTenantId` in the summary. | Do not replace it with the customer's tenant ID. Used for provider tenant restriction and Soprano OAuth authority. |
| `EPP_PROVIDER_APP_ID`, `EPP_PROVIDER_SCOPE` | Soprano API resource client ID and exact `api://.../.default` scope from the profile. | Provider administrator confirms these; API-key providers do not need them. The app ID is setup metadata; the runtime requests the configured scope. Neither is the endpoint app ID. |
| `EPP_OUTBOUND_CLIENT_ID` | Dedicated endpoint application's **client ID**, reused as the Soprano calling app. | Do not create a second client secret or substitute the Soprano API app ID. |
| `EPP_OUTBOUND_MI_CLIENT_ID` | Setup-created outbound user-assigned managed identity > Overview > Client ID. | Soprano token exchange uses this ID. Its Principal/Object ID is different and is used by the federated credential's subject. |
| `KEY_VAULT_URL` | Summary's `resources.keyVault`; vault Overview > Vault URI. | Put Telesign credentials in this vault. Setup grants its Function system identity Key Vault Secrets User. |
| `EPP_DECRYPTION_KEY_PEM`, `EPP_ENCRYPTION_KEY_ID` | Versioned Key Vault reference and the single registered encryption credential ID. The certificate can be in a reused vault distinct from `KEY_VAULT_URL`. Summary includes certificate/secret identifiers and expiry, **not** private-key bytes. | Do not view/copy the private key. Assign a [renewal owner](../setup/docs/README.md#encryption-certificate-lifecycle). |
| `EPP_PROVIDER_TIMEOUT_MS`, `EPP_PROVIDER_RETRY_INTERVAL_MS` | Profile timing values. Runtime provider HTTP timeout is capped at 2500 ms. | Neither is a whole-request deadline; retry interval metadata does **not** enable send retries. |
| `EPP_KEY_VAULT_CACHE_ENABLED`, `EPP_ACCESS_TOKEN_CACHE_ENABLED` | Setup writes `false` for FC1, `true` for EP1. | Independently control API-key/OAuth caching and startup preparation. Unset defaults to `true`; deploy a supporting package and restart after changes. See [plan guidance](../setup/docs/README.md#service-plan-selection). |
| Application Insights, storage, runtime/package settings and identities | Created/configured for the selected plan; system identity handles vault/storage/telemetry, outbound identity handles Soprano exchange. | Verify telemetry ingestion. Do not copy local emulator settings or EP1-only settings into FC1. |
| Inbound caller issuer, audience and allowlist | Function App > Authentication; setup configures Easy Auth for the Microsoft phone-provider caller. | Read back platform authentication, not just `EPP_EXPECTED_*` metadata. App settings are not an alternative caller-authentication gate. |

Guided setup writes both channel-specific endpoint settings and requires a package that reads
them. Manual configurations must also supply the endpoint for each intended channel;
a missing, empty, or invalid selected endpoint fails closed.

There are **three separate trust paths**: Easy Auth admits the Microsoft caller; the Key Vault
certificate decrypts its JWE; provider credentials authorize outbound delivery. The HTTPS
certificate is separate again. Fix the failing path rather than replacing unrelated IDs or keys.

## Complete provider authentication

<a id="provider-credential-names"></a>
Guided setup currently supports **Soprano and Telesign only**. The other bundled adapters are
developer integrations, not additional guided provider offers. The table is alphabetical,
not a recommendation order:

| Provider | Credential names / mode | Deployment support |
|---|---|---|
| `infobip` | `infobip-api-key`; `Authorization: App ...` | Adapter only; no guided profile. Validate its account/options separately. |
| `sinch` | `sinch-api-token`; static token | Adapter only; no guided profile. Validate its account/options separately. |
| `soprano` | No API-key secrets; OAuth client assertion | Guided; complete the [provider-admin handoff](#soprano-provider-administrator-handoff). |
| `telesign` | `telesign-api-key` and `telesign-customer-id`; Basic authentication | Guided; complete the [vault steps](#telesign-enter-and-verify-the-two-vault-secrets). |

### Where to enter API-key credentials in Key Vault

Use the vault created for **your endpoint**, not a vault chosen from a screenshot:

1. Open the saved deployment summary and find `resources.keyVault`.
2. In **Azure portal > Key vaults**, open that vault.
3. Select **Objects > Secrets**. This list shows secret names and status, not their values.
   Select **Generate/Import** to enter a credential.

![Key Vault Objects menu with Secrets selected and the Generate/Import action visible](images/onboarding/key-vault-secrets.png)

*This existing test vault contains examples for more than one adapter. Create only the secrets
required by your chosen integration in the table above. The screenshot does not mean guided
setup configures multiple providers or supports every adapter.*

4. Choose **Manual**. For **Name**, use the exact name in the provider table above.
   For **Secret value**, paste the credential obtained through your provider's secure process.
   Leave **Enabled** set to **Yes** and set activation/expiry dates to match your provider agreement.
5. Select **Create** only after checking the vault, name, and value. Repeat for any additional
   required credential, such as an account/customer ID.

![Unsaved Create a secret form showing a sample name, masked placeholder value, and Enabled set to Yes](images/onboarding/key-vault-create-secret.png)

*The screenshot uses `example-provider-api-key` and a fake masked value to show the form.
Neither is a working configuration. The form was cancelled without saving. Use the exact
provider-specific secret names, not this example name, and never reveal a real key for a screenshot.*

After saving, verify the name, enabled state, and version metadata without selecting
**Show Secret Value**. Do not edit or replace the setup-created encryption certificate secret.
If the vault denies access, ask the approved credential administrator for help; do not disable
vault protection or copy credentials into Function settings. See the permission and runtime
checks in the provider-specific steps below.

### Telesign: enter and verify the two vault secrets

1. Confirm account access to each intended channel's EPP URL. Use the
   [vault steps above](#where-to-enter-api-key-credentials-in-key-vault) to store the raw API key as
   `telesign-api-key` and matching raw Customer ID as `telesign-customer-id`.
   Do not encode the pair, decode the key, or enter an Authorization header; the adapter builds Basic auth.
2. Verify enabled state, validity, and version metadata without **Show Secret Value**.
   In **Access control (IAM)**, confirm the Function's **system-assigned identity** has
   **Key Vault Secrets User**. Setup gives its Azure operator **Key Vault Secrets Officer**;
   another credential administrator needs separate vault access, regardless of directory role.
   For failures, allow RBAC propagation and check networking; never replace the encryption secret,
   grant broad access, or copy credentials into app settings to bypass a denial.
3. Complete the [authorized evaluation and live checks](#validate-the-deployed-endpoint).
   Evaluation does not validate these secrets. Setup disables provider caching for FC1 and enables
   it for EP1; plan first-use/rotation checks from the [cache contract](CONTRACT.md#credential-caching-and-refresh).
   No warning is not proof of account authorization.

Use portal secret entry rather than command-line literal values, transcripts, source files,
screenshots, or chat. During rotation, coordinate the matching pair and provider validity window;
two secret updates are not atomic. Keep old credentials usable during the approved transition
where the provider supports it, and verify live delivery before retiring them.

### Soprano: provider-administrator handoff

Setup creates customer-side federation, **not** the commercial account or access in Soprano's
tenant. Complete this handoff before treating OAuth as ready.

Send the following **identifiers only** through the provider's approved onboarding channel:
customer tenant ID; `applicationId` / `EPP_OUTBOUND_CLIENT_ID`; intended channels and their full provider URLs;
`EPP_PROVIDER_TENANT_ID`, `EPP_PROVIDER_APP_ID`, and `EPP_PROVIDER_SCOPE`; and the account/sender
reference requested by the provider. If troubleshooting federation, also supply the outbound
identity Client ID and Principal ID, and the federated credential's issuer/subject/audience
metadata. Never supply the managed-identity assertion, access token, private key, or a new client secret.

Ask the provider administrator to confirm the API tenant/app/scope, provision/authorize the
calling application's service principal in that tenant through its supported process, and
confirm the exact consent/application roles and account/channel entitlement. This repository
does not publish a supported Soprano consent URL or role-ID catalog; do not guess a role or
construct an admin-consent link from the sample's GUIDs. Record their completion confirmation.

Inspect the dedicated app's **Certificates & secrets > Federated credentials** and the outbound
identity's Overview. Setup's subject is the identity's **Principal ID**, issuer is the customer's
tenant-specific v2 issuer, and audience is `api://AzureADTokenExchange`. Do not substitute the
identity Client ID into the subject. These are customer-side checks only; they do not prove
provider-side consent. See [Microsoft's federation guidance](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation-config-app-trust-managed-identity)
for the mechanism, then use an authorized controlled live test to verify the full integration.

## Validate the deployed endpoint

<a id="4-package-deploy-and-verify"></a>
**Authorized testing is an assisted gate.** This repository supplies offline runtime tests, not
a customer self-service tool that obtains a token as Microsoft's phone-provider application.
An ordinary `az account get-access-token` result or a customer's test app is not that caller.
Do not add a test application to `allowedApplications`, disable Easy Auth, or publish a local
unauthenticated host to work around this. Ask the onboarding owner to arrange Microsoft's
approved EPP caller/test procedure. If unavailable, record **not validated** and do not activate.

Provide that operator the endpoint URL, customer tenant ID, endpoint application client ID,
identifier URI, encryption key ID, **public** certificate/thumbprint, and provider from your
inventory/summary, plus the intended channels and approved test window. Agree on controlled
recipients privately and obtain explicit permission before any paid/live send.

| Order / owner | Check | Evidence to retain without sensitive payloads |
|---|---|---|
| Azure operator | Read back HTTPS/Easy Auth and verify every serving route/hostname/slot has the intended issuer, audience, caller allowlist, and no SendOtp exemption. | Configuration review with resource identity and UTC time. |
| Azure operator | Perform the missing-token negative check below. | HTTP status; a rejection is not a healthy evaluation. |
| Authorized test operator | Invalid/expired/signature/wrong-issuer/wrong-audience tokens and unauthorized callers fail before handler execution. Pair negative checks with valid evaluations to rule out a general outage. | Expected versus observed status, UTC time, safe request/correlation IDs. |
| Authorized test operator | Valid encrypted `mode: 2` / `"evaluation"` request returns `200` and the matching nonce. Tampered/invalid envelopes fail. | Nonce match **boolean**, status, latency, and correlated application events; never the nonce/body. |
| Authorized test operator + provider | Submit an approved `mode: 1` live test for each intended channel after evaluation succeeds. Verify provider acceptance and actual handset receipt/audio. | Acceptance status plus separate recipient/provider delivery confirmation. No phone number, OTP, or raw response. |
| Operations owner | Confirm request/log ingestion, correct runtime schema, and notifications. | Saved query/resource scope and tested action-group/alert routing; see [monitoring](MONITORING.md). |

This bounded PowerShell check sends **no token and no OTP data**, and does not follow redirects.
Use the summary's exact HTTPS endpoint, never an example hostname or a provider URL:

```powershell
$endpoint = 'https://<function-host>/api/SendOtp'
$response = Invoke-WebRequest -Uri $endpoint -Method Post -ContentType 'application/json' `
    -Body '{}' -SkipHttpErrorCheck -MaximumRedirection 0 -TimeoutSec 30
$response.StatusCode
```

On the default single-region Easy Auth configuration, expect `401`. A `403` may instead be a
network/access rejection and needs investigation; `200` or a handler validation `400` means
this did not demonstrate the expected authentication gate. Transport/redirect errors are not
passes. This only checks the missing-token case, not all authorization or readiness properties.

Evaluation skips provider selection/credential lookup and provider HTTP **on its request path**.
With the selected cache enabled, configured workers can independently acquire credentials at startup;
JavaScript/Python also poll for refresh. Do not confuse those events with an evaluation sending a message.

For live requests, `200` with matching nonce means **provider acceptance, not delivery**.
Soprano voice extracts the first six-digit sequence; Telesign voice paces standalone six-digit
runs and repeats the message. Verify the actual locale, spoken digits, and recipient experience.
Do not blindly retry timeouts: provider acceptance can precede a lost response or caller fallback.
Repeat deployed checks after package, authentication, credential, key, or routing changes.

## Activate, operate, and retire

Only after the acceptance checks pass, have the policy administrator follow
[manual activation and rollback](../setup/docs/README.md#step-3---manually-validate-and-activate-policy).
Public Graph SMS/voice schemas do not document the EPP `url`/`appId` update. Obtain the
product-approved procedure; no guessed PATCH body is supplied here.

For handover, [find the linked monitoring resources](MONITORING.md#find-the-linked-resources-in-the-portal),
discover requests, then use [your runtime's event schema](MONITORING.md#runtime-specific-log-discovery).
There is no universal JSON request summary; operation, invocation, and application IDs differ.
Easy Auth can reject before application logs exist; `response_prepared` does not prove caller receipt.

Use [collection diagnostics](APPLICATION-INSIGHTS.md) for missing data and
[endpoint triage](../setup/docs/Troubleshooting.md#after-deployment-triage) for failures.
[Identity monitoring](SIGN-IN-MONITORING.md) is separate; setup does not export tenant logs or create alerts.

Assign ongoing owners for request failures/latency, provider account and credential rotation,
certificate expiry/renewal, alert routing, telemetry gaps, retention/cost, and policy rollback.
Setup creates telemetry resources, **not** alert rules, action groups, availability tests,
certificate contacts, or provider delivery receipts. Complete those manual operations before
relying on alerts. Keep the saved summary, approved policy snapshots, validation evidence,
package/source version, and renewal dates in restricted operational storage.

## Optional local development and manual deployment

<a id="local-settings-and-cloud-secrets"></a>
**Skip after guided setup unless customizing code.** Follow the
[JavaScript](../javascript/README.md), [Python](../python/README.md), or [.NET](../dotnet/README.md)
local setup. Copy [sample settings](local.settings.sample.json) beside that runtime's `host.json`;
replace placeholders, use string `Values`, and select `node`, `python`, or `dotnet-isolated`.

`UseDevelopmentStorage=true` needs local Azurite. Use a local **test** PEM/base64 PEM for
`EPP_DECRYPTION_KEY_PEM`; Core Tools cannot resolve Azure Key Vault references. For evaluation-only
local work, omit provider settings so startup does not try to acquire managed-identity credentials.
Your CLI login cannot substitute for the runtime's managed identity. Bind the host to loopback,
without tunnels/public forwarding: Core Tools has no Easy Auth. Never copy the production
private key, telemetry credentials, or all cloud settings to a workstation.

For custom cloud deployment, follow [packaging instructions](../TECHNICAL.md#download-a-function-zip)
and the selected plan's deployment mechanism. Python/.NET source ZIPs are not runnable
run-from-package artifacts. Exclude local settings, keys, tests, and diagnostic scripts using the
runtime's `.funcignore` and project publish rules. Source edits or a locally built ZIP do not
update Azure; apply approved cloud settings separately and rerun deployed acceptance checks.

<a id="2-provision-encryption-and-deployment-trust"></a>
### Manual deployment trust checklist

Guided setup already configures these. A manual deployer must retain equivalent platform
protection **before opening ingress**; the anonymous handler has no backup token validator.

| Easy Auth setting | Required value |
|---|---|
| `globalValidation.requireAuthentication` | `true` |
| `globalValidation.unauthenticatedClientAction` | `Return401` |
| `httpSettings.requireHttps` | `true` |
| `identityProviders.azureActiveDirectory.registration.clientId` | Endpoint app client ID |
| `identityProviders.azureActiveDirectory.registration.openIdIssuer` | Trusted tenant issuer matching token version; never `common` or `organizations` |
| `identityProviders.azureActiveDirectory.validation.allowedAudiences` | Exact endpoint-app audience agreed with the authorized caller |
| `identityProviders.azureActiveDirectory.validation.defaultAuthorizationPolicy.allowedApplications` | Nonempty authorized Microsoft caller app-ID allowlist, not the endpoint app ID |
| `globalValidation.excludedPaths` | No SendOtp or alternate-ingress exemption |

For v1, use the agreed Application ID URI audience and `https://sts.windows.net/{tenantId}/`
issuer; for v2, use the matching tenant-specific v2 issuer and agreed audience, normally the
endpoint app client-ID GUID. Never derive trust from the request's `tenantId` or forwarded headers.
Leave the app registration's `tokenEncryptionKeyId` **null**: encrypted Entra bearer tokens are
not supported. This does not disable JWE payload encryption. Never delete encryption credentials
or change signing keys just to make token validation pass.
