# Block RDP Brute Force on Windows Server: PowerShell Script (v1.0.1) - from srvScripts.com
# Source, docs and updates: https://srvscripts.com/scripts/rdp-brute-force-blocker/
# Copyright (c) 2026 srvScripts.com. MIT licence: if you copy, share or adapt this script, keep this notice and credit srvScripts.com.
<#
.SYNOPSIS
    Block RDP brute-force sources on Windows Server: counts failed logons (Security event 4625, logon
    types 3 and 10) per source IP over the last -Minutes and blocks every IP at or above -Threshold
    with Windows Firewall rules. Report-only unless you add -Apply.

.DESCRIPTION
    Default (no -Apply): reads the events and prints a table of source addresses with their failure
    count and the decision the script would take. Nothing is changed.

    With -Apply (supports -WhatIf):
      1. New offenders are added to a small state file (JSON) together with the time they were first
         blocked. Addresses already present in the script's firewall rules are imported into the state
         file, so deleting the file does not unblock anything.
      2. With -ExpireDays, entries older than that many days are dropped (unblocked).
      3. The block list is written to one or more inbound Block rules named <RuleName>-001, -002, ...
         (at most -MaxAddressesPerRule addresses each). Existing rules are updated with
         Set-NetFirewallRule -RemoteAddress; surplus rules are removed.

    Safety:
      - Private, loopback, link-local and carrier-grade NAT ranges (10/8, 172.16/12, 192.168/16, 127/8,
        169.254/16, 100.64/10, ::1, fe80::/10, fc00::/7) are never blocked unless -IncludePrivate.
      - -AllowList / -AllowListPath addresses and CIDR ranges are never blocked (put your office and VPN
        egress addresses here) and are removed from the rules if they were blocked earlier.
      - Events without a source address ("-") are counted but cannot be blocked.

    Requirements: Windows Server 2012 R2 or later (or Windows 10/11), Windows PowerShell 5.1 or
    PowerShell 7, run as Administrator (reading the Security log and changing firewall rules both need
    it). Failed logons must be audited: "Audit Logon" (Failure) under Advanced Audit Policy > Logon/Logoff.
    The rules only matter while Windows Firewall is on for the active profile.

