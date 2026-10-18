# Exchange Online Message Trace to CSV: Get-MessageTraceV2 Script

For an Exchange Online message trace to CSV, run .\Get-EXOMessageTraceReport.ps1 -Hours 48 -RecipientAddress bob@contoso.com -CsvPath .\trace.csv. It uses Get-MessageTraceV2, the replacement for the deprecated Get-MessageTrace, and handles the new cmdlet's rules for you: at most 10 days per query, 5,000 rows per query, no page numbers (it continues with -StartingRecipientAddress and -EndDate), and 100 queries per 5 minutes. Filter by sender, recipient, status, subject or Message-ID, up to 90 days back.

**Full documentation, example output and troubleshooting:** <https://srvscripts.com/scripts/exo-message-trace-report/>

Version 1.0.0 · updated 2026-10-06 · Syntax-checked, not run yet

## Download, verify and run

```powershell
Invoke-WebRequest https://scr.srvscripts.com/exo-message-trace-report/Get-EXOMessageTraceReport.ps1 -OutFile Get-EXOMessageTraceReport.ps1
(Get-FileHash .\Get-EXOMessageTraceReport.ps1 -Algorithm SHA256).Hash   # compare with Get-EXOMessageTraceReport.ps1.sha256
Get-Help .\Get-EXOMessageTraceReport.ps1 -Full
```

Read the script before you run it, and try it on a test server first.

## Requirements

Windows PowerShell 5.1 or PowerShell 7; ExchangeOnlineManagement 3.7.0 or later; Organization Management role group or Exchange Administrator role (or a custom role that includes Get-MessageTraceV2).

## How we tested it

Syntax-checked with PowerShell 7.4.6 and PSScriptAnalyzer 1.25 on 6 Oct 2026; not yet run against a live tenant/server.

## Changes and licence

What changed in each version: [CHANGELOG.md](CHANGELOG.md). Releases are tagged `exo-message-trace-report/vX.Y.Z`.

MIT licence. If you copy, share or adapt the script, keep its header and credit [srvScripts.com](https://srvscripts.com/scripts/exo-message-trace-report/).
