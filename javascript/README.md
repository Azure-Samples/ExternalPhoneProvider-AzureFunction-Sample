# JavaScript implementation

[Documentation](../docs/README.md) | [HTTP contract](../docs/CONTRACT.md) | [Settings](#environment-configuration)

Node.js implementation for Azure Functions v4. Guided deployment uses **Node.js 22** and one
provider per Function App.

## Deploy the sample

Follow the [deployment guide](../docs/GETTING-STARTED.md), then complete
[provider authorization and endpoint validation](../docs/ONBOARDING.md#complete-provider-authentication).

## Develop locally

Use Node.js 22 and npm. From the `javascript` directory:

```powershell
npm ci
npm test
```

These tests use local fixtures and mocked dependencies. For local Function execution, install
[Azure Functions Core Tools v4](https://learn.microsoft.com/azure/azure-functions/functions-run-local)
and Azurite, then create the local settings below.
Keep the local host accessible only from your machine; Easy Auth runs in Azure.

For deployment, [build the JavaScript package](../TECHNICAL.md#build-zips-locally), configure
[Easy Auth](../docs/ONBOARDING.md#manual-deployment-trust-checklist), and repeat the deployed checks.

## Environment configuration

Create an untracked `local.settings.json` beside [host.json](host.json).
For local evaluation, start Azurite and replace the test-key placeholder:

```json
{
  "IsEncrypted": false,
  "Values": {
    "AzureWebJobsStorage": "UseDevelopmentStorage=true",
    "FUNCTIONS_WORKER_RUNTIME": "node",
    "EPP_DECRYPTION_KEY_PEM": "<base64 of your local test private PEM>"
  }
}
```

Core Tools loads `Values` into environment variables. Direct Node processes and offline tests
do not load this file. Restart the host after changing settings.

For Azure deployment, use the [shared settings reference](../TECHNICAL.md#configure-environment-variables)
and [sample settings](../docs/local.settings.sample.json).
The bundled providers use OAuth through managed identity federation. Each channel has its own
configured HTTPS endpoint. The decryption key uses a versioned Key Vault reference in Azure;
local evaluation uses a local test key.

## Request behavior

`POST /api/SendOtp` follows the [HTTP contract](../docs/CONTRACT.md#http-request).
Easy Auth validates the caller in Azure. The handler validates the envelope and decrypts the JWE.

**Evaluation** returns the nonce before provider work. **Live** requests obtain an OAuth token
and send through the selected adapter. A live success confirms provider acceptance; verify
recipient delivery separately and investigate timeouts before retrying.

See [built-in provider behavior](../TECHNICAL.md#built-in-providers) and
[credential acquisition](../TECHNICAL.md#provider-settings-and-credential-acquisition).

## Source

| Source | Purpose |
| --- | --- |
| [SendOtp.js](src/functions/SendOtp.js) | HTTP orchestration and shutdown cancellation |
| [config.js](src/functions/config.js) | Deployment settings |
| [entraPayload.js](src/functions/entraPayload.js) | Envelope parsing and validation |
| [delivery.js](src/functions/delivery.js) | Decrypted context and provider-neutral delivery |
| [jwe.js](src/functions/jwe.js) | JWE validation and decryption |
| [providerTransport.js](src/functions/providerTransport.js) | HTTPS validation, timeout, transport, and response parsing |
| [providerResult.js](src/functions/providerResult.js) | Provider outcomes and endpoint status mapping |
| [credentials.js](src/functions/credentials.js) | Bounded credential acquisition and reusable SDK clients |
| [logging.js](src/functions/logging.js) | Privacy-safe structured events |
| [providers](src/functions/providers/) | Provider-specific request and response rules |
| [test](test/) | Offline tests |

To extend the sample, follow [Add a provider](../docs/BRING-YOUR-OWN-PROVIDER.md).
For diagnostics, use the [JavaScript event queries](../docs/MONITORING.md#application-events).
