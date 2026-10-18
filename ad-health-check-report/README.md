# AD Health Check Report: dcdiag and repadmin PowerShell Script

For an AD health check, run .\Invoke-ADHealthReport.ps1 as a Domain Admin. For every domain controller it runs dcdiag /q, checks the time source with w32tm and reads the SYSVOL DFSR state, then adds repadmin /replsummary and the FSMO role holders, and saves one colour-coded HTML report. Add -SmtpServer, -From and -To to e-mail it, or just schedule it and open the file each morning.

**Full documentation, example output and troubleshooting:** <https://srvscripts.com/scripts/ad-health-check-report/>

Version 1.0.0 · updated 2026-10-06 · Lab-tested

## Download, verify and run

```powershell
Invoke-WebRequest https://scr.srvscripts.com/ad-health-check-report/Invoke-ADHealthReport.ps1 -OutFile Invoke-ADHealthReport.ps1
(Get-FileHash .\Invoke-ADHealthReport.ps1 -Algorithm SHA256).Hash   # compare with Invoke-ADHealthReport.ps1.sha256
Get-Help .\Invoke-ADHealthReport.ps1 -Full
```

Read the script before you run it, and try it on a test server first.

## Requirements

Windows PowerShell 5.1 or PowerShell 7 on Windows; ActiveDirectory module; dcdiag.exe and repadmin.exe (RSAT AD DS tools or a DC); Domain Admin or equivalent; WinRM access to the DCs; optional SMTP relay.

## Examples

```powershell
.\Invoke-ADHealthReport.ps1
.\Invoke-ADHealthReport.ps1 -OutputPath C:\Reports\ad-health.html -SkipDcdiag
.\Invoke-ADHealthReport.ps1 -SmtpServer relay.contoso.com -From adreport@contoso.com -To admins@contoso.com
```

## How we tested it

Run on 6 Oct 2026 on a Windows Server 2025 DC (build 26100.33438, Windows PowerShell 5.1) in our lab domain with a Windows 11 Pro member; syntax-checked with PowerShell 7.4.6 and PSScriptAnalyzer 1.25.

## Changes and licence

What changed in each version: [CHANGELOG.md](CHANGELOG.md). Releases are tagged `ad-health-check-report/vX.Y.Z`.

MIT licence. If you copy, share or adapt the script, keep its header and credit [srvScripts.com](https://srvscripts.com/scripts/ad-health-check-report/).
