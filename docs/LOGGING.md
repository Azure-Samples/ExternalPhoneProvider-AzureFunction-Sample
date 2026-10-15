# Application log reference

[Documentation](README.md) | [Find deployed logs](MONITORING.md#runtime-specific-log-discovery) | [HTTP contract](CONTRACT.md)

This reference explains endpoint events and how to read them. Start an investigation with the
monitoring walkthrough, then use the runtime format shown here.

**Keep request bodies, decrypted fields, credentials, nonces, raw exceptions, and provider
response bodies out of logs.** Keep SDK, platform, and proxy body tracing off. This page
describes what the application emits; the monitoring pipeline determines what is collected.

## Runtime formats

| Runtime | Emission and context |
| --- | --- |
| JavaScript | JSON service records with immutable request context and existing camelCase/`x-ms-*` fields. |
| Python | Standard `logging`; `otp_log.py` defines fixed event IDs, names, levels, and fields. An immutable `LoggerAdapter` supplies Function and Microsoft trace identifiers. |
| .NET | Standard `ILogger`; `OtpLog` defines source-generated IDs/names. `ILogger.BeginScope` supplies `FunctionName`, `FunctionRequestId`, `FunctionInvocationId`, `MsClientRequestId`, `MsCorrelationId`, and `MsCorrelationIdSource`. |

Each invocation ends with a fixed `request_completed` event. It is not a changing summary of
every earlier event.
The configured logger/exporter owns formatting and property preservation.
The fields below describe JavaScript, **not portable custom properties**. Python uses `event_name`
and extras such as `httpStatus`; .NET uses `HttpStatus` and scopes such as `FunctionRequestId`.
Python/.NET provider-result events expose fewer fields; do not assume a provider reference ID is
collected. Verify the [deployed schema](MONITORING.md#runtime-specific-log-discovery).

## Event sequence

A successful live request emits these events in order:

| Service event | Safe information recorded |
|---|---|
| `request_received` | Function invocation and available raw Microsoft trace IDs under their `x-ms-*` names; no raw body or arbitrary headers. |
| `envelope_validated` / `payload_validated` | Allowlisted body metadata: validated payload type, normalized `channel`, `evaluation` and optional `ttlSeconds`. |
| `delivery_context_decrypted` | Decryption completed; no plaintext fields, JWE or key ID. |
| `provider_selected` | Registered provider and its authentication mode. |
| `provider_credential_resolution_started` | OAuth client-assertion or Key Vault credential source, with explicitly named raw OAuth application/identity/tenant IDs. |
| `provider_credential_resolved` | Credential resolution and usability checks completed, with elapsed time; no secret, token, assertion or claims. |
| `provider_request_build_started` | The provider is preparing the outbound request. |
| `provider_request_built` | Allowlisted HTTP method, final endpoint scheme/host/port/API path, HTTPS and disabled redirects; no query string, authorization headers or body. |
| `provider_request_started` | The outbound send is beginning, with method, sanitized endpoint and timeout. |
| `provider_response_received` | Actual upstream HTTP status; emitted before response-body reading completes. |
| `provider_response_processed` | Mapped provider status/outcome, fixed failure classification and duration. Raw provider descriptions and bodies are excluded. |
| `response_prepared` | Response status and booleans indicating nonce/correlation inclusion, not their values or the response body. |
| `request_completed` | Final HTTP status, result, and elapsed time; stage-specific fields stay on their events. |

JavaScript uses `envelope_validated`; Python/.NET use `payload_validated`.
Evaluation skips provider configuration, credentials, HTTP, and provider events. It emits
`evaluation_completed`, then `response_prepared` and `request_completed`.

Failures emit `request_failed` with fixed stage, reason, and HTTP status (`FailureStage`,
`FailureReason`, `HttpStatus` in .NET). Provider results retain coarse `Outcome` and a safe
classification: `provider_http_error`, `provider_rejected`, `unrecognized_provider_status`,
`missing_provider_message_id`, or `invalid_provider_json`. `provider_response_processed` includes
that classification, upstream HTTP status, and normalized status, never descriptions/bodies.
Credential acquisition/refresh failures use `credential_refresh_failed`; unexpected failures use
`unexpected_error`. No event adds credential reads, acquisition, or send retries.

`response_prepared` runs on success **and failure** before the handler returns. It does not prove
host serialization/transmission or caller receipt; use platform request telemetry for transport
completion. A parsed provider rejection uses `provider_response_processed` with a non-success
outcome and fixed reason.

`providerHttpStatus` is recorded when response headers arrive.
An upstream `200` can precede a body-read timeout: `provider_response_received` may be followed by
`request_failed` with Function `504`, without mapped provider status or success acknowledgement.
Unknown status text and malformed JSON are never logged; malformed JSON emits only
`provider_response_invalid_json` before provider outcome rules run.

## Safe fields and identifiers

Build metadata from **validated allowlisted fields**, not a body dump with sensitive properties
removed. Unknown properties, `tenantId`, locale/risk data, and decrypted fields stay excluded.
Invalid envelopes never contribute unvalidated type or TTL values.

`providerCredentialSource` is `managed_identity_client_assertion` for app tokens and `key_vault`
for API keys. Cached resolution does not imply a network fetch or fresh token exchange.
`providerCredentialElapsedMs` includes resolution and usability checks, not a separate deadline.
SDK diagnostics remain suppressed.

`provider_request_built` describes the outbound request, not a new physical connection or HTTP
client. `providerEndpoint` records the **final** scheme, host/port, and path, which can differ
from the configured base URL. For example, `https://provider.example/epp/voice?key=secret` becomes
`https://provider.example/epp/voice`. Userinfo, query strings, and fragments are excluded, but
**path segments are not redacted**: use provider-approved paths without secrets/personal data.
Logging does not alter the actual URL or required query parameters. Standard verbs are uppercase;
custom/invalid verbs appear as `other` without changing the sent request.

JavaScript/Python events carry Function request/invocation IDs and Microsoft trace IDs available
at that stage. JavaScript also carries known channel/evaluation/provider context; Python uses
its adapter and event arguments. Initially only header IDs are available; a valid envelope can
later supply the selected correlation. The generated Function request ID joins events even when
Microsoft IDs are absent or change. Log names deliberately distinguish these sources:

| Log field | Source and meaning |
|---|---|
| `functionName` | Runtime function name: `SendOtp` in JavaScript/.NET, `send_otp` in Python. The HTTP route remains `/api/SendOtp` in every runtime. |
| `functionRequestId` | Generated by this handler. Matches `requestId` in failure responses; it is not Microsoft's request ID. |
| `functionInvocationId` | Azure Functions host invocation ID. Null for direct handler calls without a host context. |
| `x-ms-client-request-id` | Raw Microsoft per-attempt ID from the header of the same name, not the generated fallback used by dispatch. |
| `x-ms-correlation-id` | Raw selected Microsoft correlation: envelope `correlationId` first, then the header of the same name. The existing precedence is unchanged, and this never contains a generated Function ID. |
| `msCorrelationIdSource` | `envelope`, `header` or `none`; disambiguates the selected value when the envelope and header differ. |
| `providerMessageId` | Raw provider-normalized message/reference ID returned by the provider, including Telesign `reference_id`, for support lookup. Not filled from delivery or Function IDs, although a provider may echo an ID it received. |
| `providerTenantId` | Raw configured `EPP_PROVIDER_TENANT_ID` for OAuth, not incoming envelope `tenantId`. |
| `functionOutboundClientId` | Raw application's `EPP_OUTBOUND_CLIENT_ID` used for provider access, not a Microsoft request ID. Guided setup reuses the endpoint app client ID here; its outbound purpose is distinct from the inbound audience setting. |
| `functionOutboundManagedIdentityClientId` | Raw configured `EPP_OUTBOUND_MI_CLIENT_ID` used to obtain the app assertion, not the Key Vault identity or the identity's principal/Object ID. |
| `providerEndpoint` | Validated final outbound URL without userinfo, query string or fragment; scheme, host/port and API path remain visible. |

The six external/configuration ID fields preserve raw values and case, without hashing/truncation.
Only nonblank strings of **1-128 ASCII characters** are recorded: a letter/digit first, then
letters, digits, `.`, `_`, `:`, or `-`. Missing/blank values are null; other invalid values are
null and their names appear in `omittedIdFields`, never their values.
These guards affect logs only, not wire IDs, correlation precedence, or outcomes.
Application/client/tenant IDs are identifiers, not secrets or trust assertions; incoming
`tenantId` never becomes a trusted identity.

## Levels and collection

Normal/completion events use **Information**; invalid requests, non-success 4xx outcomes, and
advisories use **Warning**; 5xx failures/timeouts use **Error**.
Keep Information logs enabled for investigation without enabling SDK/body tracing.

Filters and sampling can remove events. Application events are logs, not host Request telemetry;
excluding `Request` from sampling does not retain every event. Configure collection and retention
deliberately. Easy Auth rejection happens before the handler: inspect platform/authentication
diagnostics and caller observations rather than expecting an application event.

Next: [verify collection](APPLICATION-INSIGHTS.md#single-region-configuration), then use
[runtime-specific queries](MONITORING.md#runtime-specific-log-discovery).
