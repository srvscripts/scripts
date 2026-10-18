# AutoSSL DCV Failures Report

Lists AutoSSL DCV failures on a cPanel server grouped by cause (DNS elsewhere, CAA, rate limit, blocked /.well-known/) and every installed certificate that expires within 14 days.

**Full documentation, example output and troubleshooting:** <https://srvscripts.com/scripts/autossl-failure-report/>

Version 1.0.0 · updated 2026-10-06 · Lab-tested

## Download, verify and run

```bash
curl -fsSLO https://scr.srvscripts.com/autossl-failure-report/autossl-failure-report.sh
curl -fsSLO https://scr.srvscripts.com/autossl-failure-report/autossl-failure-report.sh.sha256
sha256sum -c autossl-failure-report.sh.sha256
bash autossl-failure-report.sh --help
```

Read the script before you run it, and try it on a test server first.

## Requirements

cPanel/WHM with AutoSSL enabled, Bash 4+, root
openssl and GNU date (standard on cPanel)

## Usage

```text
Usage: autossl-failure-report.sh [options]

Lists domains that failed AutoSSL domain control validation (DCV), grouped by
cause, and installed certificates that expire soon. Read-only. Run as root.

Options:
  --runs=N      parse the last N AutoSSL runs (default 1 = latest only)
  --days=N      warn about certificates expiring within N days (default 14)
  --no-color    plain output even on a terminal
  -h, --help    this help

Exit codes: 0 = OK, 1 = failures or expiring certificates, 2 = usage/dependency error.
```

## How we tested it

AlmaLinux 9.8 with cPanel & WHM 11.138 (lab test, 5 Oct 2026); Parsing verified on sample cPanel data; written for cPanel on AlmaLinux 8/9 and CloudLinux 8/9

## Changes and licence

What changed in each version: [CHANGELOG.md](CHANGELOG.md). Releases are tagged `autossl-failure-report/vX.Y.Z`.

MIT licence. If you copy, share or adapt the script, keep its header and credit [srvScripts.com](https://srvscripts.com/scripts/autossl-failure-report/).
