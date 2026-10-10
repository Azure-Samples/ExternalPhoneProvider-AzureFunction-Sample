# Estimate SMS provider costs

Use this guide to create a planning estimate for SMS traffic before onboarding an
External Phone Provider (EPP). The report groups recent sign-in activity for users
who have a phone authentication method by the registered phone number's international
calling code, such as `+1` or `+91`. Apply your provider's destination rates to the
report to estimate a budget.

**This is an estimate, not a usage or billing report.** A sign-in does not prove that
an SMS or voice call was sent. This guide uses one message or call per counted sign-in
as its planning assumption. Actual traffic can differ because a user can use another
authentication method, reuse an existing session, retry authentication, or fall back
between methods. Confirm the assumptions, supported destinations, message segmentation,
taxes, fees, and final pricing with your provider.

## Prerequisites

Run the script in PowerShell 7 from a secured administrator workstation. The signed-in
account must be allowed to consent to or use these Microsoft Graph delegated permissions:

- `User.Read.All`
- `UserAuthenticationMethod.Read.All`
- `AuditLog.Read.All`

Access to sign-in logs also depends on your Microsoft Entra licensing, directory role,
and log-retention period. Review the requested permissions before consenting. The script
processes directory users, registered phone numbers, and sign-in records. It exports only
aggregated calling codes and counts, not full phone numbers. Store, share, and delete the
output according to your organization's privacy and retention requirements.

Create `C:\temp` before running the script, or change the `Export-Csv` path to an
approved folder.

## Generate the activity report

The following sample installs any missing Microsoft Graph modules for the current user,
connects to Microsoft Graph, identifies users with a phone authentication method, and
groups sign-ins from a selected UTC time range by the registered phone number's calling
code. Replace `$start` and `$end` with the period you want to analyze.

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

# 4. Fetch sign-ins and associate them with the user's preferred registered phone method
$activity = Get-MgUser -All -Property Id |
    % {
        $user = $_
        $phoneMethod = Get-MgUserAuthenticationPhoneMethod `
            -UserId $user.Id `
            -ErrorAction SilentlyContinue |
            Sort-Object @{ E = {
                switch ($_.PhoneType) {
                    "mobile"          { 1 }
                    "alternateMobile" { 2 }
                    "office"          { 3 }
                    default           { 4 }
                }
            }} |
            Select-Object -First 1

        if ($phoneMethod) {
            $callingCode = if ($phoneMethod.PhoneNumber -match '^\s*(\+\d{1,3})(?:\s|$)') {
                $Matches[1]
            }
            else {
                "Unknown"
            }

            Get-MgAuditLogSignIn `
                -Filter "userId eq '$($user.Id)' and createdDateTime ge $start and createdDateTime le $end" `
                -All `
                -ErrorAction SilentlyContinue |
                % {
                    [PSCustomObject]@{
                        CountryCallingCode = $callingCode
                    }
                }
        }
    }

# 5. Group and count by the phone number's international calling code
$report = $activity |
    Group-Object CountryCallingCode |
    Select-Object @{N="CountryCallingCode"; E={$_.Name}}, @{N="SignInCount"; E={$_.Count}} |
    Sort-Object SignInCount -Descending

# 6. Output and Export
$report | Format-Table -AutoSize
$report | Export-Csv -Path "C:\temp\SMS_Voice_SignIns_By_Calling_Code.csv" -NoTypeInformation
```

The script suppresses per-user read errors so that one inaccessible record does not stop
the report. It prefers a user's `mobile` method, followed by `alternateMobile`, then
`office`, so each sign-in is counted once when more than one phone method is registered.
The calling-code extraction expects the number to start with a plus-prefixed code followed
by a space, such as `+91 1234567890`; other formats are grouped as `Unknown`. Investigate
unexpectedly missing users or calling codes before relying on the result. `-All` requests
all available pages, but large tenants should still account for Microsoft Graph throttling
and execution time.

The Microsoft Graph
[list signIns API documentation](https://learn.microsoft.com/en-us/graph/api/signin-list?view=graph-rest-1.0&tabs=http)
states: **"The maximum and default page size is 1,000 objects and by default, the most
recent sign-ins are returned first. Only sign-in events that occurred within the
Microsoft Entra ID default retention period are available."** Selecting an earlier
`$start` date does not make events outside the available retention period accessible.

## Convert activity into a cost estimate

The exported report contains one aggregated row per registered phone-number calling code.
Under this guide's one-request-per-sign-in planning assumption, estimate:

```text
Estimated SMS/voice requests = sign-in count
Estimated cost               = sign-in count x provider price per request
Projected cost               = estimated cost x projected days / observed days
```

For example, if the report covers 30 days and contains 10,000 relevant sign-ins:

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
