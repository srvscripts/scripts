# AD Nested Group Membership: PowerShell Tree with Loop Detection (v1.0.0) - from srvScripts.com
# Source, docs and updates: https://srvscripts.com/scripts/ad-nested-group-membership/
# Copyright (c) 2026 srvScripts.com. MIT licence: if you copy, share or adapt this script, keep this notice and credit srvScripts.com.
<#
.SYNOPSIS
    Show the full nested group membership tree of an AD user, computer or group, with the path to each group
    and loop detection.

.DESCRIPTION
    Read-only. Two directions:
      MemberOf  every group the object belongs to, directly or through nesting (walks memberOf upwards).
                For users and computers the primary group (primaryGroupID, usually Domain Users or Domain
                Computers) is added, because it is not stored in memberOf.
      Members   everything inside a group, expanded through nested groups (walks member downwards).
    Default (Auto): MemberOf for users and computers, Members for groups.

    Each row has the depth (Level), the object, and the Path from the starting object, e.g.
    "bob > Sales-RW > Sales-All > All-Staff". Circular nesting (A in B, B in A) is reported with
    Note = "Loop" and not followed again. A group reached a second time through another branch is reported
    with Note = "Already listed" and is not expanded twice, which keeps large trees fast. Objects in other
    domains of the forest are read from that domain (worked out from the DN).

.PARAMETER Identity
    sAMAccountName, distinguished name, SID or GUID of the starting user, computer or group.
    For a computer, use its sAMAccountName with the trailing $, e.g. PC01$.

.PARAMETER Direction
    Auto (default), MemberOf or Members.

.PARAMETER MaxDepth
    Stop expanding below this depth (default 25).

.PARAMETER GroupsOnly
    In Members mode, only list groups (skip users, computers and other objects).

.PARAMETER Server
    Domain or DC to query for the starting object (default: current domain).

.PARAMETER ExportCsv
    Write the rows to this CSV file (UTF-8).

.PARAMETER PassThru
    Output the row objects to the pipeline instead of the indented tree.

.EXAMPLE
    .\Get-ADNestedGroupMembership.ps1 -Identity bob

.EXAMPLE
    .\Get-ADNestedGroupMembership.ps1 -Identity "Domain Admins" -ExportCsv C:\Reports\da-tree.csv

.EXAMPLE
    .\Get-ADNestedGroupMembership.ps1 -Identity "Sales-All" -Direction MemberOf

.EXAMPLE
    .\Get-ADNestedGroupMembership.ps1 -Identity bob -PassThru | Where-Object Note -eq 'Loop'

.NOTES
    Name:     Get-ADNestedGroupMembership.ps1
    Version:  1.0.0
    Source:   https://srvscripts.com/scripts/ad-nested-group-membership/
    License:  MIT
    Requires: Windows PowerShell 5.1 or PowerShell 7 on Windows, ActiveDirectory module (RSAT), read access to AD.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string]$Identity,

    [ValidateSet('Auto', 'MemberOf', 'Members')]
    [string]$Direction = 'Auto',

    [ValidateRange(1, 100)]
    [int]$MaxDepth = 25,

    [switch]$GroupsOnly,

    [ValidateNotNullOrEmpty()]
    [string]$Server,

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

$props = 'member', 'memberOf', 'objectClass', 'objectSid', 'sAMAccountName', 'groupType', 'primaryGroupID', 'name'

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

$cache = @{}
function Get-CachedObject {
    param([string]$DistinguishedName)
    if ($cache.ContainsKey($DistinguishedName)) { return $cache[$DistinguishedName] }
    $o = $null
    try {
        $o = Get-ADObject -Identity $DistinguishedName -Server (Get-DomainFromDN $DistinguishedName) -Properties $props
    } catch {
        Write-Warning "Cannot read '$DistinguishedName': $($_.Exception.Message)"
    }
    $cache[$DistinguishedName] = $o
    $o
}

function Get-GroupKind {
    param($Object)
    $gt = Get-AttributeValue $Object 'groupType'
    if ($null -eq $gt) { return '' }
    $v = [int64]$gt
    $scope = if ($v -band 0x2) { 'Global' } elseif ($v -band 0x4) { 'DomainLocal' } elseif ($v -band 0x8) { 'Universal' } elseif ($v -band 0x1) { 'Builtin' } else { '' }
    $cat = if ($v -band 0x80000000) { 'Security' } else { 'Distribution' }
    "$scope $cat".Trim()
}

function Get-LastClass {
    param($Object)
    $c = Get-AttributeValue $Object 'objectClass'
    if ($null -eq $c) { return [string]$Object.ObjectClass }
    [string](@($c)[-1])
}

# ---- Starting object ------------------------------------------------------------------------------------
$domArgs = @{}
if ($Server) { $domArgs.Server = $Server }
$domain = Get-ADDomain @domArgs
$startArgs = @{ Server = $domain.DNSRoot; Properties = $props }
if ($Server) { $startArgs.Server = $Server }

$start = $null
try {
    $start = Get-ADObject -Identity $Identity @startArgs
} catch {
    # Not a DN or GUID: try sAMAccountName, then SID.
    $esc = $Identity -replace '\\', '\5c' -replace '\*', '\2a' -replace '\(', '\28' -replace '\)', '\29'
    $hit = @(Get-ADObject -LDAPFilter "(sAMAccountName=$esc)" @startArgs)
    if (-not $hit.Count -and $Identity -match '^S-1-') { $hit = @(Get-ADObject -LDAPFilter "(objectSid=$Identity)" @startArgs) }
    if (-not $hit.Count) { throw "No user, computer or group '$Identity' found in $($startArgs.Server). For a computer use NAME`$ (with the dollar sign)." }
    $start = $hit[0]
}
$startClass = Get-LastClass $start
$cache[$start.DistinguishedName] = $start
$mode = $Direction
if ($mode -eq 'Auto') { $mode = if ($startClass -eq 'group') { 'Members' } else { 'MemberOf' } }
Write-Verbose "Start: $($start.DistinguishedName) ($startClass), direction $mode"

