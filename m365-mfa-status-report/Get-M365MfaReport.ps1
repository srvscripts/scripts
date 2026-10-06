# Microsoft 365 MFA Status Report: PowerShell Script for Graph (v1.0.0) - from srvScripts.com
# Source, docs and updates: https://srvscripts.com/scripts/m365-mfa-status-report/
# Copyright (c) 2026 srvScripts.com. MIT licence: if you copy, share or adapt this script, keep this notice and credit srvScripts.com.
<#
.SYNOPSIS
    Microsoft 365 MFA status report: registered authentication methods, MFA capability, admin flag,
    licence state and last sign-in for every user, exported to CSV and/or HTML.

.DESCRIPTION
    Read-only. Uses Microsoft Graph through the Microsoft.Graph.Authentication module (Connect-MgGraph and
    Invoke-MgGraphRequest), so only one small module is needed.

    Data sources:
      Report mode   GET /reports/authenticationMethods/userRegistrationDetails
                    One call per 1,000-ish users. Gives methodsRegistered, isMfaRegistered, isMfaCapable,
                    isPasswordlessCapable, isSsprRegistered, isAdmin, default and system-preferred method.
                    Needs a Microsoft Entra ID P1 or P2 licence in the tenant. Disabled users are not included.
      PerUser mode  GET /users/{id}/authentication/methods for each user (slow on big tenants, no P1 needed).
                    MFA columns are derived from the method types; admin flag comes from active directory
                    role members (PIM-eligible assignments are not counted).
      Auto          (default) Report mode, falling back to PerUser mode if the report call is refused.

    User details (type, enabled, licences, last sign-in) come from GET /users. signInActivity also needs
    Entra ID P1/P2 and AuditLog.Read.All; if it is refused, the sign-in columns are left empty and a warning
    is shown.

    Delegated (interactive) scopes requested:
      User.Read.All, AuditLog.Read.All                         always
      UserAuthenticationMethod.Read.All, RoleManagement.Read.Directory   Auto and PerUser modes
    Entra role for the signed-in admin: Reports Reader, Security Reader or Global Reader for the report;
    Global Reader or Authentication Administrator for per-user method reads.
    App-only (certificate): grant the same permissions as Application permissions with admin consent.

.PARAMETER Source              Auto (default), Report or PerUser. See DESCRIPTION.
.PARAMETER UserPrincipalName   Only report these users (UPNs). Default: all users.
.PARAMETER UserType            Member (default), Guest or All.
.PARAMETER IncludeDisabled     Include disabled accounts (Report mode returns no method data for them).
.PARAMETER NotMfaCapableOnly   Only output users who are not MFA capable/registered.
.PARAMETER AdminsOnly          Only output users flagged as admins.
.PARAMETER SkipSignInActivity  Do not request signInActivity (use on tenants without Entra ID P1/P2).
.PARAMETER CsvPath             Write the report to this CSV file.
.PARAMETER HtmlPath            Write the report to this HTML file.
.PARAMETER PassThru            Output the result objects to the pipeline.
.PARAMETER TenantId            Tenant ID or domain. Required for app-only sign-in.
.PARAMETER ClientId            App registration (client) ID for app-only sign-in.
.PARAMETER CertificateThumbprint  Thumbprint of the app's certificate (installed in the certificate store of the account running the script).

.EXAMPLE  .\Get-M365MfaReport.ps1 -CsvPath .\mfa.csv
.EXAMPLE  .\Get-M365MfaReport.ps1 -AdminsOnly -NotMfaCapableOnly -HtmlPath .\admins-without-mfa.html
.EXAMPLE  .\Get-M365MfaReport.ps1 -UserType All -Source PerUser -SkipSignInActivity -CsvPath .\mfa.csv
.EXAMPLE  .\Get-M365MfaReport.ps1 -TenantId contoso.onmicrosoft.com -ClientId <app-id> -CertificateThumbprint <thumbprint> -CsvPath C:\Reports\mfa.csv

.NOTES
    Name:     Get-M365MfaReport.ps1
    Purpose:  Per-user MFA / authentication method status for Microsoft 365 / Entra ID
    Source:   https://srvscripts.com/scripts/m365-mfa-status-report/
    License:  MIT
    Version:  1.0.0
    Requires: Windows PowerShell 5.1 or PowerShell 7, module Microsoft.Graph.Authentication
              (Install-Module Microsoft.Graph.Authentication -Scope CurrentUser).
