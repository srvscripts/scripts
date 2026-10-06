# AD Privileged Group Report: Domain Admins and adminCount Audit (v1.0.0) - from srvScripts.com
# Source, docs and updates: https://srvscripts.com/scripts/ad-privileged-group-report/
# Copyright (c) 2026 srvScripts.com. MIT licence: if you copy, share or adapt this script, keep this notice and credit srvScripts.com.
<#
.SYNOPSIS
    Report every account that is a direct or nested member of the privileged AD groups, plus adminCount=1 orphans.

.DESCRIPTION
    Read-only. Expands the member attribute of each privileged group recursively (breadth-first, so the
    shortest nesting path is reported) and returns one row per group and member account:
      Domain Admins (RID 512), Group Policy Creator Owners (520)         - current domain
      Enterprise Admins (519), Schema Admins (518)                       - forest root domain
      Administrators, Account Operators, Server Operators, Print Operators, Backup Operators
                                                                       (BUILTIN S-1-5-32-544/548/549/550/551)
      DnsAdmins                                                          - looked up by name (no fixed RID)
    Groups are found by SID, so renamed or localised group names still work.
    Users whose primaryGroupID points at a reported group are added too (that membership is not stored in
    the group's member attribute).

    For each account the report shows Enabled, LastLogonDate (lastLogonTimestamp, 9-14 days behind by
    design), PasswordLastSet, PasswordAgeDays, PasswordNeverExpires, adminCount and a Flags column.

    Orphans: accounts with adminCount=1 that are not in any reported group. AdminSDHolder sets adminCount=1
    when an account joins a protected group but does not clear it when the account leaves, so these accounts
    may still carry the protected ACL and no longer inherit permissions. Some are expected (krbtgt, members of
    protected groups not in this report such as Replicator, Key Admins or Domain Controllers).

.PARAMETER Server
    Domain to report on (default: current domain).

.PARAMETER AdditionalGroup
    Extra groups to include (sAMAccountName, DN or SID), e.g. "Key Admins","Helpdesk Tier1".

.PARAMETER StaleDays
    Flag enabled accounts with no logon for this many days (default 90).

.PARAMETER PasswordAgeDays
    Flag passwords older than this many days (default 365).

.PARAMETER SkipOrphans
    Do not search for adminCount=1 orphans.

.PARAMETER ExportCsv
    Write the report to this CSV file (UTF-8).

.PARAMETER ExportHtml
    Write the report to this HTML file.

.PARAMETER PassThru
    Output the row objects to the pipeline.

.EXAMPLE
    .\Get-ADPrivilegedGroupReport.ps1

.EXAMPLE
    .\Get-ADPrivilegedGroupReport.ps1 -ExportCsv C:\Reports\priv.csv -ExportHtml C:\Reports\priv.html

.EXAMPLE
    .\Get-ADPrivilegedGroupReport.ps1 -AdditionalGroup "Key Admins","Enterprise Key Admins" -StaleDays 60

.EXAMPLE
    .\Get-ADPrivilegedGroupReport.ps1 -PassThru | Where-Object Flags -match 'Disabled'

.NOTES
    Name:     Get-ADPrivilegedGroupReport.ps1
    Version:  1.0.0
    Source:   https://srvscripts.com/scripts/ad-privileged-group-report/
    License:  MIT
    Requires: Windows PowerShell 5.1 or PowerShell 7 on Windows, ActiveDirectory module (RSAT), read access to AD
              in every domain that holds members (any authenticated user can normally read these attributes).
#>
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string]$Server,

    [ValidateNotNullOrEmpty()]
    [string[]]$AdditionalGroup,

    [ValidateRange(1, 3650)]
    [int]$StaleDays = 90,

    [ValidateRange(1, 3650)]
    [int]$PasswordAgeDays = 365,

    [switch]$SkipOrphans,

    [ValidateNotNullOrEmpty()]
    [string]$ExportCsv,

    [ValidateNotNullOrEmpty()]
    [string]$ExportHtml,

    [switch]$PassThru
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
    throw "The ActiveDirectory module is not installed. Install RSAT: Active Directory Domain Services tools, then run again."
}
Import-Module ActiveDirectory -Verbose:$false

$now = Get-Date
$props = 'member', 'objectClass', 'objectSid', 'sAMAccountName', 'userAccountControl', 'lastLogonTimestamp',
         'pwdLastSet', 'adminCount', 'primaryGroupID', 'name'

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

function Get-DomainFromDN {
    param([string]$DistinguishedName)
    $parts = [regex]::Matches($DistinguishedName, '(?i)(?:^|,)DC=([^,]+)') | ForEach-Object { $_.Groups[1].Value }
    ($parts -join '.')
}

$objCache = @{}
function Get-CachedObject {
    param([string]$DistinguishedName)
    if ($objCache.ContainsKey($DistinguishedName)) { return $objCache[$DistinguishedName] }
    $dom = Get-DomainFromDN $DistinguishedName
    $o = $null
    try {
        $o = Get-ADObject -Identity $DistinguishedName -Server $dom -Properties $props
    } catch {
        Write-Warning "Cannot read '$DistinguishedName' from $dom : $($_.Exception.Message)"
    }
    $objCache[$DistinguishedName] = $o
    $o
}

