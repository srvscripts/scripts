# Changelog

The latest release of every script, most recently updated first. Each script folder has its full `CHANGELOG.md`.

| Updated | Script | Version | What changed |
|---|---|---|---|
| 2026-10-09 | [cPanel PHP Version Audit](cpanel-php-version-audit/CHANGELOG.md) | 1.0.0 | Initial release |
| 2026-10-09 | [cPanel Disk Usage Report](cpanel-disk-usage-report/CHANGELOG.md) | 1.0.0 | Initial release |
| 2026-10-09 | [cPanel Account Inventory](cpanel-account-inventory/CHANGELOG.md) | 1.0.0 | Initial release |
| 2026-10-09 | [WordPress Version Audit: Find Every WordPress Site and Its Version](wordpress-version-audit/CHANGELOG.md) | 1.1.0 | Status words now say what is checked: MINIMUM-MET / BELOW-MINIMUM (against 7.0.3 for CVE-2026-64638 by default) instead of OK / OUTDATED; the threshold and advi |
| 2026-10-09 | [Secure Boot 2023 Certificate Check: PowerShell Script for Many PCs](secure-boot-cert-check/CHANGELOG.md) | 1.0.0 | First release. |
| 2026-10-09 | [Restic Backup Script for Offsite Backups](restic-offsite-backup/CHANGELOG.md) | 1.2.1 | The lock file no longer falls back to /tmp/restic-offsite-backup.lock when /run/lock is missing. Root uses /run/restic-offsite-backup.lock; the file is opened f |
| 2026-10-09 | [PHP-FPM Slow Log Analyzer](php-fpm-slowlog-analyzer/CHANGELOG.md) | 1.0.0 | Initial release |
| 2026-10-09 | [NTFS Permissions Report to CSV: PowerShell Folder ACL Script](ntfs-permissions-report/CHANGELOG.md) | 1.0.0 | First release. |
| 2026-10-09 | [MySQL Health Snapshot Script: Free 10-Second MariaDB Check](mysql-health-snapshot/CHANGELOG.md) | 1.0.0 | Initial release |
| 2026-10-09 | [Microsoft 365 User Offboarding PowerShell Script (with -WhatIf)](m365-user-offboarding/CHANGELOG.md) | 1.1.0 | Before any group or licence change the script now decides whether the mailbox still needs its Exchange licence (not confirmed as shared, over 50 GB, any hold, a |
| 2026-10-09 | [Microsoft 365 MFA Status Report: PowerShell Script for Graph](m365-mfa-status-report/CHANGELOG.md) | 1.0.0 | First release. |
| 2026-10-09 | [Locked Out AD Users Report: PowerShell Script with Lockout Source](ad-locked-out-users-report/CHANGELOG.md) | 1.0.0 | First release. |
| 2026-10-09 | [Kerberos RC4 Audit Script: Find RC4 Accounts and Tickets](kerberos-rc4-audit/CHANGELOG.md) | 1.0.0 | First release. |
| 2026-10-09 | [Intune Device Compliance Report: PowerShell Script via Graph](intune-device-compliance-report/CHANGELOG.md) | 1.0.0 | First release. |
| 2026-10-09 | [Inode Usage Report: Top Directories by File Count per Account](inode-usage-report/CHANGELOG.md) | 1.1.0 | If du fails or reports errors, the account is shown as INCOMPLETE (with the partial count, e.g. 9+) or UNKNOWN instead of a clean 0/OK, and the script exits 3.  |
| 2026-10-09 | [Inactive AD Accounts Report: PowerShell Script with Safe Disable](inactive-ad-accounts-report/CHANGELOG.md) | 1.0.0 | First release. |
| 2026-10-09 | [Export AD Users to CSV: PowerShell Script with Last Logon](export-ad-users-csv/CHANGELOG.md) | 1.0.0 | First release. |
| 2026-10-09 | [Exim Mail Queue Report](exim-mail-queue-report/CHANGELOG.md) | 1.0.0 | Initial release |
| 2026-10-09 | [Exchange Online Message Trace to CSV: Get-MessageTraceV2 Script](exo-message-trace-report/CHANGELOG.md) | 1.0.0 | First release. |
| 2026-10-09 | [Exchange Online Mailbox Permissions Report: FullAccess, SendAs](exo-mailbox-permissions-report/CHANGELOG.md) | 1.0.0 | First release. |
| 2026-10-09 | [Entra ID Inactive Users Report: signInActivity PowerShell Script](entra-inactive-users-report/CHANGELOG.md) | 1.0.0 | First release. |
| 2026-10-09 | [Block RDP Brute Force on Windows Server: PowerShell Script](rdp-brute-force-blocker/CHANGELOG.md) | 1.0.1 | WhatIf the change log now says "Would block" and nothing is written to the log file. Tested on a Windows Server 2025 DC. |
| 2026-10-09 | [Backup Verify Script](backup-verify/CHANGELOG.md) | 2.1.2 | Header comment now shows the real version (it still said 2.1.0); no change to checks or output. |
| 2026-10-09 | [AutoSSL DCV Failures Report](autossl-failure-report/CHANGELOG.md) | 1.0.0 | Initial release |
| 2026-10-09 | [Asterisk Recordings to MP3: Bulk Convert FreePBX Call Recordings](asterisk-recordings-to-mp3/CHANGELOG.md) | 1.2.1 | A run interrupted while writing an MP3 (killed, server reboot, disk full) could leave a partial MP3 at the final name, and later runs then skipped that recordin |
| 2026-10-09 | [AD Privileged Group Report: Domain Admins and adminCount Audit](ad-privileged-group-report/CHANGELOG.md) | 1.0.0 | First release. |
| 2026-10-09 | [AD Nested Group Membership: PowerShell Tree with Loop Detection](ad-nested-group-membership/CHANGELOG.md) | 1.0.0 | First release. |
| 2026-10-09 | [AD Health Check Report: dcdiag and repadmin PowerShell Script](ad-health-check-report/CHANGELOG.md) | 1.0.0 | First release. |
| 2026-10-09 | [AD Change Audit Reporter: Find Who Changed Active Directory (PowerShell)](ad-change-audit-reporter/CHANGELOG.md) | 1.0.0 | 4767, 4728-4757 and 4741-4743 events on a Windows Server 2025 DC. |
| 2026-10-07 | [Server Security Audit Script](server-security-audit/CHANGELOG.md) | 2.3.0 | Firewall check is stricter: PASS only when the INPUT path ends in a catch-all DROP/REJECT (policy or final rule). A DROP that comes after a conditional ACCEPT i |
| 2026-10-06 | [Server Inventory Report](server-inventory-report/CHANGELOG.md) | 1.0.1 | ImunifyAV is reported as ImunifyAV (malware scanner only) instead of Imunify360; process titles with spaces, such as cpsrvd (SSL), are shortened to the program  |
| 2026-10-06 | [Redirect Chain Checker](redirect-tester/CHANGELOG.md) | 1.0.0 | Initial release |
| 2026-10-05 | [SSL Expiry Check Script: Free Network Test for Web and Mail](ssl-expiry-check/CHANGELOG.md) | 1.1.0 | Also verifies the certificate chain and host name: self-signed, untrusted, incomplete-chain and wrong-host certificates are now reported as BAD (previously only |
| 2026-10-05 | [MariaDB Slow Query Log Summary](mariadb-slow-query-summary/CHANGELOG.md) | 1.0.0 | Initial release |
| 2026-10-05 | [Disk and Inode Alert](disk-inode-alert/CHANGELOG.md) | 1.0.0 | Initial release |
| 2026-10-05 | [Access Log Top IPs and Bots Report](web-log-top-ips/CHANGELOG.md) | 1.0.0 | Initial release |
