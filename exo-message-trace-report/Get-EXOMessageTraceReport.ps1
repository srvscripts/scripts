# Exchange Online Message Trace to CSV: Get-MessageTraceV2 Script (v1.0.0) - from srvScripts.com
# Source, docs and updates: https://srvscripts.com/scripts/exo-message-trace-report/
# Copyright (c) 2026 srvScripts.com. MIT licence: if you copy, share or adapt this script, keep this notice and credit srvScripts.com.
<#
.SYNOPSIS
    Exchange Online message trace to CSV with Get-MessageTraceV2: filter by sender, recipient, status,
    subject and time window, with automatic 10-day splitting and continuation past 5,000 rows.

.DESCRIPTION
    Read-only. Microsoft began deprecating Get-MessageTrace and Get-MessageTraceDetail on 1 September 2025
    (Microsoft 365 message center MC1092458). This script uses the replacement, Get-MessageTraceV2
    (ExchangeOnlineManagement 3.7.0 or later), which Microsoft documents as follows:
      - searches up to the last 90 days, but at most 10 days per query;
      - returns 1,000 rows by default and up to 5,000 with -ResultSize;
      - has no page numbers: to get the next batch you repeat the query with -EndDate set to the Received
        time and -StartingRecipientAddress set to the recipient of the last row of the previous batch;
      - accepts at most 100 queries in a rolling 5-minute window;
      - returns times in UTC.
    The script handles all of that: it splits the window into 10-day slices, pages each slice, removes
    duplicate rows, and pauses when it gets close to the query limit.

    Permissions: Microsoft documents membership of the Organization Management role group, or the Exchange
    Administrator Entra role. For a narrower custom role, list the roles that contain the cmdlet with
    Get-ManagementRole -Cmdlet Get-MessageTraceV2. App-only: app with Exchange.ManageAsApp and an Entra role
    assigned to its service principal, for example Exchange Administrator.

.PARAMETER Hours               Look back this many hours (default 24, max 2160 = 90 days). Ignored with -StartDate.
.PARAMETER StartDate           Start of the window (local time). Must be within the last 90 days.
.PARAMETER EndDate             End of the window (local time, default now).
.PARAMETER SenderAddress       One or more sender addresses.
.PARAMETER RecipientAddress    One or more recipient addresses.
.PARAMETER Status              Delivered, Expanded, Failed, FilteredAsSpam, GettingStatus, Pending, Quarantined.
.PARAMETER Subject             Subject text to match.
.PARAMETER SubjectFilterType   Contains, StartsWith or EndsWith (default StartsWith; Microsoft recommends it over Contains).
.PARAMETER MessageId           Message-ID header value(s), including angle brackets if the header has them.
.PARAMETER MaxResults          Stop after this many rows (default 50000) to protect against runaway queries.
.PARAMETER CsvPath             Write the result to this CSV file.
.PARAMETER PassThru            Output objects to the pipeline.
.PARAMETER UserPrincipalName   Admin account for interactive sign-in (optional).
.PARAMETER AppId / Organization / CertificateThumbprint   Certificate (app-only) sign-in.
.PARAMETER Disconnect          Disconnect from Exchange Online when finished.

.EXAMPLE  .\Get-EXOMessageTraceReport.ps1 -Hours 48 -RecipientAddress bob@contoso.com
.EXAMPLE  .\Get-EXOMessageTraceReport.ps1 -Hours 24 -Status Failed,Quarantined,FilteredAsSpam -CsvPath .\problems.csv
.EXAMPLE  .\Get-EXOMessageTraceReport.ps1 -StartDate (Get-Date).AddDays(-30) -SenderAddress invoices@contoso.com -CsvPath .\invoices-30d.csv
.EXAMPLE  .\Get-EXOMessageTraceReport.ps1 -Hours 6 -Subject "Invoice" -SubjectFilterType StartsWith
.EXAMPLE  .\Get-EXOMessageTraceReport.ps1 -AppId <app-id> -Organization contoso.onmicrosoft.com -CertificateThumbprint <thumbprint> -Hours 24 -CsvPath C:\Reports\trace.csv -Disconnect

.NOTES
    Name:     Get-EXOMessageTraceReport.ps1
    Purpose:  Exchange Online message trace export (Get-MessageTraceV2)
    Source:   https://srvscripts.com/scripts/exo-message-trace-report/
    License:  MIT
    Version:  1.0.0
    Requires: Windows PowerShell 5.1 or PowerShell 7, module ExchangeOnlineManagement 3.7.0 or later
              (Get-MessageTraceV2; update with Update-Module ExchangeOnlineManagement).
