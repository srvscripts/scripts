# Intune Device Compliance Report: PowerShell Script via Graph

For an Intune device compliance report, run .\Get-IntuneComplianceReport.ps1 -NonCompliantOnly -CsvPath .\noncompliant.csv. It reads every Intune managed device from Microsoft Graph (GET /deviceManagement/managedDevices) and exports the compliance state, OS and version, last sync time, primary user, ownership and encryption state. It needs the DeviceManagementManagedDevices.Read.All permission and an Intune role that can read devices. Add -NotSyncedInDays 30 to find devices that have stopped checking in.

**Full documentation, example output and troubleshooting:** <https://srvscripts.com/scripts/intune-device-compliance-report/>

Version 1.0.0 · updated 2026-10-06 · Syntax-checked, not run yet

## Download, verify and run

```powershell
Invoke-WebRequest https://scr.srvscripts.com/intune-device-compliance-report/Get-IntuneComplianceReport.ps1 -OutFile Get-IntuneComplianceReport.ps1
(Get-FileHash .\Get-IntuneComplianceReport.ps1 -Algorithm SHA256).Hash   # compare with Get-IntuneComplianceReport.ps1.sha256
Get-Help .\Get-IntuneComplianceReport.ps1 -Full
```

Read the script before you run it, and try it on a test server first.

## Requirements

Windows PowerShell 5.1 or PowerShell 7; Microsoft.Graph.Authentication module; Graph DeviceManagementManagedDevices.Read.All; Intune role that can read managed devices (for example Read Only Operator); active Intune licence.

## How we tested it

Syntax-checked with PowerShell 7.4.6 and PSScriptAnalyzer 1.25 on 6 Oct 2026; not yet run against a live tenant/server.

## Changes and licence

What changed in each version: [CHANGELOG.md](CHANGELOG.md). Releases are tagged `intune-device-compliance-report/vX.Y.Z`.

MIT licence. If you copy, share or adapt the script, keep its header and credit [srvScripts.com](https://srvscripts.com/scripts/intune-device-compliance-report/).
