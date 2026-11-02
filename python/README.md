# Python implementation

[Documentation](../docs/README.md) | [HTTP contract](../docs/CONTRACT.md) | [Settings](#environment-configuration)

**Python 3.11**, Azure Functions v4, Python v2 programming model.
Guided deployment uses one provider per Function App.

## Deploy the sample

Follow the [deployment guide](../docs/GETTING-STARTED.md) with `-Language python`, then complete
[provider authorization and endpoint validation](../docs/ONBOARDING.md#complete-provider-authentication).

## Develop locally

Use Python 3.11 in a virtual environment. From the `python` directory, create and activate
the environment. For PowerShell on Windows:

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install -r requirements.txt pytest
python -m pytest tests
```

On other platforms, use the corresponding
[virtual-environment activation command](https://docs.python.org/3.11/library/venv.html#how-venvs-work).
The tests use local fixtures and mocked dependencies.

For local Function execution, install
[Azure Functions Core Tools v4](https://learn.microsoft.com/azure/azure-functions/functions-run-local)
and Azurite, then create the settings below.
Keep the local host accessible only from your machine; Easy Auth runs in Azure.

Build Azure packages on **Linux x64 with Python 3.11** using the
[Python packaging script](../TECHNICAL.md#build-zips-locally).
Configure [Easy Auth](../docs/ONBOARDING.md#manual-deployment-trust-checklist) and repeat the
deployed checks after publication.

## Environment configuration

Create an untracked `local.settings.json` beside [host.json](host.json).
For local evaluation, start Azurite and replace the test-key placeholder:

```json
{
  "IsEncrypted": false,
  "Values": {
    "AzureWebJobsStorage": "UseDevelopmentStorage=true",
    "FUNCTIONS_WORKER_RUNTIME": "python",
    "EPP_DECRYPTION_KEY_PEM": "<base64 of your local test private PEM>"
  }
}
```

Core Tools loads `Values` into `os.environ`. Direct Python processes and pytest do not load this
file. Restart the host after changing settings.

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
| [function_app.py](function_app.py) | Request handling and provider selection |
| [config.py](src/config.py) | Deployment settings |
| [models.py](src/models.py) | Envelope, delivery context, request, and result models |
| [jwe.py](src/jwe.py) | JWE decryption |
| [provider.py](src/provider.py) | HTTPS transport, timeout, and endpoint status mapping |
| [credentials.py](src/credentials.py) | Bounded credential acquisition and reusable SDK clients |
| [otp_log.py](src/otp_log.py) | Privacy-safe logging and request context |
| [providers](src/providers/) | Provider request and response mapping |
| [tests](tests/) | Offline tests |

To extend the sample, follow [Add a provider](../docs/BRING-YOUR-OWN-PROVIDER.md).
For diagnostics, verify the [runtime log format](../docs/MONITORING.md#runtime-log-formats)
preserved by your deployed logging pipeline.
