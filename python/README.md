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
	app root beside [host.json](host.json). Configure decryption from the
	[shared catalog](../docs/CONTRACT.md#4-configuration-app-settings--env) and caller trust through
	[Easy Auth](../docs/ONBOARDING.md#2-provision-encryption-and-deployment-trust), the only authentication
	gate before the anonymous Function. Enable `requireAuthentication=true`,
	`unauthenticatedClientAction=Return401` and `requireHttps=true`; pin the trusted tenant issuer,
	endpoint-app `allowedAudiences` and a nonempty `allowedApplications` list for the authorized SAS
	caller. Do not exclude SendOtp. There is no backup application token validation; never expose the
	endpoint to the public internet with Easy Auth disabled or bypassed.
4. Use a virtual environment, install [requirements.txt](requirements.txt) and pytest, then run the
	offline [tests/](tests/) from this folder. Start the local Functions host from this app root.
	Core Tools has no Easy Auth: bind only to loopback, with no tunnels or public forwarding.
5. Publish this folder to a compatible Linux Python Function App with dependencies or a supported
	remote build. Inspect the package and apply [.funcignore](.funcignore); keep local settings and keys private.
	Offline tests cover application behavior, not platform authentication; run the separate
	[deployed security checks](../docs/ONBOARDING.md#4-package-deploy-and-verify).

## Request behavior

`POST /api/SendOtp` uses the same request and trust boundaries as the other runtimes. Incoming
`mode`, `channel`, `ttlSeconds` and `tenantId` are request data, not deployment authentication settings.
Easy Auth authenticates and authorizes the caller before the anonymous handler validates the envelope
and decrypts the JWE. Incoming `Authorization` is not parsed or echoed by the handler. JWE does not
authenticate SAS: anyone with the public key can encrypt a request, and a fixed nonce is not authentication.

Use incoming `mode: 2` or `mode: "evaluation"` as the generic shutter for every provider: platform
authentication on Azure, handler validation and decryption run, but provider lookup, provider Key Vault
reads and provider HTTP do not. No provider configuration or diagnostic environment flag is required.
Live requests forward the rendered message unchanged using the configured provider's API key and
await acceptance before returning the nonce; failures omit it. Acceptance is not handset delivery.
Platform/key prerequisites and HTTP outcomes are defined in the
[contract](../docs/CONTRACT.md#evaluation-generic-shutter).

## Source

| Source | Purpose |
|---|---|
| [function_app.py](function_app.py) | HTTP handler and adapter registration |
| [src/config.py](src/config.py) | Shared deployment settings |
| [src/dispatch.py](src/dispatch.py) | Request model, JWE, provider registry and outcome mapping |
| [src/providers/](src/providers/) | Adapter manifests and API-specific implementations |
| [src/secrets.py](src/secrets.py) | Cached Key Vault access via managed identity |

Add and register an adapter without adding provider-specific branches to the shared pipeline.
See [production limitations](../docs/CONTRACT.md#production-limitations) before production use.
