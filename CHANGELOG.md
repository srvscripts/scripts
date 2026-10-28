# Changelog

The latest release of every script, most recently updated first. Each script folder has its full `CHANGELOG.md`.

| Updated | Script | Version | What changed |
|---|---|---|---|
| 2026-10-29 | [cPanel PHP Stale-Worker Check](cpanel-php-stale-worker-check/CHANGELOG.md) | 1.0.1 | Audit discovery ignores non-versioned PHP paths (e.g. an alt php-fpm dir), dropping a stray `?=?` in the installed list; audit path validated on a live cPanel server. |
| 2026-10-19 | [Backup Verify Script](backup-verify/CHANGELOG.md) | 2.1.2 | Header comment now shows the real version (it still said 2.1.0); no change to checks or output. |
| 2026-10-18 | [VoIP Toll Fraud Watch: Alert on International and After-Hours Calls in Asterisk](voip-toll-fraud-watch/CHANGELOG.md) | 1.0.1 | On FreePBX, or with --source db, an unreadable CDR database is UNKNOWN (exit 3) instead of a fallback to Master.csv. Skipped transit check shown. Alerts retried |
| 2026-10-18 | [SSL Expiry Check Script: Free Network Test for Web and Mail](ssl-expiry-check/CHANGELOG.md) | 1.1.0 | Also verifies the certificate chain and host name: self-signed, untrusted, incomplete-chain and wrong-host certificates are now reported as BAD (previously only |
| 2026-10-18 | [PJSIP Health Check: Monitor Asterisk Trunks, Registrations and Phones](pjsip-health-check/CHANGELOG.md) | 1.0.1 | A failed or malformed CLI query is UNKNOWN (exit 3); 1.0.0 could report OK with zero objects. Endpoints without a caller ID are counted. New --require-trunk. Al |
| 2026-10-18 | [MariaDB Watchdog Script: Restart MariaDB or MySQL Only When It Is Really Hung](mariadb-watchdog/CHANGELOG.md) | 1.0.0 | First release. |
| 2026-10-18 | [FreePBX Off-Site Backup Script: Databases, Config and Voicemail over rsync](freepbx-offsite-backup/CHANGELOG.md) | 1.0.1 | A failed verification run, an unreadable database server, a missing FreePBX database or a missing sqlite3 are failures; no local pruning after a failed copy. Fo |
| 2026-10-18 | [Call Recording Retention Cleaner: Delete or Archive Old FreePBX Recordings](recording-retention-cleaner/CHANGELOG.md) | 1.0.1 | Open files found in /proc (when every old file was open, 1.0.0 could remove them); each file re-checked right before removal; NUL-safe names; failed CDR update  |
| 2026-10-18 | [Asterisk Security Audit: Check FreePBX for Toll Fraud Risks and Exposed Ports](asterisk-security-audit/CHANGELOG.md) | 1.0.1 | Failed CLI or database queries are UNKNOWN (exit 3) instead of PASS; an unreadable FreePBX database is reported. Found in an independent review. |
| 2026-10-17 | [SIPp Call Load Test for Asterisk and FreePBX, Checked Against the CDR](sipp-call-load-test/CHANGELOG.md) | 1.0.1 | An incomplete run (SIPp stopped by its time limit, fewer calls started than requested, counters missing) is reported as INCOMPLETE instead of OK; carrier delive |
| 2026-10-17 | [SIP TLS Certificate Check for Asterisk and FreePBX (TLS and WSS)](sip-tls-certificate-check/CHANGELOG.md) | 1.0.2 | The private key is also compared when it is in the same PEM file as the certificate; an encrypted or missing key is reported; an unfinished TLS handshake (for e |
| 2026-10-17 | [PBX Support Bundle for Asterisk and FreePBX: Share Diagnostics Without Passwords](pbx-support-bundle/CHANGELOG.md) | 1.0.4 | Comment correction only, no change in behaviour: the 1.0.3 note now also names passwords shorter than 4 characters, which the 1.0.2 "known" file left readable a |
| 2026-10-13 | [Restic Backup Script for Offsite Backups](restic-offsite-backup/CHANGELOG.md) | 1.3.0 | RETENTION=no for append-only repositories (rest-server --append-only), where old snapshots are removed on the backup server; RESTIC_REST_USERNAME, RESTIC_REST_P |
| 2026-10-11 | [Process Hog Report: Which Account Is Using the CPU, RAM and Disk](process-hog-report/CHANGELOG.md) | 1.0.0 | Initial release |
| 2026-10-09 | [cPanel PHP Version Audit](cpanel-php-version-audit/CHANGELOG.md) | 1.0.0 | Initial release |
| 2026-10-09 | [cPanel Disk Usage Report](cpanel-disk-usage-report/CHANGELOG.md) | 1.0.0 | Initial release |
| 2026-10-09 | [cPanel Account Inventory](cpanel-account-inventory/CHANGELOG.md) | 1.0.0 | Initial release |
| 2026-10-09 | [WordPress Version Audit: Find Every WordPress Site and Its Version](wordpress-version-audit/CHANGELOG.md) | 1.1.0 | Status words now say what is checked: MINIMUM-MET / BELOW-MINIMUM (against 7.0.3 for CVE-2026-64638 by default) instead of OK / OUTDATED; the threshold and advi |
| 2026-10-09 | [Secure Boot 2023 Certificate Check: PowerShell Script for Many PCs](secure-boot-cert-check/CHANGELOG.md) | 1.0.0 | First release. |
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
| 2026-10-09 | [AutoSSL DCV Failures Report](autossl-failure-report/CHANGELOG.md) | 1.0.0 | Initial release |
| 2026-10-09 | [Asterisk Recordings to MP3: Bulk Convert FreePBX Call Recordings](asterisk-recordings-to-mp3/CHANGELOG.md) | 1.2.2 | If a folder, or a link to a folder, appeared at the MP3's name while a recording was being converted, 1.2.1 put the MP3 inside that folder and reported success, |
| 2026-10-09 | [AD Privileged Group Report: Domain Admins and adminCount Audit](ad-privileged-group-report/CHANGELOG.md) | 1.0.0 | First release. |
| 2026-10-09 | [AD Nested Group Membership: PowerShell Tree with Loop Detection](ad-nested-group-membership/CHANGELOG.md) | 1.0.0 | First release. |
| 2026-10-09 | [AD Health Check Report: dcdiag and repadmin PowerShell Script](ad-health-check-report/CHANGELOG.md) | 1.0.0 | First release. |
| 2026-10-09 | [AD Change Audit Reporter: Find Who Changed Active Directory (PowerShell)](ad-change-audit-reporter/CHANGELOG.md) | 1.0.0 | 4767, 4728-4757 and 4741-4743 events on a Windows Server 2025 DC. |
| 2026-10-07 | [Server Security Audit Script](server-security-audit/CHANGELOG.md) | 2.3.0 | Firewall check is stricter: PASS only when the INPUT path ends in a catch-all DROP/REJECT (policy or final rule). A DROP that comes after a conditional ACCEPT i |
| 2026-10-06 | [Server Inventory Report](server-inventory-report/CHANGELOG.md) | 1.0.1 | ImunifyAV is reported as ImunifyAV (malware scanner only) instead of Imunify360; process titles with spaces, such as cpsrvd (SSL), are shortened to the program  |
| 2026-10-06 | [Redirect Chain Checker](redirect-tester/CHANGELOG.md) | 1.0.0 | Initial release |
| 2026-10-05 | [MariaDB Slow Query Log Summary](mariadb-slow-query-summary/CHANGELOG.md) | 1.0.0 | Initial release |
| 2026-10-05 | [Disk and Inode Alert](disk-inode-alert/CHANGELOG.md) | 1.0.0 | Initial release |
| 2026-10-05 | [Access Log Top IPs and Bots Report](web-log-top-ips/CHANGELOG.md) | 1.0.0 | Initial release |
