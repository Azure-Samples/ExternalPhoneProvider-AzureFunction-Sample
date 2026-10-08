# Offline multi-provider configuration validation

Validate multiple named **setup provider profiles** in one local run before considering deployment.
This is not a Function invocation, SAS trigger, authenticated evaluation, or delivery test.
A passing result means **configuration validity only**: it does not prove credentials, provider
account entitlement, sender/channel approval, API availability, or handset delivery.

## Prerequisites and coverage

Use PowerShell 7+ and a local checkout of this repository containing `setup/support` and
`setup/providers`. Unlike the deployment launcher, the validator does not download missing files.
No Azure CLI, Graph modules, sign-in, Azure subscription access, Key Vault access, or provider
credentials are needed. Do not put secret values in profiles or command arguments.

The shipped [setup catalog](../setup/providers/catalog.json) contains `telesign` and `soprano`.
Their [Telesign](../setup/providers/telesign.json) and [Soprano](../setup/providers/soprano.json)
profiles support `sms`/`voice` and `global`/`eu` selections. Provider scope is not an Azure region.
The Function runtimes also have Infobip and Sinch adapters, but **there are no setup profiles for
them in this catalog**; this command rejects those IDs rather than implying they are covered.
It does not validate arbitrary runtime app settings or discover providers from the environment.

## Run from the repository root

In PowerShell:

```powershell
.\setup\Test-EppProviders.ps1 -Provider telesign,soprano -Channel sms -EndpointRegion global
$LASTEXITCODE
```

Validate the voice/EU selection, or retain a single-provider check:

```powershell
.\setup\Test-EppProviders.ps1 -Provider telesign,soprano -Channel voice -EndpointRegion eu
.\setup\Test-EppProviders.ps1 -Provider telesign -Channel sms -EndpointRegion global
```

`Provider` is a PowerShell string array of catalog IDs. Case and surrounding whitespace are
normalized; aliases, unknown IDs, empty entries, and duplicates are rejected. Every occurrence of
a duplicate fails. The channel and provider scope are explicit and shared by the selections in
that run; run again for a different pair. They never change deployed routing.

For a separate process (including CI), use `-Command` so PowerShell constructs the array;
do not pass a comma-separated string to `pwsh -File` and expect it to become an array:

```powershell
pwsh -NoProfile -Command '& .\setup\Test-EppProviders.ps1 -Provider telesign,soprano -Channel sms -EndpointRegion global'
```

To check proposed profile edits, edit the local profile JSON or supply `-ProfileDirectory` pointing
to a local directory containing `catalog.json` and its profile JSON files:

```powershell
.\setup\Test-EppProviders.ps1 -Provider telesign,soprano -Channel sms -EndpointRegion global `
    -ProfileDirectory .\candidate-providers
```

Keep the same catalog IDs and complete profile contracts when preparing candidates. Catalog
entries must have unique IDs and files and unambiguous display names. Passing a custom catalog
does not add runtime adapter support. No profile contents, resolved app settings, endpoint URLs,
tenant IDs, credential values, or raw parser exceptions are included in reports.

## Output and failure behavior

The launcher writes one JSON report and exits **0 only if all selected configurations pass**.
It exits **1** for any invalid selection, catalog, unreadable profile, or invalid profile.
An empty batch or an invalid/unreadable/ambiguous catalog fails the run with `Errors` populated
and no `Results`; no provider can be resolved safely in those cases.

A successful two-provider report has this shape:

```json
{
  "Valid": true,
  "Errors": [],
  "Results": [
    { "Index": 1, "Provider": "telesign", "Valid": true, "Code": "ConfigurationValid", "Issues": [] },
    { "Index": 2, "Provider": "soprano", "Valid": true, "Code": "ConfigurationValid", "Issues": [] }
  ]
}
```

Results retain input order and a one-based `Index`. Unknown or empty provider selections have
`Provider: null` rather than echoing arbitrary input. Other result codes are `InvalidSelection`,
`DuplicateSelection`, `UnknownProvider`, `ProfileUnreadable`, and `ProfileInvalid`. `Issues`
contains safe descriptions; malformed input is not copied into an error message.

For example, `-Provider telesign,sinch,soprano` returns three results: Telesign and Soprano can
pass independently, Sinch returns `UnknownProvider`, the overall `Valid` is `false`, and the
exit code is 1. Similarly, an invalid Telesign profile does not prevent Soprano from being checked.
Fix the reported profile fields or JSON syntax locally, then rerun the same command.

For automation already running inside PowerShell, use the exported function without exiting
the caller; check `Valid` explicitly:

```powershell
Import-Module .\setup\support\Epp.Setup.psm1
$report = Test-EppProviderConfiguration -Provider telesign,soprano -Channel sms -EndpointRegion global
if (-not $report.Valid) {
    $report | ConvertTo-Json -Depth 6
    throw 'Offline provider configuration validation failed.'
}
```

## Code and validation boundary

- [CLI entry point](../setup/Test-EppProviders.ps1): JSON serialization and exit status.
- [Shared setup module](../setup/support/Epp.Setup.psm1): `Test-EppProviderConfiguration` resolves
  independent selections using `Get-EppProviderCatalog`, then reuses
  `ConvertTo-EppProviderSettings`, the same validator used by single-provider setup.
- [Focused tests](../setup/tests/Providers.Tests.ps1): independent results, invalid/duplicate
  selections, safe errors, offline behavior, CLI status, and single-provider regression.

The shared validator checks the enabled flag, provider identity, tenant GUID, authentication mode,
Key Vault **secret-name syntax** for API-key profiles, public HTTPS endpoint syntax, timeout/retry
bounds, and OAuth application ID/scope syntax. It requires **all four SMS/voice Global/EU routes**,
including routes not selected for this run, just as deployment setup does. Public hostname syntax
is not a DNS or reachability test. Secret names are configuration references, not fetched secrets.

This command only reads local catalog/profile files. It performs no HTTP requests, provider
sends, credential reads/refresh/rotation, resource deployments, or Graph policy/role changes.
It does not contact SAS, call the Function, or rely on evaluation/fallback behavior.

Existing deployment remains **one provider per endpoint**, selected by `EPP_PROVIDER_NAME`.
No runtime switching, fan-out, fallback, or multi-provider deployment is introduced. The
authenticated encrypted evaluation contract is unchanged: valid `mode: 2` requests return the
nonce before provider selection, credential resolution, or outbound provider calls. Offline
validation does not exercise or prove that contract on a deployed endpoint. Background credential
refresh in an existing deployment remains independent and is not triggered by this command.

Deployment, authenticated evaluation, provider onboarding, and any separately authorized live
delivery checks remain distinct steps. Never interpret `ConfigurationValid` as permission to
send a message or as evidence that an exposed credential is safe to reuse.
