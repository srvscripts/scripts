# AD Change Audit Reporter: Find Who Changed Active Directory (PowerShell)

Read-only PowerShell report of Active Directory changes: who changed which user, group or computer, old and new values, and the source workstation when the logs allow it.

**Full documentation, example output and troubleshooting:** <https://srvscripts.com/scripts/ad-change-audit-reporter/>

Version 1.0.0 · updated 2026-10-07 · Lab-tested

## Download, verify and run

```powershell
Invoke-WebRequest https://scr.srvscripts.com/ad-change-audit-reporter/Get-ADChangeAudit.ps1 -OutFile Get-ADChangeAudit.ps1
(Get-FileHash .\Get-ADChangeAudit.ps1 -Algorithm SHA256).Hash   # compare with Get-ADChangeAudit.ps1.sha256
Get-Help .\Get-ADChangeAudit.ps1 -Full
```

Read the script before you run it, and try it on a test server first.

## Requirements

Windows PowerShell 5.1 or PowerShell 7; rights to read the DC Security log; AD auditing configured

## How we tested it

Run on 6 Oct 2026 on a Windows Server 2025 DC (build 26100.33438, Windows PowerShell 5.1) in our lab domain with a Windows 11 Pro member; syntax-checked with PowerShell 7.4.6 and PSScriptAnalyzer 1.25.

## Changes and licence

What changed in each version: [CHANGELOG.md](CHANGELOG.md). Releases are tagged `ad-change-audit-reporter/vX.Y.Z`.

MIT licence. If you copy, share or adapt the script, keep its header and credit [srvScripts.com](https://srvscripts.com/scripts/ad-change-audit-reporter/).
