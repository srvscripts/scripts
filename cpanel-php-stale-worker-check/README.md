# cPanel PHP Stale-Worker Check

Read-only script that finds lsphp / php-fpm workers still running a replaced PHP binary after an update — the reason a cPanel site keeps reporting the old version.

**Full documentation, example output and troubleshooting:** <https://srvscripts.com/scripts/cpanel-php-stale-worker-check/>

Version 1.1.1 · updated 2026-10-29 · Lab-tested

## Download, verify and run

```bash
curl -fsSLO https://scr.srvscripts.com/cpanel-php-stale-worker-check/cpanel-php-stale-worker-check.sh
curl -fsSLO https://scr.srvscripts.com/cpanel-php-stale-worker-check/cpanel-php-stale-worker-check.sh.sha256
sha256sum -c cpanel-php-stale-worker-check.sh.sha256
bash cpanel-php-stale-worker-check.sh --help
```

Read the script before you run it, and try it on a test server first.

## Requirements

cPanel/WHM, Bash 4+, root. Read-only audit by default; repair is opt-in and recycles one named, confirmed-stale worker.

## Usage

```text
Usage: cpanel-php-stale-worker-check.sh [options]

Finds PHP (lsphp / php-fpm) workers still running a binary that was replaced on
disk — the reason a site can keep reporting the old PHP version after an update.
AUDIT-ONLY: it never kills a process or restarts a service. Run as root for a
complete process view.

Options:
  --csv FILE        also write every worker found to FILE as CSV ("-" = stdout)
                    (CSV holds account names and executable paths — treat it as
                    sensitive server metadata; use --redact before sharing it)
  --repair-plan     print recommended fixes for what was found, then exit (no change)
  --repair --pid N  print the exact recycle command for ONE confirmed-stale PID
                    (prints only; this release does not terminate anything)
  --redact          show "uid:N" instead of account names in all output (executable
                    paths are still shown — review output before sharing)
  --pkg             also run read-only package/repository diagnostics: installed
                    EA-PHP branches and versions, RPM epoch, the Imunify360 hardened
                    repo and its enabled state, and dnf exclusions. Reads only; it
                    changes no installed package, repo config or service (a --csv
                    export is the one file it writes).
  --check-updates   with --pkg, also query dnf for available EA-PHP updates (needs
                    network). Read-only: it runs "dnf check-update" (which may refresh
                    dnf's own cache/logs) and never installs, upgrades or enables a repo.
  --no-color        plain output even on a terminal
  -h, --help        this help
  -V, --version     print version

Exit codes: 0 none, 1 unverified mismatch only, 2 confirmed stale worker(s),
            3 skipped (no evidence/tools), 4 usage/precondition.
```

## How we tested it

Written for cPanel/WHM (EasyApache 4) on AlmaLinux 8/9 and CloudLinux 8/9. Logic verified against controlled process and /proc fixtures (ShellCheck clean, two review passes); the audit path was then run on a live cPanel server (EA-PHP + CloudLinux alt-php, many PHP-FPM masters) where its output matched the running processes. Repair is advisory only - it prints the exact recycle command and never terminates a process.

## Changes and licence

What changed in each version: [CHANGELOG.md](CHANGELOG.md). Releases are tagged `cpanel-php-stale-worker-check/vX.Y.Z`.

MIT licence. If you copy, share or adapt the script, keep its header and credit [srvScripts.com](https://srvscripts.com/scripts/cpanel-php-stale-worker-check/).
