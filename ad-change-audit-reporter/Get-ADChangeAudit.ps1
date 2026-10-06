# AD Change Audit Reporter: Find Who Changed Active Directory (PowerShell) (v1.0.0) - from srvScripts.com
# Source, docs and updates: https://srvscripts.com/scripts/ad-change-audit-reporter/
# Copyright (c) 2026 srvScripts.com. MIT licence: if you copy, share or adapt this script, keep this notice and credit srvScripts.com.
<#
.SYNOPSIS
    Who changed what in Active Directory, when, and (when the logs allow it) from which computer.

.DESCRIPTION
    Read-only. Reads the Security log of a domain controller and turns directory-change and account-management
    events into one readable activity report:
      5136 5137 5139 5141                 directory object modified / created / moved / deleted (needs SACLs)
      4720 4722 4723 4724 4725 4726 4738 4767   user account created / enabled / password change / reset /
                                                disabled / deleted / changed / unlocked
      4728 4729 4732 4733 4756 4757       member added / removed: global, domain local, universal security group
      4741 4742 4743                      computer account created / changed / deleted
    5136 attribute changes are reported as one row: the "Value Deleted" event gives the old value and the
    "Value Added" event the new value (they share an OpCorrelationID).
    The source computer is taken from the 4624 logon event on the same DC whose TargetLogonId matches the
    actor's SubjectLogonId. If no such logon is found, Workstation and SourceIP say "Not available": the script
    never guesses.

    The script does NOT enable auditing, change SACLs, GPOs, accounts or logs. Your DCs must already record
    these events: see https://srvscripts.com/guides/audit-active-directory-changes/

.PARAMETER Days            Look back this many days (default 7). Ignored when -Start is given.
.PARAMETER Start / End     Explicit time window.
.PARAMETER User            Only changes made by this actor (sAMAccountName or DOMAIN\name, wildcards allowed).
.PARAMETER Target          Only changes to this target (name, DN fragment or wildcard), e.g. "Jane Doe" or "*Sales*".
.PARAMETER EventId         Only these event IDs.
.PARAMETER ComputerName    Domain controller to read (default: this computer). Run once per DC: events are per DC.
.PARAMETER LogonLookbackHours  How far before the window to search for the matching 4624 logon (default 12).
.PARAMETER Detailed        Show every field as a list instead of the summary table.
.PARAMETER PassThru        Output objects (for Where-Object, Export-Csv, ConvertTo-Json ...).
.PARAMETER ExportCsv       Also write the result to this CSV file.

.EXAMPLE  .\Get-ADChangeAudit.ps1 -Days 7
.EXAMPLE  .\Get-ADChangeAudit.ps1 -User "CONTOSO\ADuser" -Days 30
.EXAMPLE  .\Get-ADChangeAudit.ps1 -Target "Jane Doe" -Days 30 -Detailed
.EXAMPLE  .\Get-ADChangeAudit.ps1 -EventId 4728,4732,4756 -Days 90      # who added members to groups
.EXAMPLE  .\Get-ADChangeAudit.ps1 -Days 30 -ExportCsv C:\Reports\AD-Audit.csv

.NOTES
    srvScripts — https://srvscripts.com/scripts/ad-change-audit-reporter/   License: MIT
    Version 1.0.0 — run on 6 Oct 2026 against real events on a Windows Server 2025 domain controller (srvScripts lab).
    Requires: Windows PowerShell 5.1 or PowerShell 7, rights to read the DC Security log (Administrators or
    Event Log Readers on the DC), and for -ComputerName the Remote Event Log Management firewall rules.
