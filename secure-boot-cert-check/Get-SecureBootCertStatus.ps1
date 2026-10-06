# Secure Boot 2023 Certificate Check: PowerShell Script for Many PCs (v1.0.0) - from srvScripts.com
# Source, docs and updates: https://srvscripts.com/scripts/secure-boot-cert-check/
# Copyright (c) 2026 srvScripts.com. MIT licence: if you copy, share or adapt this script, keep this notice and credit srvScripts.com.
<#
.SYNOPSIS
    Secure Boot 2023 certificate status for one or many Windows computers: Secure Boot state, whether the
    2023 Microsoft certificates are in DB and KEK, the servicing registry values Windows keeps for the
    certificate update, and the latest 1801/1808 event. Read-only. CSV output.

.DESCRIPTION
    Microsoft's 2011 Secure Boot certificates expire during 2026 and are being replaced by 2023
    certificates. For each computer this script collects:

      Secure Boot   Confirm-SecureBootUEFI (falls back to HKLM\...\SecureBoot\State\UEFISecureBootEnabled).
      DB / KEK      Get-SecureBootUEFI db / kek, decoded as ASCII and searched for the certificate names, the
                    method Microsoft uses in its boot manager guidance:
                      DB:  Windows UEFI CA 2023, Microsoft UEFI CA 2023, Microsoft Option ROM UEFI CA 2023
                      KEK: Microsoft Corporation KEK 2K CA 2023
      Registry      HKLM\SYSTEM\CurrentControlSet\Control\SecureBoot:
                      AvailableUpdates, HighConfidenceOptOut, MicrosoftUpdateManagedOptIn
                    HKLM\SYSTEM\CurrentControlSet\Control\SecureBoot\Servicing:
                      UEFICA2023Status (NotStarted / InProgress / Updated), UEFICA2023Error,
                      UEFICA2023ErrorEvent, WindowsUEFICA2023Capable (reference only), ConfidenceLevel
                    ...\Servicing\DeviceAttributes: OEM manufacturer, model, firmware version and date.
                    These values exist on systems with Windows updates from 11 November 2025 or later.
      Events        Newest System log event 1801 (certificates not yet applied) or 1808 (device has the new
                    certificates), with the BucketConfidenceLevel text if the event carries it.

    The Assessment column is a summary: "Updated" when UEFICA2023Status is Updated, "Secure Boot off" when
    Secure Boot is disabled or not supported, otherwise "Action needed" (with what is missing).

    The script changes nothing. To start the update itself, follow Microsoft's guidance for IT-managed
    devices (AvailableUpdates = 0x5944 processed by Windows' scheduled Secure Boot update task, Group Policy,
    Intune or WinCS).

    Requirements: run elevated (Get-SecureBootUEFI needs administrator rights). For -ComputerName, PowerShell
    remoting (WinRM) must be enabled on the targets and your account must be an administrator there.

.PARAMETER ComputerName   Computers to check through Invoke-Command. Default: this computer only.
.PARAMETER Credential     Credential for the remote computers.
.PARAMETER ThrottleLimit  Maximum parallel remote connections (default 32).
.PARAMETER CsvPath        Write the result to this CSV file.
.PARAMETER PassThru       Output the objects to the pipeline.

.EXAMPLE  .\Get-SecureBootCertStatus.ps1
.EXAMPLE  .\Get-SecureBootCertStatus.ps1 -ComputerName (Get-Content .\servers.txt) -CsvPath .\secureboot.csv
.EXAMPLE  .\Get-SecureBootCertStatus.ps1 -ComputerName (Get-ADComputer -Filter 'OperatingSystem -like "*Server*"').DNSHostName -CsvPath C:\Reports\secureboot.csv
.EXAMPLE  .\Get-SecureBootCertStatus.ps1 -ComputerName HV01,HV02 -PassThru | Where-Object Assessment -ne 'Updated'

.NOTES
    Name:     Get-SecureBootCertStatus.ps1
    Purpose:  Read-only audit of the Secure Boot 2023 certificate update
    Source:   https://srvscripts.com/scripts/secure-boot-cert-check/
    License:  MIT
    Version:  1.0.0
    Requires: Windows PowerShell 5.1 or PowerShell 7 on Windows, Administrator; WinRM for remote computers.
#>
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string[]]$ComputerName,
    [System.Management.Automation.PSCredential]
    [System.Management.Automation.Credential()]
    $Credential = [System.Management.Automation.PSCredential]::Empty,
    [ValidateRange(1, 256)]
    [int]$ThrottleLimit = 32,
    [string]$CsvPath,
    [switch]$PassThru
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

