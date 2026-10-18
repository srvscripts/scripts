# Microsoft 365 MFA Status Report: PowerShell Script for Graph

For an M365 MFA status report, run .\Get-M365MfaReport.ps1 -CsvPath .\mfa.csv. It signs in to Microsoft Graph, reads Microsoft's per-user registration report (/reports/authenticationMethods/userRegistrationDetails) and joins it with each user's licence and sign-in data, so you get one row per user with the registered methods, MFA capable, default method and admin flag. Tenants without Microsoft Entra ID P1/P2 fall back to reading /users/{id}/authentication/methods per user. Use -AdminsOnly -NotMfaCapableOnly to find the accounts to fix first.

**Full documentation, example output and troubleshooting:** <https://srvscripts.com/scripts/m365-mfa-status-report/>

Version 1.0.0 · updated 2026-10-06 · Syntax-checked, not run yet

## Download, verify and run

```powershell
Invoke-WebRequest https://scr.srvscripts.com/m365-mfa-status-report/Get-M365MfaReport.ps1 -OutFile Get-M365MfaReport.ps1
(Get-FileHash .\Get-M365MfaReport.ps1 -Algorithm SHA256).Hash   # compare with Get-M365MfaReport.ps1.sha256
Get-Help .\Get-M365MfaReport.ps1 -Full
```

Read the script before you run it, and try it on a test server first.

## Requirements

Windows PowerShell 5.1 or PowerShell 7; Microsoft.Graph.Authentication module; Graph User.Read.All, AuditLog.Read.All, UserAuthenticationMethod.Read.All, RoleManagement.Read.Directory; Global Reader (or Reports Reader for report mode); Entra ID P1/P2 for the registration report and sign-in data.

## How we tested it

Syntax-checked with PowerShell 7.4.6 and PSScriptAnalyzer 1.25 on 6 Oct 2026; not yet run against a live tenant/server.

## Changes and licence

What changed in each version: [CHANGELOG.md](CHANGELOG.md). Releases are tagged `m365-mfa-status-report/vX.Y.Z`.

MIT licence. If you copy, share or adapt the script, keep its header and credit [srvScripts.com](https://srvscripts.com/scripts/m365-mfa-status-report/).
