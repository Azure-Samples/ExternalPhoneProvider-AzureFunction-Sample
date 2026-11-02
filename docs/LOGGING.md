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

Requests that reach the handler emit `request_completed` on completion.
Easy Auth and C# input-binding errors can occur before the handler.
Exporters control formatting and property preservation. Field names differ by runtime, so verify the
[deployed schema](MONITORING.md#runtime-specific-log-discovery).

## Event sequence

A successful live request emits these events in order:

| Service event | Safe information recorded |
| --- | --- |
| `request_received` | Function invocation and allowlisted Microsoft trace IDs. Excludes the raw body and arbitrary headers. |
| `envelope_validated` / `payload_validated` | Allowlisted body metadata: validated payload type, normalized `channel`, `evaluation` and optional `ttlSeconds`. |
| `delivery_context_decrypted` | Decryption completed. Excludes plaintext fields, JWE, and key ID. |
| `provider_selected` | Registered provider and its authentication mode. |
| `provider_credential_resolution_started` | OAuth credential source and allowlisted application, managed-identity, and token-tenant IDs. |
| `provider_credential_resolved` | Credential resolution and usability checks completed, with elapsed time. Excludes secrets, tokens, assertions, and claims. |
| `provider_request_build_started` | The provider is preparing the outbound request. |
| `provider_request_built` | Allowlisted HTTP method, final endpoint scheme/host/port/API path, HTTPS, and disabled redirects. Excludes the query string, authorization headers, and body. |
| `provider_request_started` | The outbound send is beginning, with its HTTP timeout. Method and endpoint are recorded by `provider_request_built`. |
| `provider_response_received` | Actual upstream HTTP status. Emitted before response-body reading completes. |
| `provider_response_processed` | Mapped provider status/outcome, fixed failure classification and duration. Raw provider descriptions and bodies are excluded. |
| `response_prepared` | Response status and booleans indicating nonce/correlation inclusion, not their values or the response body. |
| `request_completed` | Final HTTP status, result, and elapsed time. Stage-specific fields stay on their events. |

JavaScript uses `envelope_validated`. Python and .NET use `payload_validated`.
Evaluation skips provider work and emits `evaluation_completed`, `response_prepared`, and
`request_completed`.

Failures emit `request_failed` with stage, reason, and HTTP status (`FailureStage` and
`FailureReason` in .NET). Provider results use
`Outcome` and a safe classification: `provider_http_error`, `provider_blocked`, `provider_rejected`, `unrecognized_provider_status`,
`missing_provider_message_id`, or `invalid_provider_json`. `provider_response_processed` includes
that classification, upstream HTTP status, and normalized status, never descriptions/bodies.
Explicit risk/policy blocks use outcome `Block`, reason `provider_blocked`, and endpoint HTTP `422`.
Provider HTTP `401`/`403` remains visible as upstream status but returns endpoint `400`, not an
inbound caller authentication error.
Credential acquisition failures use `request_failed` with stage `provider_credentials`, reason
`credential_unavailable`, and HTTP `502`. A preceding `provider_credential_resolution_failed`
event supplies the [credential diagnostic](#credential-diagnostics).
Unexpected failures use `unexpected_error`.

`response_prepared` runs before successful and failed returns. It does not prove caller receipt.

`providerHttpStatus` is recorded when response headers arrive.
An upstream `200` can precede a body-read timeout: `provider_response_received` may be followed by
`request_failed` with Function `504`, without mapped provider status or success acknowledgement.
Unknown status text and malformed JSON are never logged. Malformed JSON emits only
`provider_response_invalid_json` before provider outcome rules run.

## Credential diagnostics

The request-correlated `provider_credential_resolution_failed` event logs only `aadstsCode`
(`AadstsCode` in .NET), extracted from the SDK error message. It contains `AADSTS` followed by
ASCII digits, or null when no such identifier is present. Codes are not restricted to the
examples below. Raw error text, responses and credentials are never logged. Python/.NET use event ID
**1103** at Error level.

| Code | Meaning and next check |
|---|---|
| [`AADSTS70025`](https://login.microsoftonline.com/error?code=70025) | No federated identity credentials configured for the client application. |
| [`AADSTS70021`](https://login.microsoftonline.com/error?code=70021) | No matching federation; check issuer, subject and audience. |
| [`AADSTS700016`](https://login.microsoftonline.com/error?code=700016) | Application not found in the requested directory; check app and tenant IDs. This alone does not prove missing provider consent. |

The event does not identify which acquisition step failed or infer a root cause. A null value
does not establish that authentication succeeded or that the failure was unrelated to Entra.

## Safe fields and identifiers

Build metadata from validated allowlisted fields. Exclude unknown, tenant, locale, risk, and
decrypted values.

For the bundled OAuth providers, the credential source is `managed_identity_client_assertion`.
Resolution can reuse the SDK's token cache rather than requiring a fresh exchange.
The credential duration includes resolution and usability checks.

| Runtime | Credential source field | Credential duration field |
| --- | --- | --- |
| JavaScript | `providerCredentialSource` | `providerCredentialElapsedMs` |
| Python | `credentialSource` | `elapsedMs` |
| C# | `CredentialSource` | `ElapsedMs` |

These fields appear on the corresponding credential events. SDK diagnostics remain suppressed.

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
| --- | --- |
| `functionName` | Runtime function name: `SendOtp` in JavaScript/.NET, `send_otp` in Python. The HTTP route remains `/api/SendOtp` in every runtime. |
| `functionRequestId` | Generated by this handler. Matches `requestId` in failure responses. It is not Microsoft's request ID. |
| `functionInvocationId` | Azure Functions host invocation ID. Null for direct handler calls without a host context. |
| `x-ms-client-request-id` | Raw Microsoft per-attempt ID from the header of the same name, not the generated Function request ID used by dispatch. |
| `x-ms-correlation-id` | Raw selected Microsoft correlation: envelope `correlationId` first, then the header of the same name. The existing precedence is unchanged, and this never contains a generated Function ID. |
| `msCorrelationIdSource` | `envelope`, `header`, or `none`. Identifies the selected value when the envelope and header differ. |
| `providerMessageId` | Raw provider-normalized message/reference ID returned by the provider, including Telesign `reference_id`, for support lookup. Not filled from delivery or Function IDs, although a provider may echo an ID it received. |
| `providerTenantId` | Configured OAuth token tenant (`EPP_PROVIDER_TENANT_ID`), not incoming envelope `tenantId`. Unlike this log field, the deployment summary's `providerTenantId` identifies the Security Store tenant. |
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
