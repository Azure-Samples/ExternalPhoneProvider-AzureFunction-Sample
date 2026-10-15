# Customer configuration and validation

[Documentation](README.md) | [First deployment](GETTING-STARTED.md) | [Troubleshooting](../setup/docs/Troubleshooting.md)

After deployment, complete [provider authentication](#complete-provider-authentication), then
[validate the endpoint](#validate-the-deployed-endpoint).

| Task | Go to |
| --- | --- |
| Confirm access before spending | [Eligibility and approved procedures](#before-purchasing-or-deploying) |
| Find or check setup values | [Inputs](#inputs-you-supply-to-setup), [setup-managed values](#values-setup-configures-for-you) |
| Connect the provider | [Credential names and handoff](#complete-provider-authentication) |
| Test and activate | [Acceptance checks](#validate-the-deployed-endpoint), [operations handover](#activate-operate-and-retire) |
| Build a custom package | [Custom development and deployment](#custom-development-and-manual-deployment) |

## Before purchasing or deploying

In [Microsoft Security Store](https://securitystore.microsoft.com/private-solutions), confirm
account activation, sender registration, countries, channels, pricing, and EPP access.

![Cropped examples of phone-provider offer cards in Microsoft Security Store](images/onboarding/security-store-providers.png)

*Sample cards only. Check [guided provider support](#provider-credential-names).*

Before deployment, confirm eligibility, licensing, preview access, an authorized test caller,
and Microsoft's activation procedure. Use the offer's support route or Microsoft support for
missing access. Azure subscription ownership does not grant EPP access.

Assign an **onboarding owner** to coordinate tenant policy, Azure, the provider, and Microsoft support.

Use [production readiness](../TECHNICAL.md#production-readiness) to plan the
capabilities your live service needs, such as durable delivery, retry and deduplication strategy,
an end-to-end deadline, certificate renewal, and delivery confirmation.

## Values and ownership

### Inputs you supply to setup

Use values from the named portal pages. The
[noninteractive example](../setup/docs/README.md#noninteractive-example) uses the same parameters.

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

**Global/EU selects provider routing, not Azure placement or residency.** Current Telesign and
Soprano profiles use the same Global/EU URLs; Soprano also shares its app ID and scope. Confirm
provider data locations separately.

**One guided deployment has one provider and both channels.** Validate each channel separately.
Changing provider or region with the same subscription, app, and prefix reconfigures that
endpoint. Use a new app and prefix for an independent endpoint. See [Front Door](FRONTDOOR.md)
for regional origins.

### Values setup configures for you

<a id="setup-script-compatibility"></a>
Keep `deployment-*.json` and the public certificate in private storage. Compare the summary with
the approved plan. `policyChanged: false` is expected.

Inspect settings in **Function App > Settings > Environment variables**. Keep setup-managed
values out of tickets and avoid copying settings from another app.

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

The trust paths are separate: Easy Auth checks the caller, the Key Vault certificate decrypts
the JWE, and provider credentials authorize delivery.

## Complete provider authentication

<a id="provider-credential-names"></a>
Guided setup supports **Soprano and Telesign**. Other bundled adapters require custom deployment.

| Provider | Credential names / mode | Deployment support |
|---|---|---|
| `infobip` | `infobip-api-key`; `Authorization: App ...` | Adapter only; no guided profile. Validate its account/options separately. |
| `sinch` | `sinch-api-token`; static token | Adapter only; no guided profile. Validate its account/options separately. |
| `soprano` | No API-key secrets; OAuth client assertion | Guided; complete the [provider-admin handoff](#soprano-provider-administrator-handoff). |
| `telesign` | `telesign-api-key` and `telesign-customer-id`; Basic authentication | Guided; complete the [vault steps](#telesign-enter-and-verify-the-two-vault-secrets). |

### Where to enter API-key credentials in Key Vault

Use the vault named in the deployment summary:

1. Open the saved deployment summary and find `resources.keyVault`.
2. In **Azure portal > Key vaults**, open that vault.
3. Select **Objects > Secrets**. This list shows secret names and status, not their values.
   Select **Generate/Import** to enter a credential.

![Key Vault Objects menu with Secrets selected and the Generate/Import action visible](images/onboarding/key-vault-secrets.png)

*The screenshot contains test examples. Create only the required secrets.*

4. Choose **Manual**. For **Name**, use the exact name in the provider table above.
   For **Secret value**, paste the credential obtained through your provider's secure process.
   Leave **Enabled** set to **Yes** and set activation/expiry dates to match your provider agreement.
5. Select **Create** only after checking the vault, name, and value. Repeat for any additional
   required credential, such as an account/customer ID.

![Unsaved Create a secret form showing a sample name, masked placeholder value, and Enabled set to Yes](images/onboarding/key-vault-create-secret.png)

*Use the exact provider secret name. The shown value is fake.*

After saving, verify the name, enabled state, and version without viewing the value. Keep the
setup-created encryption certificate unchanged.

<a id="telesign-enter-and-verify-the-two-vault-secrets"></a>
### Telesign credentials

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
   it for EP1. Plan first-use and rotation checks from
   [credential caching](../TECHNICAL.md#provider-settings-and-credential-caching).
   No warning is not proof of account authorization.

Use portal secret entry rather than command-line literal values, transcripts, source files,
screenshots, or chat. During rotation, coordinate the matching pair and provider validity window;
two secret updates are not atomic. Keep old credentials usable during the approved transition
where the provider supports it, and verify live delivery before retiring them.

<a id="soprano-provider-administrator-handoff"></a>
### Soprano credentials

Setup creates customer-side federation, **not** the commercial account or access in Soprano's
tenant. Complete this handoff before treating OAuth as ready.

Send **identifiers only** through the provider's approved onboarding channel:

- customer tenant ID and `applicationId` / `EPP_OUTBOUND_CLIENT_ID`
- intended channels and their full provider URLs
- `EPP_PROVIDER_TENANT_ID`, `EPP_PROVIDER_APP_ID`, and `EPP_PROVIDER_SCOPE`
- the provider-requested account or sender reference

For federation troubleshooting, also provide the outbound identity Client ID and Principal ID,
plus the federated credential's issuer, subject, and audience. Keep the managed-identity assertion,
access token, private key, and client secrets private.

Ask the provider administrator to confirm the API tenant, app, and scope. They can then authorize
the calling application's service principal through the provider's supported process and confirm
the exact consent, application roles, and account/channel access. Use the provider's approved
consent path rather than building a URL or role list from sample GUIDs. Record the completion
confirmation.

Inspect the dedicated app's **Certificates & secrets > Federated credentials** and the outbound
identity's Overview. Setup's subject is the identity's **Principal ID**, issuer is the customer's
tenant-specific v2 issuer, and audience is `api://AzureADTokenExchange`. Do not substitute the
identity Client ID into the subject. These are customer-side checks only; they do not prove
provider-side consent. See [Microsoft's federation guidance](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation-config-app-trust-managed-identity)
for the mechanism, then use an authorized controlled live test to verify the full integration.

## Validate the deployed endpoint

<a id="4-package-deploy-and-verify"></a>
**Use Microsoft's assisted process for authorized testing.** The repository provides offline
runtime tests, while Microsoft supplies the approved EPP caller and test procedure. An ordinary
`az account get-access-token` result or a customer test app represents a different caller.
Keep `allowedApplications` and Easy Auth unchanged, and keep local hosts private. Ask the
onboarding owner to arrange the approved procedure. Activate after that validation is complete.
If the procedure is not available, record **not validated** and leave the policy inactive.

Provide the operator with the endpoint URL, customer tenant ID, endpoint application client ID,
identifier URI, encryption key ID, and **public** certificate or thumbprint. Also provide the
selected provider, intended channels, and approved test window from the deployment inventory.
Agree on controlled recipients privately and get permission before any paid live send.

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

<a id="activate-operate-and-retire"></a>
## Operations lifecycle

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

<a id="optional-local-development-and-manual-deployment"></a>
## Custom development and manual deployment

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
