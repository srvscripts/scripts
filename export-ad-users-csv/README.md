# Export AD Users to CSV: PowerShell Script with Last Logon

To export AD users to CSV, run .\Export-ADUserReport.ps1 -ExportCsv C:\Reports\ad-users.csv on a machine with the ActiveDirectory module. You get one row per user with name, UPN, sAMAccountName, enabled state, last logon date, password last set, PasswordNeverExpires, manager, department, title, mail, created date and OU. Add -Enabled or -Disabled to filter, -SearchBase to limit it to one OU, -Properties for extra attributes and -ExportHtml for a page you can mail to a manager.

**Full documentation, example output and troubleshooting:** <https://srvscripts.com/scripts/export-ad-users-csv/>

Version 1.0.0 · updated 2026-10-06 · Lab-tested

## Download, verify and run

```powershell
Invoke-WebRequest https://scr.srvscripts.com/export-ad-users-csv/Export-ADUserReport.ps1 -OutFile Export-ADUserReport.ps1
(Get-FileHash .\Export-ADUserReport.ps1 -Algorithm SHA256).Hash   # compare with Export-ADUserReport.ps1.sha256
Get-Help .\Export-ADUserReport.ps1 -Full
```

Read the script before you run it, and try it on a test server first.

## Requirements

Windows PowerShell 5.1 or PowerShell 7 on Windows; ActiveDirectory module (RSAT); read access to AD.

## Examples

```powershell
.\Export-ADUserReport.ps1 -ExportCsv C:\Reports\ad-users.csv
.\Export-ADUserReport.ps1 -SearchBase "OU=Sales,DC=contoso,DC=com" -Enabled -ExportHtml C:\Reports\sales.html
.\Export-ADUserReport.ps1 -Disabled -Properties employeeID,description -ExportCsv C:\Reports\disabled.csv
.\Export-ADUserReport.ps1 -Enabled -PassThru | Where-Object { -not $_.Manager } | Format-Table Name,Department
```

## How we tested it

Run on 6 Oct 2026 on a Windows Server 2025 DC (build 26100.33438, Windows PowerShell 5.1) in our lab domain with a Windows 11 Pro member; syntax-checked with PowerShell 7.4.6 and PSScriptAnalyzer 1.25.

## Changes and licence

What changed in each version: [CHANGELOG.md](CHANGELOG.md). Releases are tagged `export-ad-users-csv/vX.Y.Z`.

MIT licence. If you copy, share or adapt the script, keep its header and credit [srvScripts.com](https://srvscripts.com/scripts/export-ad-users-csv/).
