# Exchange Online Mailbox Permissions Report: FullAccess, SendAs (v1.0.0) - from srvScripts.com
# Source, docs and updates: https://srvscripts.com/scripts/exo-mailbox-permissions-report/
# Copyright (c) 2026 srvScripts.com. MIT licence: if you copy, share or adapt this script, keep this notice and credit srvScripts.com.
<#
.SYNOPSIS
    Exchange Online mailbox permissions report: FullAccess, SendAs and SendOnBehalf for every mailbox
    (or selected mailboxes), filterable by trustee, exported to CSV.

.DESCRIPTION
    Read-only. Uses the ExchangeOnlineManagement module (REST-based V3 cmdlets):
      FullAccess    Get-EXOMailboxPermission   (non-inherited entries; NT AUTHORITY\SELF is skipped)
      SendAs        Get-EXORecipientPermission -AccessRights SendAs
      SendOnBehalf  GrantSendOnBehalfTo property from Get-EXOMailbox -Properties GrantSendOnBehalfTo
    Trustees are resolved to a primary SMTP address with Get-EXORecipient where possible. Entries that are
    bare SIDs (S-1-5-...) usually belong to deleted users or groups and are flagged as orphaned.

    Permissions needed (read-only is enough):
      Delegated sign-in: Microsoft Entra role Global Reader or Exchange Recipient Administrator, or an
      Exchange Online role group that includes the recipient read roles (for example View-Only Organization
      Management or Recipient Management). To check which roles contain a cmdlet in your tenant:
      Get-ManagementRole -Cmdlet Get-MailboxPermission
      App-only (certificate): app registration with the Office 365 Exchange Online Exchange.ManageAsApp
      application permission (admin consent) and a supported Entra role assigned to the app's service
      principal, for example Global Reader.

.PARAMETER Identity              Only these mailboxes (UPN, SMTP address or alias). Default: all mailboxes.
.PARAMETER RecipientTypeDetails  Mailbox types to include (default UserMailbox, SharedMailbox, RoomMailbox, EquipmentMailbox).
.PARAMETER PermissionType        FullAccess, SendAs, SendOnBehalf (default: all three).
.PARAMETER Trustee               Only show permissions held by this user or group (wildcards allowed, e.g. "bob*").
.PARAMETER IncludeInherited      Include inherited FullAccess entries (normally system accounts only).
.PARAMETER CsvPath               Write the result to this CSV file.
.PARAMETER PassThru              Output objects to the pipeline.
.PARAMETER UserPrincipalName     Admin account for interactive sign-in (optional; pre-fills the sign-in prompt).
.PARAMETER AppId                 App ID for certificate (app-only) sign-in.
.PARAMETER Organization          Tenant's initial domain, e.g. contoso.onmicrosoft.com (app-only).
.PARAMETER CertificateThumbprint Certificate thumbprint (app-only; Windows certificate store).
.PARAMETER Disconnect            Disconnect from Exchange Online when finished.

.EXAMPLE  .\Get-EXOMailboxPermissionReport.ps1 -CsvPath .\mailbox-permissions.csv
.EXAMPLE  .\Get-EXOMailboxPermissionReport.ps1 -RecipientTypeDetails SharedMailbox -PermissionType FullAccess,SendAs -CsvPath .\shared.csv
.EXAMPLE  .\Get-EXOMailboxPermissionReport.ps1 -Trustee bob@contoso.com          # everything Bob can open or send as
.EXAMPLE  .\Get-EXOMailboxPermissionReport.ps1 -Identity info@contoso.com,sales@contoso.com
.EXAMPLE  .\Get-EXOMailboxPermissionReport.ps1 -AppId <app-id> -Organization contoso.onmicrosoft.com -CertificateThumbprint <thumbprint> -CsvPath C:\Reports\perms.csv -Disconnect

.NOTES
    Name:     Get-EXOMailboxPermissionReport.ps1
    Purpose:  FullAccess / SendAs / SendOnBehalf audit for Exchange Online
    Source:   https://srvscripts.com/scripts/exo-mailbox-permissions-report/
    License:  MIT
    Version:  1.0.0
    Requires: Windows PowerShell 5.1 or PowerShell 7, module ExchangeOnlineManagement 3.x
              (Install-Module ExchangeOnlineManagement -Scope CurrentUser).
