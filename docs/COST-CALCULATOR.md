# Estimate SMS provider costs

Estimate SMS and voice traffic before onboarding a provider. The report groups recent
authentication steps by calling code. Apply provider rates to estimate a budget.

> [!IMPORTANT]
> This is not a billing report. Confirm retries, fallback, message segments, destinations, taxes,
> fees, and pricing with the provider.

| Step | Task |
| --- | --- |
| 1 | [Prepare access](#prerequisites) |
| 2 | [Generate the report](#generate-the-activity-report) |
| 3 | [Calculate the estimate](#convert-activity-into-a-cost-estimate) |
| 4 | [Confirm provider rates](#confirm-provider-rates) |

The `authenticationDetails` data used by this guide is currently available through the
[Microsoft Graph beta API](https://learn.microsoft.com/en-us/graph/api/resources/authenticationdetail?view=graph-rest-beta).
Review the beta API and script before each planning exercise. The script matches masked trailing
digits to registered phone methods to derive the calling code.

## Prerequisites

Run the script in PowerShell 7 from a secured administrator workstation. The signed-in
account must be allowed to consent to or use these Microsoft Graph delegated permissions:

- `AuditLog.Read.All`
- `UserAuthenticationMethod.Read.All`

Reading other users' phone methods requires a
[supported Entra role](https://learn.microsoft.com/en-us/graph/api/authentication-list-phonemethods?view=graph-rest-1.0#permissions),
Authentication Administrator receives masked phone numbers; unresolved calling codes appear as `Unknown`.

Access also depends on Microsoft Entra licensing, roles, and retention. The script exports
aggregated calling codes, methods, and counts, not full phone numbers. Protect the output.

Create `C:\temp` before running the script, or change the `Export-Csv` path to an
approved folder.

## Generate the activity report

The script installs the required modules, finds SMS and voice authentication steps, matches masked
details to registered phone methods, and groups the result. Set `$start` and `$end` first.

```powershell
# 1. Install required modules if they are missing
"Microsoft.Graph.Beta.Reports", "Microsoft.Graph.Identity.SignIns" |
    Where-Object { -not (Get-Module -ListAvailable $_) } |
    ForEach-Object {
        Install-Module $_ -Scope CurrentUser -Force -AllowClobber | Out-Null
    }

# 2. Connect to Graph API
Connect-MgGraph `
    -Scopes "AuditLog.Read.All", "UserAuthenticationMethod.Read.All" |
    Out-Null

# 3. Define Start and End Time Range (ISO 8601 UTC)
$start = "2026-10-01T00:00:00Z"
$end   = "2026-10-30T23:59:59Z"

# 4. Cache registered phone methods and resolve masked sign-in details
$phoneMethodsByUser = @{}

$activity = Get-MgBetaAuditLogSignIn `
    -Filter "createdDateTime ge $start and createdDateTime le $end" `
    -All `
    -ErrorAction Stop |
    ForEach-Object {
        $signIn = $_
        $phoneDetails = @(
            $signIn.AuthenticationDetails |
                Where-Object {
                    $_.AuthenticationMethod -in "SMS", "Text message", "Voice"
                }
        )

        if ($phoneDetails.Count -gt 0) {
            if ([string]::IsNullOrWhiteSpace($signIn.UserId)) {
                $registeredMethods = @()
            }
            else {
                if (-not $phoneMethodsByUser.ContainsKey($signIn.UserId)) {
                    $phoneMethodsByUser[$signIn.UserId] = @(
                        Get-MgUserAuthenticationPhoneMethod `
                            -UserId $signIn.UserId `
                            -ErrorAction Stop
                    )
                }

                $registeredMethods = $phoneMethodsByUser[$signIn.UserId]
            }

            $phoneDetails |
            ForEach-Object {
                $authenticationDetail = $_
                $authenticationMethod = if (
                    $authenticationDetail.AuthenticationMethod -in "SMS", "Text message"
                ) {
                    "SMS"
                }
                else {
                    "Voice"
                }

                $visibleDigits = $authenticationDetail.AuthenticationMethodDetail -replace '\D', ''

                $matchingMethods = @(
                    $registeredMethods |
                        Where-Object {
                            $registeredDigits = $_.PhoneNumber -replace '\D', ''
                            $supportsMethod = (
                                $authenticationMethod -eq "Voice" -or
                                $_.PhoneType -in "mobile", "alternateMobile"
                            )

                            $supportsMethod -and
                            $visibleDigits.Length -ge 2 -and
                            $registeredDigits.EndsWith($visibleDigits)
                        }
                )

                $callingCode = if (
                    $matchingMethods.Count -eq 1 -and
                    $matchingMethods[0].PhoneNumber -match '^\s*(\+\d{1,3})(?:\s|$)'
                ) {
                    $Matches[1]
                }
                else {
                    "Unknown"
                }

                [PSCustomObject]@{
                    CountryCallingCode = $callingCode
                    AuthenticationMethod = $authenticationMethod
                }
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

The script accepts `SMS`, `Text message`, and `Voice`, then normalizes text messages to `SMS`.

For a masked value such as `+x XXXXXXXX90`, the script matches the visible suffix to one registered
method and extracts its calling code.

SMS uses `mobile` and `alternateMobile` registrations. Voice can use any phone type. The report
uses `Unknown` rather than guessing when it cannot find one match. Review that total.

The script does not use sign-in geography. Large tenants should account for Microsoft Graph
throttling and execution time. Errors stop the report instead of returning partial results.

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

<a id="confirm-the-final-estimate-with-your-provider"></a>
## Confirm provider rates

Confirm the following with the provider:

- How each international calling code maps to the provider's destination pricing.
- Country and carrier coverage, sender registration, and route-specific rates.
- SMS segment rules, including Unicode and messages that exceed one segment.
- Minimum commitments, volume tiers, taxes, regulatory fees, and other surcharges.
- Charges for failed, rejected, retried, or duplicate submissions.
- The expected ratio of SMS sends to sign-ins for your authentication policies and users.

After deployment, compare the estimate with provider billing and approved operational
telemetry. Do not treat this report as proof of message submission, acceptance, delivery,
or the amount that the provider will invoice.
