# Changelog: cPanel PHP Stale-Worker Check

File: `cpanel-php-stale-worker-check.sh`. Page: <https://srvscripts.com/scripts/cpanel-php-stale-worker-check/>

Newest first. Each version is tagged `cpanel-php-stale-worker-check/vX.Y.Z` in this repository.

Tested on: Written for cPanel/WHM (EasyApache 4) on AlmaLinux 8/9 and CloudLinux 8/9. Logic verified against controlled process and /proc fixtures (ShellCheck clean, two review passes); the audit path was then run on a live cPanel server (EA-PHP + CloudLinux alt-php, many PHP-FPM masters) where its output matched the running processes. Repair is advisory only - it prints the exact recycle command and never terminates a process.

## 1.1.1

Audit hardening from an independent review (behaviour of the default stale-worker scan is unchanged). Package diagnostics: the dnf update query runs with DNF_DISABLE_ALIASES so a custom 'check-update' alias cannot turn it into an upgrade; the Imunify360 hardened repo is matched by its exact id rather than any name containing 'hardened'; its enabled= value is read as a proper boolean (0/false/no/off); an 'epoch >= 1' claim is made only when a real epoch >= 1 is present (CloudLinux vendor/release provenance is reported separately); 'excludepkgs=' is detected alongside 'exclude='; and a failed hardened-repo query is reported rather than dropped silently. Worker detection: a php-fpm on a replaced binary whose parent is not a detected FPM master is held back from --repair (it could be a mis-titled master), and a failing output formatter can no longer be mistaken for an empty 'no workers' result. A --csv target that is a symlink or non-regular file is refused, and the export is written owner-only. The LiteSpeed detached-PHP guidance now points to WebAdmin > Restart PHP, since a server restart may not recycle detached lsphp.

## 1.1.0

Added opt-in, read-only package and repository diagnostics (--pkg, plus --check-updates for the dnf query). On cPanel they report the installed EA-PHP branches with their RPM epoch, whether an Imunify360 hardened PHP repository is present and enabled, dnf package exclusions, and (with --check-updates) available EA-PHP updates, including updates hidden when a disabled hardened repo carries epoch-1 packages. The diagnostics only read and print the recommended dnf commands; they never enable a repository, install or upgrade. The default stale-worker audit is unchanged. Hardening: a php-fpm master is now identified by its parent process as well as its title, so a mis-titled master can never be offered for recycling; plus minor input-validation and advisory-wording fixes.

## 1.0.3

An unreadable php-fpm master is now reported INCOMPLETE (exit 3) instead of OK, so the audit can no longer pass when a master's executable cannot be read. The restart guidance (script and guide) now splits the "restart the web server" step by handler: Apache/mod_lsapi restarts its lsphp, but a LiteSpeed server restart may not recycle lsphp in detached mode (use LiteSpeed's own PHP restart or recycle the PID), and PHP-FPM is restarted via its service. Minor guide wording: confirm the packages updated first; the quick check now lists php-fpm as well as lsphp.

## 1.0.2

Hardened worker identification: a PHP worker is matched by its process name and executable, never by command-line text, so a monitoring, shell or editor process that merely mentions "php-fpm"/"lsphp" is no longer classified as a worker (and never offered for --repair). An incomplete scan (an unreadable worker, or a failed process snapshot) is now reported as INCOMPLETE and exits 3 instead of printing OK; --repair-plan surfaces a stale php-fpm master and unreadable workers instead of "nothing to recycle". --redact now also applies to the --repair advice.

## 1.0.1

Audit discovery now ignores non-versioned PHP paths (for example an alt php-fpm directory), so the installed-versions line no longer shows a stray "?=?" entry on servers that carry the alt-php-fpm packages. Audit path validated on a live cPanel server (EA-PHP + CloudLinux alt-php, many PHP-FPM masters). No change to worker classification or exit codes.

## 1.0.0

Initial release. Audit-only: reports confirmed-stale and unverified-mismatch PHP workers; --repair prints the exact recycle command for one confirmed-stale PID rather than terminating a process.
