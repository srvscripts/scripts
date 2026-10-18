# Entra ID Inactive Users Report: signInActivity PowerShell Script

To find Entra ID inactive users, run .\Get-EntraInactiveUsers.ps1 -Days 90 -CsvPath .\inactive.csv. It reads every user's signInActivity from Microsoft Graph and lists accounts whose last successful sign-in (lastSuccessfulSignInDateTime) is older than -Days, plus accounts that never signed in. Add -LicensedOnly to find paid licences you can reclaim, or -UserType Guest for stale guests. signInActivity needs a Microsoft Entra ID P1 or P2 licence in the tenant and the AuditLog.Read.All permission.

**Full documentation, example output and troubleshooting:** <https://srvscripts.com/scripts/entra-inactive-users-report/>

Version 1.0.0 · updated 2026-10-06 · Syntax-checked, not run yet

## Download, verify and run

```powershell
Invoke-WebRequest https://scr.srvscripts.com/entra-inactive-users-report/Get-EntraInactiveUsers.ps1 -OutFile Get-EntraInactiveUsers.ps1
(Get-FileHash .\Get-EntraInactiveUsers.ps1 -Algorithm SHA256).Hash   # compare with Get-EntraInactiveUsers.ps1.sha256
Get-Help .\Get-EntraInactiveUsers.ps1 -Full
```

Read the script before you run it, and try it on a test server first.

## Requirements

Windows PowerShell 5.1 or PowerShell 7; Microsoft.Graph.Authentication module; Graph User.Read.All and AuditLog.Read.All; Reports Reader or Global Reader; Microsoft Entra ID P1 or P2 licence in the tenant (for signInActivity).

## How we tested it

Syntax-checked with PowerShell 7.4.6 and PSScriptAnalyzer 1.25 on 6 Oct 2026; not yet run against a live tenant/server.

## Changes and licence

What changed in each version: [CHANGELOG.md](CHANGELOG.md). Releases are tagged `entra-inactive-users-report/vX.Y.Z`.

MIT licence. If you copy, share or adapt the script, keep its header and credit [srvScripts.com](https://srvscripts.com/scripts/entra-inactive-users-report/).
