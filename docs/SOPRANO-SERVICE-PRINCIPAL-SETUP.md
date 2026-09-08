# Soprano QA: service-principal setup and bearer authentication

This runbook describes the QA test application, not the production CYOT caller identity
or a confirmed per-customer billing architecture. Never put client secrets or access tokens here.

## Last verified QA state (2026-09-08)

- Token acquisition succeeded with v2.0 `aud`, `iss`, and `azp` matching the QA guide.
- QA4 rejected the Bearer request with HTTP `401`, error `401101` ("User cannot be authenticated").
- API-key SMS dispatch returned `201 ENROUTE`; this is acceptance, not proof of handset delivery.
- Ask Soprano to inspect authentication logs and confirm the test caller's MEMS account mapping
  and any required app role. Mapping is a likely cause, not a proven diagnosis of the 401.
- The setup steps below apply only if the enterprise application is missing; do not recreate
  an existing service principal as a way to fix an API-level authentication rejection.

## Why you're seeing this

If the QA client is missing its enterprise application in the provider tenant, Entra returns:

```
AADSTS7000229: The client application 89c1e810-568e-4398-b80c-967772eaca0f
is missing service principal in the tenant 801bae25-4443-4a29-9e56-9d1cf22ff819.
```

This is an **Entra ID** response from **your** tenant, returned *before* the request ever
reaches your API. Microsoft's app is a multitenant application; for Entra to issue a token
that targets your tenant, a **service principal** (enterprise-application entry) for that app
must exist **in your directory**. Authorizing the app ID as an accepted caller in your API
config is a separate thing and does not create this object.

This is the exact scenario documented by Microsoft:
<https://learn.microsoft.com/en-us/entra/identity/enterprise-apps/create-service-principal-cross-tenant>
(the link embedded in the `AADSTS7000229` error itself).

## Identity used by this QA test

Create one service principal for the test application in the provider tenant. This does
not establish whether production uses shared or per-customer callers. Confirm the production
identity and Marketplace-subscription mapping with the service owners separately; `azp`
is an application ID, not a Marketplace subscription ID.

| Value | ID |
| --- | --- |
| Application (client) ID / `azp` | `89c1e810-568e-4398-b80c-967772eaca0f` |
| Your tenant (where the SP must be created) | `801bae25-4443-4a29-9e56-9d1cf22ff819` |
| Your API app ID (token audience) | `32dfc82a-86dd-4515-a0a2-f20ef2f5c7fe` |

## Prerequisites

- Sign in to tenant `801bae25-4443-4a29-9e56-9d1cf22ff819`.
- Role: **Cloud Application Administrator** or **Application Administrator**.

## Do one of the following (any single method is enough)

### Option A — Azure CLI

```bash
az login --tenant 801bae25-4443-4a29-9e56-9d1cf22ff819
az ad sp create --id 89c1e810-568e-4398-b80c-967772eaca0f
```

### Option B — Microsoft Graph PowerShell

```powershell
Connect-MgGraph -TenantId 801bae25-4443-4a29-9e56-9d1cf22ff819 -Scopes "Application.ReadWrite.All"
New-MgServicePrincipal -AppId 89c1e810-568e-4398-b80c-967772eaca0f
```

### Option C — Microsoft Graph REST

```http
POST https://graph.microsoft.com/v1.0/servicePrincipals
Content-type: application/json

{ "appId": "89c1e810-568e-4398-b80c-967772eaca0f" }
```

## Verify

The service principal now appears under **Entra ID > Enterprise applications** when you
search for app ID `89c1e810-568e-4398-b80c-967772eaca0f`. Depending on the API's assignment
policy, app-role assignment or administrator consent may also be required. A role-less
app-only token can be issued for an API using an application-ID allowlist; it does not
by itself prove the caller is authorized by MEMS. The API must validate signature, lifetime,
`aud`, `iss`, and the admitted caller, plus any required application roles.

## After you're done

Let the Microsoft team know and we will re-run the token request; it should return a JWT
instead of `AADSTS7000229`, and we will send a live OTP to the whitelisted number to
confirm end to end.

## Reference

- Create an enterprise application from a multitenant application —
  <https://learn.microsoft.com/en-us/entra/identity/enterprise-apps/create-service-principal-cross-tenant>
