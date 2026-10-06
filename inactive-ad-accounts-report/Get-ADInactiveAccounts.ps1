# Inactive AD Accounts Report: PowerShell Script with Safe Disable (v1.0.0) - from srvScripts.com
# Source, docs and updates: https://srvscripts.com/scripts/inactive-ad-accounts-report/
# Copyright (c) 2026 srvScripts.com. MIT licence: if you copy, share or adapt this script, keep this notice and credit srvScripts.com.
<#
.SYNOPSIS
    Find AD user and computer accounts with no logon for N days (lastLogonTimestamp), report them to CSV and
    optionally disable them.

.DESCRIPTION
    Read-only unless -Disable is used.
    Finds enabled accounts whose lastLogonTimestamp is older than -Days, using an LDAP filter that the DC
    evaluates (no need to pull every account). With -IncludeNeverLoggedOn it also returns accounts that have
    never logged on (lastLogonTimestamp empty) and were created more than -Days ago, so brand-new accounts
    are not reported.

    lastLogonTimestamp is replicated to every DC but, by design, can be 9-14 days behind the real last
    logon (default ms-DS-Logon-Time-Sync-Interval of 14 days minus a random 0-5 days). Keep -Days well above
    14; 90 is the common choice.

    -Disable disables the reported accounts with Disable-ADAccount. It supports -WhatIf and -Confirm
    (ConfirmImpact High, so you are asked per account unless you pass -Confirm:$false). Objects marked
    isCriticalSystemObject (built-in Administrator, domain controller computer accounts, krbtgt ...) and
    anything matching -Exclude are never disabled. Export the CSV first: it is your record of what was changed.

.PARAMETER Days
    Inactivity threshold in days (default 90, minimum 15).

.PARAMETER ObjectType
    Users, Computers or Both (default Both).

.PARAMETER IncludeNeverLoggedOn
    Also report accounts that never logged on and are older than -Days.

.PARAMETER IncludeDisabled
    Also report accounts that are already disabled (they are never touched by -Disable).

.PARAMETER SearchBase
    Limit the search to this OU (DN).

.PARAMETER Exclude
    sAMAccountName patterns to leave out of the report and out of -Disable, e.g. "svc-*","SQL01$".

.PARAMETER Server
    Domain or DC to query (default: current domain).

.PARAMETER Disable
    Disable every reported, enabled account (except critical system objects and -Exclude matches).

.PARAMETER ExportCsv
    Write the report to this CSV file (UTF-8).

.PARAMETER PassThru
    Output the row objects to the pipeline.

.EXAMPLE
    .\Get-ADInactiveAccounts.ps1 -Days 90 -ExportCsv C:\Reports\inactive.csv

.EXAMPLE
    .\Get-ADInactiveAccounts.ps1 -ObjectType Computers -Days 120 -IncludeNeverLoggedOn -SearchBase "OU=Workstations,DC=contoso,DC=com"

.EXAMPLE
    .\Get-ADInactiveAccounts.ps1 -ObjectType Users -Days 120 -Exclude "svc-*" -Disable -WhatIf

.EXAMPLE
    .\Get-ADInactiveAccounts.ps1 -ObjectType Users -Days 120 -Exclude "svc-*" -Disable -Confirm:$false -ExportCsv C:\Reports\disabled-2026-10.csv

.NOTES
    Name:     Get-ADInactiveAccounts.ps1
    Version:  1.0.0
    Source:   https://srvscripts.com/scripts/inactive-ad-accounts-report/
    Guide:    https://srvscripts.com/guides/find-inactive-ad-users-computers/
    License:  MIT
    Requires: Windows PowerShell 5.1 or PowerShell 7 on Windows, ActiveDirectory module (RSAT), read access to AD;
              for -Disable, the right to disable the accounts in scope.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [ValidateRange(15, 3650)]
    [int]$Days = 90,

    [ValidateSet('Users', 'Computers', 'Both')]
    [string]$ObjectType = 'Both',

    [switch]$IncludeNeverLoggedOn,

    [switch]$IncludeDisabled,

    [ValidateNotNullOrEmpty()]
    [string]$SearchBase,

    [ValidateNotNullOrEmpty()]
    [string[]]$Exclude,

    [ValidateNotNullOrEmpty()]
    [string]$Server,

    [switch]$Disable,

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

$now = Get-Date
$cutoff = $now.AddDays(-$Days)
$cutoffFileTime = $cutoff.ToFileTimeUtc()
$cutoffGenTime = $cutoff.ToUniversalTime().ToString('yyyyMMddHHmmss') + '.0Z'

$classes = switch ($ObjectType) {
    'Users'     { @{ User = '(objectCategory=person)(objectClass=user)' } }
    'Computers' { @{ Computer = '(objectCategory=computer)' } }
    default     { [ordered]@{ User = '(objectCategory=person)(objectClass=user)'; Computer = '(objectCategory=computer)' } }
}
$enabledClause = if ($IncludeDisabled) { '' } else { '(!(userAccountControl:1.2.840.113556.1.4.803:=2))' }
$activity = "(lastLogonTimestamp<=$cutoffFileTime)"
if ($IncludeNeverLoggedOn) { $activity = "(|$activity(&(!(lastLogonTimestamp=*))(whenCreated<=$cutoffGenTime)))" }