#>
[CmdletBinding()]
param(
    [int]$Days = 7,
    [datetime]$Start,
    [datetime]$End = (Get-Date),
    [string]$User,
    [string]$Target,
    [int[]]$EventId,
    [string]$ComputerName = $env:COMPUTERNAME,
    [int]$LogonLookbackHours = 12,
    [switch]$Detailed,
    [switch]$PassThru,
    [string]$ExportCsv
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$ScriptVersion = '1.0.0'

$ChangeIds = 5136,5137,5139,5141,4720,4722,4723,4724,4725,4726,4738,4767,4728,4729,4732,4733,4756,4757,4741,4742,4743
$Actions = @{
    5136='Modified'; 5137='Created'; 5139='Moved'; 5141='Deleted'
    4720='User created'; 4722='User enabled'; 4723='Password changed (by user)'; 4724='Password reset'
    4725='User disabled'; 4726='User deleted'; 4738='User changed'; 4767='User unlocked'
    4728='Added to global group'; 4729='Removed from global group'
    4732='Added to local group'; 4733='Removed from local group'
    4756='Added to universal group'; 4757='Removed from universal group'
    4741='Computer created'; 4742='Computer changed'; 4743='Computer deleted'
}
$NA = 'Not available'

if (-not $PSBoundParameters.ContainsKey('Start')) { $Start = $End.AddDays(-[math]::Abs($Days)) }
if ($Start -ge $End) { throw "-Start must be earlier than -End." }
$ids = if ($EventId) { @($EventId | Where-Object { $ChangeIds -contains $_ }) } else { $ChangeIds }
if (-not $ids) { throw "None of the -EventId values is a change event this script reads: $($ChangeIds -join ', ')" }

function Get-EventData([System.Diagnostics.Eventing.Reader.EventRecord]$e) {
    $h = @{}
    foreach ($d in ([xml]$e.ToXml()).Event.EventData.Data) { $h[$d.Name] = [string]$d.'#text' }
    $h
}
function Get-Cn([string]$dn) {
    if (-not $dn -or $dn -eq '-') { return '' }
    if ($dn -match '^(?:CN|OU)=((?:\\,|[^,])+)') { return ($Matches[1] -replace '\\,', ',') }
    $dn
}
function Join-Account([string]$domain, [string]$name) {
    if (-not $name -or $name -eq '-') { return '' }
    if ($domain -and $domain -ne '-') { "$domain\$name" } else { $name }
}

# ---- Read access and retention check ------------------------------------------------------------------
$gw = @{ ComputerName = $ComputerName }
try {
    $oldest = Get-WinEvent @gw -LogName Security -MaxEvents 1 -Oldest
} catch [System.UnauthorizedAccessException] {
    throw "Access denied reading the Security log on $ComputerName. Run as a member of Administrators or Event Log Readers on that DC."
} catch {
    if ($_.Exception.Message -match 'denied|unauthori') { throw "Access denied reading the Security log on $ComputerName. Run as a member of Administrators or Event Log Readers on that DC." }
    throw "Cannot read the Security log on ${ComputerName}: $($_.Exception.Message)"
}
if ($oldest -and $oldest.TimeCreated -gt $Start) {
    Write-Warning ("The oldest event in the Security log on {0} is from {1:yyyy-MM-dd HH:mm}. Anything before that has been overwritten and cannot be reported. Increase the Security log size or forward events to a collector." -f $ComputerName, $oldest.TimeCreated)
}

# ---- Collect change events -----------------------------------------------------------------------------
try {
    $events = @(Get-WinEvent @gw -FilterHashtable @{ LogName = 'Security'; Id = $ids; StartTime = $Start; EndTime = $End })
} catch {
    if ($_.FullyQualifiedErrorId -match 'NoMatchingEventsFound' -or $_.Exception.Message -match 'No events were found') { $events = @() }
    else { throw }
}

$rows = [System.Collections.Generic.List[object]]::new()
$pairs = @{}   # 5136: OpCorrelationID|ObjectDN|Attribute -> row

foreach ($e in ($events | Sort-Object TimeCreated)) {
    $d = Get-EventData $e
    $id = $e.Id
    $row = [ordered]@{
        Timestamp = $e.TimeCreated; EventID = $id; Actor = (Join-Account $d['SubjectDomainName'] $d['SubjectUserName'])
        Action = $Actions[$id]; Target = ''; ObjectType = ''; Attribute = ''; OldValue = ''; NewValue = ''; Group = ''
        ObjectDN = ''; LogonID = [string]$d['SubjectLogonId']; Workstation = $NA; SourceIP = $NA; LogonType = ''
        DomainController = $e.MachineName
    }
    $handled = $false
    switch -Regex ([string]$id) {
        '^5136$' {
            $key = '{0}|{1}|{2}' -f $d['OpCorrelationID'], $d['ObjectDN'], $d['AttributeLDAPDisplayName']
            $op = $d['OperationType']   # %%14674 Value Added, %%14675 Value Deleted
            if ($pairs.ContainsKey($key)) {
                $r = $pairs[$key]
                if ($op -eq '%%14675') { $r.OldValue = $d['AttributeValue'] } else { $r.NewValue = $d['AttributeValue'] }
                $handled = $true; break
            }
            $row.Target = Get-Cn $d['ObjectDN']; $row.ObjectDN = $d['ObjectDN']; $row.ObjectType = $d['ObjectClass']
            $row.Attribute = $d['AttributeLDAPDisplayName']
            if ($op -eq '%%14675') { $row.OldValue = $d['AttributeValue'] } else { $row.NewValue = $d['AttributeValue'] }
            $row.Action = 'Modified ' + $d['ObjectClass']
            $obj = New-Object psobject -Property $row
            $pairs[$key] = $obj; $rows.Add($obj); $handled = $true; break
        }
        '^(5137|5141)$' { $row.Target = Get-Cn $d['ObjectDN']; $row.ObjectDN = $d['ObjectDN']; $row.ObjectType = $d['ObjectClass']; $row.Action = "$($Actions[$id]) $($d['ObjectClass'])" }
        '^5139$' { $row.Target = Get-Cn $d['NewObjectDN']; $row.ObjectDN = $d['NewObjectDN']; $row.ObjectType = $d['ObjectClass']; $row.OldValue = $d['OldObjectDN']; $row.NewValue = $d['NewObjectDN']; $row.Action = "Moved $($d['ObjectClass'])" }
        '^(4728|4729|4732|4733|4756|4757)$' {
            $row.Target = if ($d['MemberName'] -and $d['MemberName'] -ne '-') { Get-Cn $d['MemberName'] } else { $d['MemberSid'] }
            $row.ObjectDN = $d['MemberName']; $row.Group = Join-Account $d['TargetDomainName'] $d['TargetUserName']; $row.ObjectType = 'group membership'
            $row.Action = "$($Actions[$id]) $($d['TargetUserName'])"
        }
        '^(4741|4742|4743)$' { $row.Target = Join-Account $d['TargetDomainName'] $d['TargetUserName']; $row.ObjectType = 'computer' }
        default { $row.Target = Join-Account $d['TargetDomainName'] $d['TargetUserName']; $row.ObjectType = 'user' }
    }
    if (-not $handled) { $rows.Add((New-Object psobject -Property $row)) }
}

# ---- Filters -------------------------------------------------------------------------------------------
$out = $rows.ToArray()
if ($User) {
    $u = if ($User -match '\\') { $User } else { "*\$User" }
    $out = @($out | Where-Object { $_.Actor -like $u -or $_.Actor -like $User })
}
if ($Target) {
    $t = if ($Target -match '[*?]') { $Target } else { "*$Target*" }
    $out = @($out | Where-Object { $_.Target -like $t -or $_.ObjectDN -like $t -or $_.Group -like $t })
}

# ---- Source computer: 4624 on the same DC with TargetLogonId = actor's SubjectLogonId ------------------
$cache = @{}
foreach ($r in $out) {
    $lid = $r.LogonID
    if (-not $lid -or $lid -eq '0x3e7' -or $lid -eq '-') { if ($lid -eq '0x3e7') { $r.Workstation = 'Local SYSTEM'; $r.SourceIP = 'Local' }; continue }
    if (-not $cache.ContainsKey($lid)) {
        $hit = $null
        $xp = "*[System[(EventID=4624)]] and *[EventData[Data[@Name='TargetLogonId']='$lid']]"
        try {
            $hit = Get-WinEvent @gw -LogName Security -FilterXPath $xp -MaxEvents 5 |
                Where-Object { $_.TimeCreated -le $r.Timestamp -and $_.TimeCreated -ge $Start.AddHours(-$LogonLookbackHours) } |
                Select-Object -First 1
        } catch { $hit = $null }
        $cache[$lid] = if ($hit) { Get-EventData $hit } else { $null }
    }
    $l = $cache[$lid]
    if ($l) {
        if ($l['WorkstationName'] -and $l['WorkstationName'] -ne '-') { $r.Workstation = $l['WorkstationName'] }
        if ($l['IpAddress'] -and $l['IpAddress'] -notin '-', '::1', '127.0.0.1') { $r.SourceIP = $l['IpAddress'] }
        elseif ($l['IpAddress'] -in '::1', '127.0.0.1') { $r.SourceIP = 'Local (on the DC)' }
        $r.LogonType = $l['LogonType']
    }
}

# ---- Output --------------------------------------------------------------------------------------------
if ($ExportCsv) {
    $out | Select-Object Timestamp,EventID,Actor,Action,Target,ObjectType,Attribute,OldValue,NewValue,Group,ObjectDN,LogonID,Workstation,SourceIP,LogonType,DomainController |
        Export-Csv -Path $ExportCsv -NoTypeInformation -Encoding UTF8
    Write-Host ("{0} change(s) written to {1}" -f $out.Count, $ExportCsv)
}
if ($PassThru) { return $out }
if (-not $out.Count) {
    Write-Host ("No matching changes on {0} between {1:yyyy-MM-dd HH:mm} and {2:yyyy-MM-dd HH:mm}. If you expected some, check that auditing and SACLs are configured (see the guide)." -f $ComputerName, $Start, $End)
    return
}
if ($Detailed) {
    $out | Format-List Timestamp,EventID,Actor,Action,Target,ObjectType,ObjectDN,Attribute,OldValue,NewValue,Group,LogonID,Workstation,SourceIP,LogonType,DomainController
} else {
    $out | Select-Object @{n='Time';e={$_.Timestamp.ToString('dd-MMM HH:mm')}}, Actor, Action, Target,
        @{n='Change';e={ if ($_.Attribute) { "{0}: {1} -> {2}" -f $_.Attribute, $_.OldValue, $_.NewValue } else { '' } }},
        @{n='Source';e={ if ($_.Workstation -ne $NA) { $_.Workstation } elseif ($_.SourceIP -ne $NA) { $_.SourceIP } else { $NA } }} |
        Format-Table -AutoSize -Wrap
}
