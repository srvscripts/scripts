# Export AD Users to CSV: PowerShell Script with Last Logon (v1.0.0) - from srvScripts.com
# Source, docs and updates: https://srvscripts.com/scripts/export-ad-users-csv/
# Copyright (c) 2026 srvScripts.com. MIT licence: if you copy, share or adapt this script, keep this notice and credit srvScripts.com.
<#
.SYNOPSIS
    Export Active Directory users with the attributes admins actually ask for, to CSV and/or HTML.

.DESCRIPTION
    Read-only. Queries user objects with Get-ADUser and writes one row per user:
    Name, DisplayName, SamAccountName, UserPrincipalName, Enabled, LastLogonDate (from lastLogonTimestamp),
    PasswordLastSet (from pwdLastSet), PasswordNeverExpires (userAccountControl flag 0x10000), Manager,
    Department, Title, Mail, Created (whenCreated), OU (parent container) and DistinguishedName.
    Any extra LDAP attributes passed with -Properties are added as columns after those.

    lastLogonTimestamp is replicated, but by design it can be 9-14 days behind the real last logon.
    Use it to spot stale accounts, not to prove when someone last signed in.

.PARAMETER SearchBase
    Distinguished name of the OU or container to search, e.g. "OU=Staff,DC=contoso,DC=com". Default: whole domain.

.PARAMETER SearchScope
    Base, OneLevel or Subtree (default Subtree).

.PARAMETER Enabled
    Only enabled accounts.

.PARAMETER Disabled
    Only disabled accounts.

.PARAMETER Properties
    Extra LDAP attribute names to add as columns, e.g. employeeID, physicalDeliveryOfficeName, extensionAttribute1.
    Multi-valued attributes are joined with "; ".

.PARAMETER Server
    Domain controller or domain to query (default: a DC of the current domain).

.PARAMETER Credential
    Alternate credentials for the AD query.

.PARAMETER ExportCsv
    Write the report to this CSV file (UTF-8).

.PARAMETER ExportHtml
    Write the report to this HTML file.

.PARAMETER PassThru
    Output the row objects to the pipeline.

.EXAMPLE
    .\Export-ADUserReport.ps1 -ExportCsv C:\Reports\ad-users.csv

.EXAMPLE
    .\Export-ADUserReport.ps1 -SearchBase "OU=Sales,DC=contoso,DC=com" -Enabled -ExportHtml C:\Reports\sales.html

.EXAMPLE
    .\Export-ADUserReport.ps1 -Disabled -Properties employeeID,description -ExportCsv C:\Reports\disabled.csv

.EXAMPLE
    .\Export-ADUserReport.ps1 -Enabled -PassThru | Where-Object { -not $_.Manager } | Format-Table Name,Department

.NOTES
    Name:     Export-ADUserReport.ps1
    Version:  1.0.0
    Source:   https://srvscripts.com/scripts/export-ad-users-csv/
    License:  MIT
    Requires: Windows PowerShell 5.1 or PowerShell 7 on Windows, ActiveDirectory module (RSAT), read access to AD.
