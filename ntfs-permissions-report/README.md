# NTFS Permissions Report to CSV: PowerShell Folder ACL Script

For an NTFS permissions report, run .\Get-NTFSPermissionReport.ps1 -Path D:\Shares -Depth 3 -ExportCsv C:\Reports\acl.csv. You get one CSV row per permission entry on every folder down to three levels: who (DOMAIN\name and SID), which rights, allow or deny, inherited or explicit, and what it applies to. Add -ExplicitOnly to see only the places where someone changed permissions by hand. Folders it cannot read are listed with the error instead of stopping the scan.

**Full documentation, example output and troubleshooting:** <https://srvscripts.com/scripts/ntfs-permissions-report/>

Version 1.0.0 · updated 2026-10-06 · Lab-tested

## Download, verify and run

```powershell
Invoke-WebRequest https://scr.srvscripts.com/ntfs-permissions-report/Get-NTFSPermissionReport.ps1 -OutFile Get-NTFSPermissionReport.ps1
(Get-FileHash .\Get-NTFSPermissionReport.ps1 -Algorithm SHA256).Hash   # compare with Get-NTFSPermissionReport.ps1.sha256
Get-Help .\Get-NTFSPermissionReport.ps1 -Full
```

Read the script before you run it, and try it on a test server first.

## Requirements

Windows PowerShell 5.1 or PowerShell 7 on Windows; read access to the folders and their ACLs (run as an administrator on the file server); no extra modules.

## Examples

```powershell
.\Get-NTFSPermissionReport.ps1 -Path D:\Shares -Depth 3 -ExportCsv C:\Reports\shares-acl.csv
.\Get-NTFSPermissionReport.ps1 -Path \\fs01\Finance -ExplicitOnly -Depth 10 -ExportCsv C:\Reports\finance-explicit.csv
.\Get-NTFSPermissionReport.ps1 -Path D:\Shares -Depth 5 -Identity "*Everyone*" -PassThru | Format-Table Path, Rights
```

## How we tested it

Run on 6 Oct 2026 on a Windows Server 2025 DC (build 26100.33438, Windows PowerShell 5.1) in our lab domain with a Windows 11 Pro member; syntax-checked with PowerShell 7.4.6 and PSScriptAnalyzer 1.25.

## Changes and licence

What changed in each version: [CHANGELOG.md](CHANGELOG.md). Releases are tagged `ntfs-permissions-report/vX.Y.Z`.

MIT licence. If you copy, share or adapt the script, keep its header and credit [srvScripts.com](https://srvscripts.com/scripts/ntfs-permissions-report/).
