# Locked Out AD Users Report: PowerShell Script with Lockout Source

To find locked out AD users, run .\Get-ADLockoutReport.ps1. It lists every user that is locked out right now (checked on the PDC emulator), and for each one reads event 4740 from the PDC's Security log to show the Caller Computer Name, the machine whose bad passwords caused the lockout. Use -Hours 72 to look further back, -ExportCsv for a file, and -Unlock -WhatIf then -Unlock to unlock the accounts once the source is fixed.

**Full documentation, example output and troubleshooting:** <https://srvscripts.com/scripts/ad-locked-out-users-report/>

Version 1.0.0 · updated 2026-10-06 · Lab-tested

## Download, verify and run

```powershell
Invoke-WebRequest https://scr.srvscripts.com/ad-locked-out-users-report/Get-ADLockoutReport.ps1 -OutFile Get-ADLockoutReport.ps1
(Get-FileHash .\Get-ADLockoutReport.ps1 -Algorithm SHA256).Hash   # compare with Get-ADLockoutReport.ps1.sha256
Get-Help .\Get-ADLockoutReport.ps1 -Full
```

Read the script before you run it, and try it on a test server first.

## Requirements

Windows PowerShell 5.1 or PowerShell 7 on Windows; ActiveDirectory module (RSAT); read access to the PDC emulator Security log (Domain Admins or Event Log Readers); event 4740 auditing enabled; unlock rights for -Unlock.

## Examples

```powershell
.\Get-ADLockoutReport.ps1
.\Get-ADLockoutReport.ps1 -Hours 72 -IncludeHistory -ExportCsv C:\Reports\lockouts.csv
.\Get-ADLockoutReport.ps1 -Identity bob -Unlock -WhatIf
```

## How we tested it

Run on 6 Oct 2026 on a Windows Server 2025 DC (build 26100.33438, Windows PowerShell 5.1) in our lab domain with a Windows 11 Pro member; syntax-checked with PowerShell 7.4.6 and PSScriptAnalyzer 1.25.

## Changes and licence

What changed in each version: [CHANGELOG.md](CHANGELOG.md). Releases are tagged `ad-locked-out-users-report/vX.Y.Z`.

MIT licence. If you copy, share or adapt the script, keep its header and credit [srvScripts.com](https://srvscripts.com/scripts/ad-locked-out-users-report/).