function Get-LastClass {
    param($Object)
    $c = Get-AttributeValue $Object 'objectClass'
    if ($null -eq $c) { return [string]$Object.ObjectClass }
    [string](@($c)[-1])
}

# ---- Resolve the groups ---------------------------------------------------------------------------------
$domArgs = @{}
if ($Server) { $domArgs.Server = $Server }
$domain = Get-ADDomain @domArgs
$forest = Get-ADForest -Server $domain.DNSRoot
$root = Get-ADDomain -Server $forest.RootDomain
$dSid = $domain.DomainSID.Value
$rSid = $root.DomainSID.Value

$targets = @(
    @{ Sid = "$dSid-512"; Server = $domain.DNSRoot },
    @{ Sid = "$rSid-519"; Server = $root.DNSRoot },
    @{ Sid = "$rSid-518"; Server = $root.DNSRoot },
    @{ Sid = 'S-1-5-32-544'; Server = $domain.DNSRoot },
    @{ Sid = 'S-1-5-32-548'; Server = $domain.DNSRoot },
    @{ Sid = 'S-1-5-32-549'; Server = $domain.DNSRoot },
    @{ Sid = 'S-1-5-32-550'; Server = $domain.DNSRoot },
    @{ Sid = 'S-1-5-32-551'; Server = $domain.DNSRoot },
    @{ Sid = "$dSid-520"; Server = $domain.DNSRoot },
    @{ Name = 'DnsAdmins'; Server = $domain.DNSRoot }
)
foreach ($g in $AdditionalGroup) { $targets += @{ Name = $g; Server = $domain.DNSRoot } }

$groups = [System.Collections.Generic.List[object]]::new()
foreach ($t in $targets) {
    $id = if ($t.ContainsKey('Sid')) { $t.Sid } else { $t.Name }
    try {
        $grp = Get-ADGroup -Identity $id -Server $t.Server -Properties member, objectSid
        $groups.Add($grp)
    } catch {
        Write-Warning "Group '$id' not found in $($t.Server); skipped."
    }
}

# ---- Expand membership (breadth-first, shortest path wins) ----------------------------------------------
$rows = [System.Collections.Generic.List[object]]::new()
$seenMembers = @{}   # DN -> $true for accounts found in any reported group

function ConvertTo-ReportRow {
    param($GroupName, $Object, [string]$Via, [bool]$Direct, [int]$StaleLimit, [int]$PasswordLimit)
    $cls = Get-LastClass $Object
    $memberName = [string](Get-AttributeValue $Object 'name')
    if ($cls -eq 'foreignSecurityPrincipal') {
        try { $memberName = ([System.Security.Principal.SecurityIdentifier]$memberName).Translate([System.Security.Principal.NTAccount]).Value }
        catch { Write-Verbose "Cannot translate foreign SID $memberName" }
    }
    $uac = Get-AttributeValue $Object 'userAccountControl'
    $enabled = $null; $never = $null
    if ($null -ne $uac) { $enabled = -not ([int]$uac -band 2); $never = [bool]([int]$uac -band 0x10000) }
    $last = ConvertFrom-FileTimeValue (Get-AttributeValue $Object 'lastLogonTimestamp')
    $pwdSet = ConvertFrom-FileTimeValue (Get-AttributeValue $Object 'pwdLastSet')
    $age = $null
    if ($pwdSet) { $age = [int]($now - $pwdSet).TotalDays }
    $flags = [System.Collections.Generic.List[string]]::new()
    if ($enabled -eq $false) { $flags.Add('Disabled') }
    if ($enabled -and $cls -ne 'foreignSecurityPrincipal') {
        if (-not $last) { $flags.Add('Never logged on') }
        elseif (($now - $last).TotalDays -gt $StaleLimit) { $flags.Add("No logon >$StaleLimit d") }
    }
    if ($null -ne $age -and $age -gt $PasswordLimit) { $flags.Add("Password >$PasswordLimit d") }
    if ($null -ne $uac -and -not $pwdSet -and $cls -ne 'foreignSecurityPrincipal') { $flags.Add('Must change password / never set') }
    if ($never) { $flags.Add('PasswordNeverExpires') }
    if ($cls -eq 'foreignSecurityPrincipal') { $flags.Add('Foreign principal (other domain/forest)') }
    $adminCount = Get-AttributeValue $Object 'adminCount'
    [pscustomobject]@{
        Group                = $GroupName
        Member               = $memberName
        SamAccountName       = [string](Get-AttributeValue $Object 'sAMAccountName')
        ObjectClass          = $cls
        Direct               = $Direct
        Via                  = $Via
        Enabled              = $enabled
        LastLogonDate        = $last
        PasswordLastSet      = $pwdSet
        PasswordAgeDays      = $age
        PasswordNeverExpires = $never
        AdminCount           = $adminCount
        Flags                = ($flags -join '; ')
        Domain               = Get-DomainFromDN $Object.DistinguishedName
        DistinguishedName    = $Object.DistinguishedName
    }
}

