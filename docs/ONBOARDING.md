# Customer Onboarding

A high-level guide to setting up, securing, and deploying the External Phone Provider OTP Function. The
steps are the same for every language (`javascript/`, `dotnet/`, `python/`); only the build/run commands
differ (see each language's README). All config keys, Key Vault secret names, and behaviors are defined
once in [CONTRACT.md](CONTRACT.md).

## 1. Pick a language and a provider

Choose an implementation folder and the SMS/voice provider you have an account with (Infobip,
Telesign, Soprano, Sinch). One provider is active per deployment.

## 2. Store the provider secret in Key Vault

Provider API keys never live in code or app settings — put them in **Key Vault** under the names the
adapter expects (see [CONTRACT.md §3](CONTRACT.md)). The Function reads them at runtime via its
**managed identity**, which needs the *Key Vault Secrets User* role on the vault.

## 3. Configure

Set the app settings from [`local.settings.sample.json`](local.settings.sample.json) — locally in a
`local.settings.json` file, in Azure as environment variables. The keys are identical across languages;
the full catalog is in [CONTRACT.md §4](CONTRACT.md).

## 4. Run and send a test

Build/run per the language README, then `POST /api/SendOtp` with the cleartext envelope (the PII lives
in the encrypted JWE — see [CONTRACT.md](CONTRACT.md)). A **`200`** with the echoed `nonce`
(`{ "nonce": "<echo>", "correlationId": "<echo>", "providerStatus": "accepted" }`) means the provider
**queued** it — delivery is asynchronous, so confirm via the provider's delivery report.

## 5. Secure it — turn Easy Auth ON

**Enable App Service Authentication (Easy Auth) on the Function App. This is the recommended posture and
the primary gate** — the trigger itself is `authLevel: anonymous`, so with Easy Auth off the endpoint is
open to the internet. Configure:

- `unauthenticatedClientAction` = **`Return401`**
- `allowedApplications` = Microsoft's CYOT application id (`EPP_EXPECTED_CLIENT_ID`)

Anything else is then rejected before your code runs.

**Also set `EPP_REQUIRE_AUTH=true`.** Easy Auth is configured outside the code, so a portal change, slot
swap, or redeploy can silently drop it and nothing in the app would notice. In-process validation of the
**Entra JWT** (plus `EPP_EXPECTED_AUDIENCE` and `EPP_TENANT_ID`) is the backstop that fails closed if that
happens, and it is the only auth available when running locally with `func start`.

To test, obtain a token for the expected audience and confirm: no token → 401, valid token → 200.

## 6. Deploy

Publish the chosen language folder to a Function App (see its README). Ensure the app's managed
identity has Key Vault access and the same environment variables are set.

## 7. Add another provider

One adapter file — `manifest` + `buildRequest` + `parseResponse` — then store its secret in Key Vault
and set its endpoint app setting. No engine changes. See [CONTRACT.md §3](CONTRACT.md).
