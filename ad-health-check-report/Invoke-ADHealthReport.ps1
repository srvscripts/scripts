# AD Health Check Report: dcdiag and repadmin PowerShell Script (v1.0.0) - from srvScripts.com
# Source, docs and updates: https://srvscripts.com/scripts/ad-health-check-report/
# Copyright (c) 2026 srvScripts.com. MIT licence: if you copy, share or adapt this script, keep this notice and credit srvScripts.com.
<#
.SYNOPSIS
    One HTML health report for every domain controller: dcdiag, replication summary, FSMO holders, time source
    and SYSVOL (DFSR) state. Optionally e-mails it.

.DESCRIPTION
    Read-only. For each DC in the domain (Get-ADDomainController -Filter *) the script runs:
      dcdiag /s:<DC> /q              quiet mode: prints only errors, so empty output = all default tests passed
      w32tm /query /computer:<DC> /source
      DfsrReplicatedFolderInfo        (CIM, namespace root\MicrosoftDfs) state of the "SYSVOL Share" folder:
                                      0 Uninitialized, 1 Initialized, 2 Initial Sync, 3 Auto Recovery,
                                      4 Normal, 5 In Error
    Once per run it also captures:
      repadmin /replsummary           largest replication delta and failures per DC
      FSMO role holders               from Get-ADForest and Get-ADDomain
    The HTML report starts with a summary table (one row per DC, Pass / Warning / Fail per check) and keeps
    the raw dcdiag and repadmin output underneath for anyone who needs the detail.

    E-mail: with -SmtpServer, -To and -From the report is sent with Send-MailMessage. Microsoft marks
    Send-MailMessage as obsolete because it does not guarantee a secure connection to the SMTP server; use it
    only with an internal relay you trust, or leave the e-mail options out and collect the saved file.

.PARAMETER Server
    Domain to check (default: current domain).

.PARAMETER DomainController
    Check only these DCs (host names) instead of all DCs in the domain.

.PARAMETER OutputPath
    Where to save the HTML report (default: .\ADHealth-<domain>-<yyyyMMdd-HHmm>.html).

.PARAMETER SkipDcdiag
    Do not run dcdiag (it is the slowest check, run once per DC).

.PARAMETER SmtpServer
    SMTP relay to send the report through. Requires -To and -From.

.PARAMETER To
    Recipient address(es).

.PARAMETER From
    Sender address.

.PARAMETER Port
    SMTP port (default 25).

.PARAMETER UseSsl
    Use TLS for the SMTP connection.

.PARAMETER Credential
    SMTP credentials, if the relay needs authentication.

.PARAMETER PassThru
    Output the per-DC summary objects to the pipeline.

.EXAMPLE
    .\Invoke-ADHealthReport.ps1

.EXAMPLE
    .\Invoke-ADHealthReport.ps1 -OutputPath C:\Reports\ad-health.html -SkipDcdiag

.EXAMPLE
    .\Invoke-ADHealthReport.ps1 -SmtpServer relay.contoso.com -From adreport@contoso.com -To admins@contoso.com

.NOTES
    Name:     Invoke-ADHealthReport.ps1
    Version:  1.0.0
    Source:   https://srvscripts.com/scripts/ad-health-check-report/
    License:  MIT
    Requires: Windows PowerShell 5.1 or PowerShell 7 on Windows, ActiveDirectory module and the AD DS command-line
              tools (dcdiag.exe, repadmin.exe: RSAT AD DS tools or a DC), w32tm.exe (built in), a Domain Admin
              or equivalent account (dcdiag and the DFSR WMI namespace need admin rights on the DCs), and
              WinRM/DCOM access to the DCs for the CIM query.
