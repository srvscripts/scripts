# Inactive AD Accounts Report: PowerShell Script with Safe Disable

To find inactive AD accounts, run .\Get-ADInactiveAccounts.ps1 -Days 90 -ExportCsv C:\Reports\inactive.csv to list enabled users and computers whose lastLogonTimestamp is older than 90 days. Add -IncludeNeverLoggedOn to catch accounts that were created more than 90 days ago and never used. When you have reviewed the list, -Disable -WhatIf shows what would be disabled and -Disable does it, always skipping critical system objects and anything you -Exclude.

**Full documentation, example output and troubleshooting:** <https://srvscripts.com/scripts/inactive-ad-accounts-report/>

Version 1.0.0 · updated 2026-10-06 · Lab-tested

## Download, verify and run

```powershell
Invoke-WebRequest https://scr.srvscripts.com/inactive-ad-accounts-report/Get-ADInactiveAccounts.ps1 -OutFile Get-ADInactiveAccounts.ps1
(Get-FileHash .\Get-ADInactiveAccounts.ps1 -Algorithm SHA256).Hash   # compare with Get-ADInactiveAccounts.ps1.sha256
Get-Help .\Get-ADInactiveAccounts.ps1 -Full
```

Read the script before you run it, and try it on a test server first.

## Requirements

Windows PowerShell 5.1 or PowerShell 7 on Windows; ActiveDirectory module (RSAT); read access to AD; disable rights for -Disable.

## Examples

```powershell
.\Get-ADInactiveAccounts.ps1 -Days 90 -ExportCsv C:\Reports\inactive.csv
.\Get-ADInactiveAccounts.ps1 -ObjectType Computers -Days 120 -IncludeNeverLoggedOn -SearchBase "OU=Workstations,DC=contoso,DC=com"
.\Get-ADInactiveAccounts.ps1 -ObjectType Users -Days 120 -Exclude "svc-*" -Disable -WhatIf
.\Get-ADInactiveAccounts.ps1 -ObjectType Users -Days 120 -Exclude "svc-*" -Disable -Confirm:$false -ExportCsv C:\Reports\disabled-2026-10.csv
```

## How we tested it

Run on 6 Oct 2026 on a Windows Server 2025 DC (build 26100.33438, Windows PowerShell 5.1) in our lab domain with a Windows 11 Pro member; syntax-checked with PowerShell 7.4.6 and PSScriptAnalyzer 1.25.

## Changes and licence

What changed in each version: [CHANGELOG.md](CHANGELOG.md). Releases are tagged `inactive-ad-accounts-report/vX.Y.Z`.

MIT licence. If you copy, share or adapt the script, keep its header and credit [srvScripts.com](https://srvscripts.com/scripts/inactive-ad-accounts-report/).
