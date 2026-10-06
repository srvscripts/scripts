# Entra ID Inactive Users Report: signInActivity PowerShell Script (v1.0.0) - from srvScripts.com
# Source, docs and updates: https://srvscripts.com/scripts/entra-inactive-users-report/
# Copyright (c) 2026 srvScripts.com. MIT licence: if you copy, share or adapt this script, keep this notice and credit srvScripts.com.
<#
.SYNOPSIS
    Find inactive Microsoft Entra ID (Microsoft 365) users from signInActivity: members and guests,
    licensed or not, with last successful, interactive and non-interactive sign-in dates. CSV/HTML output.

.DESCRIPTION
    Read-only. Lists users through Microsoft Graph (GET /users with $select=signInActivity) using the
    Microsoft.Graph.Authentication module, then works out how many days each account has been inactive.

    Which date counts as "last activity" (-Basis):
      Successful (default)  lastSuccessfulSignInDateTime (interactive or non-interactive, successful only).
                            Microsoft started filling this property on 1 December 2023 and did not backfill it,
                            so when it is empty the script falls back to the newest of lastSignInDateTime and
                            lastNonInteractiveSignInDateTime and says so in the BasisUsed column.
      AnyAttempt            Newest of all three dates. lastSignInDateTime and lastNonInteractiveSignInDateTime
                            also record FAILED attempts, so a password-spray target can look "active".

    Accounts with no sign-in data at all are reported as NeverSignedIn (or "last sign-in before April 2020").
    Accounts created inside the -Days window are skipped unless -IncludeRecentlyCreated is used.

    Requirements (Microsoft Learn): signInActivity needs a Microsoft Entra ID P1 or P2 licence in the tenant
    and the AuditLog.Read.All permission (plus User.Read.All). Delegated: the signed-in admin needs at least
    the Reports Reader role (Global Reader also works). App-only: User.Read.All and AuditLog.Read.All as
    Application permissions with admin consent. The value can lag real activity by up to 24 hours.

.PARAMETER Days                    Inactive for at least this many days (default 90).
.PARAMETER UserType                All (default), Member or Guest.
.PARAMETER LicensedOnly            Only users with at least one assigned licence.
.PARAMETER IncludeDisabled         Also report disabled accounts (default: enabled accounts only).
.PARAMETER IncludeRecentlyCreated  Also report accounts created less than -Days ago.
.PARAMETER Basis                   Successful (default) or AnyAttempt. See DESCRIPTION.
.PARAMETER CsvPath                 Write the result to this CSV file.
.PARAMETER HtmlPath                Write the result to this HTML file.
.PARAMETER PassThru                Output the objects to the pipeline.
.PARAMETER TenantId                Tenant ID or domain (required for app-only sign-in).
.PARAMETER ClientId                App registration (client) ID for app-only sign-in.
.PARAMETER CertificateThumbprint   Certificate thumbprint for app-only sign-in.

.EXAMPLE  .\Get-EntraInactiveUsers.ps1 -Days 90 -CsvPath .\inactive-90.csv
.EXAMPLE  .\Get-EntraInactiveUsers.ps1 -Days 60 -LicensedOnly -UserType Member -HtmlPath .\licensed-inactive.html
.EXAMPLE  .\Get-EntraInactiveUsers.ps1 -Days 180 -UserType Guest -IncludeDisabled -CsvPath .\stale-guests.csv
.EXAMPLE  .\Get-EntraInactiveUsers.ps1 -TenantId contoso.onmicrosoft.com -ClientId <app-id> -CertificateThumbprint <thumbprint> -CsvPath C:\Reports\inactive.csv

.NOTES
    Name:     Get-EntraInactiveUsers.ps1
    Purpose:  Inactive user report for Microsoft Entra ID based on signInActivity
    Source:   https://srvscripts.com/scripts/entra-inactive-users-report/
    License:  MIT
    Version:  1.0.0
    Requires: Windows PowerShell 5.1 or PowerShell 7, module Microsoft.Graph.Authentication.