#>
[CmdletBinding(DefaultParameterSetName = 'Interactive')]
param(
    [string[]]$Identity,
    [ValidateSet('UserMailbox', 'SharedMailbox', 'RoomMailbox', 'EquipmentMailbox')]
    [string[]]$RecipientTypeDetails = @('UserMailbox', 'SharedMailbox', 'RoomMailbox', 'EquipmentMailbox'),
    [ValidateSet('FullAccess', 'SendAs', 'SendOnBehalf')]
    [string[]]$PermissionType = @('FullAccess', 'SendAs', 'SendOnBehalf'),
    [string]$Trustee,
    [switch]$IncludeInherited,
    [string]$CsvPath,
    [switch]$PassThru,
    [Parameter(ParameterSetName = 'Interactive')]
    [string]$UserPrincipalName,
    [Parameter(ParameterSetName = 'AppOnly', Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$AppId,
    [Parameter(ParameterSetName = 'AppOnly', Mandatory = $true)]
    [string]$Organization,
    [Parameter(ParameterSetName = 'AppOnly', Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F]{40}$')]
    [string]$CertificateThumbprint,
    [switch]$Disconnect
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

function Write-Status([string]$Message) { Write-Information $Message -InformationAction Continue }

# ---- Connect --------------------------------------------------------------------------------------------
if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) {
    throw 'Module ExchangeOnlineManagement is not installed. Run: Install-Module ExchangeOnlineManagement -Scope CurrentUser'
}
Import-Module ExchangeOnlineManagement
$existing = @(Get-ConnectionInformation -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Connected' -and $_.Name -like 'ExchangeOnline_*' })
if (-not $existing) {
    $c = @{ ShowBanner = $false }
    if ($PSCmdlet.ParameterSetName -eq 'AppOnly') {
        $c.AppId = $AppId; $c.Organization = $Organization; $c.CertificateThumbprint = $CertificateThumbprint
    } elseif ($UserPrincipalName) {
        $c.UserPrincipalName = $UserPrincipalName
    }
    Connect-ExchangeOnline @c
} else {
    Write-Status ("Reusing Exchange Online connection ({0})." -f $existing[0].UserPrincipalName)
}

# ---- Mailboxes ----------------------------------------------------------------------------------------------
$props = @('GrantSendOnBehalfTo')
if ($Identity) {
    $mailboxes = foreach ($id in $Identity) {
        try { Get-EXOMailbox -Identity $id -Properties $props }
        catch { Write-Warning "Mailbox not found or not readable: $id ($($_.Exception.Message))" }
    }
    $mailboxes = @($mailboxes | Where-Object { $_ })
} else {
    Write-Status 'Reading mailboxes...'
    $mailboxes = @(Get-EXOMailbox -RecipientTypeDetails $RecipientTypeDetails -Properties $props -ResultSize Unlimited)
}
Write-Status ("{0} mailbox(es) to check." -f $mailboxes.Count)
if (-not $mailboxes.Count) { return }

$cache = @{}
function Resolve-Trustee([string]$Name) {
    if (-not $Name) { return '' }
    if ($Name -match '^S-1-5-') { return 'Orphaned SID (deleted user or group)' }
    if ($Name -match '^[^@\s]+@[^@\s]+$') { return $Name }
    if ($cache.ContainsKey($Name)) { return $cache[$Name] }
    $addr = ''
    try {
        $r = Get-EXORecipient -Identity $Name -ErrorAction Stop
        if ($r) { $addr = [string]$r.PrimarySmtpAddress }
    } catch { $addr = '' }
    $cache[$Name] = $addr
    return $addr
}

$rows = [System.Collections.Generic.List[object]]::new()
$n = 0
foreach ($m in $mailboxes) {
    $n++
    Write-Progress -Activity 'Reading mailbox permissions' -Status $m.PrimarySmtpAddress -PercentComplete ($n * 100 / $mailboxes.Count)
    $base = @{ Mailbox = $m.DisplayName; MailboxAddress = [string]$m.PrimarySmtpAddress; MailboxType = [string]$m.RecipientTypeDetails }

    if ($PermissionType -contains 'FullAccess') {
        try {
            foreach ($p in @(Get-EXOMailboxPermission -PrimarySmtpAddress $m.PrimarySmtpAddress -ResultSize Unlimited)) {
                $user = [string]$p.User
                if ($user -eq 'NT AUTHORITY\SELF') { continue }
                if ($p.IsInherited -and -not $IncludeInherited) { continue }
                if (($p.AccessRights -join ',') -notmatch 'FullAccess') { continue }
                $rows.Add([pscustomobject]@{
                    Mailbox = $base.Mailbox; MailboxAddress = $base.MailboxAddress; MailboxType = $base.MailboxType
                    Permission = 'FullAccess'; Trustee = $user; TrusteeAddress = (Resolve-Trustee $user)
                    AccessRights = ($p.AccessRights -join ','); IsInherited = [bool]$p.IsInherited; Deny = [bool]$p.Deny
                })
            }
        } catch { Write-Warning "FullAccess read failed for $($m.PrimarySmtpAddress): $($_.Exception.Message)" }
    }

    if ($PermissionType -contains 'SendAs') {
        try {
            foreach ($p in @(Get-EXORecipientPermission -PrimarySmtpAddress $m.PrimarySmtpAddress -AccessRights SendAs -ResultSize Unlimited)) {
                $user = [string]$p.Trustee
                if ($user -eq 'NT AUTHORITY\SELF') { continue }
                $rows.Add([pscustomobject]@{
                    Mailbox = $base.Mailbox; MailboxAddress = $base.MailboxAddress; MailboxType = $base.MailboxType
                    Permission = 'SendAs'; Trustee = $user; TrusteeAddress = (Resolve-Trustee $user)
                    AccessRights = ($p.AccessRights -join ','); IsInherited = [bool]$p.IsInherited; Deny = ([string]$p.AccessControlType -eq 'Deny')
                })
            }
        } catch { Write-Warning "SendAs read failed for $($m.PrimarySmtpAddress): $($_.Exception.Message)" }
    }

    if ($PermissionType -contains 'SendOnBehalf') {
        foreach ($d in @($m.GrantSendOnBehalfTo | Where-Object { $_ })) {
            $user = [string]$d
            $rows.Add([pscustomobject]@{
                Mailbox = $base.Mailbox; MailboxAddress = $base.MailboxAddress; MailboxType = $base.MailboxType
                Permission = 'SendOnBehalf'; Trustee = $user; TrusteeAddress = (Resolve-Trustee $user)
                AccessRights = 'SendOnBehalf'; IsInherited = $false; Deny = $false
            })
        }
    }
}
Write-Progress -Activity 'Reading mailbox permissions' -Completed

$out = @($rows | Select-Object Mailbox, MailboxAddress, MailboxType, Permission, Trustee, TrusteeAddress, AccessRights, IsInherited, Deny)
if ($Trustee) {
    $t = if ($Trustee -match '[*?]') { $Trustee } else { "*$Trustee*" }
    $out = @($out | Where-Object { $_.Trustee -like $t -or $_.TrusteeAddress -like $t })
}
$out = @($out | Sort-Object MailboxAddress, Permission, Trustee)

if ($CsvPath) {
    $out | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8
    Write-Status ("CSV written: {0} ({1} rows)" -f $CsvPath, $out.Count)
}
$summary = $out | Group-Object Permission | ForEach-Object { "{0} {1}" -f $_.Count, $_.Name }
Write-Status ("Delegations found: {0}" -f $(if ($summary) { $summary -join ', ' } else { 'none' }))

if ($Disconnect) { Disconnect-ExchangeOnline -Confirm:$false }
if ($PassThru) { return $out }
if (-not $CsvPath) { $out | Format-Table Mailbox, Permission, Trustee, TrusteeAddress, MailboxType -AutoSize }
