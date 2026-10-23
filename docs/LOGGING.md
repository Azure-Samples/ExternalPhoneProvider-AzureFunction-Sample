# Application log reference

[Documentation](README.md) | [Find deployed logs](MONITORING.md#runtime-specific-log-discovery) | [HTTP contract](CONTRACT.md)

This reference defines safe event fields, request flow, and runtime differences.

| Need | Section |
| --- | --- |
| Compare runtime output | [Runtime formats](#runtime-formats) |
| Follow one request | [Event sequence](#event-sequence) |
| Interpret IDs and fields | [Safe fields and identifiers](#safe-fields-and-identifiers) |
| Distinguish credential failures | [Credential diagnostics](#credential-diagnostics) |
| Configure collection | [Levels and collection](#levels-and-collection) |

**Exclude request bodies, decrypted fields, credentials, nonces, raw exceptions, and provider
responses.** Keep body tracing off.

## Runtime formats

| Runtime | Emission and context |
| --- | --- |
| JavaScript | JSON service records with immutable request context and existing camelCase/`x-ms-*` fields. |
| Python | Standard `logging`. `otp_log.py` defines fixed event IDs, names, levels, and fields. An immutable `LoggerAdapter` supplies Function and Microsoft trace identifiers. |
| .NET | Standard `ILogger`. `OtpLog` defines source-generated IDs/names. `ILogger.BeginScope` supplies `FunctionName`, `FunctionRequestId`, `FunctionInvocationId`, `MsClientRequestId`, `MsCorrelationId`, and `MsCorrelationIdSource`. |

Each invocation ends with `request_completed`. Exporters control formatting and property
preservation. Field names differ by runtime, so verify the
[deployed schema](MONITORING.md#runtime-specific-log-discovery).

## Event sequence

A successful live request emits these events in order:

| Service event | Safe information recorded |
|---|---|
| `request_received` | Function invocation and available raw Microsoft trace IDs under their `x-ms-*` names. Excludes the raw body and arbitrary headers. |
| `envelope_validated` / `payload_validated` | Allowlisted body metadata: validated payload type, normalized `channel`, `evaluation` and optional `ttlSeconds`. |
| `delivery_context_decrypted` | Decryption completed. Excludes plaintext fields, JWE, and key ID. |
| `provider_selected` | Registered provider and its authentication mode. |
| `provider_credential_resolution_started` | OAuth client-assertion or Key Vault credential source, with explicitly named raw OAuth application/identity/tenant IDs. |
| `provider_credential_resolved` | Credential resolution and usability checks completed, with elapsed time. Excludes secrets, tokens, assertions, and claims. |
| `provider_request_build_started` | The provider is preparing the outbound request. |
| `provider_request_built` | Allowlisted HTTP method, final endpoint scheme/host/port/API path, HTTPS, and disabled redirects. Excludes the query string, authorization headers, and body. |
| `provider_request_started` | The outbound send is beginning, with method, sanitized endpoint and timeout. |
| `provider_response_received` | Actual upstream HTTP status. Emitted before response-body reading completes. |
| `provider_response_processed` | Mapped provider status/outcome, fixed failure classification and duration. Raw provider descriptions and bodies are excluded. |
| `response_prepared` | Response status and booleans indicating nonce/correlation inclusion, not their values or the response body. |
| `request_completed` | Final HTTP status, result, and elapsed time. Stage-specific fields stay on their events. |

JavaScript uses `envelope_validated`. Python and .NET use `payload_validated`.
Evaluation skips provider work and emits `evaluation_completed`, `response_prepared`, and
`request_completed`.

Failures emit `request_failed` with stage, reason, and HTTP status (`FailureStage` and
`FailureReason` in .NET). Provider results use
`Outcome` and a safe classification: `provider_http_error`, `provider_rejected`, `unrecognized_provider_status`,
`missing_provider_message_id`, or `invalid_provider_json`. `provider_response_processed` includes
that classification, upstream HTTP status, and normalized status, never descriptions/bodies.
Credential acquisition failures use `request_failed` with stage `provider_credentials`, reason
`credential_unavailable`, and HTTP `502`. A preceding `provider_credential_resolution_failed`
event supplies the [internal diagnostic](#credential-diagnostics). There are no background credential-refresh events.
Unexpected failures use `unexpected_error`. No event adds credential reads, acquisition, or send retries.

`response_prepared` runs before successful and failed returns. It does not prove caller receipt.

`providerHttpStatus` is recorded when response headers arrive.
An upstream `200` can precede a body-read timeout: `provider_response_received` may be followed by
`request_failed` with Function `504`, without mapped provider status or success acknowledgement.
Unknown status text and malformed JSON are never logged. Malformed JSON emits only
`provider_response_invalid_json` before provider outcome rules run.

## Credential diagnostics

JavaScript, Python and .NET emit `provider_credential_resolution_failed` at Error level
(event ID **1103** in Python/.NET). It uses the existing request context, before the unchanged
`request_failed` event. The public HTTP `502` response remains `provider_delivery_failed` with
its existing correlation/request IDs; diagnostic fields never appear in that response.

| JavaScript/Python field | .NET field | Allowed information |
|---|---|---|
| `credentialStage` | `CredentialStage` | `configuration`, `managed_identity`, `provider_token_exchange`, `key_vault`, or `unknown`. The last observed acquisition step, not an inferred root cause. Key Vault includes its SDK authentication. |
| `credentialFailure` | `CredentialFailure` | `configuration_invalid`, `credential_unavailable`, `timeout`, `cancelled`, or one of the code-based classifications below. |
| `aadstsCode` | `AadstsCode` | Only the recognized numeric strings `70025`, `70021`, `700016`, otherwise null. No raw error text, token response, assertion, claims or SDK exception. |

Code-based classifications apply only to the **provider token exchange**:

| Code / `credentialFailure` | Meaning and next check |
|---|---|
| [`70025`](https://login.microsoftonline.com/error?code=70025) / `federated_credential_missing` | The client application has no configured federated identity credentials. Check the **customer application's** trust for the Function's outbound managed identity. |
| [`70021`](https://login.microsoftonline.com/error?code=70021) / `federated_credential_mismatch` | No matching trust for the assertion. Check the exact issuer, managed-identity **principal ID** subject and audience, including propagation after a trust change. |
| [`700016`](https://login.microsoftonline.com/error?code=700016) / `provider_application_not_found` | The application was not found in the requested directory. Check the configured outbound **app client ID** and **provider tenant**; a missing provider-tenant service principal/consent is one possible cause, not the only one. Adding customer-side federation does not provision a provider-side service principal. |

Structured SDK codes are preferred; bounded traversal of wrapped errors can extract an
allowlisted `AADSTS` code from SDK text without emitting or retaining that text in the sanitized
error. Unknown codes and unclassified failures remain `credential_unavailable`; do not infer
missing federation or provider onboarding from latency or a generic `502`.

The 2.5-second acquisition budget, SDK token reuse, cancellation, evaluation behavior and next-live-request
retry behavior are unchanged. No diagnostic performs a Graph/provider lookup, adds retries, or
tests provider readiness. Stage tracking belongs to the individual acquisition, not a shared
credential client. SDK/body logging remains suppressed.

## Safe fields and identifiers

Build metadata from validated allowlisted fields. Exclude unknown, tenant, locale, risk, and
decrypted values.

`providerCredentialSource` is `managed_identity_client_assertion` for app tokens and `key_vault`
for API keys. OAuth resolution can reuse the SDK's token cache and does not imply a fresh token
exchange. API-key resolution reads Key Vault secret values for each live request.
`providerCredentialElapsedMs` includes resolution and usability checks, not a separate deadline.
SDK diagnostics remain suppressed.

`providerEndpoint` records the final scheme, host, port, and path. It removes user information,
query strings, and fragments, but not path segments. Keep secrets and personal data out of URL
paths. Logging does not change the request.

JavaScript and Python events carry Function request and invocation IDs plus Microsoft trace IDs
available at that stage. JavaScript also carries known channel, evaluation, and provider context.
Python derives these fields from its adapter and event arguments. Initially, only header IDs are
available. A valid envelope can later supply the selected correlation. The generated Function
request ID joins events even when
Microsoft IDs are absent or change. Log names deliberately distinguish these sources:

| Log field | Source and meaning |
|---|---|
| `functionName` | Runtime function name: `SendOtp` in JavaScript/.NET, `send_otp` in Python. The HTTP route remains `/api/SendOtp` in every runtime. |
| `functionRequestId` | Generated by this handler. Matches `requestId` in failure responses. It is not Microsoft's request ID. |
| `functionInvocationId` | Azure Functions host invocation ID. Null for direct handler calls without a host context. |
| `x-ms-client-request-id` | Raw Microsoft per-attempt ID from the header of the same name, not the generated Function request ID used by dispatch. |
| `x-ms-correlation-id` | Raw selected Microsoft correlation: envelope `correlationId` first, then the header of the same name. The existing precedence is unchanged, and this never contains a generated Function ID. |
| `msCorrelationIdSource` | `envelope`, `header`, or `none`. Identifies the selected value when the envelope and header differ. |
| `providerMessageId` | Raw provider-normalized message/reference ID returned by the provider, including Telesign `reference_id`, for support lookup. Not filled from delivery or Function IDs, although a provider may echo an ID it received. |
| `providerTenantId` | Raw configured `EPP_PROVIDER_TENANT_ID` for OAuth, not incoming envelope `tenantId`. |
| `functionOutboundClientId` | Raw application's `EPP_OUTBOUND_CLIENT_ID` used for provider access, not a Microsoft request ID. Guided setup reuses the endpoint app client ID here. Its outbound purpose is distinct from the inbound audience setting. |
| `functionOutboundManagedIdentityClientId` | Raw configured `EPP_OUTBOUND_MI_CLIENT_ID` used to obtain the app assertion, not the Key Vault identity or the identity's principal/Object ID. |
| `providerEndpoint` | Validated final outbound URL without userinfo, query string, or fragment. Scheme, host/port, and API path remain visible. |

External IDs keep their original value and case. Logs accept only 1-128 ASCII characters, starting
with a letter or digit and followed by letters, digits, `.`, `_`, `:`, or `-`. Missing or invalid
values are null. Invalid field names appear in `omittedIdFields`, never their values. These checks
change logs only, not request behavior or trust.

## Levels and collection

Normal and completion events use **Information**. Invalid requests, non-success 4xx outcomes, and
advisories use **Warning**. 5xx failures and timeouts use **Error**.
Keep Information logs enabled for investigation without enabling SDK/body tracing.

Filters and sampling can remove events. Application events are logs, not host Request telemetry.
Excluding `Request` from sampling does not retain every event. Configure collection and retention
deliberately. Easy Auth rejection happens before the handler: inspect platform/authentication
diagnostics and caller observations rather than expecting an application event.

Next: [verify collection](APPLICATION-INSIGHTS.md#single-region-configuration), then use
[runtime-specific queries](MONITORING.md#runtime-specific-log-discovery).
