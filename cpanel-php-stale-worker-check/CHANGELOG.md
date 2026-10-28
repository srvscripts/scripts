# Changelog: cPanel PHP Stale-Worker Check

File: `cpanel-php-stale-worker-check.sh`. Page: <https://srvscripts.com/scripts/cpanel-php-stale-worker-check/>

Newest first. Each version is tagged `cpanel-php-stale-worker-check/vX.Y.Z` in this repository.

Tested on: written for cPanel/WHM (EasyApache 4) on AlmaLinux 8/9 and CloudLinux 8/9; logic verified against controlled process and /proc fixtures; not yet run on a production cPanel server.

## 1.0.0

Initial release. Audit-only: reports confirmed-stale and unverified-mismatch PHP workers; `--repair` prints the exact recycle command for one confirmed-stale PID rather than terminating a process (automated termination withheld pending production validation).