#>
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string]$Server,

    [ValidateNotNullOrEmpty()]
    [string[]]$DomainController,

    [ValidateNotNullOrEmpty()]
    [string]$OutputPath,

    [switch]$SkipDcdiag,

    [ValidateNotNullOrEmpty()]
    [string]$SmtpServer,

    [ValidateNotNullOrEmpty()]
    [string[]]$To,

    [ValidateNotNullOrEmpty()]
    [string]$From,

    [ValidateRange(1, 65535)]
    [int]$Port = 25,

    [switch]$UseSsl,

    [System.Management.Automation.PSCredential]
    [System.Management.Automation.Credential()]
    $Credential = [System.Management.Automation.PSCredential]::Empty,

    [switch]$PassThru
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
    throw "The ActiveDirectory module is not installed. Install RSAT: Active Directory Domain Services tools, then run again."
}
Import-Module ActiveDirectory -Verbose:$false
if ($SmtpServer -and (-not $To -or -not $From)) { throw "-SmtpServer needs -To and -From." }
foreach ($exe in 'repadmin.exe', 'w32tm.exe') {
    if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) { throw "$exe not found. Run on a DC or install RSAT: Active Directory Domain Services tools." }
}
if (-not $SkipDcdiag -and -not (Get-Command 'dcdiag.exe' -ErrorAction SilentlyContinue)) {
    throw "dcdiag.exe not found. Run on a DC, install RSAT: Active Directory Domain Services tools, or use -SkipDcdiag."
}

function ConvertTo-HtmlText { param([string]$Text) [System.Net.WebUtility]::HtmlEncode($Text) }

function Invoke-Native {
    param([string]$FilePath, [string[]]$ArgumentList)
    # Windows PowerShell 5.1 turns redirected stderr into error records; do not let them stop the script.
    $ErrorActionPreference = 'Continue'
    $text = (& $FilePath @ArgumentList 2>&1 | ForEach-Object { [string]$_ }) -join "`n"
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $text.Trim() }
}

# ---- Domain, forest, DCs, FSMO --------------------------------------------------------------------------
$domArgs = @{}
if ($Server) { $domArgs.Server = $Server }
$domain = Get-ADDomain @domArgs
$forest = Get-ADForest -Server $domain.DNSRoot
$dcs = @(Get-ADDomainController -Filter * -Server $domain.DNSRoot | Sort-Object HostName)
if ($DomainController) {
    $dcs = @($dcs | Where-Object { $DomainController -contains $_.HostName -or $DomainController -contains $_.Name })
    if (-not $dcs.Count) { throw "None of the -DomainController names is a DC of $($domain.DNSRoot)." }
}
if (-not $dcs.Count) { throw "No domain controllers returned for $($domain.DNSRoot)." }
$fsmo = [ordered]@{
    'Schema master'         = $forest.SchemaMaster
    'Domain naming master'  = $forest.DomainNamingMaster
    'PDC emulator'          = $domain.PDCEmulator
    'RID master'            = $domain.RIDMaster
    'Infrastructure master' = $domain.InfrastructureMaster
}
if (-not $OutputPath) { $OutputPath = Join-Path (Get-Location).Path ("ADHealth-{0}-{1:yyyyMMdd-HHmm}.html" -f $domain.DNSRoot, (Get-Date)) }