#>
[CmdletBinding(DefaultParameterSetName = 'Interactive')]
param(
    [ValidateRange(1, 2160)]
    [int]$Hours = 24,
    [datetime]$StartDate,
    [datetime]$EndDate = (Get-Date),
    [string[]]$SenderAddress,
    [string[]]$RecipientAddress,
    [ValidateSet('Delivered', 'Expanded', 'Failed', 'FilteredAsSpam', 'GettingStatus', 'Pending', 'Quarantined')]
    [string[]]$Status,
    [string]$Subject,
    [ValidateSet('Contains', 'StartsWith', 'EndsWith')]
    [string]$SubjectFilterType = 'StartsWith',
    [string[]]$MessageId,
    [ValidateRange(1, 1000000)]
    [int]$MaxResults = 50000,
    [string]$CsvPath,
    [switch]$PassThru,
    [Parameter(ParameterSetName = 'Interactive')]
    [string]$UserPrincipalName,
    [Parameter(ParameterSetName = 'AppOnly', Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$AppId,
    [Parameter(ParameterSetName = 'AppOnly', Mandatory = $true)]
    [string]$Organization,
    [Parameter(ParameterSetName = 'AppOnly', Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F]{40}$')]
    [string]$CertificateThumbprint,
    [switch]$Disconnect
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$PageSize = 5000          # Get-MessageTraceV2 maximum
$SliceDays = 10           # maximum window per query
$QueryLimit = 95          # stay under 100 queries per rolling 5 minutes

function Write-Status([string]$Message) { Write-Information $Message -InformationAction Continue }

# Get-MessageTraceV2 returns UTC times; make sure the DateTime is marked as UTC before it is reused.
function ConvertTo-Utc([datetime]$Value) {
    if ($Value.Kind -eq [DateTimeKind]::Local) { return $Value.ToUniversalTime() }
    return [datetime]::SpecifyKind($Value, [DateTimeKind]::Utc)
}

# ---- Window -------------------------------------------------------------------------------------------
$endUtc = $EndDate.ToUniversalTime()
$startUtc = if ($PSBoundParameters.ContainsKey('StartDate')) { $StartDate.ToUniversalTime() } else { $endUtc.AddHours(-$Hours) }
$nowUtc = (Get-Date).ToUniversalTime()
if ($startUtc -ge $endUtc) { throw '-StartDate must be earlier than -EndDate.' }
if ($endUtc -gt $nowUtc) { $endUtc = $nowUtc }
$oldest = $nowUtc.AddDays(-90).AddMinutes(1)
if ($startUtc -lt $oldest -and $startUtc -gt $oldest.AddHours(-1)) { $startUtc = $oldest }   # -Hours 2160 rounding
if ($startUtc -lt $oldest) { throw 'Get-MessageTraceV2 only searches the last 90 days. Use a later -StartDate (or a historical search in the Exchange admin center).' }

# ---- Connect --------------------------------------------------------------------------------------------
if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) {
    throw 'Module ExchangeOnlineManagement is not installed. Run: Install-Module ExchangeOnlineManagement -Scope CurrentUser'
}
Import-Module ExchangeOnlineManagement
$existing = @(Get-ConnectionInformation -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Connected' -and $_.Name -like 'ExchangeOnline_*' })
if (-not $existing) {
    $c = @{ ShowBanner = $false }
    if ($PSCmdlet.ParameterSetName -eq 'AppOnly') {
        $c.AppId = $AppId; $c.Organization = $Organization; $c.CertificateThumbprint = $CertificateThumbprint
    } elseif ($UserPrincipalName) { $c.UserPrincipalName = $UserPrincipalName }
    Connect-ExchangeOnline @c
}
if (-not (Get-Command Get-MessageTraceV2 -ErrorAction SilentlyContinue)) {
    throw 'Get-MessageTraceV2 is not available in this session. Update ExchangeOnlineManagement to 3.7.0 or later (Update-Module ExchangeOnlineManagement) and check that your account has message trace permissions (Organization Management role group or Exchange Administrator).'
}

# ---- Query helper with rolling-window throttle -----------------------------------------------------------
$queryTimes = [System.Collections.Generic.Queue[datetime]]::new()
function Invoke-TraceQuery([hashtable]$Params) {
    while ($queryTimes.Count -gt 0 -and $queryTimes.Peek() -lt (Get-Date).AddMinutes(-5)) { [void]$queryTimes.Dequeue() }
    if ($queryTimes.Count -ge $QueryLimit) {
        $wait = [int][math]::Ceiling(($queryTimes.Peek().AddMinutes(5) - (Get-Date)).TotalSeconds) + 1
        Write-Status "Close to the 100 queries / 5 minutes limit, waiting $wait s..."
        Start-Sleep -Seconds ([math]::Max($wait, 1))
    }
    $queryTimes.Enqueue((Get-Date))
    $attempt = 0
    while ($true) {
        $attempt++
        try { return @(Get-MessageTraceV2 @Params -ErrorAction Stop) }
        catch {
            if ($attempt -lt 4 -and $_.Exception.Message -match 'throttl|Too many|429|temporarily') {
                Start-Sleep -Seconds (30 * $attempt); continue
            }
            throw
        }
    }
}

# ---- Run ------------------------------------------------------------------------------------------------
$filter = @{}
if ($SenderAddress) { $filter.SenderAddress = $SenderAddress }
if ($RecipientAddress) { $filter.RecipientAddress = $RecipientAddress }
if ($Status) { $filter.Status = $Status }
if ($Subject) { $filter.Subject = $Subject; $filter.SubjectFilterType = $SubjectFilterType }
if ($MessageId) { $filter.MessageId = $MessageId }

$seen = @{}
$rows = [System.Collections.Generic.List[object]]::new()
$sliceEnd = $endUtc
$capped = $false
while ($sliceEnd -gt $startUtc -and -not $capped) {
    $sliceStart = $sliceEnd.AddDays(-$SliceDays)
    if ($sliceStart -lt $startUtc) { $sliceStart = $startUtc }
    Write-Status ("Tracing {0:yyyy-MM-dd HH:mm} to {1:yyyy-MM-dd HH:mm} UTC..." -f $sliceStart, $sliceEnd)

    $queryEnd = $sliceEnd
    $startingRecipient = $null
    do {
        $p = $filter.Clone()
        $p.StartDate = $sliceStart; $p.EndDate = $queryEnd; $p.ResultSize = $PageSize
        if ($startingRecipient) { $p.StartingRecipientAddress = $startingRecipient }
        $batch = @(Invoke-TraceQuery $p)
        foreach ($m in $batch) {
            $key = '{0}|{1}|{2:o}|{3}' -f $m.MessageTraceId, $m.RecipientAddress, $m.Received, $m.Status
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            $rows.Add([pscustomobject]@{
                ReceivedUtc      = (ConvertTo-Utc $m.Received)
                SenderAddress    = $m.SenderAddress
                RecipientAddress = $m.RecipientAddress
                Subject          = $m.Subject
                Status           = $m.Status
                Size             = $m.Size
                FromIP           = $m.FromIP
                ToIP             = $m.ToIP
                MessageId        = $m.MessageId
                MessageTraceId   = $m.MessageTraceId
            })
            if ($rows.Count -ge $MaxResults) { $capped = $true; break }
        }
        $more = ($batch.Count -ge $PageSize) -and -not $capped
        if ($more) {
            $last = $batch[$batch.Count - 1]
            $lastReceived = ConvertTo-Utc $last.Received
            if ($lastReceived -eq $queryEnd -and [string]$last.RecipientAddress -eq $startingRecipient) {
                Write-Warning 'Continuation did not advance; stopping this slice to avoid a loop.'
                $more = $false
            } else {
                $queryEnd = $lastReceived
                $startingRecipient = [string]$last.RecipientAddress
            }
        }
    } while ($more)
    $sliceEnd = $sliceStart
}
if ($capped) { Write-Warning "Stopped at -MaxResults $MaxResults rows. Narrow the filters or raise -MaxResults." }

$out = @($rows | Sort-Object ReceivedUtc -Descending)
if ($CsvPath) {
    $out | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8
    Write-Status ("CSV written: {0} ({1} rows)" -f $CsvPath, $out.Count)
}
$byStatus = $out | Group-Object Status | Sort-Object Count -Descending | ForEach-Object { "{0} {1}" -f $_.Count, $_.Name }
Write-Status ("Messages: {0}. By status: {1}" -f $out.Count, $(if ($byStatus) { $byStatus -join ', ' } else { 'none' }))

if ($Disconnect) { Disconnect-ExchangeOnline -Confirm:$false }
if ($PassThru) { return $out }
if (-not $CsvPath) { $out | Select-Object ReceivedUtc, SenderAddress, RecipientAddress, Status, Subject | Format-Table -AutoSize }
