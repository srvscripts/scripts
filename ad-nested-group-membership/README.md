# AD Nested Group Membership: PowerShell Tree with Loop Detection

To check nested group membership in AD, run .\Get-ADNestedGroupMembership.ps1 -Identity bob to see every group a user belongs to, directly or through nesting, as an indented tree with the path to each group. Point it at a group (-Identity "Domain Admins") to expand everything inside it instead. Circular nesting is detected and marked as a loop, the primary group is included, and -ExportCsv saves the full tree with paths.

**Full documentation, example output and troubleshooting:** <https://srvscripts.com/scripts/ad-nested-group-membership/>

Version 1.0.0 · updated 2026-10-06 · Lab-tested

## Download, verify and run

```powershell
Invoke-WebRequest https://scr.srvscripts.com/ad-nested-group-membership/Get-ADNestedGroupMembership.ps1 -OutFile Get-ADNestedGroupMembership.ps1
(Get-FileHash .\Get-ADNestedGroupMembership.ps1 -Algorithm SHA256).Hash   # compare with Get-ADNestedGroupMembership.ps1.sha256
Get-Help .\Get-ADNestedGroupMembership.ps1 -Full
```

Read the script before you run it, and try it on a test server first.

## Requirements

Windows PowerShell 5.1 or PowerShell 7 on Windows; ActiveDirectory module (RSAT); read access to AD.

## Examples

```powershell
.\Get-ADNestedGroupMembership.ps1 -Identity bob
.\Get-ADNestedGroupMembership.ps1 -Identity "Domain Admins" -ExportCsv C:\Reports\da-tree.csv
.\Get-ADNestedGroupMembership.ps1 -Identity "Sales-All" -Direction MemberOf
.\Get-ADNestedGroupMembership.ps1 -Identity bob -PassThru | Where-Object Note -eq 'Loop'
```

## How we tested it

Run on 6 Oct 2026 on a Windows Server 2025 DC (build 26100.33438, Windows PowerShell 5.1) in our lab domain with a Windows 11 Pro member; syntax-checked with PowerShell 7.4.6 and PSScriptAnalyzer 1.25.

## Changes and licence

What changed in each version: [CHANGELOG.md](CHANGELOG.md). Releases are tagged `ad-nested-group-membership/vX.Y.Z`.

MIT licence. If you copy, share or adapt the script, keep its header and credit [srvScripts.com](https://srvscripts.com/scripts/ad-nested-group-membership/).
