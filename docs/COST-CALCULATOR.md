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
and log-retention period. Review the requested permissions before consenting. The output
contains user principal names and sign-in location data; store, share, and delete it
according to your organization's privacy and retention requirements.

Create `C:\temp` before running the script, or change `$outputPath` to an approved folder.

## Generate the activity report

The following sample installs any missing Microsoft Graph modules for the current user,
connects to Microsoft Graph, identifies users with a phone authentication method, and
groups up to 500 recent sign-ins per user by sign-in country or region.

```powershell
# 1. Install missing modules silently
"Microsoft.Graph.Users", "Microsoft.Graph.Identity.SignIns", "Microsoft.Graph.Reports" |
    ForEach-Object {
        if (-not (Get-Module -ListAvailable $_)) {
            Install-Module $_ -Scope CurrentUser -Force -AllowClobber | Out-Null
        }
    }

# 2. Connect to Microsoft Graph
Connect-MgGraph `
    -Scopes "User.Read.All", "UserAuthenticationMethod.Read.All", "AuditLog.Read.All" |
    Out-Null

# 3. Process users and build the report
$report = [System.Collections.Generic.List[PSCustomObject]]::new()
$users = Get-MgUser -All -Property Id, UserPrincipalName

foreach ($user in $users) {
    $phoneMethods = Get-MgUserAuthenticationPhoneMethod `
        -UserId $user.Id `
        -ErrorAction SilentlyContinue

    if ($phoneMethods) {
        $logs = Get-MgAuditLogSignIn `
            -Filter "userId eq '$($user.Id)'" `
            -Top 500 `
            -ErrorAction SilentlyContinue

        if ($logs) {
            $logs |
                Group-Object -Property { $_.Location.CountryOrRegion } |
                ForEach-Object {
                    $countryOrRegion = if ([string]::IsNullOrWhiteSpace($_.Name)) {
                        "Unknown"
                    }
                    else {
                        $_.Name
                    }

                    $report.Add([PSCustomObject]@{
                        UserPrincipalName = $user.UserPrincipalName
                        CountryOrRegion   = $countryOrRegion
                        SignInCount       = $_.Count
                    })
                }
        }
    }
}

# 4. Display and export the report
$outputPath = "C:\temp\SMS_Voice_Users_Country_Counts.csv"
$report | Sort-Object CountryOrRegion, UserPrincipalName | Format-Table -AutoSize
$report | Export-Csv -Path $outputPath -NoTypeInformation
```

The script suppresses per-user read errors so that one inaccessible record does not stop
the report. Investigate unexpectedly missing users or countries before relying on the
result. For a large tenant or a longer analysis window, replace the 500-record cap with
an organization-approved reporting approach that handles Microsoft Graph pagination,
throttling, and your available sign-in-log retention.

## Convert activity into a cost estimate

First, summarize the exported activity by country or region:

```powershell
$activity = Import-Csv "C:\temp\SMS_Voice_Users_Country_Counts.csv"

$activity |
    Group-Object CountryOrRegion |
    ForEach-Object {
        [PSCustomObject]@{
            CountryOrRegion = $_.Name
            SignInCount     = ($_.Group.SignInCount | Measure-Object -Sum).Sum
        }
    } |
    Sort-Object CountryOrRegion |
    Export-Csv "C:\temp\SMS_Activity_By_Country.csv" -NoTypeInformation
```

For each country or region, obtain the provider's applicable price and estimate:

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
