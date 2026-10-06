# Kerberos RC4 Audit Script: Find RC4 Accounts and Tickets (v1.0.0) - from srvScripts.com
# Source, docs and updates: https://srvscripts.com/scripts/kerberos-rc4-audit/
# Copyright (c) 2026 srvScripts.com. MIT licence: if you copy, share or adapt this script, keep this notice and credit srvScripts.com.
<#
.SYNOPSIS
    Find AD accounts that still allow (or only allow) Kerberos RC4, and optionally the RC4 tickets your DCs
    actually issued (events 4768/4769 with encryption type 0x17).

.DESCRIPTION
    Read-only.
    Part 1 - configuration. Reads msDS-SupportedEncryptionTypes on the accounts that matter for Kerberos
    service tickets: user and managed service accounts with a servicePrincipalName, computer accounts, and
    trust objects (trustedDomain). Use -AllUsers to include every user account. Each account is classified:
      NotSet     attribute empty or 0: the KDC uses the DefaultDomainSupportedEncTypes value of the DC,
                 so the result depends on your DCs' configuration and update level
      RC4Only    RC4 (0x4) allowed and no AES bit (0x8, 0x10)
      RC4AndAES  RC4 and at least one AES type allowed
      AESOnly    AES allowed, RC4 not allowed
      DESOnly    only DES bits (0x1, 0x2) set
    A separate DESAllowed column is True whenever a DES bit is set (DES is disabled by default since
    Windows 7 / Server 2008 R2), for example the common value 0x1F (DES, RC4, AES128, AES256).
    It also flags userAccountControl USE_DES_KEY_ONLY (0x200000) and shows when the password was last set:
    an account whose password has not changed since the domain first ran Windows Server 2008 domain
    controllers may have no AES keys at all.

    Part 2 - usage (-Events). Reads the Security log of each DC for 4769 (service ticket) and, with
    -IncludeTgt, 4768 (TGT) events whose TicketEncryptionType is 0x17 (RC4-HMAC) or 0x18 (RC4-HMAC-EXP),
    and groups them by client, service and source IP. On DCs with the January 2025 or later security update
    the events also carry AccountAvailableKeys / ServiceAvailableKeys, which the report includes.
    Requires "Audit Kerberos Service Ticket Operations" (and for 4768 "Audit Kerberos Authentication
    Service") success auditing on the DCs.

.PARAMETER Server
    Domain to check (default: current domain).

.PARAMETER SearchBase
    Limit the account scan to this OU (DN).

.PARAMETER AllUsers
    Include all user accounts, not only those with a servicePrincipalName.

.PARAMETER IncludeAesOnly
    Also output accounts classified AESOnly (default: only accounts that need attention).

.PARAMETER Events
    Also read RC4 ticket events from the domain controllers.

.PARAMETER IncludeTgt
    With -Events, also read 4768 (TGT) events, not only 4769.

.PARAMETER Hours
    With -Events, how far back to read (default 24, maximum 720).

.PARAMETER MaxEvents
    With -Events, maximum events read per DC (default 5000).

.PARAMETER DomainController
    With -Events, read only these DCs.

.PARAMETER ExportCsv
    Write the account report to this CSV file. With -Events the usage report is written next to it with
    "-events" added to the file name.

.PARAMETER PassThru
    Output objects (accounts, then usage rows) to the pipeline.

.EXAMPLE
    .\Get-KerberosRC4Usage.ps1

.EXAMPLE
    .\Get-KerberosRC4Usage.ps1 -Events -Hours 72 -ExportCsv C:\Reports\rc4.csv

.EXAMPLE
    .\Get-KerberosRC4Usage.ps1 -AllUsers -IncludeAesOnly -PassThru | Group-Object Classification

.NOTES
    Name:     Get-KerberosRC4Usage.ps1
    Version:  1.0.0
    Source:   https://srvscripts.com/scripts/kerberos-rc4-audit/
    License:  MIT
    Requires: Windows PowerShell 5.1 or PowerShell 7 on Windows, ActiveDirectory module (RSAT); for -Events,
              rights to read the DC Security logs (Domain Admins or Event Log Readers) and the Remote Event Log
              Management firewall rules on the DCs.
    Microsoft also publishes Kerberos audit scripts (Get-KerbEncryptionUsage.ps1, List-AccountKeys.ps1) in
    its Kerberos-Crypto GitHub repository; see https://learn.microsoft.com/windows-server/security/kerberos/detect-remediate-rc4-kerberos
#>
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string]$Server,

    [ValidateNotNullOrEmpty()]
    [string]$SearchBase,

    [switch]$AllUsers,

    [switch]$IncludeAesOnly,

    [switch]$Events,

    [switch]$IncludeTgt,

    [ValidateRange(1, 720)]
    [int]$Hours = 24,

    [ValidateRange(1, 1000000)]
    [int]$MaxEvents = 5000,

    [ValidateNotNullOrEmpty()]
    [string[]]$DomainController,

    [ValidateNotNullOrEmpty()]
    [string]$ExportCsv,

    [switch]$PassThru
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
    throw "The ActiveDirectory module is not installed. Install RSAT: Active Directory Domain Services tools, then run again."
}
Import-Module ActiveDirectory -Verbose:$false