function Write-Status([string]$Message) { Write-Information $Message -InformationAction Continue }

# Runs on each computer. Self-contained: no functions or variables from the outer script are used.
$probe = {
    $ErrorActionPreference = 'Stop'
    $sbKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot'
    $notes = [System.Collections.Generic.List[string]]::new()

    function Get-RegValue([string]$Path, [string]$Name) {
        try {
            $item = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop
            return $item.$Name
        } catch { return $null }
    }

    function Test-UefiVar([string]$Name, [string]$Pattern) {
        try {
            $var = Get-SecureBootUEFI -Name $Name -ErrorAction Stop
            return ([System.Text.Encoding]::ASCII.GetString($var.Bytes) -match [regex]::Escape($Pattern))
        } catch { return $null }
    }

    $secureBoot = $null
    try { $secureBoot = [bool](Confirm-SecureBootUEFI -ErrorAction Stop) }
    catch {
        $v = Get-RegValue "$sbKey\State" 'UEFISecureBootEnabled'
        if ($null -ne $v) { $secureBoot = ([int]$v -eq 1) }
        $notes.Add('Confirm-SecureBootUEFI failed (legacy BIOS, not elevated, or not supported)')
    }

    $dbWin = $null; $dbUefi = $null; $dbOprom = $null; $kek = $null
    if ($secureBoot) {
        $dbWin = Test-UefiVar 'db' 'Windows UEFI CA 2023'
        $dbUefi = Test-UefiVar 'db' 'Microsoft UEFI CA 2023'
        $dbOprom = Test-UefiVar 'db' 'Microsoft Option ROM UEFI CA 2023'
        $kek = Test-UefiVar 'KEK' 'Microsoft Corporation KEK 2K CA 2023'
        if ($null -eq $dbWin) { $notes.Add('Get-SecureBootUEFI could not read db/KEK (run elevated)') }
    }

    $avail = Get-RegValue $sbKey 'AvailableUpdates'
    $status = Get-RegValue "$sbKey\Servicing" 'UEFICA2023Status'
    $err = Get-RegValue "$sbKey\Servicing" 'UEFICA2023Error'
    $errEvent = Get-RegValue "$sbKey\Servicing" 'UEFICA2023ErrorEvent'
    $capable = Get-RegValue "$sbKey\Servicing" 'WindowsUEFICA2023Capable'
    $confidence = Get-RegValue "$sbKey\Servicing" 'ConfidenceLevel'
    $attr = "$sbKey\Servicing\DeviceAttributes"
    if ($null -eq $status) { $notes.Add('No UEFICA2023Status value (needs Windows updates from 11 Nov 2025 or later)') }

    $lastEventId = $null; $lastEventTime = $null; $bucketConfidence = $null
    try {
        $ev = Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 1801, 1808 } -MaxEvents 1 -ErrorAction Stop
        if ($ev) {
            $lastEventId = $ev.Id; $lastEventTime = $ev.TimeCreated
            if ($ev.Message -match 'BucketConfidenceLevel:\s*(.+)') { $bucketConfidence = $Matches[1].Trim() }
        }
    } catch {
        if ($_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound*') { $notes.Add("Event log: $($_.Exception.Message)") }
    }

    $os = $null
    try { $os = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).Caption } catch { $os = $null }

    $missing = @()
    if ($dbWin -eq $false) { $missing += 'DB: Windows UEFI CA 2023' }
    if ($kek -eq $false) { $missing += 'KEK: KEK 2K CA 2023' }
    if ($status -and $status -ne 'Updated') { $missing += "Status: $status" }
    $assessment = if ($secureBoot -eq $false) { 'Secure Boot off' }
    elseif ($null -eq $secureBoot) { 'Unknown (Secure Boot state not readable)' }
    elseif ($status -eq 'Updated') { 'Updated' }
    elseif ($missing.Count) { 'Action needed: ' + ($missing -join '; ') }
    else { 'Action needed: status unknown' }

    [pscustomobject]@{
        ComputerName              = $env:COMPUTERNAME
        OS                        = $os
        SecureBootEnabled         = $secureBoot
        Assessment                = $assessment
        DB_WindowsUEFICA2023      = $dbWin
        DB_MicrosoftUEFICA2023    = $dbUefi
        DB_OptionROMUEFICA2023    = $dbOprom
        KEK_2023                  = $kek
        UEFICA2023Status          = $status
        UEFICA2023Error           = $err
        UEFICA2023ErrorEvent      = $errEvent
        WindowsUEFICA2023Capable  = $capable
        AvailableUpdates          = $(if ($null -ne $avail) { '0x{0:X}' -f [int64]$avail } else { $null })
        HighConfidenceOptOut      = Get-RegValue $sbKey 'HighConfidenceOptOut'
        MicrosoftUpdateManagedOptIn = Get-RegValue $sbKey 'MicrosoftUpdateManagedOptIn'
        ConfidenceLevel           = $confidence
        LastEventId               = $lastEventId
        LastEventTime             = $lastEventTime
        EventBucketConfidence     = $bucketConfidence
        Manufacturer              = Get-RegValue $attr 'OEMManufacturerName'
        Model                     = Get-RegValue $attr 'OEMModelNumber'
        FirmwareVersion           = Get-RegValue $attr 'FirmwareVersion'
        FirmwareReleaseDate       = Get-RegValue $attr 'FirmwareReleaseDate'
        Notes                     = ($notes -join '; ')
    }
}

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT -and -not $ComputerName) {
    throw 'Run this script on Windows, or use -ComputerName to query Windows computers remotely.'
}

