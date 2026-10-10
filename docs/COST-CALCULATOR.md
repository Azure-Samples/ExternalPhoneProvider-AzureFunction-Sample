# Estimate SMS provider costs

Use this guide to create a planning estimate for SMS traffic before onboarding an
External Phone Provider (EPP). The report finds SMS and voice authentication steps in
recent sign-in activity and groups them by the phone number's international calling
code, such as `+1` or `+91`. Apply your provider's destination rates to the report to
estimate a budget.

**This is an estimate, not a usage or billing report.** A sign-in does not prove that
the provider accepted or delivered an SMS or voice call. Authentication details can
contain multiple SMS or voice steps for one sign-in, so this guide counts each matching
step as one estimated request. Actual provider billing can differ because of retries,
fallback, failures, message segmentation, and provider-specific charging rules. Confirm
the assumptions, supported destinations, taxes, fees, and final pricing with your provider.

The `authenticationDetails` data used by this guide is currently available through the
[Microsoft Graph beta API](https://learn.microsoft.com/en-us/graph/api/resources/authenticationdetail?view=graph-rest-beta).
Beta APIs are subject to change and are not supported for production applications. Review
and test this reporting script before each planning exercise.

## Prerequisites

Run the script in PowerShell 7 from a secured administrator workstation. The signed-in
account must be allowed to consent to or use these Microsoft Graph delegated permissions:

- `AuditLog.Read.All`

Access to sign-in logs also depends on your Microsoft Entra licensing, directory role,
and log-retention period. Review the requested permissions before consenting. The script
processes sign-in authentication details that can include phone numbers. It exports only
aggregated calling codes, methods, and counts, not full phone numbers. Store, share, and
delete the output according to your organization's privacy and retention requirements.

Create `C:\temp` before running the script, or change the `Export-Csv` path to an
approved folder.

## Generate the activity report

The following sample installs the Microsoft Graph beta reports module for the current
user, connects to Microsoft Graph, identifies SMS and voice authentication steps, and
groups them by the phone number's calling code. Replace `$start` and `$end` with the
period you want to analyze.

```powershell
# 1. Install the beta reports module if it is missing
if (-not (Get-Module -ListAvailable "Microsoft.Graph.Beta.Reports")) {
    Install-Module "Microsoft.Graph.Beta.Reports" `
        -Scope CurrentUser `
        -Force `
        -AllowClobber |
        Out-Null
}

# 2. Connect to Graph API
Connect-MgGraph -Scopes "AuditLog.Read.All" | Out-Null

# 3. Define Start and End Time Range (ISO 8601 UTC)
$start = "2026-10-01T00:00:00Z"
$end   = "2026-10-30T23:59:59Z"

# 4. Fetch sign-ins and emit one row for each SMS or voice authentication step
$activity = Get-MgBetaAuditLogSignIn `
    -Filter "createdDateTime ge $start and createdDateTime le $end" `
    -Property "authenticationDetails" `
    -All `
    -ErrorAction Stop |
    ForEach-Object {
        $_.AuthenticationDetails |
            Where-Object { $_.AuthenticationMethod -in "SMS", "Voice" } |
            ForEach-Object {
                $callingCode = if (
                    $_.AuthenticationMethodDetail -match '^\s*(\+\d{1,3})(?:\s|$)'
                ) {
                    $Matches[1]
                }
                else {
                    "Unknown"
                }

                [PSCustomObject]@{
                    CountryCallingCode = $callingCode
                    AuthenticationMethod = $_.AuthenticationMethod
                }
            }
    }

# 5. Group and count by calling code and authentication method
$report = $activity |
    Group-Object CountryCallingCode, AuthenticationMethod |
    ForEach-Object {
        [PSCustomObject]@{
            CountryCallingCode   = $_.Group[0].CountryCallingCode
            AuthenticationMethod = $_.Group[0].AuthenticationMethod
            EstimatedRequests    = $_.Count
        }
    } |
    Sort-Object CountryCallingCode, AuthenticationMethod

# 6. Display and export the aggregated report
$report | Format-Table -AutoSize
$report | Export-Csv -Path "C:\temp\SMS_Voice_SignIns_By_Calling_Code.csv" -NoTypeInformation
```

Microsoft documents `SMS` and `Voice` as authentication method values and states that
`authenticationMethodDetail` can contain the phone number for those methods. The script
does not match an undocumented `Text` value. It also does not use sign-in geography or a
user's currently registered default number, because those can differ from the phone method
recorded for the authentication step.

The calling-code extraction expects the detail to start with a plus-prefixed code followed
by a space, such as `+91 1234567890`. Masked values or other formats are grouped as
`Unknown`; review a small, securely handled sample in your tenant before relying on the
aggregation. `-All` requests all available pages, but large tenants should still account
for Microsoft Graph throttling and execution time. The script uses `-ErrorAction Stop`
rather than silently producing a partial report when the sign-in query fails.

The Microsoft Graph
[list signIns API documentation](https://learn.microsoft.com/en-us/graph/api/signin-list?view=graph-rest-1.0&tabs=http)
states: **"The maximum and default page size is 1,000 objects and by default, the most
recent sign-ins are returned first. Only sign-in events that occurred within the
Microsoft Entra ID default retention period are available."** Selecting an earlier
`$start` date does not make events outside the available retention period accessible.

## Convert activity into a cost estimate

The exported report contains one row per calling code and authentication method. It counts
each SMS or voice authentication step as one estimated request:

```text
Estimated SMS/voice requests = matching authentication-step count
Estimated cost               = estimated requests x provider price per request
Projected cost               = estimated cost x projected days / observed days
```

For example, if the report covers 30 days and contains 10,000 matching authentication
steps:

```text
Estimated SMS/voice requests = 10,000
```

Apply the provider's destination-specific rates to those estimated requests. Use separate
rows when rates differ by destination, sender type, route, or message category. Include a
contingency for growth, retries, fallback behavior, and seasonal peaks.

## Confirm the final estimate with your provider

Work with your provider to validate:

- How each international calling code maps to the provider's destination pricing.
- Country and carrier coverage, sender registration, and route-specific rates.
- SMS segment rules, including Unicode and messages that exceed one segment.
- Minimum commitments, volume tiers, taxes, regulatory fees, and other surcharges.
- Charges for failed, rejected, retried, or duplicate submissions.
- The expected ratio of SMS sends to sign-ins for your authentication policies and users.

After deployment, compare the estimate with provider billing and approved operational
telemetry. Do not treat this report as proof of message submission, acceptance, delivery,
or the amount that the provider will invoice.