function ConvertFrom-FileTimeValue {
    param($Value)
    if ($null -eq $Value) { return $null }
    $v = [int64]$Value
    if ($v -le 0 -or $v -eq [int64]::MaxValue) { return $null }
    [DateTime]::FromFileTime($v)
}

function Get-AttributeValue {
    param($Entity, [string]$Name)
    if ($Entity.PropertyNames -contains $Name) { return $Entity[$Name].Value }
    $null
}

function Get-EncTypeName {
    param([int64]$Value)
    $n = @()
    if ($Value -band 0x1)  { $n += 'DES-CBC-CRC' }
    if ($Value -band 0x2)  { $n += 'DES-CBC-MD5' }
    if ($Value -band 0x4)  { $n += 'RC4-HMAC' }
    if ($Value -band 0x8)  { $n += 'AES128' }
    if ($Value -band 0x10) { $n += 'AES256' }
    if ($Value -band -bnot 0x1F) { $n += ('other bits 0x{0:X}' -f ($Value -band -bnot 0x1F)) }
    $n -join ', '
}

function Get-EncClassification {
    param($Value)
    if ($null -eq $Value -or [int64]$Value -eq 0) { return 'NotSet' }
    $v = [int64]$Value
    $rc4 = [bool]($v -band 0x4)
    $aes = [bool]($v -band 0x18)
    $des = [bool]($v -band 0x3)
    if ($rc4 -and -not $aes) { return 'RC4Only' }
    if ($rc4 -and $aes) { return 'RC4AndAES' }
    if ($aes) { return 'AESOnly' }
    if ($des) { return 'DESOnly' }
    'NoKerberosEtype'
}

$domArgs = @{}
if ($Server) { $domArgs.Server = $Server }
$domain = Get-ADDomain @domArgs
$srv = $domain.DNSRoot

# ---- Part 1: account configuration ----------------------------------------------------------------------
$attrs = 'msDS-SupportedEncryptionTypes', 'userAccountControl', 'pwdLastSet', 'servicePrincipalName', 'sAMAccountName', 'objectClass', 'name', 'operatingSystem'
$userFilter = if ($AllUsers) { '(&(objectCategory=person)(objectClass=user))' } else { '(&(objectCategory=person)(objectClass=user)(servicePrincipalName=*))' }
$filters = [ordered]@{
    'User'              = $userFilter
    'Computer'          = '(objectCategory=computer)'
    'ManagedSvcAccount' = '(|(objectClass=msDS-GroupManagedServiceAccount)(objectClass=msDS-ManagedServiceAccount))'
    'Trust'             = '(objectClass=trustedDomain)'
}
$q = @{ Server = $srv; Properties = $attrs; ResultPageSize = 500 }
if ($SearchBase) { $q.SearchBase = $SearchBase }

$accounts = [System.Collections.Generic.List[object]]::new()
$seen = @{}
foreach ($kind in $filters.Keys) {
    Write-Verbose "Scanning $kind objects"
    $objs = @(Get-ADObject -LDAPFilter $filters[$kind] @q)
    foreach ($o in $objs) {
        if ($seen.ContainsKey($o.DistinguishedName)) { continue }
        $seen[$o.DistinguishedName] = $true
        $et = Get-AttributeValue $o 'msDS-SupportedEncryptionTypes'
        $uac = Get-AttributeValue $o 'userAccountControl'
        $cls = Get-EncClassification $et
        $desOnly = ($null -ne $uac -and ([int]$uac -band 0x200000))
        $desAllowed = ($null -ne $et -and ([int64]$et -band 0x3))
        if ($cls -eq 'AESOnly' -and -not $desOnly -and -not $desAllowed -and -not $IncludeAesOnly) { continue }
        $spn = @(Get-AttributeValue $o 'servicePrincipalName' | Where-Object { $_ })
        $etText = 'Not set'
        $etHex = ''
        if ($null -ne $et -and [int64]$et -ne 0) { $etText = Get-EncTypeName ([int64]$et); $etHex = '0x{0:X}' -f [int64]$et }
        $accounts.Add([pscustomobject]@{
            Name                 = [string](Get-AttributeValue $o 'name')
            SamAccountName       = [string](Get-AttributeValue $o 'sAMAccountName')
            Kind                 = $kind
            Classification       = $cls
            SupportedEncTypes    = $etHex
            EncTypesDecoded      = $etText
            DESAllowed           = [bool]$desAllowed
            UseDesKeyOnly        = [bool]$desOnly
            Enabled              = if ($null -ne $uac) { -not ([int]$uac -band 2) } else { $null }
            PasswordLastSet      = ConvertFrom-FileTimeValue (Get-AttributeValue $o 'pwdLastSet')
            SPNCount             = $spn.Count
            OperatingSystem      = [string](Get-AttributeValue $o 'operatingSystem')
            DistinguishedName    = $o.DistinguishedName
        })
    }
}
$accountRows = @($accounts | Sort-Object @{ Expression = { switch ($_.Classification) { 'RC4Only' { 0 } 'DESOnly' { 1 } 'RC4AndAES' { 2 } 'NotSet' { 3 } default { 4 } } } }, Kind, Name)

