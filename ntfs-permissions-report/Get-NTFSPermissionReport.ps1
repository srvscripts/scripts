# NTFS Permissions Report to CSV: PowerShell Folder ACL Script (v1.0.0) - from srvScripts.com
# Source, docs and updates: https://srvscripts.com/scripts/ntfs-permissions-report/
# Copyright (c) 2026 srvScripts.com. MIT licence: if you copy, share or adapt this script, keep this notice and credit srvScripts.com.
<#
.SYNOPSIS
    Export the NTFS permissions (ACLs) of a folder tree to CSV: who has what, explicit or inherited.

.DESCRIPTION
    Read-only. Walks a folder (local path or UNC share) to -Depth levels with Get-ChildItem, reads each ACL
    with Get-Acl and writes one row per access rule (ACE):
      Path, ItemType, Owner, InheritanceBlocked, Identity, Sid, Rights, AccessType, IsInherited,
      AppliesTo, InheritanceFlags, PropagationFlags, Error
    SIDs are translated to DOMAIN\name once each (cached). A SID that no longer resolves (deleted account)
    is reported as "Unresolved SID", which is usually worth cleaning up.
    Generic rights that appear on inherit-only entries (for example CREATOR OWNER) are shown by name
    (GenericAll, GenericRead ...) instead of a bare number.
    Folders that cannot be read (access denied, path too long) get a row with the Error column filled and
    the scan carries on.

.PARAMETER Path
    Root folder to scan, e.g. D:\Shares\Finance or \\fs01\Finance.

.PARAMETER Depth
    How many levels below -Path to scan (default 2; 0 = only the root folder).

.PARAMETER IncludeFiles
    Also report files (default: folders only). On large trees this multiplies the run time.

.PARAMETER ExplicitOnly
    Report only explicit (non-inherited) entries, plus the root folder in full. This is the quickest way to
    find where permissions were changed by hand.

.PARAMETER Identity
    Only report entries for identities matching this wildcard, e.g. "*Finance*" or "CONTOSO\bob".

.PARAMETER ExportCsv
    Write the report to this CSV file (UTF-8).

.PARAMETER PassThru
    Output the row objects to the pipeline.

.EXAMPLE
    .\Get-NTFSPermissionReport.ps1 -Path D:\Shares -Depth 3 -ExportCsv C:\Reports\shares-acl.csv

.EXAMPLE
    .\Get-NTFSPermissionReport.ps1 -Path \\fs01\Finance -ExplicitOnly -Depth 10 -ExportCsv C:\Reports\finance-explicit.csv

.EXAMPLE
    .\Get-NTFSPermissionReport.ps1 -Path D:\Shares -Depth 5 -Identity "*Everyone*" -PassThru | Format-Table Path, Rights

.NOTES
    Name:     Get-NTFSPermissionReport.ps1
    Version:  1.0.0
    Source:   https://srvscripts.com/scripts/ntfs-permissions-report/
    License:  MIT
    Requires: Windows PowerShell 5.1 or PowerShell 7 on Windows, read permission on the folders (run as an
              account that can read every ACL, e.g. a member of Administrators on the file server).
              No extra modules.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string]$Path,

    [ValidateRange(0, 100)]
    [int]$Depth = 2,

    [switch]$IncludeFiles,

    [switch]$ExplicitOnly,

    [ValidateNotNullOrEmpty()]
    [string]$Identity,

    [ValidateNotNullOrEmpty()]
    [string]$ExportCsv,

    [switch]$PassThru
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    throw "Folder not found or not accessible: $Path"
}
$rootItem = Get-Item -LiteralPath $Path

$sidCache = @{}
function Resolve-Sid {
    param([System.Security.Principal.SecurityIdentifier]$Sid)
    $k = $Sid.Value
    if (-not $sidCache.ContainsKey($k)) {
        try { $sidCache[$k] = $Sid.Translate([System.Security.Principal.NTAccount]).Value }
        catch { $sidCache[$k] = "Unresolved SID ($k)" }
    }
    $sidCache[$k]
}

function Format-Right {
    param($Rights)
    $v = [int64]([int]$Rights) -band 0xFFFFFFFFL
    $generic = @()
    if ($v -band 0x10000000L) { $generic += 'GenericAll' }
    if ($v -band 0x20000000L) { $generic += 'GenericExecute' }
    if ($v -band 0x40000000L) { $generic += 'GenericWrite' }
    if ($v -band 0x80000000L) { $generic += 'GenericRead' }
    $specific = $v -band 0x0FFFFFFFL
    $parts = @()
    if ($specific) { $parts += [Enum]::ToObject([System.Security.AccessControl.FileSystemRights], [int]$specific).ToString() }
    ($parts + $generic) -join ', '
}