$rows = [System.Collections.Generic.List[object]]::new()
if (-not $ComputerName) {
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Warning 'Not elevated: Get-SecureBootUEFI and Confirm-SecureBootUEFI need administrator rights, so DB/KEK columns will be empty.'
    }
    $rows.Add((& $probe))
} else {
    $targets = @($ComputerName | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Sort-Object -Unique)
    Write-Status ("Querying {0} computer(s)..." -f $targets.Count)
    $ic = @{ ComputerName = $targets; ScriptBlock = $probe; ThrottleLimit = $ThrottleLimit; ErrorAction = 'SilentlyContinue'; ErrorVariable = 'remoteErrors' }
    if ($Credential -ne [System.Management.Automation.PSCredential]::Empty) { $ic.Credential = $Credential }
    $remoteErrors = $null
    $results = @(Invoke-Command @ic)
    foreach ($r in $results) {
        $rows.Add(($r | Select-Object -Property * -ExcludeProperty PSComputerName, RunspaceId, PSShowComputerName))
    }
    $answered = @($results | ForEach-Object { [string]$_.PSComputerName })
    foreach ($t in $targets) {
        if ($answered -notcontains $t) {
            $msg = @($remoteErrors | Where-Object { $_.TargetObject -eq $t -or "$($_.Exception.Message)" -like "*$t*" } | Select-Object -First 1)
            $rows.Add([pscustomobject]@{
                ComputerName = $t; OS = $null; SecureBootEnabled = $null
                Assessment = 'Unreachable'
                Notes = $(if ($msg) { $msg[0].Exception.Message } else { 'No result (WinRM, DNS or permissions)' })
            })
        }
    }
}

$out = @($rows | Sort-Object Assessment, ComputerName)
if ($CsvPath) {
    # Select explicit columns so rows for unreachable computers line up with the others.
    $cols = 'ComputerName', 'OS', 'SecureBootEnabled', 'Assessment', 'DB_WindowsUEFICA2023', 'DB_MicrosoftUEFICA2023', 'DB_OptionROMUEFICA2023',
    'KEK_2023', 'UEFICA2023Status', 'UEFICA2023Error', 'UEFICA2023ErrorEvent', 'WindowsUEFICA2023Capable', 'AvailableUpdates',
    'HighConfidenceOptOut', 'MicrosoftUpdateManagedOptIn', 'ConfidenceLevel', 'LastEventId', 'LastEventTime', 'EventBucketConfidence',
    'Manufacturer', 'Model', 'FirmwareVersion', 'FirmwareReleaseDate', 'Notes'
    $out | Select-Object -Property $cols | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8
    Write-Status ("CSV written: {0} ({1} rows)" -f $CsvPath, $out.Count)
}
$summary = $out | Group-Object { ($_.Assessment -split ':')[0] } | ForEach-Object { "{0} {1}" -f $_.Count, $_.Name }
Write-Status ("Computers: {0}. {1}" -f $out.Count, ($summary -join ', '))

if ($PassThru) { return $out }
if (-not $CsvPath) {
    $out | Select-Object ComputerName, SecureBootEnabled, Assessment, UEFICA2023Status, LastEventId | Format-Table -AutoSize -Wrap
}