# ---- Walk -----------------------------------------------------------------------------------------------
$rows = [System.Collections.Generic.List[object]]::new()
$expanded = @{}

function Add-Row {
    param($Object, [int]$Level, [string]$Path, [string]$Note)
    $rows.Add([pscustomobject]@{
        Level             = $Level
        Name              = [string](Get-AttributeValue $Object 'name')
        SamAccountName    = [string](Get-AttributeValue $Object 'sAMAccountName')
        ObjectClass       = Get-LastClass $Object
        GroupType         = Get-GroupKind $Object
        Path              = $Path
        Note              = $Note
        Domain            = Get-DomainFromDN $Object.DistinguishedName
        DistinguishedName = $Object.DistinguishedName
    })
}

function Invoke-Walk {
    param($Object, [int]$Level, [string]$Path, [string[]]$Ancestors, [int]$DepthLimit, [bool]$OnlyGroups)
    if ($Level -gt $DepthLimit) { return }
    $attr = if ($mode -eq 'MemberOf') { 'memberOf' } else { 'member' }
    $links = @(Get-AttributeValue $Object $attr | Where-Object { $_ })
    foreach ($dn in ($links | Sort-Object)) {
        $o = Get-CachedObject ([string]$dn)
        if (-not $o) { continue }
        $cls = Get-LastClass $o
        $name = [string](Get-AttributeValue $o 'name')
        $p = "$Path > $name"
        if ($Ancestors -contains $o.DistinguishedName) { Add-Row $o $Level $p 'Loop'; continue }
        if ($cls -ne 'group') {
            if (-not $OnlyGroups) { Add-Row $o $Level $p '' }
            continue
        }
        if ($expanded.ContainsKey($o.DistinguishedName)) { Add-Row $o $Level $p 'Already listed'; continue }
        $expanded[$o.DistinguishedName] = $true
        $note = ''
        if ($Level -eq $DepthLimit) { $note = 'MaxDepth reached' }
        Add-Row $o $Level $p $note
        Invoke-Walk -Object $o -Level ($Level + 1) -Path $p -Ancestors ($Ancestors + $o.DistinguishedName) -DepthLimit $DepthLimit -OnlyGroups $OnlyGroups
    }
}

$startName = [string](Get-AttributeValue $start 'name')
Invoke-Walk -Object $start -Level 1 -Path $startName -Ancestors @($start.DistinguishedName) -DepthLimit $MaxDepth -OnlyGroups $GroupsOnly.IsPresent

# Primary group (MemberOf mode, users and computers)
if ($mode -eq 'MemberOf') {
    $pgid = Get-AttributeValue $start 'primaryGroupID'
    $sid = Get-AttributeValue $start 'objectSid'
    if ($null -ne $pgid -and $null -ne $sid) {
        $sidText = [string]$sid
        if ($sid -is [System.Security.Principal.SecurityIdentifier]) { $sidText = $sid.Value }
        $domainSid = $sidText -replace '-\d+$', ''
        try {
            $pg = Get-ADGroup -Identity "$domainSid-$pgid" -Server (Get-DomainFromDN $start.DistinguishedName) -Properties $props
            $cache[$pg.DistinguishedName] = $pg
            if (-not $expanded.ContainsKey($pg.DistinguishedName)) {
                $expanded[$pg.DistinguishedName] = $true
                Add-Row $pg 1 "$startName > $($pg.Name)" 'Primary group'
                Invoke-Walk -Object $pg -Level 2 -Path "$startName > $($pg.Name)" -Ancestors @($start.DistinguishedName, $pg.DistinguishedName) -DepthLimit $MaxDepth -OnlyGroups $GroupsOnly.IsPresent
            }
        } catch {
            Write-Verbose "Primary group $domainSid-$pgid not resolved: $($_.Exception.Message)"
        }
    }
}

$out = @($rows)

# ---- Output ---------------------------------------------------------------------------------------------
if ($ExportCsv) {
    $out | Export-Csv -LiteralPath $ExportCsv -NoTypeInformation -Encoding UTF8
    Write-Information ("{0} row(s) written to {1}" -f $out.Count, $ExportCsv) -InformationAction Continue
}
if ($PassThru) { return $out }

$groupCount = @($out | Where-Object { $_.ObjectClass -eq 'group' -and $_.Note -ne 'Already listed' -and $_.Note -ne 'Loop' }).Count
$loops = @($out | Where-Object { $_.Note -eq 'Loop' }).Count
Write-Information ("{0} ({1}) - {2}: {3} unique group(s), {4} row(s), {5} loop(s)" -f $startName, $startClass, $mode, $groupCount, $out.Count, $loops) -InformationAction Continue
foreach ($r in $out) {
    $tag = ''
    if ($r.Note) { $tag = "  [$($r.Note)]" }
    $kind = $r.ObjectClass
    if ($r.GroupType) { $kind = $r.GroupType }
    Write-Information (('  ' * $r.Level) + "$($r.Name) ($kind)$tag") -InformationAction Continue
}