#>
[CmdletBinding(DefaultParameterSetName = 'Interactive')]
param(
    [ValidateSet('Auto', 'Report', 'PerUser')]
    [string]$Source = 'Auto',
    [string[]]$UserPrincipalName,
    [ValidateSet('Member', 'Guest', 'All')]
    [string]$UserType = 'Member',
    [switch]$IncludeDisabled,
    [switch]$NotMfaCapableOnly,
    [switch]$AdminsOnly,
    [switch]$SkipSignInActivity,
    [string]$CsvPath,
    [string]$HtmlPath,
    [switch]$PassThru,
    [Parameter(ParameterSetName = 'Interactive')]
    [Parameter(ParameterSetName = 'AppOnly', Mandatory = $true)]
    [string]$TenantId,
    [Parameter(ParameterSetName = 'AppOnly', Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$ClientId,
    [Parameter(ParameterSetName = 'AppOnly', Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F]{40}$')]
    [string]$CertificateThumbprint
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$Graph = 'https://graph.microsoft.com/v1.0'

function Write-Status([string]$Message) { Write-Information $Message -InformationAction Continue }

function Invoke-GraphWithRetry {
    param([string]$Uri, [string]$Method = 'GET', [hashtable]$Headers)
    $attempt = 0
    while ($true) {
        $attempt++
        try {
            $p = @{ Method = $Method; Uri = $Uri; OutputType = 'HashTable'; ErrorAction = 'Stop' }
            if ($Headers) { $p.Headers = $Headers }
            return Invoke-MgGraphRequest @p
        } catch {
            $msg = $_.Exception.Message
            if ($attempt -lt 5 -and $msg -match '429|TooManyRequests|503|ServiceUnavailable|504|GatewayTimeout') {
                $wait = [math]::Pow(2, $attempt) * 5
                Write-Verbose "Graph throttled or busy, waiting $wait s (attempt $attempt)."
                Start-Sleep -Seconds $wait
                continue
            }
            throw
        }
    }
}

function Get-GraphCollection {
    param([string]$Uri, [hashtable]$Headers)
    $next = $Uri
    while ($next) {
        $r = Invoke-GraphWithRetry -Uri $next -Headers $Headers
        if ($r['value']) { foreach ($i in $r['value']) { $i } }
        $next = $r['@odata.nextLink']
    }
}

function Get-Value($Hash, [string]$Key) {
    if ($null -ne $Hash -and $Hash.ContainsKey($Key)) { return $Hash[$Key] }
    return $null
}

# ---- Connect --------------------------------------------------------------------------------------------
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
    throw 'Module Microsoft.Graph.Authentication is not installed. Run: Install-Module Microsoft.Graph.Authentication -Scope CurrentUser'
}
Import-Module Microsoft.Graph.Authentication

$scopes = @('User.Read.All', 'AuditLog.Read.All')
if ($Source -ne 'Report') { $scopes += 'UserAuthenticationMethod.Read.All', 'RoleManagement.Read.Directory' }

if ($PSCmdlet.ParameterSetName -eq 'AppOnly') {
    Connect-MgGraph -TenantId $TenantId -ClientId $ClientId -CertificateThumbprint $CertificateThumbprint -NoWelcome
} else {
    $cp = @{ Scopes = $scopes; NoWelcome = $true }
    if ($TenantId) { $cp.TenantId = $TenantId }
    Connect-MgGraph @cp
}
$ctx = Get-MgContext
if (-not $ctx) { throw 'Not connected to Microsoft Graph.' }
Write-Status ("Connected to tenant {0} as {1}" -f $ctx.TenantId, $(if ($ctx.Account) { $ctx.Account } else { "app $($ctx.ClientId)" }))

# ---- Users ----------------------------------------------------------------------------------------------
$select = 'id,displayName,userPrincipalName,userType,accountEnabled,assignedLicenses'
$withSignIn = -not $SkipSignInActivity
$users = @()
if ($UserPrincipalName) {
    foreach ($upn in $UserPrincipalName) {
        $sel = if ($withSignIn) { "$select,signInActivity" } else { $select }
        try {
            $users += Invoke-GraphWithRetry -Uri ("$Graph/users/{0}?`$select={1}" -f [uri]::EscapeDataString($upn), $sel)
        } catch {
            if ($withSignIn -and $_.Exception.Message -match 'Forbidden|403|premium|license') {
                Write-Warning 'signInActivity was refused (needs Entra ID P1/P2 and AuditLog.Read.All). Sign-in columns will be empty.'
                $withSignIn = $false
                $users += Invoke-GraphWithRetry -Uri ("$Graph/users/{0}?`$select={1}" -f [uri]::EscapeDataString($upn), $select)
            } elseif ($_.Exception.Message -match 'NotFound|404|does not exist') {
                Write-Warning "User not found: $upn"
            } else { throw }
        }
    }
} else {
    try {
        $sel = if ($withSignIn) { "$select,signInActivity" } else { $select }
        $top = if ($withSignIn) { 500 } else { 999 }
        $users = @(Get-GraphCollection -Uri "$Graph/users?`$select=$sel&`$top=$top")
    } catch {
        if ($withSignIn -and $_.Exception.Message -match 'Forbidden|403|premium|license') {
            Write-Warning 'signInActivity was refused (needs Entra ID P1/P2 and AuditLog.Read.All). Sign-in columns will be empty.'
            $withSignIn = $false
            $users = @(Get-GraphCollection -Uri "$Graph/users?`$select=$select&`$top=999")
        } else { throw }
    }
}
if ($UserType -ne 'All') { $users = @($users | Where-Object { (Get-Value $_ 'userType') -eq $UserType }) }
if (-not $IncludeDisabled) { $users = @($users | Where-Object { (Get-Value $_ 'accountEnabled') -ne $false }) }
Write-Status ("{0} user(s) in scope." -f $users.Count)
if (-not $users.Count) { return }

# ---- Registration data ------------------------------------------------------------------------------------
$reg = @{}
$mode = $Source
if ($Source -in 'Auto', 'Report') {
    try {
        foreach ($r in (Get-GraphCollection -Uri "$Graph/reports/authenticationMethods/userRegistrationDetails")) { $reg[$r['id']] = $r }
        $mode = 'Report'
    } catch {
        if ($Source -eq 'Report') {
            throw "userRegistrationDetails failed: $($_.Exception.Message). It needs Entra ID P1/P2, AuditLog.Read.All and a Reports Reader / Security Reader / Global Reader role."
        }
        Write-Warning "userRegistrationDetails is not available ($($_.Exception.Message)). Falling back to per-user method reads (slower)."
        $mode = 'PerUser'
    }
}

$admins = @{}
if ($mode -eq 'PerUser') {
    foreach ($role in (Get-GraphCollection -Uri "$Graph/directoryRoles?`$select=id,displayName")) {
        foreach ($m in (Get-GraphCollection -Uri ("$Graph/directoryRoles/{0}/members?`$select=id" -f $role['id']))) {
            $admins[$m['id']] = $true
        }
    }
}

# Method types that count as a second factor in PerUser mode (password, email and TAP do not).
$mfaTypes = 'microsoftAuthenticator', 'phone', 'fido2', 'softwareOath', 'windowsHelloForBusiness', 'platformCredential', 'external'
$passwordlessTypes = 'fido2', 'windowsHelloForBusiness', 'platformCredential'

# ---- Build rows -------------------------------------------------------------------------------------------
$rows = [System.Collections.Generic.List[object]]::new()
$i = 0
foreach ($u in $users) {
    $i++
    if ($mode -eq 'PerUser') { Write-Progress -Activity 'Reading authentication methods' -Status (Get-Value $u 'userPrincipalName') -PercentComplete ($i * 100 / $users.Count) }
    $sia = Get-Value $u 'signInActivity'
    $lic = @(Get-Value $u 'assignedLicenses')
    $licCount = @($lic | Where-Object { $_ }).Count
    $row = [ordered]@{
        DisplayName              = Get-Value $u 'displayName'
        UserPrincipalName        = Get-Value $u 'userPrincipalName'
        UserType                 = Get-Value $u 'userType'
        AccountEnabled           = Get-Value $u 'accountEnabled'
        IsLicensed               = ($licCount -gt 0)
        LicenseCount             = $licCount
        IsAdmin                  = $null
        IsMfaRegistered          = $null
        IsMfaCapable             = $null
        IsPasswordlessCapable    = $null
        IsSsprRegistered         = $null
        DefaultMfaMethod         = ''
        SystemPreferredMethods   = ''
        MethodsRegistered        = ''
        LastSignIn               = Get-Value $sia 'lastSignInDateTime'
        LastSuccessfulSignIn     = Get-Value $sia 'lastSuccessfulSignInDateTime'
        LastNonInteractiveSignIn = Get-Value $sia 'lastNonInteractiveSignInDateTime'
        ReportUpdated            = $null
        Source                   = $mode
    }
    if ($mode -eq 'Report') {
        $r = $reg[(Get-Value $u 'id')]
        if ($r) {
            $row.IsAdmin = Get-Value $r 'isAdmin'
            $row.IsMfaRegistered = Get-Value $r 'isMfaRegistered'
            $row.IsMfaCapable = Get-Value $r 'isMfaCapable'
            $row.IsPasswordlessCapable = Get-Value $r 'isPasswordlessCapable'
            $row.IsSsprRegistered = Get-Value $r 'isSsprRegistered'
            $row.DefaultMfaMethod = [string](Get-Value $r 'userPreferredMethodForSecondaryAuthentication')
            $row.SystemPreferredMethods = (@(Get-Value $r 'systemPreferredAuthenticationMethods') | Where-Object { $_ }) -join ';'
            $row.MethodsRegistered = (@(Get-Value $r 'methodsRegistered') | Where-Object { $_ }) -join ';'
            $row.ReportUpdated = Get-Value $r 'lastUpdatedDateTime'
        } else {
            $row.Source = 'Report (no entry)'
        }
    } else {
        $row.IsAdmin = $admins.ContainsKey((Get-Value $u 'id'))
        try {
            $methods = @(Get-GraphCollection -Uri ("$Graph/users/{0}/authentication/methods" -f (Get-Value $u 'id')))
            $types = @($methods | ForEach-Object { ([string]$_['@odata.type']) -replace '^#microsoft\.graph\.', '' -replace 'AuthenticationMethod$', '' } | Sort-Object -Unique)
            $row.MethodsRegistered = $types -join ';'
            $row.IsMfaRegistered = [bool]@($types | Where-Object { $mfaTypes -contains $_ }).Count
            $row.IsPasswordlessCapable = [bool]@($types | Where-Object { $passwordlessTypes -contains $_ }).Count
        } catch {
            $row.MethodsRegistered = "ERROR: $($_.Exception.Message)"
        }
    }
    $rows.Add((New-Object psobject -Property $row))
}
if ($mode -eq 'PerUser') { Write-Progress -Activity 'Reading authentication methods' -Completed }

# ---- Filters and output -------------------------------------------------------------------------------------
$out = @($rows)
if ($AdminsOnly) { $out = @($out | Where-Object { $_.IsAdmin -eq $true }) }
if ($NotMfaCapableOnly) {
    $out = @($out | Where-Object { if ($mode -eq 'Report') { $_.IsMfaCapable -ne $true } else { $_.IsMfaRegistered -ne $true } })
}
$out = @($out | Sort-Object @{ e = { $_.IsAdmin -eq $true }; Descending = $true }, UserPrincipalName)

if ($CsvPath) {
    $out | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8
    Write-Status ("CSV written: {0} ({1} rows)" -f $CsvPath, $out.Count)
}
if ($HtmlPath) {
    $css = '<style>body{font-family:Segoe UI,Arial,sans-serif;font-size:13px}table{border-collapse:collapse}th,td{border:1px solid #ccc;padding:4px 6px;text-align:left}th{background:#eee}</style>'
    $pre = "<h2>Microsoft 365 MFA status</h2><p>Tenant $($ctx.TenantId). Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm'). Source: $mode. Users: $($out.Count).</p>"
    $out | ConvertTo-Html -Head $css -PreContent $pre | Out-File -FilePath $HtmlPath -Encoding UTF8
    Write-Status "HTML written: $HtmlPath"
}

$total = $out.Count
$noMfa = @($out | Where-Object { $_.IsMfaRegistered -ne $true }).Count
$adminNoMfa = @($out | Where-Object { $_.IsAdmin -eq $true -and $_.IsMfaRegistered -ne $true }).Count
Write-Status ("Users reported: {0}. Without a registered MFA method: {1}. Admins without MFA: {2}." -f $total, $noMfa, $adminNoMfa)

if ($PassThru) { return $out }
if (-not $CsvPath -and -not $HtmlPath) {
    $out | Select-Object DisplayName, UserPrincipalName, IsAdmin, IsLicensed, IsMfaRegistered, IsMfaCapable, DefaultMfaMethod, LastSuccessfulSignIn |
        Format-Table -AutoSize
}