#>
[CmdletBinding(DefaultParameterSetName = 'All')]
param(
    [ValidateNotNullOrEmpty()]
    [string]$SearchBase,

    [ValidateSet('Base', 'OneLevel', 'Subtree')]
    [string]$SearchScope = 'Subtree',

    [Parameter(ParameterSetName = 'Enabled')]
    [switch]$Enabled,

    [Parameter(ParameterSetName = 'Disabled')]
    [switch]$Disabled,

    [ValidatePattern('^[A-Za-z][A-Za-z0-9-]*$')]
    [string[]]$Properties,

    [ValidateNotNullOrEmpty()]
    [string]$Server,

    [System.Management.Automation.PSCredential]
    [System.Management.Automation.Credential()]
    $Credential = [System.Management.Automation.PSCredential]::Empty,

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

if (-not $ExportCsv -and -not $ExportHtml -and -not $PassThru) {
    Write-Verbose 'No -ExportCsv, -ExportHtml or -PassThru given: results are shown on screen only.'
}

# ---- Helpers --------------------------------------------------------------------------------------------
function ConvertFrom-FileTimeValue {
    param($Value)
    if ($null -eq $Value) { return $null }
    $v = [int64]$Value
    if ($v -le 0 -or $v -eq [int64]::MaxValue) { return $null }
    [DateTime]::FromFileTime($v)
}

function Get-RdnValue {
    param([string]$DistinguishedName)
    if (-not $DistinguishedName) { return '' }
    if ($DistinguishedName -match '^(?:CN|OU)=((?:\\,|[^,])+)') { return ($Matches[1] -replace '\\,', ',') }
    $DistinguishedName
}

function Get-ParentPath {
    param([string]$DistinguishedName)
    # Strip the first RDN, honouring escaped commas.
    if ($DistinguishedName -match '^(?:\\,|[^,])+,(.+)$') { return $Matches[1] }
    ''
}

function Get-AttributeValue {
    param($Entity, [string]$Name)
    if ($Entity.PropertyNames -contains $Name) { return $Entity[$Name].Value }
    $null
}

function Format-AttributeValue {
    param($Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [System.Collections.ICollection] -and $Value -isnot [string] -and $Value -isnot [byte[]]) {
        return (@($Value) | ForEach-Object { [string]$_ }) -join '; '
    }
    if ($Value -is [byte[]]) { return [Convert]::ToBase64String($Value) }
    [string]$Value
}

# ---- Query ----------------------------------------------------------------------------------------------
$baseAttrs = 'displayName', 'mail', 'manager', 'department', 'title', 'whenCreated', 'lastLogonTimestamp', 'pwdLastSet', 'userAccountControl'
$extra = @()
if ($Properties) { $extra = @($Properties | Where-Object { $baseAttrs -notcontains $_ } | Select-Object -Unique) }

$ldap = '(&(objectCategory=person)(objectClass=user)'
if ($Enabled)  { $ldap += '(!(userAccountControl:1.2.840.113556.1.4.803:=2))' }
if ($Disabled) { $ldap += '(userAccountControl:1.2.840.113556.1.4.803:=2)' }
$ldap += ')'

$query = @{
    LDAPFilter     = $ldap
    Properties     = @($baseAttrs + $extra)
    SearchScope    = $SearchScope
    ResultPageSize = 500
}
if ($SearchBase) { $query.SearchBase = $SearchBase }
if ($Server)     { $query.Server = $Server }
if ($Credential -ne [System.Management.Automation.PSCredential]::Empty) { $query.Credential = $Credential }

Write-Verbose "LDAP filter: $ldap"
try {
    $users = @(Get-ADUser @query)
} catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {
    throw "SearchBase not found: '$SearchBase'. Check the distinguished name (Get-ADOrganizationalUnit -Filter * | Select DistinguishedName)."
} catch {
    if ($_.Exception.Message -match 'attribute|property') {
        throw "AD rejected the query. Check the names given to -Properties (LDAP display names such as employeeID). Details: $($_.Exception.Message)"
    }
    throw
}

# ---- Build rows -----------------------------------------------------------------------------------------
$rows = foreach ($u in $users) {
    $uac = 0
    $uacValue = Get-AttributeValue $u 'userAccountControl'
    if ($null -ne $uacValue) { $uac = [int]$uacValue }
    $row = [ordered]@{
        Name                 = $u.Name
        DisplayName          = Format-AttributeValue (Get-AttributeValue $u 'displayName')
        SamAccountName       = $u.SamAccountName
        UserPrincipalName    = $u.UserPrincipalName
        Enabled              = $u.Enabled
        LastLogonDate        = ConvertFrom-FileTimeValue (Get-AttributeValue $u 'lastLogonTimestamp')
        PasswordLastSet      = ConvertFrom-FileTimeValue (Get-AttributeValue $u 'pwdLastSet')
        PasswordNeverExpires = [bool]($uac -band 0x10000)
        Manager              = Get-RdnValue (Format-AttributeValue (Get-AttributeValue $u 'manager'))
        Department           = Format-AttributeValue (Get-AttributeValue $u 'department')
        Title                = Format-AttributeValue (Get-AttributeValue $u 'title')
        Mail                 = Format-AttributeValue (Get-AttributeValue $u 'mail')
        Created              = (Get-AttributeValue $u 'whenCreated')
        OU                   = Get-ParentPath $u.DistinguishedName
        DistinguishedName    = $u.DistinguishedName
    }
    foreach ($a in $extra) {
        $row[$a] = Format-AttributeValue (Get-AttributeValue $u $a)
    }
    New-Object -TypeName psobject -Property $row
}
$rows = @($rows | Sort-Object Name)

# ---- Output ---------------------------------------------------------------------------------------------
if ($ExportCsv) {
    $rows | Export-Csv -LiteralPath $ExportCsv -NoTypeInformation -Encoding UTF8
    Write-Information ("{0} user(s) written to {1}" -f $rows.Count, $ExportCsv) -InformationAction Continue
}
if ($ExportHtml) {
    $css = 'body{font-family:Segoe UI,Arial,sans-serif;font-size:13px;margin:20px}table{border-collapse:collapse}' +
           'th,td{border:1px solid #ccc;padding:4px 8px;text-align:left}th{background:#f0f0f0}tr:nth-child(even){background:#fafafa}'
    $title = 'AD user report'
    $pre = "<h1>$title</h1><p>Generated {0:yyyy-MM-dd HH:mm} on {1}. {2} user(s).</p>" -f (Get-Date), $env:COMPUTERNAME, $rows.Count
    $rows | ConvertTo-Html -Title $title -Head "<style>$css</style>" -PreContent $pre | Out-File -LiteralPath $ExportHtml -Encoding utf8
    Write-Information ("HTML report written to {0}" -f $ExportHtml) -InformationAction Continue
}
if ($PassThru) { return $rows }
if (-not $ExportCsv -and -not $ExportHtml) {
    if (-not $rows.Count) { Write-Information 'No users matched.' -InformationAction Continue; return }
    $rows | Format-Table Name, SamAccountName, Enabled, LastLogonDate, PasswordLastSet, Department, Title -AutoSize
}
