# Estimate SMS provider costs

Use this guide to create a planning estimate for SMS traffic before onboarding an
External Phone Provider (EPP). The report groups recent sign-in activity for users
who have a phone authentication method. Apply your provider's country or region
rates to the report to estimate a budget.

**This is an estimate, not a usage or billing report.** A sign-in does not prove that
an SMS was sent, and one sign-in can result in no message or more than one message.
The sign-in location is based on the sign-in event and might not match the country
of the destination phone number. Confirm the assumptions, supported destinations,
message segmentation, taxes, fees, and final pricing with your provider.

## Prerequisites

Run the script in PowerShell 7 from a secured administrator workstation. The signed-in
account must be allowed to consent to or use these Microsoft Graph delegated permissions:

- `User.Read.All`
- `UserAuthenticationMethod.Read.All`
- `AuditLog.Read.All`

Access to sign-in logs also depends on your Microsoft Entra licensing, directory role,
and log-retention period. Review the requested permissions before consenting. The script
processes directory users, authentication methods, and sign-in location data. Store, share,
and delete the aggregated output according to your organization's privacy and retention
requirements.

Create `C:\temp` before running the script, or change the `Export-Csv` path to an
approved folder.

## Generate the activity report

The following sample installs any missing Microsoft Graph modules for the current user,
connects to Microsoft Graph, identifies users with a phone authentication method, and
groups sign-ins from a selected UTC time range by sign-in country or region. Replace
`$start` and `$end` with the period you want to analyze.

```powershell
# 1. Install missing modules silently
"Microsoft.Graph.Users", "Microsoft.Graph.Identity.SignIns", "Microsoft.Graph.Reports" |
    ? { -not (Get-Module -ListAvailable $_) } |
    % { Install-Module $_ -Scope CurrentUser -Force -AllowClobber | Out-Null }

# 2. Connect to Graph API
Connect-MgGraph -Scopes "User.Read.All", "UserAuthenticationMethod.Read.All", "AuditLog.Read.All" | Out-Null

# 3. Define Start and End Time Range (ISO 8601 UTC)
$start = "2026-10-01T00:00:00Z"
$end   = "2026-10-30T23:59:59Z"

# 4. Single Pipeline: Filter users with Phone Auth -> Fetch Sign-ins -> Extract Country -> Group & Count
$report = Get-MgUser -All -Property Id |
    ? { Get-MgUserAuthenticationPhoneMethod -UserId $_.Id -ErrorAction SilentlyContinue } |
    % { Get-MgAuditLogSignIn -Filter "userId eq '$($_.Id)' and createdDateTime ge $start and createdDateTime le $end" -All -ErrorAction SilentlyContinue } |
    Group-Object -Property { $_.Location.CountryOrRegion } |
    Select-Object @{N="CountryCode"; E={$_.Name}}, @{N="SignInCount"; E={$_.Count}} |
    Sort-Object SignInCount -Descending

# 5. Output and Export
$report | Format-Table -AutoSize
$report | Export-Csv -Path "C:\temp\SMS_Voice_SignIns_By_Country.csv" -NoTypeInformation
```

The script suppresses per-user read errors so that one inaccessible record does not stop
the report. Investigate unexpectedly missing users or countries before relying on the
result. `-All` requests all available pages, but large tenants should still account for
Microsoft Graph throttling and execution time.

The Microsoft Graph
[list signIns API documentation](https://learn.microsoft.com/en-us/graph/api/signin-list?view=graph-rest-1.0&tabs=http)
states: **"The maximum and default page size is 1,000 objects and by default, the most
recent sign-ins are returned first. Only sign-in events that occurred within the
Microsoft Entra ID default retention period are available."** Selecting an earlier
`$start` date does not make events outside the available retention period accessible.

## Convert activity into a cost estimate

The exported report already contains one aggregated row per sign-in country or region.
For each row, obtain the provider's applicable price and estimate:

```text
Estimated messages = sign-in count x assumed SMS messages per sign-in
Estimated cost     = estimated messages x provider price per SMS
Projected cost     = estimated cost x projected days / observed days
```

For example, if the report covers 30 days, contains 10,000 relevant sign-ins, and your
planning assumption is 0.25 SMS messages per sign-in:

```text
Estimated messages = 10,000 x 0.25 = 2,500
```

Apply the provider's destination-specific rates to those estimated messages. Use separate
rows when rates differ by destination, sender type, route, or message category. Include a
contingency for growth, retries, fallback behavior, and seasonal peaks.

## Confirm the final estimate with your provider

Work with your provider to validate:

- Whether pricing uses the destination phone number rather than sign-in location.
- Country and carrier coverage, sender registration, and route-specific rates.
- SMS segment rules, including Unicode and messages that exceed one segment.
- Minimum commitments, volume tiers, taxes, regulatory fees, and other surcharges.
- Charges for failed, rejected, retried, or duplicate submissions.
- The expected ratio of SMS sends to sign-ins for your authentication policies and users.

After deployment, compare the estimate with provider billing and approved operational
telemetry. Do not treat this report as proof of message submission, acceptance, delivery,
or the amount that the provider will invoice.