.PARAMETER Minutes              Look back this many minutes in the Security log (default 60).
.PARAMETER Threshold            Block a source with at least this many failures in the window (default 10).
.PARAMETER LogonType            Logon types to count: 3 (Network, used by RDP with NLA) and/or 10 (RemoteInteractive). Default both.
.PARAMETER AllowList            IP addresses or CIDR ranges that are never blocked.
.PARAMETER AllowListPath        Text file with one IP or CIDR per line (# comments allowed).
.PARAMETER IncludePrivate       Also block private, loopback, link-local and CGNAT addresses.
.PARAMETER Apply                Create/update the firewall rules. Without it the script only reports.
.PARAMETER RuleName             Base name of the firewall rules (default srvScripts-RDP-BruteForce).
.PARAMETER LocalPort            Block only this TCP port (for example 3389). Default 0 = block all traffic from the address.
.PARAMETER MaxAddressesPerRule  Addresses per firewall rule before a new rule is started (default 1000).
.PARAMETER ExpireDays           Unblock addresses this many days after they were first blocked (default 0 = never).
.PARAMETER StatePath            State file (default %ProgramData%\srvScripts\rdp-blocklist.json).
.PARAMETER LogPath              Append one line per change to this text file.
.PARAMETER CsvPath              Write the per-address report to CSV.
.PARAMETER PassThru             Output the report objects to the pipeline.

.EXAMPLE  .\Block-RdpBruteForce.ps1
          Report only: failures per source IP in the last 60 minutes.
.EXAMPLE  .\Block-RdpBruteForce.ps1 -Minutes 30 -Threshold 10 -AllowList 203.0.113.10,198.51.100.0/24 -Apply -WhatIf
.EXAMPLE  .\Block-RdpBruteForce.ps1 -Minutes 30 -Threshold 10 -AllowListPath C:\Scripts\rdp-allow.txt -ExpireDays 30 -Apply -LogPath C:\Scripts\rdp-block.log
.EXAMPLE  .\Block-RdpBruteForce.ps1 -Minutes 1440 -Threshold 3 -CsvPath C:\Reports\rdp-failures.csv

.NOTES
    Name:     Block-RdpBruteForce.ps1
    Purpose:  Turn failed RDP logons (event 4625) into Windows Firewall block rules
    Source:   https://srvscripts.com/scripts/rdp-brute-force-blocker/
    License:  MIT
    Version:  1.0.1
    Requires: Windows PowerShell 5.1 or PowerShell 7 on Windows, NetSecurity module (built in), Administrator.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [ValidateRange(1, 10080)]
    [int]$Minutes = 60,
    [ValidateRange(1, 100000)]
    [int]$Threshold = 10,
    [ValidateSet(3, 10)]
    [int[]]$LogonType = @(3, 10),
    [string[]]$AllowList,
    [string]$AllowListPath,
    [switch]$IncludePrivate,
    [switch]$Apply,
    [ValidatePattern('^[A-Za-z0-9 ._-]{3,60}$')]
    [string]$RuleName = 'srvScripts-RDP-BruteForce',
    [ValidateRange(0, 65535)]
    [int]$LocalPort = 0,
    [ValidateRange(10, 10000)]
    [int]$MaxAddressesPerRule = 1000,
    [ValidateRange(0, 3650)]
    [int]$ExpireDays = 0,
    [string]$StatePath,
    [string]$LogPath,
    [string]$CsvPath,
    [switch]$PassThru
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

function Write-Status([string]$Message) { Write-Information $Message -InformationAction Continue }

$changeLogFile = $LogPath
$skipPrivate = -not $IncludePrivate

function Write-ChangeLog([string]$Message) {
    $line = '{0} {1}' -f (Get-Date -Format 's'), $Message
    Write-Status $line
    if ($changeLogFile) { Add-Content -LiteralPath $changeLogFile -Value $line -Encoding UTF8 -WhatIf:$false }
}

# ---- Address helpers ------------------------------------------------------------------------------------
function ConvertTo-IpAddress([string]$Text) {
    $ip = $null
    if (-not [System.Net.IPAddress]::TryParse($Text.Trim(), [ref]$ip)) { return $null }
    if ($ip.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6 -and $ip.IsIPv4MappedToIPv6) { $ip = $ip.MapToIPv4() }
    if ($ip.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6) { $ip.ScopeId = 0 }
    return $ip
}

function ConvertTo-Network([string]$Text) {
    # Accepts "192.0.2.10", "192.0.2.0/24", "2001:db8::/32". Returns @{ Bytes; Prefix } or $null.
    $parts = $Text.Trim() -split '/', 2
    $ip = ConvertTo-IpAddress $parts[0]
    if (-not $ip) { return $null }
    $bytes = $ip.GetAddressBytes()
    $max = $bytes.Length * 8
    $prefix = $max
    if ($parts.Count -eq 2) {
        $p = 0
        if (-not [int]::TryParse($parts[1], [ref]$p) -or $p -lt 0 -or $p -gt $max) { return $null }
        $prefix = $p
    }
    return @{ Bytes = $bytes; Prefix = $prefix }
}

function Test-InNetwork([System.Net.IPAddress]$Ip, [hashtable]$Network) {
    $a = $Ip.GetAddressBytes()
    $b = $Network.Bytes
    if ($a.Length -ne $b.Length) { return $false }
    $bits = $Network.Prefix
    for ($i = 0; $i -lt $a.Length -and $bits -gt 0; $i++) {
        $take = [math]::Min(8, $bits)
        $mask = [byte]((0xFF -shl (8 - $take)) -band 0xFF)
        if (($a[$i] -band $mask) -ne ($b[$i] -band $mask)) { return $false }
        $bits -= $take
    }
    return $true
}

$privateNets = @('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', '127.0.0.0/8', '169.254.0.0/16', '100.64.0.0/10',
    '::1/128', 'fe80::/10', 'fc00::/7') | ForEach-Object { ConvertTo-Network $_ }

$allowNets = [System.Collections.Generic.List[object]]::new()
$allowEntries = @()
if ($AllowList) { $allowEntries += $AllowList }
if ($AllowListPath) {
    if (-not (Test-Path -LiteralPath $AllowListPath)) { throw "Allow-list file not found: $AllowListPath" }
    $allowEntries += @(Get-Content -LiteralPath $AllowListPath | ForEach-Object { ($_ -replace '#.*$', '').Trim() } | Where-Object { $_ })
}
foreach ($entry in $allowEntries) {
    $n = ConvertTo-Network $entry
    if (-not $n) { throw "Allow-list entry is not an IP address or CIDR range: '$entry'" }
    $allowNets.Add($n)
}

function Get-SkipReason([System.Net.IPAddress]$Ip) {
    foreach ($n in $allowNets) { if (Test-InNetwork $Ip $n) { return 'AllowListed' } }
    if ($skipPrivate) { foreach ($n in $privateNets) { if (Test-InNetwork $Ip $n) { return 'Private (use -IncludePrivate)' } } }
    return $null
}

# ---- Pre-flight -----------------------------------------------------------------------------------------
if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) { throw 'This script runs on Windows only.' }
if (-not $StatePath) { $StatePath = Join-Path $env:ProgramData 'srvScripts\rdp-blocklist.json' }
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script from an elevated PowerShell (Administrator): reading the Security log and changing firewall rules need it.'
}

