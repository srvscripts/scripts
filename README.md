# srvScripts script library

Free, read-only-by-default scripts for server admins from [srvScripts.com](https://srvscripts.com/scripts/): Bash, PowerShell and Python for cPanel, DirectAdmin, Linux, Active Directory, Microsoft 365 and VoIP servers.

Each script has a page on srvScripts.com that explains what it does, its options, how to schedule it and how we tested it. Always read a script before you run it.

Download a single file from [scr.srvscripts.com](https://scr.srvscripts.com/) and verify it with the `.sha256` file next to it.

## Bash

| Script | File | Version |
|---|---|---|
| [Access Log Top IPs and Bots Report](https://srvscripts.com/scripts/web-log-top-ips/) | [`web-log-top-ips.sh`](web-log-top-ips/web-log-top-ips.sh) | 1.0.0 |
| [Asterisk Recordings to MP3: Bulk Convert FreePBX Call Recordings](https://srvscripts.com/scripts/asterisk-recordings-to-mp3/) | [`asterisk-recordings-to-mp3.sh`](asterisk-recordings-to-mp3/asterisk-recordings-to-mp3.sh) | 1.0.0 |
| [AutoSSL DCV Failures Report](https://srvscripts.com/scripts/autossl-failure-report/) | [`autossl-failure-report.sh`](autossl-failure-report/autossl-failure-report.sh) | 1.0.0 |
| [Backup Verify Script](https://srvscripts.com/scripts/backup-verify/) | [`backup-verify.sh`](backup-verify/backup-verify.sh) | 2.1.1 |
| [cPanel Account Inventory](https://srvscripts.com/scripts/cpanel-account-inventory/) | [`cpanel-account-inventory.sh`](cpanel-account-inventory/cpanel-account-inventory.sh) | 1.0.0 |
| [cPanel Disk Usage Report](https://srvscripts.com/scripts/cpanel-disk-usage-report/) | [`cpanel-disk-usage-report.sh`](cpanel-disk-usage-report/cpanel-disk-usage-report.sh) | 1.0.0 |
| [cPanel PHP Version Audit](https://srvscripts.com/scripts/cpanel-php-version-audit/) | [`cpanel-php-version-audit.sh`](cpanel-php-version-audit/cpanel-php-version-audit.sh) | 1.0.0 |
| [Disk and Inode Alert](https://srvscripts.com/scripts/disk-inode-alert/) | [`disk-inode-alert.sh`](disk-inode-alert/disk-inode-alert.sh) | 1.0.0 |
| [Exim Mail Queue Report](https://srvscripts.com/scripts/exim-mail-queue-report/) | [`exim-mail-queue-report.sh`](exim-mail-queue-report/exim-mail-queue-report.sh) | 1.0.0 |
| [Inode Usage Report: Top Directories by File Count per Account](https://srvscripts.com/scripts/inode-usage-report/) | [`inode-usage-report.sh`](inode-usage-report/inode-usage-report.sh) | 1.0.0 |
| [MariaDB Slow Query Log Summary](https://srvscripts.com/scripts/mariadb-slow-query-summary/) | [`mariadb-slow-query-summary.sh`](mariadb-slow-query-summary/mariadb-slow-query-summary.sh) | 1.0.0 |
| [MySQL Health Snapshot Script: Free 10-Second MariaDB Check](https://srvscripts.com/scripts/mysql-health-snapshot/) | [`mysql-health-snapshot.sh`](mysql-health-snapshot/mysql-health-snapshot.sh) | 1.0.0 |
| [PHP-FPM Slow Log Analyzer](https://srvscripts.com/scripts/php-fpm-slowlog-analyzer/) | [`php-fpm-slowlog-analyzer.sh`](php-fpm-slowlog-analyzer/php-fpm-slowlog-analyzer.sh) | 1.0.0 |
| [Redirect Chain Checker](https://srvscripts.com/scripts/redirect-tester/) | [`redirect-tester.sh`](redirect-tester/redirect-tester.sh) | 1.0.0 |
| [Restic Backup Script for Offsite Backups](https://srvscripts.com/scripts/restic-offsite-backup/) | [`restic-offsite-backup.sh`](restic-offsite-backup/restic-offsite-backup.sh) | 1.1.0 |
| [Server Inventory Report](https://srvscripts.com/scripts/server-inventory-report/) | [`server-inventory-report.sh`](server-inventory-report/server-inventory-report.sh) | 1.0.1 |
| [Server Security Audit Script](https://srvscripts.com/scripts/server-security-audit/) | [`server-security-audit.sh`](server-security-audit/server-security-audit.sh) | 2.2.1 |
| [SSL Expiry Check Script: Free Network Test for Web and Mail](https://srvscripts.com/scripts/ssl-expiry-check/) | [`ssl-expiry-check.sh`](ssl-expiry-check/ssl-expiry-check.sh) | 1.1.0 |
| [WordPress Version Audit: Find Every WordPress Site and Its Version](https://srvscripts.com/scripts/wordpress-version-audit/) | [`wordpress-version-audit.sh`](wordpress-version-audit/wordpress-version-audit.sh) | 1.0.0 |

## PowerShell

| Script | File | Version |
|---|---|---|
| [AD Change Audit Reporter: Find Who Changed Active Directory (PowerShell)](https://srvscripts.com/scripts/ad-change-audit-reporter/) | [`Get-ADChangeAudit.ps1`](ad-change-audit-reporter/Get-ADChangeAudit.ps1) | 1.0.0 |
| [AD Health Check Report: dcdiag and repadmin PowerShell Script](https://srvscripts.com/scripts/ad-health-check-report/) | [`Invoke-ADHealthReport.ps1`](ad-health-check-report/Invoke-ADHealthReport.ps1) | 1.0.0 |
| [AD Nested Group Membership: PowerShell Tree with Loop Detection](https://srvscripts.com/scripts/ad-nested-group-membership/) | [`Get-ADNestedGroupMembership.ps1`](ad-nested-group-membership/Get-ADNestedGroupMembership.ps1) | 1.0.0 |
| [AD Privileged Group Report: Domain Admins and adminCount Audit](https://srvscripts.com/scripts/ad-privileged-group-report/) | [`Get-ADPrivilegedGroupReport.ps1`](ad-privileged-group-report/Get-ADPrivilegedGroupReport.ps1) | 1.0.0 |
| [Block RDP Brute Force on Windows Server: PowerShell Script](https://srvscripts.com/scripts/rdp-brute-force-blocker/) | [`Block-RdpBruteForce.ps1`](rdp-brute-force-blocker/Block-RdpBruteForce.ps1) | 1.0.1 |
| [Entra ID Inactive Users Report: signInActivity PowerShell Script](https://srvscripts.com/scripts/entra-inactive-users-report/) | [`Get-EntraInactiveUsers.ps1`](entra-inactive-users-report/Get-EntraInactiveUsers.ps1) | 1.0.0 |
| [Exchange Online Mailbox Permissions Report: FullAccess, SendAs](https://srvscripts.com/scripts/exo-mailbox-permissions-report/) | [`Get-EXOMailboxPermissionReport.ps1`](exo-mailbox-permissions-report/Get-EXOMailboxPermissionReport.ps1) | 1.0.0 |
| [Exchange Online Message Trace to CSV: Get-MessageTraceV2 Script](https://srvscripts.com/scripts/exo-message-trace-report/) | [`Get-EXOMessageTraceReport.ps1`](exo-message-trace-report/Get-EXOMessageTraceReport.ps1) | 1.0.0 |
| [Export AD Users to CSV: PowerShell Script with Last Logon](https://srvscripts.com/scripts/export-ad-users-csv/) | [`Export-ADUserReport.ps1`](export-ad-users-csv/Export-ADUserReport.ps1) | 1.0.0 |
| [Inactive AD Accounts Report: PowerShell Script with Safe Disable](https://srvscripts.com/scripts/inactive-ad-accounts-report/) | [`Get-ADInactiveAccounts.ps1`](inactive-ad-accounts-report/Get-ADInactiveAccounts.ps1) | 1.0.0 |
| [Intune Device Compliance Report: PowerShell Script via Graph](https://srvscripts.com/scripts/intune-device-compliance-report/) | [`Get-IntuneComplianceReport.ps1`](intune-device-compliance-report/Get-IntuneComplianceReport.ps1) | 1.0.0 |
| [Kerberos RC4 Audit Script: Find RC4 Accounts and Tickets](https://srvscripts.com/scripts/kerberos-rc4-audit/) | [`Get-KerberosRC4Usage.ps1`](kerberos-rc4-audit/Get-KerberosRC4Usage.ps1) | 1.0.0 |
| [Locked Out AD Users Report: PowerShell Script with Lockout Source](https://srvscripts.com/scripts/ad-locked-out-users-report/) | [`Get-ADLockoutReport.ps1`](ad-locked-out-users-report/Get-ADLockoutReport.ps1) | 1.0.0 |
| [Microsoft 365 MFA Status Report: PowerShell Script for Graph](https://srvscripts.com/scripts/m365-mfa-status-report/) | [`Get-M365MfaReport.ps1`](m365-mfa-status-report/Get-M365MfaReport.ps1) | 1.0.0 |
| [Microsoft 365 User Offboarding PowerShell Script (with -WhatIf)](https://srvscripts.com/scripts/m365-user-offboarding/) | [`Invoke-M365Offboarding.ps1`](m365-user-offboarding/Invoke-M365Offboarding.ps1) | 1.0.0 |
| [NTFS Permissions Report to CSV: PowerShell Folder ACL Script](https://srvscripts.com/scripts/ntfs-permissions-report/) | [`Get-NTFSPermissionReport.ps1`](ntfs-permissions-report/Get-NTFSPermissionReport.ps1) | 1.0.0 |
| [Secure Boot 2023 Certificate Check: PowerShell Script for Many PCs](https://srvscripts.com/scripts/secure-boot-cert-check/) | [`Get-SecureBootCertStatus.ps1`](secure-boot-cert-check/Get-SecureBootCertStatus.ps1) | 1.0.0 |

## Licence

MIT, see [LICENSE](LICENSE). If you copy, share or adapt a script, keep its header and credit srvScripts.com.

Issues and fixes are welcome; the canonical version of every script lives on srvScripts.com and this repository is synced from it automatically.
