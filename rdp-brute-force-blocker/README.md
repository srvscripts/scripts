# Block RDP Brute Force on Windows Server: PowerShell Script

To block RDP brute force attempts, run .\Block-RdpBruteForce.ps1 -Minutes 30 -Threshold 10 -AllowList 203.0.113.10 -Apply -WhatIf as Administrator to preview, then without -WhatIf to block. The script counts failed logons (Security event 4625, logon types 3 and 10) per source IP over the last -Minutes, and puts every address at or above -Threshold into an inbound Windows Firewall block rule. Private ranges and your allow-list are never blocked. Schedule it every 15 minutes for a small fail2ban-style blocker.

**Full documentation, example output and troubleshooting:** <https://srvscripts.com/scripts/rdp-brute-force-blocker/>

Version 1.0.1 · updated 2026-10-07 · Lab-tested

## Download, verify and run

```powershell
Invoke-WebRequest https://scr.srvscripts.com/rdp-brute-force-blocker/Block-RdpBruteForce.ps1 -OutFile Block-RdpBruteForce.ps1
(Get-FileHash .\Block-RdpBruteForce.ps1 -Algorithm SHA256).Hash   # compare with Block-RdpBruteForce.ps1.sha256
Get-Help .\Block-RdpBruteForce.ps1 -Full
```

Read the script before you run it, and try it on a test server first.

## Requirements

Windows Server 2012 R2 or later (or Windows 10/11); Windows PowerShell 5.1 or PowerShell 7; run as Administrator; Audit Logon failure auditing enabled; Windows Firewall enabled.

## How we tested it

Run on 6 Oct 2026 on a Windows Server 2025 DC (build 26100.33438, Windows PowerShell 5.1) in our lab domain with a Windows 11 Pro member; syntax-checked with PowerShell 7.4.6 and PSScriptAnalyzer 1.25.

## Changes and licence

What changed in each version: [CHANGELOG.md](CHANGELOG.md). Releases are tagged `rdp-brute-force-blocker/vX.Y.Z`.

MIT licence. If you copy, share or adapt the script, keep its header and credit [srvScripts.com](https://srvscripts.com/scripts/rdp-brute-force-blocker/).
