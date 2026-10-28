# Changelog: cPanel PHP Stale-Worker Check

File: `cpanel-php-stale-worker-check.sh`. Page: <https://srvscripts.com/scripts/cpanel-php-stale-worker-check/>

Newest first. Each version is tagged `cpanel-php-stale-worker-check/vX.Y.Z` in this repository.

Tested on: written for cPanel/WHM (EasyApache 4) on AlmaLinux 8/9 and CloudLinux 8/9; logic verified against controlled process and /proc fixtures, and the audit path was then run on a live cPanel server (EA-PHP plus CloudLinux alt-php) where its output matched the running processes.

## 1.0.3

An unreadable php-fpm master is now reported INCOMPLETE (exit 3) instead of OK — the audit can no longer pass when a master's executable cannot be read (it keeps its master identity in the HANDLER column, verdict `master?`). The restart guidance (this script's `--repair`/`--repair-plan` and the guide) now splits the "restart the web server" step by handler: Apache/mod_lsapi restarts its lsphp, a LiteSpeed server restart may not recycle lsphp run in detached mode (use LiteSpeed's own PHP restart or recycle the PID), and PHP-FPM is restarted via its service.

## 1.0.2

Hardened worker identification: a PHP worker is matched by its process name (comm) and its executable, never by command-line text, so a monitoring, shell or editor process that merely mentions `php-fpm`/`lsphp` is no longer classified as a worker and is never offered for `--repair`. An incomplete scan — an unreadable worker, or a failed process snapshot (ps unavailable) — is now reported as INCOMPLETE and exits 3 instead of printing OK; `--repair-plan` surfaces a stale php-fpm master and unreadable workers instead of "nothing to recycle". `--redact` now also applies to the `--repair` advice. No change to the confirmed-stale / unverified-mismatch verdict meanings or their exit codes.

## 1.0.1

Audit discovery now ignores non-versioned PHP paths (for example an alt `php-fpm` directory), so the installed-versions line no longer shows a stray `?=?` entry on servers that carry the alt-php-fpm packages. The audit path was validated on a live cPanel server (EA-PHP plus CloudLinux alt-php, many PHP-FPM masters) where its output matched the running processes. No change to worker classification, repair behaviour or exit codes.

## 1.0.0

Initial release. Audit-only: reports confirmed-stale and unverified-mismatch PHP workers; `--repair` prints the exact recycle command for one confirmed-stale PID rather than terminating a process (automated termination withheld pending production validation).
