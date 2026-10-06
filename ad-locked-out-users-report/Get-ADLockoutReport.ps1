# Locked Out AD Users Report: PowerShell Script with Lockout Source (v1.0.0) - from srvScripts.com
# Source, docs and updates: https://srvscripts.com/scripts/ad-locked-out-users-report/
# Copyright (c) 2026 srvScripts.com. MIT licence: if you copy, share or adapt this script, keep this notice and credit srvScripts.com.
<#
.SYNOPSIS
    List locked-out AD users and the computer each lockout came from (event 4740 on the PDC emulator).

.DESCRIPTION
    Read-only unless -Unlock is used.
    1. Finds locked-out users with Search-ADAccount -LockedOut against the PDC emulator, then keeps only the
       accounts whose msDS-User-Account-Control-Computed lockout bit (0x10) is still set, so accounts whose
       lockout duration has already expired are not reported as locked.
    2. Reads event 4740 ("A user account was locked out") from the Security log of the PDC emulator for the
       last -Hours hours. The Caller Computer Name is read from the event's second data field
       (TargetDomainName in the event XML), which is the machine the failed logons came from.
    3. Joins the two: one row per locked user with lockout time, bad password count, the lockout events in
       the window and every caller computer seen.

    -Unlock unlocks the reported accounts on the PDC emulator. It supports -WhatIf and -Confirm. Unlocking
    does not fix the cause: find and fix the device in CallerComputers first, or the account locks again.

.PARAMETER Hours
    How far back to read 4740 events (default 24, maximum 720).

.PARAMETER Identity
    Only report these users (sAMAccountName). Wildcards are not supported here.

.PARAMETER Server
    Domain to query (default: current domain). The script always talks to that domain's PDC emulator.

.PARAMETER EventComputer
    Read 4740 events from this computer instead of the PDC emulator (for example a log collector that
    receives forwarded Security events).

.PARAMETER IncludeHistory
    Also output users that were locked out in the window but are no longer locked.

.PARAMETER Unlock
    Unlock every reported account that is currently locked. Use -WhatIf first.

.PARAMETER ExportCsv
    Write the report to this CSV file (UTF-8).

.PARAMETER PassThru
    Output the row objects to the pipeline.

.EXAMPLE
    .\Get-ADLockoutReport.ps1

.EXAMPLE
    .\Get-ADLockoutReport.ps1 -Hours 72 -IncludeHistory -ExportCsv C:\Reports\lockouts.csv

.EXAMPLE
    .\Get-ADLockoutReport.ps1 -Identity bob -Unlock -WhatIf

.NOTES
    Name:     Get-ADLockoutReport.ps1
    Version:  1.0.0
    Source:   https://srvscripts.com/scripts/ad-locked-out-users-report/
    License:  MIT
    Requires: Windows PowerShell 5.1 or PowerShell 7 on Windows, ActiveDirectory module (RSAT), rights to read
              the PDC emulator's Security log (Domain Admins, or Event Log Readers on the DCs), the Remote Event
              Log Management firewall rules on the PDC, "Audit User Account Management" success auditing on DCs
              (needed for 4740), and for -Unlock the right to unlock the accounts.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [ValidateRange(1, 720)]
    [int]$Hours = 24,

    [ValidateNotNullOrEmpty()]
    [string[]]$Identity,

    [ValidateNotNullOrEmpty()]
    [string]$Server,

    [ValidateNotNullOrEmpty()]
    [string]$EventComputer,

    [switch]$IncludeHistory,

    [switch]$Unlock,

    [ValidateNotNullOrEmpty()]
    [string]$ExportCsv,

    [switch]$PassThru
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
    throw "The ActiveDirectory module is not installed. Install RSAT: Active Directory Domain Services tools, then run again."
}
Import-Module ActiveDirectory -Verbose:$false

function ConvertFrom-FileTimeValue {
    param($Value)
    if ($null -eq $Value) { return $null }
    $v = [int64]$Value
    if ($v -le 0 -or $v -eq [int64]::MaxValue) { return $null }
    [DateTime]::FromFileTime($v)
}

function Get-AttributeValue {
    param($Entity, [string]$Name)
    if ($Entity.PropertyNames -contains $Name) { return $Entity[$Name].Value }
    $null
}

# ---- Find the PDC emulator ------------------------------------------------------------------------------
$domainArgs = @{}
if ($Server) { $domainArgs.Server = $Server }
$domain = Get-ADDomain @domainArgs
$pdc = $domain.PDCEmulator
$logHost = if ($EventComputer) { $EventComputer } else { $pdc }
Write-Verbose "Domain $($domain.DNSRoot), PDC emulator $pdc, reading 4740 events from $logHost"

# ---- Currently locked accounts (from the PDC) -----------------------------------------------------------
$lockProps = 'lockoutTime', 'badPwdCount', 'badPasswordTime', 'msDS-User-Account-Control-Computed', 'displayName'
$locked = @{}
$candidates = @(Search-ADAccount -LockedOut -UsersOnly -Server $pdc)
foreach ($c in $candidates) {
    if ($Identity -and ($Identity -notcontains $c.SamAccountName)) { continue }
    $u = Get-ADUser -Identity $c.DistinguishedName -Server $pdc -Properties $lockProps
    $computed = Get-AttributeValue $u 'msDS-User-Account-Control-Computed'
    if ($null -ne $computed -and -not ([int]$computed -band 0x10)) {
        Write-Verbose "$($u.SamAccountName): lockoutTime is set but the lockout has expired; not reported as locked."
        continue
    }
    $locked[$u.SamAccountName.ToLowerInvariant()] = $u
}