# ---- Read failed logons ---------------------------------------------------------------------------------
$since = (Get-Date).AddMinutes(-$Minutes)
Write-Status ("Reading event 4625 since {0:yyyy-MM-dd HH:mm} (logon types {1})..." -f $since, ($LogonType -join ', '))
$events = @()
try {
    $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'Security'; Id = 4625; StartTime = $since } -ErrorAction Stop)
} catch {
    if ($_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound*') { throw }
}

$stats = @{}
$noAddress = 0
foreach ($e in $events) {
    $data = @{}
    foreach ($d in ([xml]$e.ToXml()).Event.EventData.Data) { $data[[string]$d.Name] = [string]$d.InnerText }
    $lt = 0
    if (-not $data.ContainsKey('LogonType') -or -not [int]::TryParse($data['LogonType'], [ref]$lt)) { continue }
    if ($LogonType -notcontains $lt) { continue }
    $raw = if ($data.ContainsKey('IpAddress')) { $data['IpAddress'] } else { '' }
    $ip = if ($raw -and $raw -ne '-') { ConvertTo-IpAddress $raw } else { $null }
    if (-not $ip) { $noAddress++; continue }
    $key = $ip.ToString()
    if (-not $stats.ContainsKey($key)) {
        $stats[$key] = @{ Ip = $ip; Fails = 0; Users = @{}; Types = @{}; First = $e.TimeCreated; Last = $e.TimeCreated }
    }
    $s = $stats[$key]
    $s.Fails++
    $user = if ($data.ContainsKey('TargetUserName')) { $data['TargetUserName'] } else { '' }
    if ($user) { $s.Users[$user] = $true }
    $s.Types[[string]$lt] = $true
    if ($e.TimeCreated -lt $s.First) { $s.First = $e.TimeCreated }
    if ($e.TimeCreated -gt $s.Last) { $s.Last = $e.TimeCreated }
}
$totalFails = 0
foreach ($s in $stats.Values) { $totalFails += $s.Fails }
Write-Status ("{0} matching failures from {1} source address(es); {2} without a source address." -f $totalFails, $stats.Count, $noAddress)
if (-not $events.Count) {
    Write-Warning 'No 4625 events in the window. If you expected some, check that "Audit Logon" failure auditing is enabled (auditpol /get /subcategory:"Logon").'
}

# ---- Current rules and state ----------------------------------------------------------------------------
$rulePattern = "$RuleName-*"
$existingRules = @(Get-NetFirewallRule -Name $rulePattern -ErrorAction SilentlyContinue)
$blocked = @{}
foreach ($r in $existingRules) {
    foreach ($a in @(($r | Get-NetFirewallAddressFilter).RemoteAddress)) {
        $addr = ([string]$a) -replace '/(255\.255\.255\.255|32|128)$', ''
        if ($addr -and $addr -ne 'Any') { $blocked[$addr] = @{ FirstBlockedUtc = (Get-Date).ToUniversalTime().ToString('o'); Source = 'rule' } }
    }
}
if (Test-Path -LiteralPath $StatePath) {
    try {
        $parsed = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
        foreach ($entry in $parsed) {
            if ($entry -and $entry.Address) { $blocked[[string]$entry.Address] = @{ FirstBlockedUtc = [string]$entry.FirstBlockedUtc; Source = 'state' } }
        }
    } catch { Write-Warning "State file could not be read and is ignored: $($_.Exception.Message)" }
}

# ---- Decide ---------------------------------------------------------------------------------------------
$nowUtc = (Get-Date).ToUniversalTime()
$report = [System.Collections.Generic.List[object]]::new()
$toAdd = [System.Collections.Generic.List[string]]::new()
foreach ($s in ($stats.Values | Sort-Object { $_['Fails'] } -Descending)) {
    $addr = $s.Ip.ToString()
    $skip = Get-SkipReason $s.Ip
    $decision = if ($skip) { $skip }
    elseif ($blocked.ContainsKey($addr)) { 'AlreadyBlocked' }
    elseif ($s.Fails -ge $Threshold) { 'Block' }
    else { 'BelowThreshold' }
    if ($decision -eq 'Block') { $toAdd.Add($addr) }
    $report.Add([pscustomobject][ordered]@{
        SourceAddress = $addr
        Failures      = $s.Fails
        DistinctUsers = $s.Users.Count
        SampleUsers   = (@($s.Users.Keys | Sort-Object | Select-Object -First 5) -join '; ')
        LogonTypes    = (@($s.Types.Keys | Sort-Object) -join ',')
        FirstSeen     = $s.First
        LastSeen      = $s.Last
        Decision      = $decision
    })
}

# Allow-listed or private entries that are blocked from an earlier run get removed; expired ones too.
$toRemove = [System.Collections.Generic.List[string]]::new()
foreach ($addr in @($blocked.Keys)) {
    $n = ConvertTo-Network $addr
    if ($n) {
        $ipText = ($addr -split '/', 2)[0]
        $ip = ConvertTo-IpAddress $ipText
        if ($ip -and (Get-SkipReason $ip)) { $toRemove.Add($addr); continue }
    }
    if ($ExpireDays -gt 0) {
        $first = [datetime]::MinValue
        if ([datetime]::TryParse($blocked[$addr].FirstBlockedUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$first) -and
            $first.ToUniversalTime() -lt $nowUtc.AddDays(-$ExpireDays)) { $toRemove.Add($addr) }
    }
}

$final = @{}
foreach ($addr in $blocked.Keys) { if (-not $toRemove.Contains($addr)) { $final[$addr] = $blocked[$addr].FirstBlockedUtc } }
foreach ($addr in $toAdd) { $final[$addr] = $nowUtc.ToString('o') }

Write-Status ("To block now: {0}. To unblock (allow-listed, private or expired): {1}. Total after this run: {2}." -f $toAdd.Count, $toRemove.Count, $final.Count)

# ---- Apply ----------------------------------------------------------------------------------------------
if ($Apply) {
    $addresses = @($final.Keys | Sort-Object)
    $chunks = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $addresses.Count; $i += $MaxAddressesPerRule) {
        $end = [math]::Min($i + $MaxAddressesPerRule, $addresses.Count) - 1
        $chunks.Add(@($addresses[$i..$end]))
    }
    $wanted = @{}
    for ($c = 0; $c -lt $chunks.Count; $c++) {
        $name = '{0}-{1:000}' -f $RuleName, ($c + 1)
        $wanted[$name] = $true
        $list = [string[]]$chunks[$c]
        $rule = $existingRules | Where-Object { $_.Name -eq $name }
        if ($rule) {
            if ($PSCmdlet.ShouldProcess($name, "Set block list to $($list.Count) address(es)")) {
                Set-NetFirewallRule -Name $name -RemoteAddress $list
                Write-ChangeLog "Updated rule $name ($($list.Count) addresses)"
            }
        } elseif ($PSCmdlet.ShouldProcess($name, "Create inbound block rule for $($list.Count) address(es)")) {
            $p = @{
                Name          = $name
                DisplayName   = $name
                Description   = "Created by Block-RdpBruteForce.ps1 (srvscripts.com). Sources with $Threshold+ failed logons (event 4625)."
                Direction     = 'Inbound'
                Action        = 'Block'
                Profile       = 'Any'
                RemoteAddress = $list
                Enabled       = 'True'
            }
            if ($LocalPort -gt 0) { $p.Protocol = 'TCP'; $p.LocalPort = [string]$LocalPort }
            New-NetFirewallRule @p | Out-Null
            Write-ChangeLog "Created rule $name ($($list.Count) addresses)"
        }
    }
    foreach ($r in $existingRules) {
        if (-not $wanted.ContainsKey($r.Name) -and $PSCmdlet.ShouldProcess($r.Name, 'Remove surplus block rule')) {
            Remove-NetFirewallRule -Name $r.Name
            Write-ChangeLog "Removed rule $($r.Name)"
        }
    }
    foreach ($addr in $toAdd) {
        $msg = "$addr ($(@($report | Where-Object SourceAddress -eq $addr)[0].Failures) failures in $Minutes min)"
        if ($WhatIfPreference) { Write-Status "Would block $msg" } else { Write-ChangeLog "Blocked $msg" }
    }
    foreach ($addr in $toRemove) { if ($WhatIfPreference) { Write-Status "Would unblock $addr" } else { Write-ChangeLog "Unblocked $addr" } }

    if ($PSCmdlet.ShouldProcess($StatePath, 'Save block list state')) {
        $dir = Split-Path -Parent $StatePath
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $items = @($final.Keys | Sort-Object | ForEach-Object { [pscustomobject]@{ Address = $_; FirstBlockedUtc = $final[$_] } })
        $json = if ($items.Count) { ConvertTo-Json -InputObject $items -Depth 3 } else { '[]' }
        Set-Content -LiteralPath $StatePath -Value $json -Encoding UTF8
    }
} else {
    Write-Status 'Report only. Add -Apply to create or update the firewall rules (add -WhatIf to preview).'
}

# ---- Output ---------------------------------------------------------------------------------------------
if ($CsvPath) {
    $report | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8 -WhatIf:$false
    Write-Status "CSV written: $CsvPath"
}
if ($PassThru) { return $report }
if (-not $CsvPath -and $report.Count) {
    $report | Select-Object SourceAddress, Failures, DistinctUsers, LogonTypes, LastSeen, Decision | Format-Table -AutoSize
}