# ---- Per-DC checks --------------------------------------------------------------------------------------
$summary = [System.Collections.Generic.List[object]]::new()
$details = [System.Collections.Generic.List[string]]::new()
$dfsrStates = @{ 0 = 'Uninitialized'; 1 = 'Initialized'; 2 = 'Initial Sync'; 3 = 'Auto Recovery'; 4 = 'Normal'; 5 = 'In Error' }
$i = 0
foreach ($dc in $dcs) {
    $i++
    $h = $dc.HostName
    Write-Progress -Activity 'AD health check' -Status $h -PercentComplete (100 * ($i - 1) / $dcs.Count)
    $roles = @($fsmo.Keys | Where-Object { $fsmo[$_] -eq $h })

    # dcdiag
    $dcdiagStatus = 'Skipped'; $dcdiagOut = ''
    if (-not $SkipDcdiag) {
        Write-Verbose "dcdiag /s:$h /q"
        $r = Invoke-Native 'dcdiag.exe' @("/s:$h", '/q')
        $dcdiagOut = $r.Output
        $dcdiagStatus = if (-not $r.Output) { 'Pass' } else { 'Fail' }
    }

    # time source
    $t = Invoke-Native 'w32tm.exe' @('/query', "/computer:$h", '/source')
    $timeSource = $t.Output
    $timeStatus = 'Pass'
    if ($t.ExitCode -ne 0 -or -not $timeSource) { $timeStatus = 'Fail' }
    elseif ($timeSource -match 'Local CMOS Clock|Free-running System Clock') {
        $timeStatus = if ($h -eq $domain.PDCEmulator -and $domain.DNSRoot -eq $forest.RootDomain) { 'Fail' } else { 'Warning' }
    }

    # SYSVOL DFSR state
    $sysvol = 'Unknown'; $sysvolStatus = 'Warning'
    try {
        $rf = @(Get-CimInstance -ComputerName $h -Namespace 'root/MicrosoftDfs' -ClassName 'DfsrReplicatedFolderInfo' -OperationTimeoutSec 60 |
            Where-Object { $_.ReplicatedFolderName -eq 'SYSVOL Share' })
        if ($rf.Count) {
            $st = [int]$rf[0].State
            $sysvol = if ($dfsrStates.ContainsKey($st)) { $dfsrStates[$st] } else { "State $st" }
            $sysvolStatus = if ($st -eq 4) { 'Pass' } elseif ($st -eq 5) { 'Fail' } else { 'Warning' }
        } else {
            $sysvol = 'No DFSR SYSVOL folder found (FRS-replicated SYSVOL, or DFSR not set up)'
        }
    } catch {
        $sysvol = "Query failed: $($_.Exception.Message)"
    }

    $overall = if (@($dcdiagStatus, $timeStatus, $sysvolStatus) -contains 'Fail') { 'Fail' }
               elseif (@($dcdiagStatus, $timeStatus, $sysvolStatus) -contains 'Warning') { 'Warning' } else { 'Pass' }
    $summary.Add([pscustomobject]@{
        DomainController = $h
        Site             = $dc.Site
        OperatingSystem  = $dc.OperatingSystem
        GlobalCatalog    = $dc.IsGlobalCatalog
        ReadOnly         = $dc.IsReadOnly
        FSMORoles        = ($roles -join ', ')
        Dcdiag           = $dcdiagStatus
        TimeSource       = $timeSource
        TimeStatus       = $timeStatus
        SysvolDfsr       = $sysvol
        SysvolStatus     = $sysvolStatus
        Overall          = $overall
    })
    if ($dcdiagOut) { $details.Add("<h3>dcdiag errors: $(ConvertTo-HtmlText $h)</h3><pre>$(ConvertTo-HtmlText $dcdiagOut)</pre>") }
}
Write-Progress -Activity 'AD health check' -Completed

# ---- Replication summary --------------------------------------------------------------------------------
Write-Verbose 'repadmin /replsummary'
$rep = Invoke-Native 'repadmin.exe' @('/replsummary')
$repStatus = 'Pass'
# Each DC row has a "fails / total" pair. Any row with fails above zero, or a non-zero exit code, is a failure.
$failCounts = @(($rep.Output -split "`n") | Where-Object { $_ -notmatch 'Start Time' } | ForEach-Object {
    $m = [regex]::Match($_, '(?<![\d/])(\d+)\s*/\s*(\d+)\s+(\d{1,3})(?![\d/:])')
    if ($m.Success) { [int]$m.Groups[1].Value }
})
if ($rep.ExitCode -ne 0 -or -not $rep.Output) { $repStatus = 'Fail' }
elseif (@($failCounts | Where-Object { $_ -gt 0 }).Count) { $repStatus = 'Fail' }
elseif ($rep.Output -match 'operational errors') { $repStatus = 'Warning' }

