# AD Privileged Group Report: Domain Admins and adminCount Audit

For a privileged group report, run .\Get-ADPrivilegedGroupReport.ps1 -ExportCsv C:\Reports\priv.csv. It lists every account that is a direct or nested member of Domain Admins, Enterprise Admins, Schema Admins, Administrators, Account/Server/Backup/Print Operators, DnsAdmins and Group Policy Creator Owners, with the nesting path, enabled state, last logon and password age. It also finds "orphaned" accounts that still have adminCount=1 but are no longer in any of those groups.

**Full documentation, example output and troubleshooting:** <https://srvscripts.com/scripts/ad-privileged-group-report/>

Version 1.0.0 · updated 2026-10-06 · Lab-tested

## Download, verify and run

```powershell
Invoke-WebRequest https://scr.srvscripts.com/ad-privileged-group-report/Get-ADPrivilegedGroupReport.ps1 -OutFile Get-ADPrivilegedGroupReport.ps1
(Get-FileHash .\Get-ADPrivilegedGroupReport.ps1 -Algorithm SHA256).Hash   # compare with Get-ADPrivilegedGroupReport.ps1.sha256
Get-Help .\Get-ADPrivilegedGroupReport.ps1 -Full
```

Read the script before you run it, and try it on a test server first.

## Requirements

Windows PowerShell 5.1 or PowerShell 7 on Windows; ActiveDirectory module (RSAT); read access to AD in each domain that holds members.

## Examples

```powershell
.\Get-ADPrivilegedGroupReport.ps1
.\Get-ADPrivilegedGroupReport.ps1 -ExportCsv C:\Reports\priv.csv -ExportHtml C:\Reports\priv.html
.\Get-ADPrivilegedGroupReport.ps1 -AdditionalGroup "Key Admins","Enterprise Key Admins" -StaleDays 60
.\Get-ADPrivilegedGroupReport.ps1 -PassThru | Where-Object Flags -match 'Disabled'
```

## How we tested it

Run on 6 Oct 2026 on a Windows Server 2025 DC (build 26100.33438, Windows PowerShell 5.1) in our lab domain with a Windows 11 Pro member; syntax-checked with PowerShell 7.4.6 and PSScriptAnalyzer 1.25.

## Changes and licence

What changed in each version: [CHANGELOG.md](CHANGELOG.md). Releases are tagged `ad-privileged-group-report/vX.Y.Z`.

MIT licence. If you copy, share or adapt the script, keep its header and credit [srvScripts.com](https://srvscripts.com/scripts/ad-privileged-group-report/).
