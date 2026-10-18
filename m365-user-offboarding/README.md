# Microsoft 365 User Offboarding PowerShell Script (with -WhatIf)

For M365 user offboarding, run .\Invoke-M365Offboarding.ps1 -UserPrincipalName bob@contoso.com -ConvertToShared -ForwardToManager -Apply -WhatIf to see exactly what would happen, then run it again without -WhatIf. In one logged run it blocks sign-in, revokes sessions, converts the mailbox to shared, sets an auto-reply, forwards new mail to the manager, removes group memberships and removes direct licences, after saving a JSON snapshot of the user's licences, groups and mailbox settings. Before any group or licence change it works out whether the mailbox still needs its Exchange licence; if it does, the licence and the groups that assign it are kept. Without -Apply it only shows the plan.

**Full documentation, example output and troubleshooting:** <https://srvscripts.com/scripts/m365-user-offboarding/>

Version 1.1.0 · updated 2026-10-07 · Fixture-tested

## Download, verify and run

```powershell
Invoke-WebRequest https://scr.srvscripts.com/m365-user-offboarding/Invoke-M365Offboarding.ps1 -OutFile Invoke-M365Offboarding.ps1
(Get-FileHash .\Invoke-M365Offboarding.ps1 -Algorithm SHA256).Hash   # compare with Invoke-M365Offboarding.ps1.sha256
Get-Help .\Invoke-M365Offboarding.ps1 -Full
```

Read the script before you run it, and try it on a test server first.

## Requirements

Windows PowerShell 5.1 or PowerShell 7; Microsoft.Graph.Authentication; ExchangeOnlineManagement 3.x for mailbox steps; Graph User.Read.All, User.EnableDisableAccount.All, User.RevokeSessions.All, LicenseAssignment.ReadWrite.All, GroupMember.ReadWrite.All; User Administrator plus an Exchange recipient role.

## How we tested it

1.1.0 licence decisions tested offline with 28 synthetic cases (group-only and mixed licences, >50 GB, holds, archive, failed/declined conversion, unknown size, -WhatIf and plan-only make no changes); apply mode not yet re-run against a sandbox tenant, so start with the plan and -WhatIf; Syntax-checked with PowerShell 7.4.6 and PSScriptAnalyzer 1.25 on 6 Oct 2026; not yet run against a live tenant/server.

## Changes and licence

What changed in each version: [CHANGELOG.md](CHANGELOG.md). Releases are tagged `m365-user-offboarding/vX.Y.Z`.

MIT licence. If you copy, share or adapt the script, keep its header and credit [srvScripts.com](https://srvscripts.com/scripts/m365-user-offboarding/).
