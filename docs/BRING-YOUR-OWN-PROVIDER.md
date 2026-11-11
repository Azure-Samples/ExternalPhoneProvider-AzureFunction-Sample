# Add a provider adapter

[Documentation](README.md) | [Send OTP API](CONTRACT.md) | [Built-in providers](../TECHNICAL.md#built-in-providers)

Use the existing provider interfaces to extend one runtime. Start from the bundled Infobip,
Soprano, or Telesign adapter and your provider's documented API.

This is a development guide. For a standard deployment, use the
[deployment guide](GETTING-STARTED.md).

## Before you start

- Choose [JavaScript](../javascript/README.md), [C#](../dotnet/README.md), or [Python](../python/README.md).
- Confirm the provider's authentication, SMS and voice schemas, endpoints, and acceptance statuses.
- Prepare offline fixtures and an authorized provider test account.
- Review the [HTTP contract](CONTRACT.md) and [logging requirements](LOGGING.md).

Keep caller authentication, envelope validation, JWE decryption, evaluation, and public responses
in the shared request flow. The adapter owns provider credentials, request mapping, and response
interpretation.

## Implement and register the adapter

### JavaScript

1. Add the adapter under [providers](../javascript/src/functions/providers/).
2. Implement `name`, `authenticationMode`, `credentialSpec`, `createRequest`, and `interpretResponse`.
3. Register its fixed lowercase ID in `selectProvider` in [index.js](../javascript/src/functions/providers/index.js).
4. Return a `ProviderResult` using the shared outcome and safe failure classifications.
5. Add tests under [javascript/test](../javascript/test/).

### C#

1. Derive from [PhoneProviderBase](../dotnet/Src/PhoneProviderBase.cs) under
   [Providers](../dotnet/Src/Providers/).
2. Implement `Name`, `AuthenticationMode`, `FetchCredentialsAsync`, and `SendOtpAsync`.
3. Use `SendJsonAsync` for the shared JSON transport and return `ProviderResult`.
4. Register the provider as a singleton `PhoneProviderBase` in [Program.cs](../dotnet/Program.cs).
5. Add tests under [dotnet/tests](../dotnet/tests/).

### Python

1. Derive from [PhoneProviderBase](../python/src/provider.py) under
   [providers](../python/src/providers/).
2. Implement `name`, `authentication_mode`, `credential_spec`, `build_request`, and `map_response`.
3. Return `OutboundRequest` and `ProviderResult`.
4. Register an instance in `_providers` in [function_app.py](../python/function_app.py).
5. Add tests under [python/tests](../python/tests/).

## Configure and test

Set `EPP_PROVIDER_NAME` to the registered adapter ID and supply its authentication and complete
channel URLs. Reuse the shared credential-acquisition and timeout services.
See [runtime settings](../TECHNICAL.md#configure-environment-variables).

Verify:

- Provider selection, required settings, and SMS/voice mapping.
- Accepted, blocked, rejected, unknown, and malformed responses.
- Missing credentials, network failures, and timeouts.
- Evaluation returns before provider work.
- Logs and responses exclude phone data, OTPs, nonces, tokens, private keys, and raw provider bodies.

Only recognized provider acceptance can produce a live success response. Provider acceptance
and recipient delivery are separate outcomes.

## Package and deploy

1. Run the runtime's offline tests.
2. [Build a package](../TECHNICAL.md#build-zips-locally) containing the new adapter.
3. Follow the [custom deployment instructions](ONBOARDING.md#custom-deployment).
4. Complete provider authorization and the [endpoint checks](ONBOARDING.md#validate-the-deployed-endpoint).
5. Review [production readiness](../TECHNICAL.md#production-readiness).

Guided setup selects providers from its [catalog](../setup/providers/catalog.json).
Keep reusable onboarding in this repository; provider implementations belong in the provider's
own fork. No provider-specific setup script is needed.

### Prepare a provider fork

1. Fork the repository, enable GitHub Actions, and permit the package workflow's
   `contents: write` permission under your organization's policy.
2. Add and register the adapter, its tests, and `setup/providers/<provider-id>.json`.
   Add its ID, display name, and filename to `setup/providers/catalog.json`.
3. Declare `deployment.languages` as an array of implemented runtimes (`javascript`, `dotnet`,
   `python`). Omission retains all three runtimes for existing profiles.
4. Declare `deployment.supportedEndpointRegions` as `["global"]`, `["eu"]`, or both, and
   provide matching `deployment.routes`. Omission retains both routes. A tenant whose detected
   route is unsupported is rejected, not silently redirected.
5. Push to the fork's `main` branch. The existing **Function ZIPs** workflow runs offline
   runtime tests, packages the code, and automatically creates per-runtime releases in
   **the fork**, never in the upstream repository.

Each release is named `epp-packages-<run>-<attempt>-<language>` and contains exactly
`released-package.zip` and `SHA256SUMS.txt`. The release targets the workflow commit and is
not marked as GitHub's latest release. Automatic push builds remain restricted to `main`.
Pull requests and other branches do not publish; manual workflow dispatch publishes only
when run on `main`. Forks using a different release branch must change the push filter and
publication condition in their own workflow. Packaging currently
builds all three runtimes; `deployment.languages` prevents setup from selecting an unimplemented
runtime for your provider.

Customers download the normal launcher from your fork and explicitly select your repository:

```powershell
Invoke-WebRequest `
    -Uri 'https://raw.githubusercontent.com/<owner>/<fork>/main/setup/Setup-Epp.ps1' `
    -OutFile .\Setup-Epp.ps1

# Review the downloaded script before running it. Replace the sample values.
.\Setup-Epp.ps1 `
    -SourceRepository '<owner>/<fork>' `
    -SourceRef 'main' `
    -Provider '<provider-id>' `
    -Language javascript `
    -PackageReleaseTag 'epp-packages-<run>-<attempt>-javascript' `
    -ProviderEnvironment @{ SAMPLE_SERVICE_ID = 'svc-1234' }
```

`SourceRef` pins the setup assets to one resolved commit; `PackageReleaseTag` independently
pins the tested Function package. Both assets and packages come from `SourceRepository`.
Omitting the tag selects the latest matching stable release in that repository. Publish the
fork's first package release before distributing the setup command. Do not direct customers
to upstream ZIPs that lack your adapter.

### API-key provisioning metadata

For an API-key provider, use this authentication object in `deployment`:

```json
{
  "authentication": {
    "mode": "apiKey",
    "keyVaultSecretName": "sample-api-key-secret",
    "identityKeyVaultSecretName": "sample-api-key-id"
  }
}
```

`identityKeyVaultSecretName` is optional for single-secret APIs. The adapter's credential
specification must use these same names. Do not put credential values in JSON, application
settings, setup arguments, or terminal prompts. A `tenantId` is not required for API-key
authentication; OAuth profiles still require their provider tenant and API scopes.

After deployment approval, shared setup creates **disabled** `CUSTOMER-ACTION-REQUIRED`
versions only for missing secret names. Existing secrets are preserved without reading their
values. Soft-deleted conflicts and authorization failures stop setup rather than purging,
overwriting, or pretending credential provisioning succeeded.

API-key Functions retain the system identity for storage, monitoring, and Key Vault, but do
not create the outbound OAuth identity or federation. Microsoft caller authentication,
restricted application audiences, Easy Auth, encryption certificates, final approval, and
manual policy activation remain unchanged. Previously approved application tenant IDs are
preserved; a tenant-less provider adds no invented provider tenant.

### Additional non-secret settings

Declare a dictionary in `deployment.environmentVariables`, keyed by the exact app-setting name:

```json
{
  "environmentVariables": {
    "SAMPLE_SERVICE_ID": {
      "displayName": "Sample service ID",
      "description": "Existing service configured by the provider administrator.",
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
}
```

Names must start with the uppercased first segment of the provider ID plus `_` and use
3-64 uppercase letters, digits, or underscores. Reserved runtime/platform prefixes cannot be
used. Each field requires `displayName`, `source` (`input` or `fixed`), and boolean `required`;
only `fixed` fields declare `value`. Optional validation is `e164` or an anchored `pattern`
of at most 200 characters, evaluated with a one-second timeout.

Collect required **non-secret** inputs during setup, before approval. Customers can supply
`-ProviderEnvironment @{ NAME = 'value' }`; missing required inputs prompt interactively or
fail in unattended mode. Input fields may declare a validated string `default`, used on Enter
or in unattended mode when no value is supplied. Unknown names, fixed-field overrides, invalid
metadata, and invalid values fail explicitly. Values are strings up to 2048 characters without control characters
or angle brackets. The plan and saved summary display these values, so never declare secrets.

Reruns reuse existing declared input values unless explicitly replaced, validate them again,
and reject changes made to those settings between plan review and deployment. Fixed values
come from the reviewed profile. Optional inputs are not prompted; an explicit empty string
clears an optional setting. Undeclared settings are not adopted or merged by this feature.

### Customer credential handoff

Only after resources exist, the customer uses **Key Vault > Secrets > the named secret >
New Version** to upload each real credential as an **enabled** version. Never enable the dummy
placeholder version. Use the same application and resource prefix when rerunning setup;
do not run concurrent credential edits while provisioning.

Setup reports infrastructure completion separately from pending credentials and does not
send a live message. Evaluation can validate caller authentication and decryption with
placeholders still disabled; it cannot validate provider credentials or delivery. Test
authorized SMS and voice delivery, then activate each intended channel's policy manually.
