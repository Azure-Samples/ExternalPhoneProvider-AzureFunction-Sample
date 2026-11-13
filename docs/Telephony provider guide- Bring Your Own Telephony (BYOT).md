# Telephony provider guide: Bring Your Own Telephony (BYOT)

**Audience:** Telephony providers who want Microsoft Entra ID customers to send SMS and voice sign-in codes through the provider's own service. You own your adapter, provider profile, tests, packages, and customer instructions. You reuse the shared setup, security, and runtime framework in this repository.

> **This guide is for BYOT only.** With Bring Your Own Telephony (BYOT), you publish your own integration and each customer deploys it in their own Azure subscription. It doesn't apply to Choose Your Own Telephony (CYOT), where customers select an integrated provider in the Microsoft Entra admin center. CYOT providers follow a separate Microsoft onboarding process.

> **Not a provider?** If you are a customer deploying a provider's published integration, use [Set up SMS and voice with your own telephony provider by using APIs](Set%20up%20SMS%20and%20voice%20with%20your%20own%20telephony%20provider%20by%20using%20APIs%20-%20BYOT.md) instead.

## How it works

1. Microsoft Entra ID sends an authenticated, encrypted one-time passcode (OTP) request to an Azure Function in the **customer's** Azure subscription.
2. The shared framework validates the caller, decrypts the request, and passes a provider-neutral message to **your adapter**.
3. Your adapter calls **your SMS or voice API** and tells the framework whether your API accepted the message.
4. The Function returns the result to Microsoft Entra ID. A success response means your API **accepted** the message, not that it reached the recipient.

You build step 3. Everything else is already done for you.

## What you deliver

When you finish this guide, you will have:

- A public GitHub fork containing your adapter, provider profile, and tests.
- Published Function packages (ZIP files) for each runtime you implemented.
- Customer instructions that include your repository, a fixed source version, your provider ID, the runtime, the package download URL, and how to authorize with your service.

## Before you start

- Choose one or more runtimes: JavaScript, C#, or Python. You don't need to implement all three.
- Gather your API details: authentication method, SMS and voice request formats, endpoint URLs, and the response statuses that mean "accepted", "blocked", and "failed".
- Prepare a provider test account you're authorized to use, plus offline sample responses for tests.
- Read the [Send OTP API contract](CONTRACT.md) (what Microsoft Entra ID sends and expects back) and the [logging requirements](LOGGING.md).

## 1. Create your repository

