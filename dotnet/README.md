# C# implementation

[Documentation](../docs/README.md) | [HTTP contract](../docs/CONTRACT.md) | [Settings](#environment-configuration)

**.NET 10 isolated worker** implementation for Azure Functions v4.
Guided deployment uses one provider per Function App on Linux Flex Consumption or Premium.

## Deploy the sample

Follow the [deployment guide](../docs/GETTING-STARTED.md) with `-Language csharp`, then complete
[provider authorization and endpoint validation](../docs/ONBOARDING.md#complete-provider-authentication).

## Develop locally

Install the .NET 10 SDK. From the `dotnet` directory:

```powershell
dotnet build
dotnet test tests
```

These tests use local fixtures and mocked dependencies. For local Function execution, install
[Azure Functions Core Tools v4](https://learn.microsoft.com/azure/azure-functions/functions-run-local)
and Azurite, then create the local settings below.
Keep the local host accessible only from your machine; Easy Auth runs in Azure.

For deployment, [build the C# package](../TECHNICAL.md#build-zips-locally), configure
[Easy Auth](../docs/ONBOARDING.md#manual-deployment-trust-checklist), and repeat the deployed checks.

## Environment configuration

Create an untracked `local.settings.json` beside [host.json](host.json).
For local evaluation, start Azurite and replace the test-key placeholder:

```json
{
  "IsEncrypted": false,
  "Values": {
    "AzureWebJobsStorage": "UseDevelopmentStorage=true",
    "FUNCTIONS_WORKER_RUNTIME": "dotnet-isolated",
    "EPP_DECRYPTION_KEY_PEM": "<base64 of your local test private PEM>"
  }
}
```

Core Tools loads `Values` into environment variables. Direct worker execution and tests do not.
Restart the host after changing settings. The project excludes local settings from publish output.

For Azure deployment, use the [shared settings reference](../TECHNICAL.md#configure-environment-variables)
and [sample settings](../docs/local.settings.sample.json).
The bundled providers use OAuth through managed identity federation. Each channel has its own
configured HTTPS endpoint. The decryption key uses a versioned Key Vault reference in Azure;
local evaluation uses a local test key.

## Request behavior

`POST /api/SendOtp` follows the [HTTP contract](../docs/CONTRACT.md#http-request).
Easy Auth validates the caller in Azure. The Functions host binds `EntraSendOtpPayload` before
the handler runs. Malformed JSON or invalid enum values can therefore produce a host-generated
error before application logging.

**Evaluation** returns the nonce before provider work. **Live** requests obtain an OAuth token
and send through the selected adapter. A live success confirms provider acceptance; verify
recipient delivery separately and investigate timeouts before retrying.

See [built-in provider behavior](../TECHNICAL.md#built-in-providers) and
[credential acquisition](../TECHNICAL.md#provider-settings-and-credential-acquisition).

## Source

| Source | Purpose |
| --- | --- |
| [Program.cs](Program.cs) | Host, provider, credential-service, and HTTP-client registration |
| [SendOtp.cs](Functions/SendOtp.cs) | Request handling and delivery orchestration |
| [AppConfig.cs](Src/AppConfig.cs) | Deployment settings |
| [EntraSendOtpPayload.cs](Src/EntraSendOtpPayload.cs) | Bound envelope and validation |
| [JweDeliveryContext.cs](Src/JweDeliveryContext.cs) | JWE decryption and delivery context |
| [CredentialTokenService.cs](Src/CredentialTokenService.cs) | Bounded provider credential acquisition |
| [OAuthCredentialSource.cs](Src/OAuthCredentialSource.cs) | Managed-identity assertion exchange and reusable SDK clients |
| [OtpLog.cs](Src/OtpLog.cs) | Typed structured logging |
| [PhoneProviderBase.cs](Src/PhoneProviderBase.cs) | Provider interface and shared JSON/HTTP transport |
| [Providers](Src/Providers/) | Provider request and response mapping |
| [Models.cs](Src/Models.cs) | Outcomes and shared records |
| [tests](tests/) | Offline tests |

To extend the sample, follow [Add a provider](../docs/BRING-YOUR-OWN-PROVIDER.md).
For diagnostics, verify the deployed [runtime log format](../docs/MONITORING.md#runtime-log-formats)
and [collection configuration](../docs/APPLICATION-INSIGHTS.md#collection).