#>
[CmdletBinding(DefaultParameterSetName = 'Interactive')]
param(
    [ValidateRange(1, 3650)]
    [int]$Days = 90,
    [ValidateSet('All', 'Member', 'Guest')]
    [string]$UserType = 'All',
    [switch]$LicensedOnly,
    [switch]$IncludeDisabled,
    [switch]$IncludeRecentlyCreated,
    [ValidateSet('Successful', 'AnyAttempt')]
    [string]$Basis = 'Successful',
    [string]$CsvPath,
    [string]$HtmlPath,
    [switch]$PassThru,
    [Parameter(ParameterSetName = 'Interactive')]
    [Parameter(ParameterSetName = 'AppOnly', Mandatory = $true)]
    [string]$TenantId,
    [Parameter(ParameterSetName = 'AppOnly', Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$ClientId,
    [Parameter(ParameterSetName = 'AppOnly', Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F]{40}$')]
    [string]$CertificateThumbprint
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$Graph = 'https://graph.microsoft.com/v1.0'

function Write-Status([string]$Message) { Write-Information $Message -InformationAction Continue }

function Invoke-GraphWithRetry {
    param([string]$Uri)
    $attempt = 0
    while ($true) {
        $attempt++
        try {
            return Invoke-MgGraphRequest -Method GET -Uri $Uri -OutputType HashTable -ErrorAction Stop
        } catch {
            if ($attempt -lt 5 -and $_.Exception.Message -match '429|TooManyRequests|503|ServiceUnavailable|504|GatewayTimeout') {
                Start-Sleep -Seconds ([math]::Pow(2, $attempt) * 5)
                continue
            }
            throw
        }
    }
}

function Get-GraphCollection([string]$Uri) {
    $next = $Uri
    while ($next) {
        $r = Invoke-GraphWithRetry -Uri $next
        if ($r['value']) { foreach ($i in $r['value']) { $i } }
        $next = $r['@odata.nextLink']
    }
}

function Get-Value($Hash, [string]$Key) {
    if ($null -ne $Hash -and $Hash.ContainsKey($Key)) { return $Hash[$Key] }
    return $null
}

function ConvertTo-UtcDate($Value) {
    if ($null -eq $Value -or "$Value" -eq '') { return $null }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    if ($Value -is [datetimeoffset]) { return $Value.UtcDateTime }
    return ([datetimeoffset]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture)).UtcDateTime
}

function Get-Newest([object[]]$Dates) {
    $d = @($Dates | Where-Object { $null -ne $_ } | Sort-Object -Descending)
    if ($d.Count) { return $d[0] }
    return $null
}

# ---- Connect --------------------------------------------------------------------------------------------
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
    throw 'Module Microsoft.Graph.Authentication is not installed. Run: Install-Module Microsoft.Graph.Authentication -Scope CurrentUser'
}
Import-Module Microsoft.Graph.Authentication
if ($PSCmdlet.ParameterSetName -eq 'AppOnly') {
    Connect-MgGraph -TenantId $TenantId -ClientId $ClientId -CertificateThumbprint $CertificateThumbprint -NoWelcome
} else {
    $cp = @{ Scopes = @('User.Read.All', 'AuditLog.Read.All'); NoWelcome = $true }
    if ($TenantId) { $cp.TenantId = $TenantId }
    Connect-MgGraph @cp
}
$ctx = Get-MgContext
if (-not $ctx) { throw 'Not connected to Microsoft Graph.' }

# ---- Read users -----------------------------------------------------------------------------------------
$select = 'id,displayName,userPrincipalName,userType,accountEnabled,createdDateTime,assignedLicenses,onPremisesSyncEnabled,externalUserState,signInActivity'
Write-Status 'Reading users and signInActivity (500 per page)...'
try {
    $users = @(Get-GraphCollection -Uri "$Graph/users?`$select=$select&`$top=500")
} catch {
    if ($_.Exception.Message -match 'Forbidden|403|premium|license|Authorization_RequestDenied') {
        throw "Graph refused signInActivity: $($_.Exception.Message). It needs a Microsoft Entra ID P1/P2 licence in the tenant, the AuditLog.Read.All permission and (delegated) at least the Reports Reader role."
    }
    throw
}
Write-Status ("{0} user objects read." -f $users.Count)

$now = (Get-Date).ToUniversalTime()
$cutoff = $now.AddDays(-$Days)
$rows = [System.Collections.Generic.List[object]]::new()

foreach ($u in $users) {
    $type = [string](Get-Value $u 'userType')
    if ($UserType -ne 'All' -and $type -ne $UserType) { continue }
    $enabled = Get-Value $u 'accountEnabled'
    if (-not $IncludeDisabled -and $enabled -eq $false) { continue }
    $licCount = @(@(Get-Value $u 'assignedLicenses') | Where-Object { $_ }).Count
    if ($LicensedOnly -and $licCount -eq 0) { continue }
    $created = ConvertTo-UtcDate (Get-Value $u 'createdDateTime')
    if (-not $IncludeRecentlyCreated -and $created -and $created -gt $cutoff) { continue }

    $sia = Get-Value $u 'signInActivity'
    $succ = ConvertTo-UtcDate (Get-Value $sia 'lastSuccessfulSignInDateTime')
    $inter = ConvertTo-UtcDate (Get-Value $sia 'lastSignInDateTime')
    $nonInter = ConvertTo-UtcDate (Get-Value $sia 'lastNonInteractiveSignInDateTime')

    if ($Basis -eq 'AnyAttempt') {
        $last = Get-Newest @($succ, $inter, $nonInter); $used = 'AnyAttempt'
    } elseif ($succ) {
        $last = $succ; $used = 'LastSuccessful'
    } else {
        $last = Get-Newest @($inter, $nonInter); $used = if ($last) { 'Fallback: last attempt (no successful sign-in recorded)' } else { '' }
    }
    if ($last -and $last -gt $cutoff) { continue }

    $daysInactive = if ($last) { [int][math]::Floor(($now - $last).TotalDays) } else { $null }
    $rows.Add([pscustomobject][ordered]@{
        DisplayName              = Get-Value $u 'displayName'
        UserPrincipalName        = Get-Value $u 'userPrincipalName'
        UserType                 = $type
        AccountEnabled           = $enabled
        IsLicensed               = ($licCount -gt 0)
        LicenseCount             = $licCount
        CreatedDateTime          = $created
        LastSuccessfulSignIn     = $succ
        LastInteractiveSignIn    = $inter
        LastNonInteractiveSignIn = $nonInter
        LastActivity             = $last
        DaysInactive             = $daysInactive
        Status                   = if ($last) { "Inactive $daysInactive days" } else { 'NeverSignedIn (or last sign-in before April 2020)' }
        BasisUsed                = $used
        OnPremisesSynced         = [bool](Get-Value $u 'onPremisesSyncEnabled')
        ExternalUserState        = Get-Value $u 'externalUserState'
        Id                       = Get-Value $u 'id'
    })
}

$out = @($rows | Sort-Object @{ e = { if ($null -eq $_.DaysInactive) { [int]::MaxValue } else { $_.DaysInactive } }; Descending = $true }, UserPrincipalName)

if ($CsvPath) {
    $out | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8
    Write-Status ("CSV written: {0}" -f $CsvPath)
}
if ($HtmlPath) {
    $css = '<style>body{font-family:Segoe UI,Arial,sans-serif;font-size:13px}table{border-collapse:collapse}th,td{border:1px solid #ccc;padding:4px 6px;text-align:left}th{background:#eee}</style>'
    $pre = "<h2>Inactive Entra ID users ($Days+ days)</h2><p>Tenant $($ctx.TenantId). Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm'). Basis: $Basis. Users: $($out.Count).</p>"
    $out | Select-Object -Property * -ExcludeProperty Id | ConvertTo-Html -Head $css -PreContent $pre | Out-File -FilePath $HtmlPath -Encoding UTF8
    Write-Status "HTML written: $HtmlPath"
}

$never = @($out | Where-Object { $null -eq $_.LastActivity }).Count
$guests = @($out | Where-Object { $_.UserType -eq 'Guest' }).Count
$lic = @($out | Where-Object { $_.IsLicensed }).Count
Write-Status ("Inactive {0}+ days: {1} (guests {2}, licensed {3}, never signed in {4})." -f $Days, $out.Count, $guests, $lic, $never)

if ($PassThru) { return $out }
if (-not $CsvPath -and -not $HtmlPath) {
    $out | Select-Object DisplayName, UserPrincipalName, UserType, IsLicensed, AccountEnabled, LastActivity, DaysInactive | Format-Table -AutoSize
}
