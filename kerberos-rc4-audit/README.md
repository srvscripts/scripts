# Kerberos RC4 Audit Script: Find RC4 Accounts and Tickets

For a Kerberos RC4 audit, run .\Get-KerberosRC4Usage.ps1 to list service accounts, computers, managed service accounts and trusts whose msDS-SupportedEncryptionTypes allows RC4, allows only RC4, or is not set. Add -Events to read events 4769 (and with -IncludeTgt 4768) on every DC and count the tickets that were actually issued with RC4 (TicketEncryptionType 0x17 or 0x18), grouped by client, service and source IP. Fix the "RC4Only" accounts and the services in the usage list before you turn RC4 off.

**Full documentation, example output and troubleshooting:** <https://srvscripts.com/scripts/kerberos-rc4-audit/>

Version 1.0.0 · updated 2026-10-06 · Lab-tested

## Download, verify and run

```powershell
Invoke-WebRequest https://scr.srvscripts.com/kerberos-rc4-audit/Get-KerberosRC4Usage.ps1 -OutFile Get-KerberosRC4Usage.ps1
(Get-FileHash .\Get-KerberosRC4Usage.ps1 -Algorithm SHA256).Hash   # compare with Get-KerberosRC4Usage.ps1.sha256
Get-Help .\Get-KerberosRC4Usage.ps1 -Full
```

Read the script before you run it, and try it on a test server first.

## Requirements

Windows PowerShell 5.1 or PowerShell 7 on Windows; ActiveDirectory module (RSAT); for -Events: Kerberos auditing on DCs and read access to their Security logs (Domain Admins or Event Log Readers).

## Examples

```powershell
.\Get-KerberosRC4Usage.ps1
.\Get-KerberosRC4Usage.ps1 -Events -Hours 72 -ExportCsv C:\Reports\rc4.csv
.\Get-KerberosRC4Usage.ps1 -AllUsers -IncludeAesOnly -PassThru | Group-Object Classification
```

## How we tested it

Run on 6 Oct 2026 on a Windows Server 2025 DC (build 26100.33438, Windows PowerShell 5.1) in our lab domain with a Windows 11 Pro member; syntax-checked with PowerShell 7.4.6 and PSScriptAnalyzer 1.25.

## Changes and licence

What changed in each version: [CHANGELOG.md](CHANGELOG.md). Releases are tagged `kerberos-rc4-audit/vX.Y.Z`.

MIT licence. If you copy, share or adapt the script, keep its header and credit [srvScripts.com](https://srvscripts.com/scripts/kerberos-rc4-audit/).
