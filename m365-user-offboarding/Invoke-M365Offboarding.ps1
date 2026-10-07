# Microsoft 365 User Offboarding PowerShell Script (with -WhatIf) (v1.1.0) - from srvScripts.com
# Source, docs and updates: https://srvscripts.com/scripts/m365-user-offboarding/
# Copyright (c) 2026 srvScripts.com. MIT licence: if you copy, share or adapt this script, keep this notice and credit srvScripts.com.
<#
.SYNOPSIS
    Microsoft 365 user offboarding: block sign-in, revoke sessions, optionally convert the mailbox to shared,
    set an auto-reply and forward mail to the manager, remove group memberships and direct licences, with a
    before-snapshot and a log. Shows a plan only unless you add -Apply; use -Apply -WhatIf for a dry run.

.DESCRIPTION
    Default (no -Apply): reads the user, licences, group memberships and (if Exchange steps are requested)
    the mailbox, then prints the plan and writes a snapshot. Nothing is changed.

    With -Apply, steps run in this order. Every change goes through ShouldProcess, so -WhatIf works and
    -Confirm prompts per step (ConfirmImpact High: you are prompted unless you pass -Confirm:$false).
      1. Snapshot  JSON file with the user's licences (direct and group-based), groups and mailbox details.
      2. Block sign-in   PATCH /users/{id} accountEnabled=false. Skipped for users synced from on-premises
                         AD (disable them in AD; the change syncs up).
      3. Revoke sessions POST /users/{id}/revokeSignInSessions (refresh tokens and session cookies).
      4. Convert mailbox Set-Mailbox -Type Shared (only with -ConvertToShared; Exchange Online).
                         Microsoft: the mailbox must still be licensed when converted; an unlicensed shared
                         mailbox is limited to 50 GB; litigation/in-place hold on a shared mailbox needs a licence.
                         Users synced from on-premises AD in an Exchange hybrid are left for manual conversion.
                         After conversion the mailbox is read again to confirm it is now shared.
      5. Auto-reply      Set-MailboxAutoReplyConfiguration (only with -AutoReplyMessage).
      5b. Forwarding     Set-Mailbox -ForwardingAddress <manager> -DeliverToMailboxAndForward $true (only with
                         -ForwardToManager or -ForwardTo). The manager is read from GET /users/{id}/manager.
      5c. Licence plan   Before any group or licence change the licences are read again and the script decides
                         whether the mailbox still needs its Exchange licence. It does when the mailbox was not
                         confirmed as converted to shared (not requested, skipped, failed or declined), is over
                         50 GB, is on any hold (litigation, in-place/eDiscovery, retention policy or label, delay
                         hold), has an archive, or when any of these facts cannot be read (fail closed).
      6. Groups          Security and Microsoft 365 groups: DELETE /groups/{id}/members/{userId}/$ref.
                         Distribution lists and mail-enabled security groups: Remove-DistributionGroupMember
                         (needs the Exchange connection). Dynamic, on-premises-synced and role-assignable
                         groups are skipped and listed for manual follow-up. Groups that assign an Exchange
                         licence the mailbox still needs are kept, unless the user already has an active direct
                         licence with the same Exchange service plans. With -SkipLicenseRemoval every group
                         that assigns a licence is kept.
      7. Licences        Direct-assigned licences only (group-based licences go with the group membership),
                         via POST /users/{id}/assignLicense. Only done when the mailbox no longer needs a
                         licence (step 5c) and was converted to shared, or when -ForceLicenseRemoval is used,
                         because Microsoft deletes a mailbox's mail, contacts and calendar 30 days after its
                         licence is removed.
      8. Log             CSV with every planned/applied/skipped/failed step.

    The script does NOT reset the password, wipe devices, delete the account, change OneDrive access or
    remove admin roles (admin roles are reported as a warning). Microsoft notes that blocking sign-in can
    take up to 24 hours to take effect and recommends a password reset for immediate effect.

    Microsoft Graph permissions (delegated scopes requested by the script):
      Plan only:  User.Read.All, GroupMember.Read.All, LicenseAssignment.Read.All
      -Apply:     User.Read.All, User.EnableDisableAccount.All, User.RevokeSessions.All,
                  LicenseAssignment.ReadWrite.All, GroupMember.ReadWrite.All
      Entra role: User Administrator covers block, revoke, licences and group membership for normal users.
                  To block an administrator, Microsoft lists Privileged Authentication Administrator as the
                  least privileged role.
    App-only (certificate): the same Graph permissions as Application permissions plus Directory.Read.All
    (listing another user's memberOf app-only needs it). Microsoft documents no application permission for
    GET /users/{id}/manager, so with app-only sign-in pass -ForwardTo instead of -ForwardToManager.
    Exchange steps app-only: Exchange.ManageAsApp and an Entra role such as Exchange Administrator on the
    app's service principal, plus -Organization.

.PARAMETER UserPrincipalName     The user to offboard.
.PARAMETER Apply                 Make the changes. Without it the script only shows the plan.
.PARAMETER ConvertToShared       Convert the user's mailbox to a shared mailbox (Exchange Online).
.PARAMETER AutoReplyMessage      Turn on automatic replies with this text (internal and external).
.PARAMETER ExternalAudience      Who gets the external auto-reply: None, Known or All (default All).
.PARAMETER ForwardToManager      Forward new mail to the user's manager (from Entra ID) and keep a copy in the mailbox.
.PARAMETER ForwardTo             Forward new mail to this internal recipient instead (UPN or SMTP address).
.PARAMETER KeepGroup             Group display names or object IDs to leave the user in.
.PARAMETER SkipBlockSignIn       Do not block sign-in.
.PARAMETER SkipRevokeSessions    Do not revoke sessions.
.PARAMETER SkipGroupRemoval      Do not remove group memberships.
.PARAMETER SkipLicenseRemoval    Do not remove licences. Also keeps the user in every group that assigns a licence.
.PARAMETER ForceLicenseRemoval   Remove licences (direct, and Exchange licence groups) even if the mailbox was not
                                 converted to shared. It does not override size, hold, archive or unknown facts.
                                 Needs the Exchange connection to read those facts.
.PARAMETER LogFolder             Folder for the snapshot JSON and log CSV (default: current folder).
.PARAMETER TenantId              Tenant ID or domain (required for app-only sign-in).
.PARAMETER ClientId              App registration (client) ID for app-only sign-in (Graph and Exchange).
.PARAMETER CertificateThumbprint Certificate thumbprint for app-only sign-in.
.PARAMETER Organization          Tenant's initial domain (contoso.onmicrosoft.com) for app-only Exchange sign-in.
.PARAMETER ExchangeAdminUpn      Admin account to pre-fill the interactive Exchange Online sign-in.

.EXAMPLE  .\Invoke-M365Offboarding.ps1 -UserPrincipalName bob@contoso.com
          Plan only: shows what would happen and writes a snapshot.
.EXAMPLE  .\Invoke-M365Offboarding.ps1 -UserPrincipalName bob@contoso.com -ConvertToShared -AutoReplyMessage "Bob has left Contoso. Please email sales@contoso.com." -Apply
.EXAMPLE  .\Invoke-M365Offboarding.ps1 -UserPrincipalName bob@contoso.com -ConvertToShared -ForwardToManager -Apply -WhatIf
.EXAMPLE  .\Invoke-M365Offboarding.ps1 -UserPrincipalName bob@contoso.com -Apply -Confirm:$false -KeepGroup "All Staff Alumni" -SkipLicenseRemoval
.EXAMPLE  .\Invoke-M365Offboarding.ps1 -UserPrincipalName bob@contoso.com -ConvertToShared -Apply -Confirm:$false -TenantId contoso.onmicrosoft.com -ClientId <app-id> -CertificateThumbprint <thumbprint> -Organization contoso.onmicrosoft.com

.NOTES
    Name:     Invoke-M365Offboarding.ps1
    Purpose:  Repeatable, logged Microsoft 365 leaver process (plan first, apply on request)
    Source:   https://srvscripts.com/scripts/m365-user-offboarding/
    License:  MIT
    Version:  1.1.0
    Changes:  1.1.0 - Groups that assign an Exchange licence the mailbox still needs (not converted, over 50 GB,
                      any hold, archive, or unknown facts) are no longer removed; -SkipLicenseRemoval also keeps
                      licence groups; conversion and licences are re-read before group and licence changes.
              1.0.0 - First release.
    Requires: Windows PowerShell 5.1 or PowerShell 7, Microsoft.Graph.Authentication; ExchangeOnlineManagement 3.x
              for -ConvertToShared, -AutoReplyMessage, forwarding, -ForceLicenseRemoval and distribution list removal.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High', DefaultParameterSetName = 'Interactive')]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[^@\s]+@[^@\s]+\.[^@\s]+$')]
    [string]$UserPrincipalName,
    [switch]$Apply,
    [switch]$ConvertToShared,
    [ValidateLength(1, 8000)]
    [string]$AutoReplyMessage,
    [ValidateSet('None', 'Known', 'All')]
    [string]$ExternalAudience = 'All',
    [switch]$ForwardToManager,
    [ValidatePattern('^[^@\s]+@[^@\s]+\.[^@\s]+$')]
    [string]$ForwardTo,
    [string[]]$KeepGroup,
    [switch]$SkipBlockSignIn,
    [switch]$SkipRevokeSessions,
    [switch]$SkipGroupRemoval,
    [switch]$SkipLicenseRemoval,
    [switch]$ForceLicenseRemoval,
    [string]$LogFolder = (Get-Location).Path,
    [Parameter(ParameterSetName = 'Interactive')]
    [Parameter(ParameterSetName = 'AppOnly', Mandatory = $true)]
    [string]$TenantId,
    [Parameter(ParameterSetName = 'AppOnly', Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$ClientId,
    [Parameter(ParameterSetName = 'AppOnly', Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F]{40}$')]
    [string]$CertificateThumbprint,
    [Parameter(ParameterSetName = 'AppOnly')]
    [string]$Organization,
    [Parameter(ParameterSetName = 'Interactive')]
    [string]$ExchangeAdminUpn
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$Graph = 'https://graph.microsoft.com/v1.0'
$SharedLimitBytes = 50GB
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$safeUpn = $UserPrincipalName -replace '[^A-Za-z0-9._-]', '_'
if (-not (Test-Path -LiteralPath $LogFolder)) { throw "Log folder not found: $LogFolder" }
$LogCsv = Join-Path $LogFolder "Offboarding-$safeUpn-$stamp.csv"
$SnapshotJson = Join-Path $LogFolder "Offboarding-$safeUpn-$stamp-before.json"
if ($ForwardToManager -and $ForwardTo) { throw 'Use either -ForwardToManager or -ForwardTo, not both.' }
$needExchange = $ConvertToShared -or [bool]$AutoReplyMessage -or $ForwardToManager -or [bool]$ForwardTo -or $ForceLicenseRemoval

function Write-Status([string]$Message) { Write-Information $Message -InformationAction Continue }

$log = [System.Collections.Generic.List[object]]::new()
function Add-LogEntry([string]$Step, [string]$Target, [string]$Action, [string]$Result, [string]$Detail = '') {
    $e = [pscustomobject]@{ Time = (Get-Date).ToString('s'); User = $UserPrincipalName; Step = $Step; Target = $Target; Action = $Action; Result = $Result; Detail = $Detail }
    $log.Add($e)
    $line = "[{0}] {1}: {2} {3}{4}" -f $Result, $Step, $Action, $Target, $(if ($Detail) { " - $Detail" } else { '' })
    if ($Result -eq 'Failed') { Write-Warning $line } else { Write-Status $line }
}

function Invoke-Graph {
    param([string]$Method = 'GET', [string]$Uri, $Body)
    $attempt = 0
    while ($true) {
        $attempt++
        try {
            $p = @{ Method = $Method; Uri = $Uri; OutputType = 'HashTable'; ErrorAction = 'Stop' }
            if ($null -ne $Body) { $p.Body = ($Body | ConvertTo-Json -Depth 5 -Compress); $p.ContentType = 'application/json' }
            return Invoke-MgGraphRequest @p
        } catch {
            if ($attempt -lt 5 -and $_.Exception.Message -match '429|TooManyRequests|503|ServiceUnavailable|504|GatewayTimeout') {
                Start-Sleep -Seconds ([math]::Pow(2, $attempt) * 5); continue
            }
            throw
        }
    }
}

function Get-GraphCollection([string]$Uri) {
    $next = $Uri
    while ($next) {
        $r = Invoke-Graph -Uri $next
        if ($r['value']) { foreach ($i in $r['value']) { $i } }
        $next = $r['@odata.nextLink']
    }
}

function Get-Value($Hash, [string]$Key) {
    if ($null -ne $Hash -and $Hash.ContainsKey($Key)) { return $Hash[$Key] }
    return $null
}

function Write-LogFile {
    $log | Export-Csv -Path $LogCsv -NoTypeInformation -Encoding UTF8
}

# ---- Licence preservation decisions (1.1.0) ---------------------------------------------------------------
# Exchange mailbox/archive service plans (EXCHANGE_S_STANDARD, _ENTERPRISE, _DESKLESS, _ARCHIVE_ADDON ...).
# EXCHANGE_S_FOUNDATION and EXCHANGE_ANALYTICS give no mailbox.
function Test-ExchangePlanName([string]$Name) {
    return ($Name -like 'EXCHANGE_*' -and $Name -notlike 'EXCHANGE_S_FOUNDATION*' -and $Name -ne 'EXCHANGE_ANALYTICS')
}

# Builds licence rows from Graph licenseAssignmentStates. ExchangePlans lists the enabled Exchange service plans
# of the assignment; $null means unknown (SKU details not readable), which callers treat as Exchange (fail closed).
function Get-LicenseInfo($States, [hashtable]$SkuNames, [hashtable]$SkuPlans) {
    foreach ($l in @($States)) {
        if (-not $l) { continue }
        $sku = [string]$l['skuId']
        $off = @(@(Get-Value $l 'disabledPlans') | Where-Object { $_ } | ForEach-Object { [string]$_ })
        $exo = $null
        if ($SkuPlans.ContainsKey($sku)) { $exo = @($SkuPlans[$sku] | Where-Object { (Test-ExchangePlanName $_.Name) -and $off -notcontains $_.Id } | ForEach-Object { $_.Name }) }
        [pscustomobject]@{
            SkuId = $sku; SkuPartNumber = $(if ($SkuNames.ContainsKey($sku)) { $SkuNames[$sku] } else { '' })
            AssignedByGroup = [string](Get-Value $l 'assignedByGroup'); State = [string](Get-Value $l 'state'); ExchangePlans = $exo
        }
    }
}

# Fresh read of the user's licence assignments. Returns $null when they cannot be read (callers fail closed).
function Read-LicenseState {
    try {
        $u = Invoke-Graph -Uri ("$Graph/users/{0}?`$select=id,licenseAssignmentStates" -f $userId)
        return , @(Get-LicenseInfo (Get-Value $u 'licenseAssignmentStates') $skuNames $skuPlans)
    } catch {
        Write-Warning "Could not re-read the user's licences: $($_.Exception.Message)"
        return $null
    }
}

function Get-MailboxValue($Mailbox, [string]$Name) {
    if ($null -ne $Mailbox -and $Mailbox.PSObject.Properties[$Name]) { return $Mailbox.PSObject.Properties[$Name].Value }
    return $null
}

# Reasons the mailbox still needs its Exchange licence after offboarding. Facts that cannot be read are
# reasons too (Code Unknown). Only NotConverted can be overridden (-ForceLicenseRemoval).
function Get-MailboxLicenseReason($Mailbox, $MailboxBytes, $OrgHolds, [bool]$Converted, [int64]$LimitBytes = 50GB) {
    $r = [System.Collections.Generic.List[object]]::new()
    $add = { param($c, $t) $r.Add([pscustomobject]@{ Code = $c; Text = $t }) }
    if (-not $Converted) { & $add 'NotConverted' 'Mailbox is not confirmed as shared (conversion not requested, skipped, failed or declined); removing its licence deletes mailbox data after 30 days' }
    if (-not $Mailbox) { & $add 'Unknown' 'Mailbox facts unknown (mailbox not read or Exchange Online not connected)'; return $r }
    if ($null -eq $MailboxBytes) { & $add 'Unknown' 'Mailbox size unknown' }
    elseif ($MailboxBytes -gt $LimitBytes) { & $add 'Size' ("Mailbox is {0:N1} GB; an unlicensed shared mailbox is limited to 50 GB" -f ($MailboxBytes / 1GB)) }
    foreach ($n in 'LitigationHoldEnabled', 'ComplianceTagHoldApplied', 'DelayHoldApplied', 'DelayReleaseHoldApplied') {
        $v = "$(Get-MailboxValue $Mailbox $n)"
        if ($v -eq 'True') { & $add 'Hold' "$n is on; a shared mailbox on hold needs a licence" }
        elseif ($v -ne 'False') { & $add 'Unknown' "$n unknown" }
    }
    $mbxHolds = @()
    if (-not $Mailbox.PSObject.Properties['InPlaceHolds']) { & $add 'Unknown' 'InPlaceHolds unknown' }
    else {
        $mbxHolds = @(@(Get-MailboxValue $Mailbox 'InPlaceHolds') | Where-Object { $_ } | ForEach-Object { [string]$_ })
        # Entries starting with '-' are exclusions from an organisation-wide policy, not holds.
        $on = @($mbxHolds | Where-Object { $_ -notlike '-*' })
        if ($on.Count) { & $add 'Hold' ("In-place/eDiscovery hold or retention policy on the mailbox: {0}" -f ($on -join ', ')) }
    }
    if ($null -eq $OrgHolds) { & $add 'Unknown' 'Organisation-wide retention policies unknown (Get-OrganizationConfig not read)' }
    else {
        $org = @(@($OrgHolds) | Where-Object { "$_" -like 'mbx*' } | Where-Object {
                $g = ("$_" -replace '^mbx', '') -replace ':.*$', ''
                -not @($mbxHolds | Where-Object { $_ -like "-mbx$g*" }).Count })
        if ($org.Count) { & $add 'Hold' ("Organisation-wide retention policy covers mailboxes: {0}" -f ($org -join ', ')) }
    }
    $as = "$(Get-MailboxValue $Mailbox 'ArchiveStatus')"
    $ag = "$(Get-MailboxValue $Mailbox 'ArchiveGuid')"
    if (-not $as) { & $add 'Unknown' 'ArchiveStatus unknown' }
    elseif ($as -ne 'None' -or ($ag -and $ag -ne [guid]::Empty.ToString())) { & $add 'Archive' 'Mailbox has an archive; a shared mailbox with an archive needs a licence' }
    return $r
}

# Effective licence-preservation plan, decided before any membership or licence change.
#   Licenses        rows read at the start; CurrentLicenses: rows re-read just before the group phase ($null = re-read failed)
#   ProtectedGroupIds  groups the user must stay in; NeedsLicense: direct licences must not be removed either.
function Get-LicensePreservationPlan($Licenses, $CurrentLicenses, $Reasons, [bool]$ForceRemoval, [bool]$SkipLicenseRemoval) {
    $activeStates = @('Active', 'ActiveWithSolutionUpdate')
    $all = @(@($Licenses) + @($CurrentLicenses) | Where-Object { $_ })
    $exo = @($all | Where-Object { $null -eq $_.ExchangePlans -or @($_.ExchangePlans).Count })
    $needed = @($Reasons | Where-Object { $_ -and -not ($ForceRemoval -and $_.Code -eq 'NotConverted') })
    $needsLicense = ($exo.Count -gt 0 -and $needed.Count -gt 0)
    $exoGroups = @($exo | Where-Object { $_.AssignedByGroup } | ForEach-Object { $_.AssignedByGroup } | Select-Object -Unique)
    $anyGroups = @($all | Where-Object { $_.AssignedByGroup } | ForEach-Object { $_.AssignedByGroup } | Select-Object -Unique)
    # A replacement counts only when the fresh read shows active direct licences that already give every Exchange
    # service plan the licence groups give. The script does not assign replacements itself.
    $verified = $false
    if ($needsLicense -and $exoGroups.Count -and $null -ne $CurrentLicenses) {
        $fromGroups = @($all | Where-Object { $_.AssignedByGroup -and $exoGroups -contains $_.AssignedByGroup })
        $direct = @(@($CurrentLicenses) | Where-Object { $_ -and -not $_.AssignedByGroup -and $activeStates -contains $_.State -and $null -ne $_.ExchangePlans })
        $want = @($fromGroups | ForEach-Object { $_.ExchangePlans } | Select-Object -Unique)
        $have = @($direct | ForEach-Object { $_.ExchangePlans } | Select-Object -Unique)
        $unknown = @($fromGroups | Where-Object { $null -eq $_.ExchangePlans }).Count
        $verified = (-not $unknown -and $want.Count -gt 0 -and -not @($want | Where-Object { $have -notcontains $_ }).Count)
    }
    $protected = @(); $why = ''
    if ($SkipLicenseRemoval) { $protected = $anyGroups; $why = 'Group assigns a licence and -SkipLicenseRemoval is set' }
    elseif ($needsLicense -and -not $verified) {
        $protected = $exoGroups
        $why = 'Group assigns an Exchange licence the mailbox still needs (see LicensePlan); assign and verify a direct licence with the same Exchange plans first, or remove the membership later'
    }
    [pscustomobject]@{
        NeedsLicense = $needsLicense; Reasons = @($(if ($needsLicense) { $needed | ForEach-Object { $_.Text } }))
        ExchangeLicenseGroupIds = $exoGroups; ReplacementVerified = $verified; ProtectedGroupIds = @($protected); ProtectReason = $why
    }
}

# ---- Connect to Microsoft Graph ---------------------------------------------------------------------------
foreach ($m in @('Microsoft.Graph.Authentication') + $(if ($needExchange) { 'ExchangeOnlineManagement' } else { @() })) {
    if (-not (Get-Module -ListAvailable -Name $m)) { throw "Module $m is not installed. Run: Install-Module $m -Scope CurrentUser" }
}
Import-Module Microsoft.Graph.Authentication
if ($PSCmdlet.ParameterSetName -eq 'AppOnly') {
    Connect-MgGraph -TenantId $TenantId -ClientId $ClientId -CertificateThumbprint $CertificateThumbprint -NoWelcome
} else {
    $scopes = if ($Apply) {
        'User.Read.All', 'User.EnableDisableAccount.All', 'User.RevokeSessions.All', 'LicenseAssignment.ReadWrite.All', 'GroupMember.ReadWrite.All'
    } else {
        'User.Read.All', 'GroupMember.Read.All', 'LicenseAssignment.Read.All'
    }
    $cp = @{ Scopes = @($scopes); NoWelcome = $true }
    if ($TenantId) { $cp.TenantId = $TenantId }
    Connect-MgGraph @cp
}

# ---- Read current state -----------------------------------------------------------------------------------
$sel = 'id,displayName,userPrincipalName,mail,userType,accountEnabled,onPremisesSyncEnabled,assignedLicenses,licenseAssignmentStates'
try {
    $user = Invoke-Graph -Uri ("$Graph/users/{0}?`$select={1}" -f [uri]::EscapeDataString($UserPrincipalName), $sel)
} catch {
    throw "Cannot read user ${UserPrincipalName}: $($_.Exception.Message)"
}
$userId = [string]$user['id']
$isSynced = [bool](Get-Value $user 'onPremisesSyncEnabled')

$skuNames = @{}; $skuPlans = @{}
try {
    foreach ($s in (Get-GraphCollection "$Graph/subscribedSkus")) {
        $skuNames[[string]$s['skuId']] = [string]$s['skuPartNumber']
        $skuPlans[[string]$s['skuId']] = @(foreach ($p in @(Get-Value $s 'servicePlans')) { if ($p) { [pscustomobject]@{ Id = [string]$p['servicePlanId']; Name = [string]$p['servicePlanName'] } } })
    }
} catch { Write-Warning "subscribedSkus not readable ($($_.Exception.Message)); every licence is treated as an Exchange licence" }

$licenses = @(Get-LicenseInfo (Get-Value $user 'licenseAssignmentStates') $skuNames $skuPlans)
$directSkus = @($licenses | Where-Object { -not $_.AssignedByGroup } | Select-Object -ExpandProperty SkuId -Unique)

$memberOf = @(Get-GraphCollection ("$Graph/users/{0}/memberOf" -f $userId))
$groups = @($memberOf | Where-Object { $_['@odata.type'] -eq '#microsoft.graph.group' } | ForEach-Object {
        $gt = @(Get-Value $_ 'groupTypes')
        [pscustomobject]@{
            Id = [string]$_['id']; DisplayName = [string](Get-Value $_ 'displayName'); Mail = [string](Get-Value $_ 'mail')
            IsUnified = ($gt -contains 'Unified'); IsDynamic = ($gt -contains 'DynamicMembership')
            MailEnabled = [bool](Get-Value $_ 'mailEnabled'); SecurityEnabled = [bool](Get-Value $_ 'securityEnabled')
            OnPremSynced = [bool](Get-Value $_ 'onPremisesSyncEnabled'); RoleAssignable = [bool](Get-Value $_ 'isAssignableToRole')
        }
    })
$roles = @($memberOf | Where-Object { $_['@odata.type'] -eq '#microsoft.graph.directoryRole' })

$forwardTarget = $null; $forwardNote = ''
if ($ForwardTo) { $forwardTarget = $ForwardTo }
elseif ($ForwardToManager) {
    try {
        $mgr = Invoke-Graph -Uri ("$Graph/users/{0}/manager?`$select=id,displayName,userPrincipalName,mail" -f $userId)
        $forwardTarget = if (Get-Value $mgr 'mail') { [string]$mgr['mail'] } else { [string](Get-Value $mgr 'userPrincipalName') }
    } catch {
        $forwardNote = if ($_.Exception.Message -match 'NotFound|404|does not exist') { 'No manager is set on the user in Entra ID; use -ForwardTo' }
        else { "Could not read the manager ($($_.Exception.Message)); use -ForwardTo" }
    }
}

# ---- Exchange Online --------------------------------------------------------------------------------------
$mailbox = $null; $mailboxBytes = $null; $orgHolds = $null; $exoConnected = $false
if ($needExchange -or ($groups | Where-Object { $_.MailEnabled -and -not $_.IsUnified })) {
    if (Get-Module -ListAvailable -Name ExchangeOnlineManagement) {
        Import-Module ExchangeOnlineManagement
        $existing = @(Get-ConnectionInformation -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Connected' -and $_.Name -like 'ExchangeOnline_*' })
        if ($existing) { $exoConnected = $true }
        elseif ($needExchange) {
            $c = @{ ShowBanner = $false }
            if ($PSCmdlet.ParameterSetName -eq 'AppOnly') {
                if (-not $Organization) { throw 'App-only Exchange steps need -Organization (the tenant''s initial domain, e.g. contoso.onmicrosoft.com).' }
                $c.AppId = $ClientId; $c.CertificateThumbprint = $CertificateThumbprint; $c.Organization = $Organization
            } elseif ($ExchangeAdminUpn) { $c.UserPrincipalName = $ExchangeAdminUpn }
            Connect-ExchangeOnline @c
            $exoConnected = $true
        }
    }
    if ($exoConnected) {
        try {
            $mailbox = Get-EXOMailbox -Identity $UserPrincipalName -Properties LitigationHoldEnabled, InPlaceHolds, ComplianceTagHoldApplied, DelayHoldApplied, DelayReleaseHoldApplied, ArchiveStatus, ArchiveGuid, RecipientTypeDetails, ForwardingAddress, ForwardingSmtpAddress, DeliverToMailboxAndForward -ErrorAction Stop
            $stats = Get-EXOMailboxStatistics -Identity $UserPrincipalName -ErrorAction Stop
            if ("$($stats.TotalItemSize)" -match '\(([\d,\.]+) bytes\)') { $mailboxBytes = [int64]($Matches[1] -replace '[,\.]', '') }
        } catch {
            Write-Warning "Could not read the mailbox: $($_.Exception.Message)"
        }
        # Organisation-wide retention policies (not listed on the mailbox). Unreadable = unknown = licences kept.
        try { $orgHolds = @(@((Get-OrganizationConfig -ErrorAction Stop).InPlaceHolds) | Where-Object { $_ } | ForEach-Object { [string]$_ }) }
        catch { Write-Warning "Could not read organisation-wide holds: $($_.Exception.Message)" }
    }
}

# ---- Snapshot -----------------------------------------------------------------------------------------------
$snapshot = [ordered]@{
    TakenAt = (Get-Date).ToString('o'); UserPrincipalName = $UserPrincipalName; Id = $userId
    DisplayName = Get-Value $user 'displayName'; AccountEnabled = Get-Value $user 'accountEnabled'; OnPremisesSynced = $isSynced
    Licenses = $licenses; Groups = $groups; DirectoryRoles = @($roles | ForEach-Object { [string](Get-Value $_ 'displayName') })
    MailboxType = $(if ($mailbox) { [string]$mailbox.RecipientTypeDetails } else { $null })
    MailboxSizeBytes = $mailboxBytes; LitigationHold = $(if ($mailbox) { [bool]$mailbox.LitigationHoldEnabled } else { $null })
    InPlaceHolds = @(@(Get-MailboxValue $mailbox 'InPlaceHolds') | Where-Object { $_ } | ForEach-Object { [string]$_ })
    ArchiveStatus = [string](Get-MailboxValue $mailbox 'ArchiveStatus'); OrganizationHolds = $orgHolds
    ForwardingAddress = $(if ($mailbox) { [string]$mailbox.ForwardingAddress } else { $null })
    ForwardingSmtpAddress = $(if ($mailbox) { [string]$mailbox.ForwardingSmtpAddress } else { $null })
    DeliverToMailboxAndForward = $(if ($mailbox) { [bool]$mailbox.DeliverToMailboxAndForward } else { $null })
    PlannedForwardTarget = $forwardTarget
}
$snapshot | ConvertTo-Json -Depth 5 | Out-File -FilePath $SnapshotJson -Encoding UTF8
Write-Status "Snapshot written: $SnapshotJson"

Write-Status ("User: {0} ({1}), enabled={2}, synced from AD={3}" -f (Get-Value $user 'displayName'), $UserPrincipalName, (Get-Value $user 'accountEnabled'), $isSynced)
Write-Status ("Licences: {0} direct, {1} via group. Groups: {2}. Admin roles: {3}." -f $directSkus.Count, @($licenses | Where-Object { $_.AssignedByGroup }).Count, $groups.Count, $roles.Count)
if ($roles.Count) { Write-Warning ("User holds directory role(s): {0}. Remove them separately (and check PIM eligible assignments)." -f (($roles | ForEach-Object { Get-Value $_ 'displayName' }) -join ', ')) }
if (-not $Apply) { Write-Status 'PLAN ONLY - nothing will be changed. Add -Apply to run these steps (use -WhatIf with -Apply for a dry run of the apply path).' }

function Invoke-Step {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param([string]$Step, [string]$Target, [string]$Action, [scriptblock]$Do)
    if (-not $Apply) { Add-LogEntry $Step $Target $Action 'Planned'; return $true }
    if (-not $PSCmdlet.ShouldProcess("$Target", $Action)) { Add-LogEntry $Step $Target $Action 'NotRun (WhatIf/declined)'; return $false }
    try { $null = & $Do; Add-LogEntry $Step $Target $Action 'Done'; return $true }
    catch { Add-LogEntry $Step $Target $Action 'Failed' $_.Exception.Message; return $false }
}

try {
    # 2. Block sign-in
    if ($SkipBlockSignIn) { Add-LogEntry 'BlockSignIn' $UserPrincipalName 'Block sign-in' 'Skipped' '-SkipBlockSignIn' }
    elseif ($isSynced) { Add-LogEntry 'BlockSignIn' $UserPrincipalName 'Block sign-in' 'Skipped' 'Synced from on-premises AD: disable the account in AD' }
    elseif ((Get-Value $user 'accountEnabled') -eq $false) { Add-LogEntry 'BlockSignIn' $UserPrincipalName 'Block sign-in' 'Skipped' 'Already blocked' }
    else {
        [void](Invoke-Step 'BlockSignIn' $UserPrincipalName 'Block sign-in (accountEnabled=false)' {
                Invoke-Graph -Method PATCH -Uri "$Graph/users/$userId" -Body @{ accountEnabled = $false } | Out-Null })
    }

    # 3. Revoke sessions
    if ($SkipRevokeSessions) { Add-LogEntry 'RevokeSessions' $UserPrincipalName 'Revoke sign-in sessions' 'Skipped' '-SkipRevokeSessions' }
    else {
        [void](Invoke-Step 'RevokeSessions' $UserPrincipalName 'Revoke sign-in sessions' {
                Invoke-Graph -Method POST -Uri "$Graph/users/$userId/revokeSignInSessions" | Out-Null })
    }

    # 4. Convert mailbox to shared
    $converted = $false
    if ($ConvertToShared) {
        if (-not $mailbox) { Add-LogEntry 'ConvertMailbox' $UserPrincipalName 'Convert to shared mailbox' 'Skipped' 'No mailbox found or Exchange Online not connected' }
        elseif ([string]$mailbox.RecipientTypeDetails -eq 'SharedMailbox') { $converted = $true; Add-LogEntry 'ConvertMailbox' $UserPrincipalName 'Convert to shared mailbox' 'Skipped' 'Already a shared mailbox' }
        elseif ($isSynced) { Add-LogEntry 'ConvertMailbox' $UserPrincipalName 'Convert to shared mailbox' 'Manual' 'User is synced from on-premises AD: in an Exchange hybrid convert the remote mailbox on-premises so directory sync does not turn it back into a user mailbox' }
        elseif ($directSkus.Count -eq 0 -and @($licenses).Count -eq 0) { Add-LogEntry 'ConvertMailbox' $UserPrincipalName 'Convert to shared mailbox' 'Skipped' 'User has no licence; Microsoft requires a licence on the mailbox to convert it' }
        else {
            $converted = Invoke-Step 'ConvertMailbox' $UserPrincipalName 'Convert to shared mailbox (Set-Mailbox -Type Shared)' {
                Set-Mailbox -Identity $UserPrincipalName -Type Shared -Confirm:$false -ErrorAction Stop }
            if ($converted -and $Apply) {
                # Re-read the recipient: only a confirmed shared mailbox lets licences go.
                try { $converted = ([string](Get-EXOMailbox -Identity $UserPrincipalName -Properties RecipientTypeDetails -ErrorAction Stop).RecipientTypeDetails -eq 'SharedMailbox') }
                catch { $converted = $false }
                if (-not $converted) { Add-LogEntry 'ConvertMailbox' $UserPrincipalName 'Verify shared mailbox' 'Warning' 'Could not confirm the mailbox is now shared; licences and licence groups are kept' }
            }
        }
    }

    # 5. Auto-reply
    if ($AutoReplyMessage) {
        if (-not $mailbox) { Add-LogEntry 'AutoReply' $UserPrincipalName 'Set automatic replies' 'Skipped' 'No mailbox found or Exchange Online not connected' }
        else {
            [void](Invoke-Step 'AutoReply' $UserPrincipalName "Set automatic replies (external audience: $ExternalAudience)" {
                    Set-MailboxAutoReplyConfiguration -Identity $UserPrincipalName -AutoReplyState Enabled -InternalMessage $AutoReplyMessage -ExternalMessage $AutoReplyMessage -ExternalAudience $ExternalAudience -Confirm:$false -ErrorAction Stop })
        }
    }

    # 5b. Forwarding
    if ($ForwardToManager -or $ForwardTo) {
        if (-not $forwardTarget) { Add-LogEntry 'Forwarding' $UserPrincipalName 'Forward mail' 'Skipped' $forwardNote }
        elseif (-not $mailbox) { Add-LogEntry 'Forwarding' $UserPrincipalName 'Forward mail' 'Skipped' 'No mailbox found or Exchange Online not connected' }
        else {
            if ([string]$mailbox.ForwardingSmtpAddress) {
                Add-LogEntry 'Forwarding' $UserPrincipalName 'Existing forward' 'Warning' ("ForwardingSmtpAddress is already set to {0}; check it, it can override the new forward" -f $mailbox.ForwardingSmtpAddress)
            }
            [void](Invoke-Step 'Forwarding' $UserPrincipalName "Forward new mail to $forwardTarget (keep a copy)" {
                    Set-Mailbox -Identity $UserPrincipalName -ForwardingAddress $forwardTarget -DeliverToMailboxAndForward $true -Confirm:$false -ErrorAction Stop })
        }
    }

    # 5c. Licence preservation plan: decided here, before any group membership or licence change
    if ($Apply) { $currentLicenses = Read-LicenseState } else { $currentLicenses = $licenses }
    $mbxReasons = @(Get-MailboxLicenseReason $mailbox $mailboxBytes $orgHolds ([bool]$converted) $SharedLimitBytes)
    $licensePlan = Get-LicensePreservationPlan $licenses $currentLicenses $mbxReasons ([bool]$ForceLicenseRemoval) ([bool]$SkipLicenseRemoval)
    foreach ($t in $licensePlan.Reasons) { Add-LogEntry 'LicensePlan' $UserPrincipalName 'Mailbox needs a licence' 'Warning' $t }
    if ($licensePlan.ProtectedGroupIds.Count) {
        Add-LogEntry 'LicensePlan' $UserPrincipalName 'Keep licence groups' 'Info' ("{0} group(s) kept: {1}" -f $licensePlan.ProtectedGroupIds.Count, $licensePlan.ProtectReason)
    } elseif ($licensePlan.ReplacementVerified) {
        Add-LogEntry 'LicensePlan' $UserPrincipalName 'Keep licence groups' 'Info' 'Active direct licences already give the Exchange plans of the licence groups; groups can be left, direct licences are kept'
    }

    # 6. Groups
    foreach ($g in $groups) {
        $name = if ($g.DisplayName) { $g.DisplayName } else { $g.Id }
        if ($SkipGroupRemoval) { Add-LogEntry 'Groups' $name 'Remove membership' 'Skipped' '-SkipGroupRemoval'; continue }
        if ($KeepGroup -and ($KeepGroup -contains $g.Id -or $KeepGroup -contains $g.DisplayName)) { Add-LogEntry 'Groups' $name 'Remove membership' 'Skipped' 'In -KeepGroup'; continue }
        if ($licensePlan.ProtectedGroupIds -contains $g.Id) { Add-LogEntry 'Groups' $name 'Remove membership' 'Skipped' $licensePlan.ProtectReason; continue }
        if ($g.IsDynamic) { Add-LogEntry 'Groups' $name 'Remove membership' 'Manual' 'Dynamic group: membership follows its rule'; continue }
        if ($g.OnPremSynced) { Add-LogEntry 'Groups' $name 'Remove membership' 'Manual' 'Group is synced from on-premises AD: remove the member in AD'; continue }
        if ($g.RoleAssignable) { Add-LogEntry 'Groups' $name 'Remove membership' 'Manual' 'Role-assignable group: needs Privileged Role Administrator'; continue }
        if ($g.MailEnabled -and -not $g.IsUnified) {
            if (-not $exoConnected) { Add-LogEntry 'Groups' $name 'Remove membership' 'Manual' 'Distribution list or mail-enabled security group: needs Exchange Online (run with -ConvertToShared/-AutoReplyMessage or remove in the EAC)'; continue }
            $gid = if ($g.Mail) { $g.Mail } else { $g.DisplayName }
            [void](Invoke-Step 'Groups' $name 'Remove membership (Remove-DistributionGroupMember)' {
                    Remove-DistributionGroupMember -Identity $gid -Member $UserPrincipalName -BypassSecurityGroupManagerCheck -Confirm:$false -ErrorAction Stop })
            continue
        }
        # Graph: the /$ref suffix is essential. Without it the DELETE targets the user object itself.
        $refUri = ('{0}/groups/{1}/members/{2}/$ref' -f $Graph, $g.Id, $userId)
        if ($refUri -notmatch '/members/[0-9a-fA-F-]{36}/\$ref$') { Add-LogEntry 'Groups' $name 'Remove membership' 'Failed' "Refusing to call unexpected URI $refUri"; continue }
        [void](Invoke-Step 'Groups' $name 'Remove membership (Graph)' {
                Invoke-Graph -Method DELETE -Uri $refUri | Out-Null })
    }

    # 7. Licences (direct only). Re-read first when the mailbox still needs a licence, to report whether it kept one.
    if ($Apply -and $licensePlan.NeedsLicense) {
        $after = Read-LicenseState
        if ($null -ne $after -and -not @($after | Where-Object { @('Active', 'ActiveWithSolutionUpdate') -contains $_.State -and ($null -eq $_.ExchangePlans -or @($_.ExchangePlans).Count) }).Count) {
            Add-LogEntry 'LicensePlan' $UserPrincipalName 'Verify mailbox licence' 'Failed' 'No active Exchange licence is left on a mailbox that needs one; assign one within 30 days'
        }
    }
    if ($SkipLicenseRemoval) { Add-LogEntry 'Licenses' $UserPrincipalName 'Remove direct licences' 'Skipped' '-SkipLicenseRemoval' }
    elseif ($directSkus.Count -eq 0) { Add-LogEntry 'Licenses' $UserPrincipalName 'Remove direct licences' 'Skipped' 'No direct licences (group-based licences follow group membership)' }
    elseif ($licensePlan.NeedsLicense) { Add-LogEntry 'Licenses' $UserPrincipalName 'Remove direct licences' 'Skipped' 'Mailbox still needs a licence (see LicensePlan)' }
    elseif (-not $ForceLicenseRemoval -and -not ($ConvertToShared -and ($converted -or -not $Apply))) {
        Add-LogEntry 'Licenses' $UserPrincipalName 'Remove direct licences' 'Skipped' 'Mailbox not converted to shared; removing licences deletes mailbox data after 30 days. Use -ConvertToShared or -ForceLicenseRemoval'
    } else {
        $names = ($directSkus | ForEach-Object { if ($skuNames.ContainsKey($_)) { $skuNames[$_] } else { $_ } }) -join ', '
        [void](Invoke-Step 'Licenses' $UserPrincipalName "Remove direct licences: $names" {
                Invoke-Graph -Method POST -Uri "$Graph/users/$userId/assignLicense" -Body @{ addLicenses = @(); removeLicenses = @($directSkus) } | Out-Null })
    }
    foreach ($l in @($licenses | Where-Object { $_.AssignedByGroup })) {
        Add-LogEntry 'Licenses' $(if ($l.SkuPartNumber) { $l.SkuPartNumber } else { $l.SkuId }) 'Group-based licence' 'Info' "Assigned by group $($l.AssignedByGroup); removed when the user leaves that group"
    }
} finally {
    Write-LogFile
    Write-Status "Log written: $LogCsv"
}
$failed = @($log | Where-Object { $_.Result -eq 'Failed' }).Count
$manual = @($log | Where-Object { $_.Result -eq 'Manual' }).Count
Write-Status ("Finished. Failed: {0}. Manual follow-up: {1}." -f $failed, $manual)
