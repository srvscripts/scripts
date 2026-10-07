# Changelog: Inode Usage Report: Top Directories by File Count per Account

File: `inode-usage-report.sh`. Page: <https://srvscripts.com/scripts/inode-usage-report/>

Newest first. Each version is tagged `inode-usage-report/vX.Y.Z` in this repository.

Tested on: 1.1.0 on AlmaLinux 9.8 with cPanel & WHM 11.138 (lab test, 7 Oct 2026); 14 fixtures (unreadable subtree, vanished directory, I/O error, missing total); Run on 6 Oct 2026 on AlmaLinux 9.8 with cPanel & WHM 11.138 (3 accounts) and AlmaLinux 9.8 with DirectAdmin 1.712 (1 account, 3 domains), including summary, threshold and CSV modes; bash -n and ShellCheck 0.9.0 clean.

## 1.1.0

If du fails or reports errors, the account is shown as INCOMPLETE (with the partial count, e.g. 9+) or UNKNOWN instead of a clean 0/OK, and the script exits 3. Empty and unknown accounts now also get a CSV row. Found in an external review (PROD7-05).

## 1.0.0

First release.
