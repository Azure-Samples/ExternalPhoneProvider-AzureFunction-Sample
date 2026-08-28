# External Phone Provider Function — C# (.NET isolated worker)

A C# implementation of the External Phone Provider OTP-delivery Function, conforming to the shared
[contract](../docs/CONTRACT.md). Same design as the [`javascript/`](../javascript/) version:
one dispatch engine + drop-in provider adapters, env-provisioned config, secrets in Key Vault.

## Layout

```
dotnet/
├─ Program.cs                 # host + DI registration (add one line to onboard a provider)
├─ Functions/SendOtp.cs       # HTTP trigger: POST /api/SendOtp
├─ Src/
│  ├─ DispatchEngine.cs       # envelope parse → JWE decrypt → provider dispatch
│  ├─ ProviderRegistry.cs     # keyed adapter registry + EPP_PROVIDER_NAME resolution
│  ├─ IProviderAdapter.cs     # Manifest + BuildRequest + ParseResponse
│  ├─ Providers/*.cs          # infobip, telesign, soprano, sinch
│  ├─ SecretResolver.cs       # Key Vault via managed identity (cached)
│  ├─ ISecretResolver.cs      # secret-resolver abstraction (injectable for tests)
│  ├─ OutcomeMapper.cs        # status → outcome → HTTP status
│  ├─ Models.cs               # DispatchRequest + shared records
│  └─ TokenValidator.cs       # Entra JWT validation when EPP_REQUIRE_AUTH=true
└─ tests/                     # xUnit conformance tests
```

## Build, test, run

```bash
cd dotnet
dotnet build                       # build the Functions app
dotnet test tests                  # run conformance tests
func start                         # run locally (copy ../docs/local.settings.sample.json to local.settings.json)
```

## Deploy

```bash
func azure functionapp publish <your-function-app> --dotnet-isolated
```

The app's **managed identity** needs the **Key Vault Secrets User** role on the vault. Configuration
(env var names, Key Vault secret names, behaviors) is identical to the contract — see
[`../docs/CONTRACT.md`](../docs/CONTRACT.md).

Target: .NET 8 isolated worker, Functions v4.