function Get-AppliesTo {
    param([System.Security.AccessControl.InheritanceFlags]$Inherit,
          [System.Security.AccessControl.PropagationFlags]$Propagate,
          [bool]$IsContainer)
    if (-not $IsContainer) { return 'This file' }
    $ci = [bool]($Inherit -band [System.Security.AccessControl.InheritanceFlags]::ContainerInherit)
    $oi = [bool]($Inherit -band [System.Security.AccessControl.InheritanceFlags]::ObjectInherit)
    $io = [bool]($Propagate -band [System.Security.AccessControl.PropagationFlags]::InheritOnly)
    $np = [bool]($Propagate -band [System.Security.AccessControl.PropagationFlags]::NoPropagateInherit)
    $text = if (-not $ci -and -not $oi) { 'This folder only' }
            elseif ($ci -and $oi -and -not $io) { 'This folder, subfolders and files' }
            elseif ($ci -and -not $oi -and -not $io) { 'This folder and subfolders' }
            elseif ($oi -and -not $ci -and -not $io) { 'This folder and files' }
            elseif ($ci -and $oi -and $io) { 'Subfolders and files only' }
            elseif ($ci -and $io) { 'Subfolders only' }
            else { 'Files only' }
    if ($np -and ($ci -or $oi)) { $text += ' (one level only)' }
    $text
}

function Get-ErrorRow {
    param([string]$ItemPath, [string]$Type, [string]$Message)
    [pscustomobject]@{
        Path = $ItemPath; ItemType = $Type; Owner = ''; InheritanceBlocked = $null; Identity = ''; Sid = ''
        Rights = ''; AccessType = ''; IsInherited = $null; AppliesTo = ''; InheritanceFlags = ''; PropagationFlags = ''
        Error = $Message
    }
}

# ---- Collect items --------------------------------------------------------------------------------------
$items = [System.Collections.Generic.List[object]]::new()
$items.Add($rootItem)
$scanErrors = @()
if ($Depth -gt 0) {
    $gci = @{ LiteralPath = $rootItem.FullName; Recurse = $true; Depth = ($Depth - 1); Force = $true;
              ErrorAction = 'SilentlyContinue'; ErrorVariable = 'scanErrors' }
    if (-not $IncludeFiles) { $gci.Directory = $true }
    foreach ($i in (Get-ChildItem @gci)) { $items.Add($i) }
}
Write-Verbose ("{0} item(s) to read" -f $items.Count)

# ---- Read ACLs ------------------------------------------------------------------------------------------
$rows = [System.Collections.Generic.List[object]]::new()
foreach ($e in $scanErrors) {
    $target = [string]$e.TargetObject
    if (-not $target) { $target = $Path }
    $rows.Add((Get-ErrorRow -ItemPath $target -Type 'Folder' -Message ("Not listed: " + $e.Exception.Message)))
}

$n = 0
foreach ($item in $items) {
    $n++
    if ($n % 200 -eq 0) { Write-Progress -Activity 'Reading ACLs' -Status $item.FullName -PercentComplete (100 * $n / $items.Count) }
    $isDir = $item.PSIsContainer
    $type = if ($isDir) { 'Folder' } else { 'File' }
    try {
        $acl = Get-Acl -LiteralPath $item.FullName
    } catch {
        $rows.Add((Get-ErrorRow -ItemPath $item.FullName -Type $type -Message $_.Exception.Message))
        continue
    }
    $owner = ''
    try { $owner = $acl.Owner } catch { $owner = 'Unknown' }
    $isRoot = ($item.FullName -eq $rootItem.FullName)
    $rules = $acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])
    foreach ($r in $rules) {
        if ($ExplicitOnly -and $r.IsInherited -and -not $isRoot) { continue }
        $name = Resolve-Sid $r.IdentityReference
        if ($Identity -and ($name -notlike $Identity)) { continue }
        $rows.Add([pscustomobject]@{
            Path               = $item.FullName
            ItemType           = $type
            Owner              = $owner
            InheritanceBlocked = $acl.AreAccessRulesProtected
            Identity           = $name
            Sid                = $r.IdentityReference.Value
            Rights             = Format-Right $r.FileSystemRights
            AccessType         = [string]$r.AccessControlType
            IsInherited        = $r.IsInherited
            AppliesTo          = Get-AppliesTo $r.InheritanceFlags $r.PropagationFlags $isDir
            InheritanceFlags   = [string]$r.InheritanceFlags
            PropagationFlags   = [string]$r.PropagationFlags
            Error              = ''
        })
    }
}
Write-Progress -Activity 'Reading ACLs' -Completed
$out = @($rows)

# ---- Output ---------------------------------------------------------------------------------------------
$errCount = @($out | Where-Object { $_.Error }).Count
if ($ExportCsv) {
    $out | Export-Csv -LiteralPath $ExportCsv -NoTypeInformation -Encoding UTF8
    Write-Information ("{0} row(s) from {1} item(s) written to {2}; {3} item(s) could not be read." -f $out.Count, $items.Count, $ExportCsv, $errCount) -InformationAction Continue
}
if ($PassThru) { return $out }
if (-not $ExportCsv) {
    $out | Format-Table Path, Identity, Rights, AccessType, IsInherited, AppliesTo, Error -AutoSize -Wrap
}