1. Fork [ExternalPhoneProvider-AzureFunction-Sample](https://github.com/Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample) from the latest `main` into a **public GitHub repository** in your organization. Keep your implementation and customer releases in this fork. You don't need to merge anything back to the original repository.
2. Enable GitHub Actions in your fork.
3. Allow the package workflow's `contents: write` permission, according to your organization's policy. The workflow needs this permission to publish releases.
4. Use `main` for automatic builds and releases. If you release from a different branch, update the push filter and publication condition in your fork's workflow.

Don't change the shared endpoint security or the existing providers. You don't need a provider-specific setup script.

## 2. Choose how the Function authenticates to your API

**Recommended: Microsoft Entra OAuth with managed identity federation.** No secrets are stored. All built-in providers use this method.

How it works:

1. The customer's Function uses its managed identity to act as the **customer's application**, without a secret.
2. That application requests a token from **your Microsoft Entra tenant** for **your API's scope**.
3. The adapter sends the token to your API as a bearer token.

What you set up once:

- An app registration in your tenant that exposes your API. Note its **application (client) ID**, which goes in `appId`, and its **scope**, for example `api://<your-api-app-id>/.default`.
- An API that validates incoming tokens. Check that the token was issued by your tenant, that the audience is your API, and that the calling application is one you have authorized for that customer's account.

What you do for each customer:

- The customer sends you their tenant ID, their application (client) ID, the channels they want (SMS, voice, or both), and the provider values from their setup summary.
- Your administrator authorizes that customer application in your tenant and links it to the customer's account.

If your API can't accept Microsoft Entra tokens, use [API-key authentication](#appendix-a-alternative-api-key-authentication).

## 3. Add your provider profile

The provider profile is a JSON file that setup reads to deploy and configure your integration.

1. Choose a fixed, lowercase provider ID, such as `sample`. Customers type this ID during setup.
2. Create `setup/providers/sample.json`. Replace every illustrative value with your own:

```json
{
  "deployment": {
    "enabled": true,
    "providerName": "Sample",
    "tenantId": "11111111-1111-1111-1111-111111111111",
    "languages": ["javascript"],
    "supportedEndpointRegions": ["global"],
    "authentication": {
      "mode": "oauth"
    },
    "routes": {
      "global": {
        "smsEndpoint": "https://api.example.com/sms",
        "voiceEndpoint": "https://api.example.com/voice",
        "appId": "22222222-2222-2222-2222-222222222222",
        "scope": "api://22222222-2222-2222-2222-222222222222/.default",
        "timeoutMilliseconds": 1500,
        "retryIntervalSeconds": 30
      }
    }
  }
}
```

3. Append `{"id":"sample","displayName":"Sample","file":"sample.json"}` to the `providers` array in `setup/providers/catalog.json`.

| Field | What to enter |
| --- | --- |
| `providerName` | The display name customers see. |
| `tenantId` | The ID of **your** Microsoft Entra tenant, the one that issues tokens for your API. If tokens come from a different tenant, add `AccessTokenScopeTenant` with that tenant's ID. Setup uses it instead of `tenantId`. |
| `languages` | Only the runtimes you implemented: `javascript`, `python`, and/or `dotnet`. Setup won't offer the others to customers. |
| `supportedEndpointRegions` | `["global"]`, `["eu"]`, or both. Add a matching entry under `routes` for each one. Setup detects each customer's route from their tenant. If you don't support that route, setup **rejects** the customer rather than redirecting them to another route. |
| `smsEndpoint`, `voiceEndpoint` | Complete HTTPS URLs for each channel. They can't contain credentials or fragments. Redirects aren't followed. |
| `appId`, `scope` | Your API's application ID and scope from step 2. The scope must match your API's exposed audience and end in `/.default`. |
| `timeoutMilliseconds` | How long the Function waits for your API. The default is 1500 and the maximum is 2500. Microsoft Entra ID waits only a short time, so keep your API fast. |
| `retryIntervalSeconds` | Retry guidance that setup records for handoff. The runtime makes at most one send attempt per request. |

## 4. Build and register your adapter

| Runtime | Add your implementation | Register it |
| --- | --- | --- |
| JavaScript | `javascript/src/functions/providers/sample.js`: `name`, `authenticationMode`, `credentialSpec`, `createRequest`, `interpretResponse` | Import or export it and add `sample` to `selectProvider` in `providers/index.js`. |
| Python | `python/src/providers/sample.py`: subclass `PhoneProviderBase` and implement `name`, `authentication_mode`, `credential_spec`, `build_request`, `map_response` | Add an instance to `_providers` in `python/function_app.py`. |
| C# | `dotnet/Src/Providers/SampleProvider.cs`: subclass `PhoneProviderBase` and implement `Name`, `AuthenticationMode`, `FetchCredentialsAsync`, `SendOtpAsync` (use `SendJsonAsync` for the shared JSON transport) | Register it as a singleton `PhoneProviderBase` in `dotnet/Program.cs`. |

Start from a built-in adapter (Infobip, Soprano, or Telesign) that is closest to your API.

**Your adapter must:**

- Use an authentication mode that matches the profile.
- Use the existing credential, timeout, transport, and result helpers.
- Map SMS and voice requests to your API.
- Deliver the **original Microsoft Entra OTP** exactly as received, preserving leading zeros. Don't generate a replacement code or verify the code yourself.
- Report acceptance only when your API returns a status you recognize as accepted. Treat unknown or malformed responses as failures.
- Report your API's documented risk or policy blocks as **blocks**, separately from failures.

**Your adapter must not:**

- Change caller authentication, decryption, evaluation, or public responses. The shared handler owns these.
- Log or return phone numbers, OTPs, nonces, tokens, credentials, private keys, or raw provider responses.

**How results reach Microsoft Entra ID:**

| Your API's outcome | Function response |
| --- | --- |
| Recognized acceptance | 200 |
| Explicit risk or policy block | 422 |
| Throttling (HTTP 429) | 429 |
| Other 4xx, including 401 and 403 | 400 |
| Credential, network, unrecognized, or malformed response | 502 |
| Timeout | 504 |

## 5. Test

Add tests to the existing test folder for each runtime you implemented (`javascript/test`, `python/tests`, `dotnet/tests`). Cover:

- Provider selection, required settings, and SMS and voice mapping.
- Exact OTP delivery, including leading zeros.
- Accepted, blocked, rejected, unknown, and malformed responses.
- Missing credentials, authentication failures, network failures, and timeouts.
- Evaluation requests that return **without reading credentials or calling your API**.
- Logs and responses that contain none of the sensitive data listed in step 4.

Also update any setup test fixtures that assume a fixed provider catalog. Follow each runtime's README and run its existing tests before you merge.

## 6. Publish packages

1. Push to your fork's `main` branch.
2. The **Function ZIPs** workflow runs the offline tests, builds all three runtimes, and publishes one release per runtime **in your repository**, named `epp-packages-<run>-<attempt>-<language>`. Each release contains `released-package.zip` and `SHA256SUMS.txt`.
3. Pull requests don't publish releases.

**Note:** Publish your first release **before** you share the setup command. Don't point customers to packages from the original repository, because those packages don't include your adapter. Advertise only the runtimes you implemented.

## 7. Give customers setup instructions

Direct customers to [Set up SMS and voice with your own telephony provider by using APIs](Set%20up%20SMS%20and%20voice%20with%20your%20own%20telephony%20provider%20by%20using%20APIs%20-%20BYOT.md) for deployment, provider authorization, authentication method policy configuration, and testing. Supply the provider-specific values that guide asks for.

Customers need:

- The environment and tools listed in the customer guide's [prerequisites](Set%20up%20SMS%20and%20voice%20with%20your%20own%20telephony%20provider%20by%20using%20APIs%20-%20BYOT.md#prerequisites).
- The Azure and Microsoft Entra permissions listed in the customer guide's [required permissions](Set%20up%20SMS%20and%20voice%20with%20your%20own%20telephony%20provider%20by%20using%20APIs%20-%20BYOT.md#required-permissions).

Share a command like this one. Replace each placeholder with your published values:

```powershell
$repository = '<provider-organization>/<provider-repository>'
$revision   = '<commit-id>'   # The exact source version you tested (a 40-character Git commit ID)

Invoke-WebRequest `
    -Uri "https://raw.githubusercontent.com/$repository/$revision/setup/Setup-Epp.ps1" `
    -OutFile .\Setup-Epp.ps1

# Review the downloaded script before running it.
.\Setup-Epp.ps1 -SourceRepository $repository -SourceRef $revision `
    -Provider sample -Language javascript `
    -PackagePath 'https://github.com/<provider-organization>/<provider-repository>/releases/download/<release-tag>/released-package.zip'
```

What the values mean:

- **`$revision`** pins the setup scripts to the exact version you tested. Find the commit ID on GitHub under your fork's **Commits** page.
- **`-PackagePath`** is the package to deploy. It can be the release download URL or a local file, such as `.\provider-package.zip`. The package must contain built deployment files and dependencies, not a source code archive. A URL must use HTTPS and can't contain credentials, query strings, or fragments.
  - Setup validates the archive and records its hash, but it doesn't compare checksums for direct packages. Distribute only trusted builds.
- **`-PackageReleaseTag`** is an alternative to `-PackagePath`. It selects a release in your repository by tag. If you leave out both options, setup uses the latest matching stable release. Don't use both.

Setup asks the customer to choose the tenant, subscription, application, Azure region, and hosting plan.

### What customers do after setup

Include these steps in your customer instructions:

1. **Review and approve** the deployment plan, then save the deployment summary.
2. **Authorize with you.** Send your onboarding team the customer tenant ID, application (client) ID, intended channels, and the provider values from the summary. For API-key providers, upload credentials as described in [Appendix A](#appendix-a-alternative-api-key-authentication).
3. **Validate.** An evaluation request confirms that the endpoint accepts and decrypts authenticated requests from Microsoft Entra ID. It doesn't contact your API or test credentials or delivery.
4. **Test live delivery** of SMS and voice to authorized test numbers. Confirm both your API's acceptance and actual delivery to the recipient.
5. **Meet your service's production requirements**, such as sender registration and supported countries.
6. **Activate** each intended channel's policy in Microsoft Entra ID **manually**.

Setup doesn't send live messages or activate policies. Direct customers to [Step 4: Update the authentication method policy](Set%20up%20SMS%20and%20voice%20with%20your%20own%20telephony%20provider%20by%20using%20APIs%20-%20BYOT.md#step-4-update-the-authentication-method-policy) and [Step 5: Test the integration](Set%20up%20SMS%20and%20voice%20with%20your%20own%20telephony%20provider%20by%20using%20APIs%20-%20BYOT.md#step-5-test-the-integration) in the customer guide.

## Appendix A. Alternative: API-key authentication

Use this option only if your API can't accept Microsoft Entra tokens.

**In your provider profile,** replace `deployment.authentication` with:

```json
{
  "mode": "apiKey",
  "identityKeyVaultSecretName": "sample-api-key-id",
  "keyVaultSecretName": "sample-api-key-secret"
}
```

- Set the adapter's authentication mode to `apiKey`, and use these exact secret names in its credential lookup.
- Remove the OAuth-only fields: `tenantId`, `AccessTokenScopeTenant`, and the route `appId` and `scope`.
- Omit `identityKeyVaultSecretName` if your API uses a single secret.
- Never put credential values in JSON, app settings, setup arguments, or terminal prompts.

**What setup does:**

- Creates any missing secrets as **disabled placeholders**.
- Keeps existing secrets without reading them.
- Stops, without overwriting anything, if it finds a soft-deleted secret with the same name or lacks Key Vault permission.
- Skips the outbound OAuth identity and federation, and keeps the endpoint application single-tenant.

How Microsoft Entra ID authenticates to the endpoint doesn't change.

**What customers do after setup:**

1. In the Azure portal, go to **Key Vault** > **Secrets** and select the named secret.
2. Select **New Version**, paste the real credential, and make sure the version is **enabled**.
3. Repeat for each secret. Never enable the placeholder version.
4. When rerunning setup, use the same application and resource prefix. Don't edit credentials while setup is running.

## Appendix B. Additional non-secret settings

If your adapter needs extra Function app settings, such as a service ID, add them under `deployment.environmentVariables`:

```json
{
  "SAMPLE_SERVICE_ID": {
    "displayName": "Provider service ID",
    "source": "input",
    "required": true,
    "validation": { "type": "pattern", "pattern": "^svc-[0-9]{4}$" }
  },
  "SAMPLE_REGION": {
    "displayName": "Provider region",
    "source": "fixed",
    "required": true,
    "value": "global"
  }
}
```

**Rules:**

- **Names** start with your uppercased provider ID followed by `_`, such as `SAMPLE_`. They are 3 to 64 characters long and use only uppercase letters, digits, or underscores. Reserved runtime and platform prefixes aren't allowed.
- **Each entry** needs `displayName`, `source` (`input` for a value the customer provides, or `fixed` for a value you set), and `required` (true or false). Only `fixed` entries include a `value`.
- **Validation** is optional. Use `e164` for phone numbers, or a regular expression anchored with `^…$`, up to 200 characters.
- **Values** are strings of up to 2,048 characters, with no control characters or angle brackets (`<`, `>`).
- An `input` entry can include a validated default, which is used when the customer presses Enter or runs setup unattended.

**How customers supply values:**

- Customers can add `-ProviderEnvironment @{ SAMPLE_SERVICE_ID = 'svc-1234' }` to the setup command. Otherwise, setup prompts for required values, or fails if it's running unattended.
- Setup shows the values in the plan before approval and saves them as app settings.
- On reruns, setup reuses existing values unless the customer replaces them. An empty string clears an optional value.
- Unknown names, overrides of fixed values, and invalid values fail with an explicit error.

**Note:** These values appear in the deployment plan and summary. **Never use them for secrets.**
