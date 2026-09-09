# External Phone Provider Function — Python (v2 model)

Implements the shared [contract](../docs/CONTRACT.md) with one dispatch engine and one selected
provider per deployment. Target: Python 3.11, Azure Functions v4, Python v2 programming model.

## Setup and deployment

1. Follow [customer onboarding](../docs/ONBOARDING.md). Set `EPP_PROVIDER_NAME` to the selected
	adapter's registered manifest id (`<adapter-id>` is only a placeholder).
2. Consult the selected adapter and its manifest in [src/providers/](src/providers/) for required
	credentials and options. Store credentials in Key Vault under the declared secret names, grant
	the Function's managed identity *Key Vault Secrets User*, and configure the matching endpoint/options.
3. Base private local settings on [../docs/local.settings.sample.json](../docs/local.settings.sample.json),
	replacing placeholders and selecting `FUNCTIONS_WORKER_RUNTIME=python`. Put settings at the
	app root beside [host.json](host.json). Use the shared authentication/encryption catalog; Azure
	requires Easy Auth and in-process JWT validation. No host-detection setting is customer-provisioned.
4. Use a virtual environment, install [requirements.txt](requirements.txt) and pytest, then run the
	offline [tests/](tests/) from this folder. Start the local Functions host from this app root.
5. Publish this folder to a compatible Linux Python Function App with dependencies or a supported
	remote build. Inspect the package and apply [.funcignore](.funcignore); keep local settings and keys private.

## Request behavior

`POST /api/SendOtp` uses the same request and trust boundaries as the other runtimes. Incoming
`mode`, `channel`, `ttlSeconds` and `tenantId` are request data, not deployment authentication settings.

Use incoming `mode: 2` or `mode: "evaluation"` as the generic shutter for every provider: authentication,
validation and decryption run, but provider lookup, provider Key Vault reads and provider HTTP do not.
No provider configuration or diagnostic environment flag is required. Authentication/key prerequisites
and live acceptance semantics are defined in the [contract](../docs/CONTRACT.md#evaluation-generic-shutter).

## Source

| Source | Purpose |
|---|---|
| [function_app.py](function_app.py) | HTTP handler and adapter registration |
| [src/config.py](src/config.py) | Shared deployment settings |
| [src/dispatch.py](src/dispatch.py) | Request model, JWE, provider registry and outcome mapping |
| [src/providers/](src/providers/) | Adapter manifests and API-specific implementations |
| [src/secrets.py](src/secrets.py) | Cached Key Vault access via managed identity |
| [src/security.py](src/security.py) | Inbound JWT validation |

Add and register an adapter without adding provider-specific branches to the shared pipeline.
See [production limitations](../docs/CONTRACT.md#production-limitations) before production use.