# ---- HTML -----------------------------------------------------------------------------------------------
$css = @'
body{font-family:Segoe UI,Arial,sans-serif;font-size:13px;margin:20px;color:#222}
table{border-collapse:collapse;margin-bottom:16px}th,td{border:1px solid #ccc;padding:4px 8px;text-align:left;vertical-align:top}
th{background:#f0f0f0}pre{background:#f7f7f7;border:1px solid #ddd;padding:8px;overflow:auto;font-size:12px}
.Pass{background:#e3f4e3}.Warning{background:#fff4d6}.Fail{background:#fbe0e0}
'@
$cell = { param($v) $c = [string]$v; if ($c -in 'Pass', 'Warning', 'Fail') { "<td class=`"$c`">$c</td>" } else { "<td>$(ConvertTo-HtmlText $c)</td>" } }
$cols = 'DomainController', 'Site', 'OperatingSystem', 'GlobalCatalog', 'ReadOnly', 'FSMORoles', 'Dcdiag', 'TimeSource', 'TimeStatus', 'SysvolDfsr', 'SysvolStatus', 'Overall'
$sb = New-Object System.Text.StringBuilder
[void]$sb.Append("<!DOCTYPE html><html><head><meta charset=`"utf-8`"><title>AD health report $(ConvertTo-HtmlText $domain.DNSRoot)</title><style>$css</style></head><body>")
[void]$sb.Append(("<h1>AD health report: {0}</h1><p>Generated {1:yyyy-MM-dd HH:mm} on {2}. Forest {3}, {4} DC(s) checked.</p>" -f (ConvertTo-HtmlText $domain.DNSRoot), (Get-Date), $env:COMPUTERNAME, (ConvertTo-HtmlText $forest.Name), $summary.Count))
[void]$sb.Append('<h2>Domain controllers</h2><table><tr>' + (($cols | ForEach-Object { "<th>$_</th>" }) -join '') + '</tr>')
foreach ($s in $summary) { [void]$sb.Append('<tr>' + (($cols | ForEach-Object { & $cell $s.$_ }) -join '') + '</tr>') }
[void]$sb.Append('</table><h2>FSMO role holders</h2><table><tr><th>Role</th><th>Holder</th></tr>')
foreach ($k in $fsmo.Keys) { [void]$sb.Append("<tr><td>$k</td><td>$(ConvertTo-HtmlText $fsmo[$k])</td></tr>") }
[void]$sb.Append("</table><h2>Replication summary (repadmin /replsummary)</h2><table><tr><th>Status</th></tr><tr>$(& $cell $repStatus)</tr></table><pre>$(ConvertTo-HtmlText $rep.Output)</pre>")
if ($details.Count) { [void]$sb.Append('<h2>dcdiag details</h2>' + ($details -join '')) }
[void]$sb.Append('<p>dcdiag ran in quiet mode (/q): only failing tests print text. Status rules: time source "Local CMOS Clock" or "Free-running System Clock" is a warning on a DC and a failure on the forest-root PDC emulator; SYSVOL is Pass only in DFSR state 4 (Normal).</p></body></html>')
$sb.ToString() | Out-File -LiteralPath $OutputPath -Encoding utf8
Write-Information ("Report saved to {0}" -f $OutputPath) -InformationAction Continue

# ---- Optional e-mail ------------------------------------------------------------------------------------
if ($SmtpServer) {
    $states = @($summary | ForEach-Object { $_.Overall })
    $worst = if ($states -contains 'Fail' -or $repStatus -eq 'Fail') { 'FAIL' } elseif ($states -contains 'Warning' -or $repStatus -eq 'Warning') { 'WARNING' } else { 'PASS' }
    $mail = @{
        SmtpServer = $SmtpServer; Port = $Port; To = $To; From = $From
        Subject = "AD health $($domain.DNSRoot): $worst"; Body = $sb.ToString(); BodyAsHtml = $true; Attachments = $OutputPath
    }
    if ($UseSsl) { $mail.UseSsl = $true }
    if ($Credential -ne [System.Management.Automation.PSCredential]::Empty) { $mail.Credential = $Credential }
    try {
        Send-MailMessage @mail -WarningAction SilentlyContinue
        Write-Information "Report e-mailed to $($To -join ', ')" -InformationAction Continue
    } catch {
        Write-Warning "E-mail failed: $($_.Exception.Message). The report is still saved at $OutputPath."
    }
}

if ($PassThru) { return $summary }
$summary | Format-Table DomainController, Dcdiag, TimeStatus, SysvolStatus, Overall, FSMORoles -AutoSize
Write-Information "Replication summary: $repStatus" -InformationAction Continue
