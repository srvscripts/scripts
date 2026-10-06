# Intune Device Compliance Report: PowerShell Script via Graph (v1.0.0) - from srvScripts.com
# Source, docs and updates: https://srvscripts.com/scripts/intune-device-compliance-report/
# Copyright (c) 2026 srvScripts.com. MIT licence: if you copy, share or adapt this script, keep this notice and credit srvScripts.com.
<#
.SYNOPSIS
    Intune device compliance report from Microsoft Graph: compliance state, OS and version, last sync,
    primary user, ownership, encryption and hardware details for every managed device. CSV/HTML output.

.DESCRIPTION
    Read-only. Calls GET /deviceManagement/managedDevices (Microsoft Graph v1.0) through the
    Microsoft.Graph.Authentication module and follows @odata.nextLink until every device is read.
    Filters are applied locally so the script does not depend on which $filter operators the
    managedDevices endpoint accepts for each property.

    complianceState values (Microsoft Graph): unknown, compliant, noncompliant, conflict, error,
    inGracePeriod, configManager.

    Permissions:
      Delegated scope   DeviceManagementManagedDevices.Read.All
      Application       DeviceManagementManagedDevices.Read.All (admin consent)
      The signed-in admin also needs an Intune role that can read managed devices, for example the
      built-in Read Only Operator role, or the Intune Administrator Entra role.

.PARAMETER ComplianceState    Only these states (e.g. noncompliant,inGracePeriod,error,conflict).
.PARAMETER NonCompliantOnly   Shortcut: everything that is not compliant.
.PARAMETER OperatingSystem    Only these OS names (Windows, iOS, Android, macOS ...). Wildcards allowed.
.PARAMETER NotSyncedInDays    Only devices whose last successful sync is older than this many days.
.PARAMETER UserPrincipalName  Only devices whose primary user UPN matches (wildcards allowed).
.PARAMETER CsvPath            Write the result to this CSV file.
.PARAMETER HtmlPath           Write the result to this HTML file.
.PARAMETER PassThru           Output objects to the pipeline.
.PARAMETER TenantId           Tenant ID or domain (required for app-only sign-in).
.PARAMETER ClientId           App registration (client) ID for app-only sign-in.
.PARAMETER CertificateThumbprint  Certificate thumbprint for app-only sign-in.

.EXAMPLE  .\Get-IntuneComplianceReport.ps1 -CsvPath .\intune-devices.csv
.EXAMPLE  .\Get-IntuneComplianceReport.ps1 -NonCompliantOnly -OperatingSystem Windows -HtmlPath .\noncompliant-windows.html
.EXAMPLE  .\Get-IntuneComplianceReport.ps1 -NotSyncedInDays 30 -CsvPath .\stale-devices.csv
.EXAMPLE  .\Get-IntuneComplianceReport.ps1 -TenantId contoso.onmicrosoft.com -ClientId <app-id> -CertificateThumbprint <thumbprint> -CsvPath C:\Reports\intune.csv

.NOTES
    Name:     Get-IntuneComplianceReport.ps1
    Purpose:  Intune managed device compliance and health export
    Source:   https://srvscripts.com/scripts/intune-device-compliance-report/
    License:  MIT
    Version:  1.0.0
    Requires: Windows PowerShell 5.1 or PowerShell 7, module Microsoft.Graph.Authentication.
#>
[CmdletBinding(DefaultParameterSetName = 'Interactive')]
param(
    [ValidateSet('unknown', 'compliant', 'noncompliant', 'conflict', 'error', 'inGracePeriod', 'configManager')]
    [string[]]$ComplianceState,
    [switch]$NonCompliantOnly,
    [string[]]$OperatingSystem,
    [ValidateRange(1, 3650)]
    [int]$NotSyncedInDays,
    [string]$UserPrincipalName,
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

function Invoke-GraphWithRetry([string]$Uri) {
    $attempt = 0
    while ($true) {
        $attempt++
        try { return Invoke-MgGraphRequest -Method GET -Uri $Uri -OutputType HashTable -ErrorAction Stop }
        catch {
            if ($attempt -lt 5 -and $_.Exception.Message -match '429|TooManyRequests|503|ServiceUnavailable|504|GatewayTimeout') {
                Start-Sleep -Seconds ([math]::Pow(2, $attempt) * 5); continue
            }
            throw
        }
    }
}

function Get-GraphCollection([string]$Uri) {
    $next = $Uri
    while ($next) {
        $r = Invoke-GraphWithRetry $next
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
    if ($Value -is [datetime]) { $d = $Value.ToUniversalTime() }
    elseif ($Value -is [datetimeoffset]) { $d = $Value.UtcDateTime }
    else { $d = ([datetimeoffset]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture)).UtcDateTime }
    if ($d.Year -le 1) { return $null }   # 0001-01-01 means "never"
    return $d
}

# ---- Connect --------------------------------------------------------------------------------------------
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
    throw 'Module Microsoft.Graph.Authentication is not installed. Run: Install-Module Microsoft.Graph.Authentication -Scope CurrentUser'
}
Import-Module Microsoft.Graph.Authentication
if ($PSCmdlet.ParameterSetName -eq 'AppOnly') {
    Connect-MgGraph -TenantId $TenantId -ClientId $ClientId -CertificateThumbprint $CertificateThumbprint -NoWelcome
} else {
    $cp = @{ Scopes = @('DeviceManagementManagedDevices.Read.All'); NoWelcome = $true }
    if ($TenantId) { $cp.TenantId = $TenantId }
    Connect-MgGraph @cp
}
$ctx = Get-MgContext
if (-not $ctx) { throw 'Not connected to Microsoft Graph.' }

