# Exchange Online Mailbox Permissions Report: FullAccess, SendAs

For an Exchange Online mailbox permissions report, run .\Get-EXOMailboxPermissionReport.ps1 -CsvPath .\mailbox-permissions.csv. It connects to Exchange Online and, for every user, shared, room and equipment mailbox, lists who has FullAccess (Get-EXOMailboxPermission), SendAs (Get-EXORecipientPermission) and SendOnBehalf (the GrantSendOnBehalfTo property), skipping NT AUTHORITY\SELF. Use -Trustee bob@contoso.com to see everything one person can open or send as.

**Full documentation, example output and troubleshooting:** <https://srvscripts.com/scripts/exo-mailbox-permissions-report/>

Version 1.0.0 · updated 2026-10-06 · Syntax-checked, not run yet

## Download, verify and run

```powershell
Invoke-WebRequest https://scr.srvscripts.com/exo-mailbox-permissions-report/Get-EXOMailboxPermissionReport.ps1 -OutFile Get-EXOMailboxPermissionReport.ps1
(Get-FileHash .\Get-EXOMailboxPermissionReport.ps1 -Algorithm SHA256).Hash   # compare with Get-EXOMailboxPermissionReport.ps1.sha256
Get-Help .\Get-EXOMailboxPermissionReport.ps1 -Full
```

Read the script before you run it, and try it on a test server first.

## Requirements

Windows PowerShell 5.1 or PowerShell 7; ExchangeOnlineManagement 3.0 or later; Global Reader or an Exchange role that can read recipients and permissions; for app-only: Exchange.ManageAsApp plus a supported Entra role on the app.

## How we tested it

Syntax-checked with PowerShell 7.4.6 and PSScriptAnalyzer 1.25 on 6 Oct 2026; not yet run against a live tenant/server.

## Changes and licence

What changed in each version: [CHANGELOG.md](CHANGELOG.md). Releases are tagged `exo-mailbox-permissions-report/vX.Y.Z`.

MIT licence. If you copy, share or adapt the script, keep its header and credit [srvScripts.com](https://srvscripts.com/scripts/exo-mailbox-permissions-report/).