# ---- Part 2: RC4 tickets issued -------------------------------------------------------------------------
$usageRows = @()
if ($Events) {
    $dcs = @(Get-ADDomainController -Filter * -Server $srv | ForEach-Object { $_.HostName })
    if ($DomainController) { $dcs = @($dcs | Where-Object { $DomainController -contains $_ }) }
    $ms = [int64]$Hours * 3600 * 1000
    $ids = if ($IncludeTgt) { '(EventID=4769 or EventID=4768)' } else { 'EventID=4769' }
    $xpath = "*[System[$ids and TimeCreated[timediff(@SystemTime) <= $ms]]] and " +
             "*[EventData[Data[@Name='TicketEncryptionType']='0x17' or Data[@Name='TicketEncryptionType']='0x18']]"
    $agg = @{}
    foreach ($dc in $dcs) {
        Write-Verbose "Reading RC4 ticket events on $dc"
        $evs = @()
        try {
            $evs = @(Get-WinEvent -ComputerName $dc -LogName Security -FilterXPath $xpath -MaxEvents $MaxEvents)
        } catch {
            if ($_.FullyQualifiedErrorId -match 'NoMatchingEventsFound' -or $_.Exception.Message -match 'No events were found') { continue }
            Write-Warning "Cannot read the Security log on ${dc}: $($_.Exception.Message)"
            continue
        }
        if ($evs.Count -ge $MaxEvents) { Write-Warning "$dc returned $MaxEvents events (the -MaxEvents limit); counts for this DC are incomplete." }
        foreach ($e in $evs) {
            $d = @{}
            foreach ($n in ([xml]$e.ToXml()).Event.EventData.Data) { $d[$n.Name] = [string]$n.InnerText }
            $ip = ([string]$d['IpAddress']) -replace '^::ffff:', ''
            $key = '{0}|{1}|{2}|{3}|{4}' -f $e.Id, $d['TargetUserName'], $d['ServiceName'], $ip, $d['TicketEncryptionType']
            if (-not $agg.ContainsKey($key)) {
                $agg[$key] = [pscustomobject]@{
                    EventId              = $e.Id
                    Client               = [string]$d['TargetUserName']
                    Service              = [string]$d['ServiceName']
                    SourceIP             = $ip
                    TicketEncryptionType = [string]$d['TicketEncryptionType']
                    Count                = 0
                    FirstSeen            = $e.TimeCreated
                    LastSeen             = $e.TimeCreated
                    DomainControllers    = ''
                    AccountAvailableKeys = [string]$d['AccountAvailableKeys']
                    ServiceAvailableKeys = [string]$d['ServiceAvailableKeys']
                    ClientAdvertizedEncryptionTypes = [string]$d['ClientAdvertizedEncryptionTypes']
                }
            }
            $a = $agg[$key]
            $a.Count++
            if ($e.TimeCreated -lt $a.FirstSeen) { $a.FirstSeen = $e.TimeCreated }
            if ($e.TimeCreated -gt $a.LastSeen) { $a.LastSeen = $e.TimeCreated }
            if (($a.DomainControllers -split '; ') -notcontains $dc) { $a.DomainControllers = (@($a.DomainControllers -split '; ' | Where-Object { $_ }) + $dc) -join '; ' }
        }
    }
    $usageRows = @($agg.Values | Sort-Object Count -Descending)
}

# ---- Output ---------------------------------------------------------------------------------------------
if ($ExportCsv) {
    $accountRows | Export-Csv -LiteralPath $ExportCsv -NoTypeInformation -Encoding UTF8
    Write-Information ("{0} account(s) written to {1}" -f $accountRows.Count, $ExportCsv) -InformationAction Continue
    if ($Events) {
        $evFile = [System.IO.Path]::ChangeExtension($ExportCsv, $null).TrimEnd('.') + '-events.csv'
        $usageRows | Export-Csv -LiteralPath $evFile -NoTypeInformation -Encoding UTF8
        Write-Information ("{0} RC4 usage row(s) written to {1}" -f $usageRows.Count, $evFile) -InformationAction Continue
    }
}
if ($PassThru) { $accountRows; $usageRows; return }

$accountRows | Group-Object Classification | Sort-Object Name | Format-Table @{ n = 'Classification'; e = { $_.Name } }, Count -AutoSize
$accountRows | Where-Object { $_.Classification -in 'RC4Only', 'DESOnly', 'RC4AndAES' -or $_.DESAllowed -or $_.UseDesKeyOnly } |
    Format-Table Name, Kind, Classification, SupportedEncTypes, EncTypesDecoded, PasswordLastSet -AutoSize
if ($Events) {
    if ($usageRows.Count) {
        $usageRows | Select-Object -First 50 | Format-Table Count, EventId, Client, Service, SourceIP, LastSeen -AutoSize
    } else {
        Write-Information "No RC4 (0x17/0x18) ticket events found in the last $Hours hour(s) on: $($dcs -join ', ')" -InformationAction Continue
    }
}