foreach ($grp in $groups) {
    $gName = $grp.Name
    $doneGroups = @{ $grp.DistinguishedName = $true }
    $doneAccounts = @{}
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue(@{ DN = $grp.DistinguishedName; Path = $gName; Depth = 0 })
    while ($queue.Count) {
        $item = $queue.Dequeue()
        $g = Get-CachedObject $item.DN
        if (-not $g) { continue }
        foreach ($m in @(Get-AttributeValue $g 'member')) {
            if (-not $m) { continue }
            $o = Get-CachedObject ([string]$m)
            if (-not $o) { continue }
            $cls = Get-LastClass $o
            if ($cls -eq 'group') {
                if ($doneGroups.ContainsKey($o.DistinguishedName)) { continue }   # loop or already expanded
                $doneGroups[$o.DistinguishedName] = $true
                $queue.Enqueue(@{ DN = $o.DistinguishedName; Path = "$($item.Path) > $($o.Name)"; Depth = $item.Depth + 1 })
                continue
            }
            if ($doneAccounts.ContainsKey($o.DistinguishedName)) { continue }
            $doneAccounts[$o.DistinguishedName] = $true
            $seenMembers[$o.DistinguishedName] = $true
            $rows.Add((ConvertTo-ReportRow -GroupName $gName -Object $o -Via $item.Path -Direct ($item.Depth -eq 0) -StaleLimit $StaleDays -PasswordLimit $PasswordAgeDays))
        }
    }

    # primaryGroupID membership (domain groups only: RID after the domain SID)
    $sid = $grp.SID.Value
    if ($sid -match '^S-1-5-21-.+-(\d+)$') {
        $rid = $Matches[1]
        $gDom = Get-DomainFromDN $grp.DistinguishedName
        $pg = @(Get-ADObject -LDAPFilter "(primaryGroupID=$rid)" -Server $gDom -Properties $props)
        foreach ($o in $pg) {
            if ($doneAccounts.ContainsKey($o.DistinguishedName)) { continue }
            $doneAccounts[$o.DistinguishedName] = $true
            $seenMembers[$o.DistinguishedName] = $true
            $objCache[$o.DistinguishedName] = $o
            $rows.Add((ConvertTo-ReportRow -GroupName $gName -Object $o -Via "$gName (primary group)" -Direct $true -StaleLimit $StaleDays -PasswordLimit $PasswordAgeDays))
        }
    }
    Write-Verbose ("{0}: {1} account(s)" -f $gName, $doneAccounts.Count)
}

# ---- adminCount=1 orphans -------------------------------------------------------------------------------
if (-not $SkipOrphans) {
    $ac = @(Get-ADObject -LDAPFilter '(&(adminCount=1)(|(objectClass=user)(objectClass=computer)))' -Server $domain.DNSRoot -Properties $props)
    foreach ($o in $ac) {
        if ($seenMembers.ContainsKey($o.DistinguishedName)) { continue }
        $r = ConvertTo-ReportRow -GroupName '(adminCount=1, not in a reported group)' -Object $o -Via '' -Direct $false -StaleLimit $StaleDays -PasswordLimit $PasswordAgeDays
        $r.Flags = (@('Orphaned adminCount') + @($r.Flags | Where-Object { $_ })) -join '; '
        $rows.Add($r)
    }
}

$out = @($rows)

# ---- Output ---------------------------------------------------------------------------------------------
if ($ExportCsv) {
    $out | Export-Csv -LiteralPath $ExportCsv -NoTypeInformation -Encoding UTF8
    Write-Information ("{0} row(s) written to {1}" -f $out.Count, $ExportCsv) -InformationAction Continue
}
if ($ExportHtml) {
    $css = 'body{font-family:Segoe UI,Arial,sans-serif;font-size:13px;margin:20px}table{border-collapse:collapse}' +
           'th,td{border:1px solid #ccc;padding:4px 8px;text-align:left}th{background:#f0f0f0}'
    $summary = $out | Group-Object Group | Sort-Object Name | ForEach-Object {
        '<li>{0}: {1} account(s), {2} flagged</li>' -f [System.Net.WebUtility]::HtmlEncode($_.Name), $_.Count, @($_.Group | Where-Object { $_.Flags }).Count
    }
    $pre = "<h1>Privileged group report: $($domain.DNSRoot)</h1><p>Generated {0:yyyy-MM-dd HH:mm}.</p><ul>{1}</ul>" -f $now, ($summary -join '')
    $out | ConvertTo-Html -Title 'Privileged group report' -Head "<style>$css</style>" -PreContent $pre | Out-File -LiteralPath $ExportHtml -Encoding utf8
    Write-Information ("HTML report written to {0}" -f $ExportHtml) -InformationAction Continue
}
if ($PassThru) { return $out }
if (-not $ExportCsv -and -not $ExportHtml) {
    $out | Sort-Object Group, Member | Format-Table Group, Member, ObjectClass, Enabled, LastLogonDate, PasswordAgeDays, Via, Flags -AutoSize -Wrap
}
