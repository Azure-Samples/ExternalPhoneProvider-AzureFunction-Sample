# CYOT and Microsoft native delivery isolation

[Documentation](README.md) | [Send OTP API](CONTRACT.md) | [Technical reference](../TECHNICAL.md)

Choose Your Own Telco Provider (CYOT) and Microsoft native delivery are separate execution paths
within the Microsoft Entra routing flow. The customer-hosted Function handles requests routed to
the CYOT endpoint. If CYOT delivery fails, Microsoft Entra can apply its configured policy and
route a separate attempt through native delivery.

The customer Function reports the CYOT outcome. It does not call, configure, or authenticate to
the Microsoft native delivery service.

## Isolation model

| Boundary | CYOT path | Microsoft native path |
| --- | --- | --- |
| Routing | Microsoft Entra routes an approved request to the customer endpoint. | Microsoft Entra can route a separate native attempt when the configured fallback policy applies. |
| Hosting | The customer owns the Azure Function, Key Vault, Application Insights, and related Azure resources. | Microsoft owns and operates the native service. |
| Inbound identity | Easy Auth validates the approved Microsoft caller before the Function runs. | Native-service authentication remains outside the customer deployment. |
| Request data | The Function decrypts the CYOT delivery context only after caller authentication and request validation. | Native-path request processing does not use the customer Function or its decryption key. |
| Provider access | Customer-managed provider credentials authorize the outbound provider request. | Native-service credentials are not stored in or available to the customer Function. |
| Operations | The customer monitors Function execution and provider outcomes in the customer Azure environment. | Microsoft monitors the native service separately. |

Deploying the sample does not change the Microsoft Entra routing policy or activate CYOT.
Activation and native fallback behavior follow the approved Microsoft configuration.

## Request flow

For a request routed to CYOT:

1. Easy Auth validates the approved Microsoft caller.
2. The Function validates the envelope and decrypts the delivery context.
3. Evaluation mode completes without contacting a provider.
4. Live mode contacts only the provider configured for that deployment.
5. The Function returns the documented HTTP outcome to the caller.

The Function does not redirect a failed request to Microsoft native delivery. It returns the CYOT
outcome so Microsoft Entra can apply the configured native fallback policy outside the Function.

## Fallback and retries

Microsoft Entra owns CYOT-to-native fallback. The customer Function returns the CYOT result, and
Microsoft Entra decides whether the configured policy requires a native attempt.

This is separate from customer-managed [provider fallback](MULTI-PROVIDER-IMPLEMENTATION.md) inside
the CYOT deployment.

- Do not call the native delivery path from the customer Function.
- Do not forward the inbound Microsoft bearer token to a provider or another delivery service.
- Do not use provider fallback to bypass authentication, fraud, policy, recipient, or payload denials.
- Do not automatically resend after a timeout or lost response. The provider may have accepted the
  first request.
- Return the documented CYOT result and let Microsoft Entra apply its native fallback policy.
- Track provider acceptance, CYOT outcome, native fallback, and recipient delivery as separate
  stages.

These rules prevent the customer endpoint from joining two delivery systems into one uncontrolled
retry chain.

## Credentials and data

Keep each trust path separate:

- **Inbound caller:** Easy Auth issuer, audience, and caller allowlist.
- **Request confidentiality:** the registered JWE encryption key and customer-held private key.
- **Azure access:** managed identities with scoped access to customer Azure resources.
- **Provider access:** the selected provider's OAuth or Key Vault credentials.

The Function must not store Microsoft native-service credentials. Provider credentials must not be
used to authenticate inbound callers. Keep phone numbers, OTPs, decrypted bodies, tokens, keys, and
raw provider responses out of logs.

## Validation

Run these checks in a nonproduction environment using the approved test procedure:

| Check | Expected result |
| --- | --- |
| Missing or unauthorized caller token | Easy Auth returns `401` or `403`; the Function does not run. |
| Valid evaluation request | The Function validates and decrypts the request without contacting a provider. |
| Valid live CYOT request | Only the configured provider is contacted. |
| Provider rejection or configuration failure | The Function returns the mapped CYOT error. Microsoft Entra can then apply its configured native fallback policy. |
| Provider timeout or uncertain response | No automatic resend or native call occurs inside the Function. Microsoft Entra handles any configured fallback outside it. |
| Approved native-fallback test | The Function records the CYOT attempt. The later native attempt does not create a second customer-Function invocation. |
| Telemetry review | Customer logs contain CYOT Function and provider outcomes only, without secrets or request content. |

Use [monitoring](MONITORING.md) to confirm Function activity and provider outcomes. Absence of a
Function invocation does not by itself prove that native delivery succeeded.

## Ownership

| Owner | Responsibility |
| --- | --- |
| Microsoft | Configure Microsoft Entra routing, evaluate the CYOT outcome, and run native fallback when the policy applies. |
| Customer | Secure, configure, monitor, and operate the CYOT Azure deployment and provider account. |
| Provider | Authenticate the customer account, accept or reject delivery requests, and report provider-side outcomes. |

Review this isolation model whenever routing policy, provider fallback, authentication, or retry
behavior changes.
