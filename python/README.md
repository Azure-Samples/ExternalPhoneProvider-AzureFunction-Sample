# External Phone Provider Function — Python (v2 model)

A Python implementation of the External Phone Provider OTP-delivery Function, conforming to the shared
[contract](../docs/CONTRACT.md). Same design as the [`javascript/`](../javascript/) and
[`dotnet/`](../dotnet/) versions: one dispatch engine + drop-in provider adapters, env-provisioned
config, secrets in Key Vault.

## Layout

```
python/
├─ function_app.py            # HTTP trigger: POST /api/SendOtp (v2 model)
├─ requirements.txt
├─ src/
│  ├─ dispatch.py             # envelope parse → JWE decrypt → provider dispatch
│  ├─ providers/*.py          # infobip, telesign, soprano, sinch (manifest + build/parse)
│  ├─ secrets.py              # Key Vault via managed identity (cached)
│  └─ security.py             # Entra JWT validation when EPP_REQUIRE_AUTH=true
└─ tests/                     # pytest conformance tests
```

## Build, test, run

```bash
cd python
python -m venv .venv && .venv\Scripts\activate      # (macOS/Linux: source .venv/bin/activate)
pip install -r requirements.txt pytest
python -m pytest tests                               # run conformance tests
func start                                           # run locally (copy ../docs/local.settings.sample.json)
```

## Deploy

```bash
func azure functionapp publish <your-function-app>   # Linux Python Function App
```

The app's **managed identity** needs the **Key Vault Secrets User** role on the vault. Configuration
(env var names, Key Vault secret names, behaviors) is identical to the contract — see
[`../docs/CONTRACT.md`](../docs/CONTRACT.md).

Target: Azure Functions Python **v2** programming model (Python 3.11), Functions v4.

## Privacy and tracing

The handler emits one `[EPP]` summary with `requestId`, a log-safe `correlationId`, provider/channel/mode,
HTTP status/outcome, elapsed time, and booleans indicating nonce echo and evaluation processing.
GUIDs are normalized; other trace IDs use a labeled hash. Original wire IDs are preserved,
including the correlation-header fallback.

No plaintext logging switch is supported. Even `EPP_LOG_PLAINTEXT=true` cannot enable logging of
phone numbers, messages/codes, nonce values, risk context, tokens, keys, tenant IDs, JWE headers, or
raw bodies. Engine failures log fixed categories, never exception text or provider diagnostics.
Keep SDK/HTTP body tracing disabled as well; these application traces do not sanitize third-party logs.

Provider HTTP failures retain their mapped HTTP status and return a generic error, fixed outcome/status,
correlation ID, and generated request ID. Internal provider diagnostics must not be logged or forwarded
wholesale.
Success still returns `nonce`, `correlationId`, and `providerStatus: accepted`, including evaluation
mode. OAuth token acquisition and the Soprano `/messages/omnimsg` adapter are unchanged; the draft
design's future wire format is not implemented.
