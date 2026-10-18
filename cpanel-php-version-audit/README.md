# cPanel PHP Version Audit

A cPanel PHP version audit for EasyApache 4 MultiPHP: every domain's PHP version, a count per version, and a list of sites still running end-of-life PHP. Optional CSV export.

**Full documentation, example output and troubleshooting:** <https://srvscripts.com/scripts/cpanel-php-version-audit/>

Version 1.0.0 · updated 2026-10-06 · Lab-tested

## Download, verify and run

```bash
curl -fsSLO https://scr.srvscripts.com/cpanel-php-version-audit/cpanel-php-version-audit.sh
curl -fsSLO https://scr.srvscripts.com/cpanel-php-version-audit/cpanel-php-version-audit.sh.sha256
sha256sum -c cpanel-php-version-audit.sh.sha256
bash cpanel-php-version-audit.sh --help
```

Read the script before you run it, and try it on a test server first.

## Requirements

cPanel/WHM with EasyApache 4, Bash 4+, root

## Usage

```text
Usage: cpanel-php-version-audit.sh [options]

Shows every domain's PHP version (EasyApache 4 MultiPHP), counts domains per
version and lists sites on end-of-life PHP. Read-only. Run as root.

Options:
  --csv FILE            also write every vhost to FILE as CSV ("-" = stdout)
  --eol-below=X.Y       versions below X.Y count as end-of-life (default 8.2)
  --security-below=X.Y  versions below X.Y count as security-only (default 8.4)
  --source=api|files    force whmapi1 or the userdata files (default: api, then files)
  --no-color            plain output even on a terminal
  -h, --help            this help

Exit codes: 0 = OK, 1 = a site runs end-of-life PHP, 2 = usage/dependency error.
```

## How we tested it

AlmaLinux 9.8 with cPanel & WHM 11.138 (lab test, 5 Oct 2026); Parsing verified on sample cPanel data; written for cPanel on AlmaLinux 8/9 and CloudLinux 8/9

## Changes and licence

What changed in each version: [CHANGELOG.md](CHANGELOG.md). Releases are tagged `cpanel-php-version-audit/vX.Y.Z`.

MIT licence. If you copy, share or adapt the script, keep its header and credit [srvScripts.com](https://srvscripts.com/scripts/cpanel-php-version-audit/).