# ---- 4740 events in the window --------------------------------------------------------------------------
$start = (Get-Date).AddHours(-$Hours)
$events = @()
try {
    $events = @(Get-WinEvent -ComputerName $logHost -FilterHashtable @{ LogName = 'Security'; Id = 4740; StartTime = $start })
} catch {
    $msg = $_.Exception.Message
    if ($_.FullyQualifiedErrorId -match 'NoMatchingEventsFound' -or $msg -match 'No events were found') {
        $events = @()
    } elseif ($msg -match 'denied|unauthori') {
        Write-Warning "Access denied reading the Security log on $logHost. Run as Domain Admin or a member of Event Log Readers on the DCs. Lockout sources will be empty."
    } else {
        Write-Warning "Could not read the Security log on ${logHost}: $msg. Lockout sources will be empty."
    }
}

$byUser = @{}
foreach ($e in $events) {
    $x = [xml]$e.ToXml()
    $d = @{}
    foreach ($n in $x.Event.EventData.Data) { $d[$n.Name] = [string]$n.InnerText }
    $name = [string]$d['TargetUserName']
    if (-not $name) { continue }
    $key = $name.ToLowerInvariant()
    if ($Identity -and ($Identity -notcontains $name)) { continue }
    if (-not $byUser.ContainsKey($key)) { $byUser[$key] = [System.Collections.Generic.List[object]]::new() }
    $byUser[$key].Add([pscustomobject]@{ Time = $e.TimeCreated; Caller = [string]$d['TargetDomainName']; DC = $e.MachineName })
}
Write-Verbose ("{0} lockout event(s) since {1:yyyy-MM-dd HH:mm}" -f $events.Count, $start)

# ---- Join -----------------------------------------------------------------------------------------------
$keys = [System.Collections.Generic.List[string]]::new()
foreach ($k in $locked.Keys) { $keys.Add($k) }
if ($IncludeHistory) { foreach ($k in $byUser.Keys) { if (-not $keys.Contains($k)) { $keys.Add($k) } } }

$rows = foreach ($k in $keys) {
    $u = $null
    if ($locked.ContainsKey($k)) { $u = $locked[$k] }
    $ev = @()
    if ($byUser.ContainsKey($k)) { $ev = @($byUser[$k] | Sort-Object Time -Descending) }
    $callers = @($ev | ForEach-Object { if ($_.Caller) { $_.Caller } else { '(blank)' } } | Select-Object -Unique)
    $name = $k; $display = ''; $dn = ''
    if ($u) { $name = $u.SamAccountName; $display = [string](Get-AttributeValue $u 'displayName'); $dn = $u.DistinguishedName }
    [pscustomobject]@{
        SamAccountName    = $name
        DisplayName       = $display
        LockedNow         = [bool]$u
        LockoutTime       = if ($u) { ConvertFrom-FileTimeValue (Get-AttributeValue $u 'lockoutTime') } else { $null }
        BadPwdCount       = if ($u) { Get-AttributeValue $u 'badPwdCount' } else { $null }
        LastBadPassword   = if ($u) { ConvertFrom-FileTimeValue (Get-AttributeValue $u 'badPasswordTime') } else { $null }
        LockoutEvents     = $ev.Count
        LastEventTime     = if ($ev.Count) { $ev[0].Time } else { $null }
        LastCaller        = if ($ev.Count) { $ev[0].Caller } else { '' }
        CallerComputers   = ($callers -join '; ')
        EventSource       = $logHost
        DistinguishedName = $dn
        Action            = ''
    }
}
$rows = @($rows | Sort-Object @{ Expression = 'LockedNow'; Descending = $true }, SamAccountName)

# ---- Optional unlock ------------------------------------------------------------------------------------
if ($Unlock) {
    foreach ($r in $rows | Where-Object { $_.LockedNow }) {
        if ($PSCmdlet.ShouldProcess("$($r.SamAccountName) on $pdc", 'Unlock-ADAccount')) {
            try {
                Unlock-ADAccount -Identity $r.DistinguishedName -Server $pdc -Confirm:$false
                $r.Action = 'Unlocked'
            } catch {
                $r.Action = "Unlock failed: $($_.Exception.Message)"
                Write-Warning "Could not unlock $($r.SamAccountName): $($_.Exception.Message)"
            }
        } else {
            $r.Action = 'WhatIf / skipped'
        }
    }
}

# ---- Output ---------------------------------------------------------------------------------------------
if ($ExportCsv) {
    $rows | Export-Csv -LiteralPath $ExportCsv -NoTypeInformation -Encoding UTF8
    Write-Information ("{0} row(s) written to {1}" -f $rows.Count, $ExportCsv) -InformationAction Continue
}
if ($PassThru) { return $rows }
if (-not $rows.Count) {
    Write-Information ("No locked-out users found on {0}. 4740 events read since {1:yyyy-MM-dd HH:mm}: {2}." -f $pdc, $start, $events.Count) -InformationAction Continue
    return
}
$rows | Format-Table SamAccountName, LockedNow, LockoutTime, BadPwdCount, LockoutEvents, LastCaller, CallerComputers, Action -AutoSize -Wrap
