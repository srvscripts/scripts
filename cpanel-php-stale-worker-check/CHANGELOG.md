# Changelog: cPanel PHP Stale-Worker Check

File: `cpanel-php-stale-worker-check.sh`. Page: <https://srvscripts.com/scripts/cpanel-php-stale-worker-check/>

Newest first. Each version is tagged `cpanel-php-stale-worker-check/vX.Y.Z` in this repository.

Tested on: written for cPanel/WHM (EasyApache 4) on AlmaLinux 8/9 and CloudLinux 8/9; logic verified against controlled process and /proc fixtures, and the audit path was then run on a live cPanel server (EA-PHP plus CloudLinux alt-php) where its output matched the running processes.

## 1.0.1

Audit discovery now ignores non-versioned PHP paths (for example an alt `php-fpm` directory), so the installed-versions line no longer shows a stray `?=?` entry on servers that carry the alt-php-fpm packages. The audit path was validated on a live cPanel server (EA-PHP plus CloudLinux alt-php, many PHP-FPM masters) where its output matched the running processes. No change to worker classification, repair behaviour or exit codes.

## 1.0.0

Initial release. Audit-only: reports confirmed-stale and unverified-mismatch PHP workers; `--repair` prints the exact recycle command for one confirmed-stale PID rather than terminating a process (automated termination withheld pending production validation).
