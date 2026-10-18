# Secure Boot 2023 Certificate Check: PowerShell Script for Many PCs

For a Secure Boot cert check on many computers, run .\Get-SecureBootCertStatus.ps1 -ComputerName (Get-Content .\servers.txt) -CsvPath .\secureboot.csv from an elevated PowerShell. For each computer it checks that Secure Boot is on (Confirm-SecureBootUEFI), whether the 2023 Microsoft certificates are in DB and KEK (Get-SecureBootUEFI), and reads the servicing values Windows keeps for the update, mainly UEFICA2023Status (NotStarted, InProgress or Updated) under HKLM\SYSTEM\CurrentControlSet\Control\SecureBoot\Servicing. It changes nothing.

**Full documentation, example output and troubleshooting:** <https://srvscripts.com/scripts/secure-boot-cert-check/>

Version 1.0.0 · updated 2026-10-06 · Lab-tested

## Download, verify and run

```powershell
Invoke-WebRequest https://scr.srvscripts.com/secure-boot-cert-check/Get-SecureBootCertStatus.ps1 -OutFile Get-SecureBootCertStatus.ps1
(Get-FileHash .\Get-SecureBootCertStatus.ps1 -Algorithm SHA256).Hash   # compare with Get-SecureBootCertStatus.ps1.sha256
Get-Help .\Get-SecureBootCertStatus.ps1 -Full
```

Read the script before you run it, and try it on a test server first.

## Requirements

Windows PowerShell 5.1 or PowerShell 7 on Windows, run as Administrator; UEFI firmware; Windows updates from 11 Nov 2025 or later for the Servicing registry values; WinRM and local admin rights for -ComputerName.

## How we tested it

Run on 6 Oct 2026 on a Windows Server 2025 DC (build 26100.33438, Windows PowerShell 5.1) in our lab domain with a Windows 11 Pro member; syntax-checked with PowerShell 7.4.6 and PSScriptAnalyzer 1.25.

## Changes and licence

What changed in each version: [CHANGELOG.md](CHANGELOG.md). Releases are tagged `secure-boot-cert-check/vX.Y.Z`.

MIT licence. If you copy, share or adapt the script, keep its header and credit [srvScripts.com](https://srvscripts.com/scripts/secure-boot-cert-check/).