# ---- Read devices ---------------------------------------------------------------------------------------
Write-Status 'Reading Intune managed devices...'
try {
    $devices = @(Get-GraphCollection "$Graph/deviceManagement/managedDevices")
} catch {
    if ($_.Exception.Message -match 'Forbidden|403|Unauthorized|401') {
        throw "Graph refused managedDevices: $($_.Exception.Message). Check DeviceManagementManagedDevices.Read.All consent and that your account has an Intune role (for example Read Only Operator)."
    }
    throw
}
Write-Status ("{0} managed device(s) read." -f $devices.Count)

$now = (Get-Date).ToUniversalTime()
$rows = [System.Collections.Generic.List[object]]::new()
foreach ($d in $devices) {
    $sync = ConvertTo-UtcDate (Get-Value $d 'lastSyncDateTime')
    $rows.Add([pscustomobject][ordered]@{
        DeviceName                      = Get-Value $d 'deviceName'
        UserPrincipalName               = Get-Value $d 'userPrincipalName'
        UserDisplayName                 = Get-Value $d 'userDisplayName'
        OperatingSystem                 = Get-Value $d 'operatingSystem'
        OSVersion                       = Get-Value $d 'osVersion'
        ComplianceState                 = [string](Get-Value $d 'complianceState')
        ComplianceGracePeriodExpiration = ConvertTo-UtcDate (Get-Value $d 'complianceGracePeriodExpirationDateTime')
        LastSyncUtc                     = $sync
        DaysSinceSync                   = if ($sync) { [int][math]::Floor(($now - $sync).TotalDays) } else { $null }
        IsEncrypted                     = Get-Value $d 'isEncrypted'
        OwnerType                       = Get-Value $d 'managedDeviceOwnerType'
        ManagementAgent                 = Get-Value $d 'managementAgent'
        EnrollmentType                  = Get-Value $d 'deviceEnrollmentType'
        EnrolledUtc                     = ConvertTo-UtcDate (Get-Value $d 'enrolledDateTime')
        Manufacturer                    = Get-Value $d 'manufacturer'
        Model                           = Get-Value $d 'model'
        SerialNumber                    = Get-Value $d 'serialNumber'
        JailBroken                      = Get-Value $d 'jailBroken'
        AzureADDeviceId                 = Get-Value $d 'azureADDeviceId'
        IntuneDeviceId                  = Get-Value $d 'id'
    })
}

# ---- Filters --------------------------------------------------------------------------------------------
$out = @($rows)
if ($NonCompliantOnly) { $out = @($out | Where-Object { $_.ComplianceState -ne 'compliant' }) }
if ($ComplianceState) { $out = @($out | Where-Object { $ComplianceState -contains $_.ComplianceState }) }
if ($OperatingSystem) {
    $out = @($out | Where-Object { $os = $_.OperatingSystem; @($OperatingSystem | Where-Object { $os -like $_ }).Count -gt 0 })
}
if ($PSBoundParameters.ContainsKey('NotSyncedInDays')) {
    $out = @($out | Where-Object { $null -eq $_.DaysSinceSync -or $_.DaysSinceSync -ge $NotSyncedInDays })
}
if ($UserPrincipalName) {
    $u = if ($UserPrincipalName -match '[*?]') { $UserPrincipalName } else { "*$UserPrincipalName*" }
    $out = @($out | Where-Object { $_.UserPrincipalName -like $u })
}
$out = @($out | Sort-Object ComplianceState, OperatingSystem, DeviceName)

# ---- Output ---------------------------------------------------------------------------------------------
if ($CsvPath) {
    $out | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8
    Write-Status ("CSV written: {0} ({1} rows)" -f $CsvPath, $out.Count)
}
if ($HtmlPath) {
    $css = '<style>body{font-family:Segoe UI,Arial,sans-serif;font-size:13px}table{border-collapse:collapse}th,td{border:1px solid #ccc;padding:4px 6px;text-align:left}th{background:#eee}</style>'
    $pre = "<h2>Intune device compliance</h2><p>Tenant $($ctx.TenantId). Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm'). Devices: $($out.Count).</p>"
    $out | Select-Object DeviceName, UserPrincipalName, OperatingSystem, OSVersion, ComplianceState, LastSyncUtc, DaysSinceSync, IsEncrypted, OwnerType, Model, SerialNumber |
        ConvertTo-Html -Head $css -PreContent $pre | Out-File -FilePath $HtmlPath -Encoding UTF8
    Write-Status "HTML written: $HtmlPath"
}
$summary = $out | Group-Object ComplianceState | Sort-Object Count -Descending | ForEach-Object { "{0} {1}" -f $_.Count, $_.Name }
Write-Status ("Devices reported: {0}. By state: {1}. Not encrypted: {2}." -f $out.Count, $(if ($summary) { $summary -join ', ' } else { 'none' }), @($out | Where-Object { $_.IsEncrypted -eq $false }).Count)

if ($PassThru) { return $out }
if (-not $CsvPath -and -not $HtmlPath) {
    $out | Select-Object DeviceName, UserPrincipalName, OperatingSystem, ComplianceState, LastSyncUtc, IsEncrypted | Format-Table -AutoSize
}