$attrs = 'lastLogonTimestamp', 'whenCreated', 'pwdLastSet', 'userAccountControl', 'description', 'operatingSystem',
         'isCriticalSystemObject', 'sAMAccountName', 'name'
$q = @{ Properties = $attrs; ResultPageSize = 500 }
if ($SearchBase) { $q.SearchBase = $SearchBase }
if ($Server) { $q.Server = $Server }

$rows = [System.Collections.Generic.List[object]]::new()
foreach ($kind in $classes.Keys) {
    $filter = "(&$($classes[$kind])$enabledClause$activity)"
    Write-Verbose "$kind filter: $filter"
    try {
        $objs = @(Get-ADObject -LDAPFilter $filter @q)
    } catch [System.ArgumentException] {
        throw "Invalid -SearchBase or filter: $($_.Exception.Message)"
    }
    foreach ($o in $objs) {
        $sam = [string](Get-AttributeValue $o 'sAMAccountName')
        $skip = $false
        foreach ($pattern in $Exclude) { if ($sam -like $pattern) { $skip = $true; break } }
        if ($skip) { Write-Verbose "Excluded: $sam"; continue }
        $last = ConvertFrom-FileTimeValue (Get-AttributeValue $o 'lastLogonTimestamp')
        $uac = Get-AttributeValue $o 'userAccountControl'
        $enabled = $null
        if ($null -ne $uac) { $enabled = -not ([int]$uac -band 2) }
        $created = Get-AttributeValue $o 'whenCreated'
        $inactiveDays = $null
        if ($last) { $inactiveDays = [int]($now - $last).TotalDays } elseif ($created) { $inactiveDays = [int]($now - $created).TotalDays }
        $rows.Add([pscustomobject]@{
            Name              = [string](Get-AttributeValue $o 'name')
            SamAccountName    = $sam
            ObjectType        = $kind
            Enabled           = $enabled
            LastLogonDate     = $last
            DaysInactive      = $inactiveDays
            NeverLoggedOn     = (-not $last)
            Created           = $created
            PasswordLastSet   = ConvertFrom-FileTimeValue (Get-AttributeValue $o 'pwdLastSet')
            OperatingSystem   = [string](Get-AttributeValue $o 'operatingSystem')
            Description       = [string](Get-AttributeValue $o 'description')
            Critical          = [bool](Get-AttributeValue $o 'isCriticalSystemObject')
            DistinguishedName = $o.DistinguishedName
            Action            = ''
        })
    }
}
$out = @($rows | Sort-Object ObjectType, @{ Expression = 'DaysInactive'; Descending = $true })

# ---- Optional disable -----------------------------------------------------------------------------------
if ($Disable) {
    $dArgs = @{}
    if ($Server) { $dArgs.Server = $Server }
    foreach ($r in $out) {
        if (-not $r.Enabled) { $r.Action = 'Already disabled'; continue }
        if ($r.Critical) { $r.Action = 'Skipped: critical system object'; continue }
        $what = if ($r.NeverLoggedOn) { 'never logged on' } else { "last logon $($r.LastLogonDate.ToString('yyyy-MM-dd'))" }
        if ($PSCmdlet.ShouldProcess("$($r.SamAccountName) ($($r.ObjectType), $what)", 'Disable-ADAccount')) {
            try {
                Disable-ADAccount -Identity $r.DistinguishedName @dArgs -Confirm:$false
                $r.Action = 'Disabled'
            } catch {
                $r.Action = "Disable failed: $($_.Exception.Message)"
                Write-Warning "Could not disable $($r.SamAccountName): $($_.Exception.Message)"
            }
        } else {
            $r.Action = 'WhatIf / skipped'
        }
    }
}

# ---- Output ---------------------------------------------------------------------------------------------
if ($ExportCsv) {
    $out | Export-Csv -LiteralPath $ExportCsv -NoTypeInformation -Encoding UTF8
    Write-Information ("{0} account(s) written to {1}" -f $out.Count, $ExportCsv) -InformationAction Continue
}
if ($PassThru) { return $out }
$users = @($out | Where-Object { $_.ObjectType -eq 'User' }).Count
$computers = @($out | Where-Object { $_.ObjectType -eq 'Computer' }).Count
Write-Information ("Inactive for {0}+ days (before {1:yyyy-MM-dd}): {2} user(s), {3} computer(s)." -f $Days, $cutoff, $users, $computers) -InformationAction Continue
if (-not $ExportCsv -and $out.Count) {
    $out | Format-Table Name, ObjectType, Enabled, LastLogonDate, DaysInactive, NeverLoggedOn, Action -AutoSize
}
