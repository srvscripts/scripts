# Backup Verify Script

A backup verify script that checks every account and database series: fresh, not shrinking, opens cleanly, and present for every expected account. Anything it cannot test is a failure.

**Full documentation, example output and troubleshooting:** <https://srvscripts.com/scripts/backup-verify/>

Version 2.1.2 · updated 2026-10-08 · Lab-tested

## Download, verify and run

```bash
curl -fsSLO https://scr.srvscripts.com/backup-verify/backup-verify.sh
curl -fsSLO https://scr.srvscripts.com/backup-verify/backup-verify.sh.sha256
sha256sum -c backup-verify.sh.sha256
bash backup-verify.sh --help
```

Read the script before you run it, and try it on a test server first.

## Requirements

Bash 4.4+, GNU findutils, coreutils and tar
Optional: zstd, xz, bzip2, unzip for those formats (a missing tool is reported as UNVERIFIED)

## Usage

```text
Usage: backup-verify.sh DIR [options]

  --max-age H          newest file of every series must be younger than H hours (26)
  --shrink PCT         FAIL when a series' newest file is PCT% smaller than its previous one (20)
  --min-size BYTES     FAIL for backup files smaller than this (1024)
  --min-count N        FAIL when fewer than N backup files are found (1)
  --depth N            how deep to search under DIR (5)
  --deep               list every archive with tar/unzip and check SQL dump trailers
  --all                test every file of every series, not only the newest
  --accounts-file F    expected account names, one per line (# comments allowed)
  --expect "u1 u2"     expected account names on the command line
  --require-coverage   FAIL (not just UNVERIFIED) when there is no list of expected accounts
  --archives-only      check the archives only; account coverage is skipped and the summary
                       says so (--no-coverage is accepted as the old name)
  --allow-unverified   do not count UNVERIFIED (tool missing, unreadable dir) as a problem
  -q, --quiet          print only problems and the summary line when there are any
  --no-color           no colours (colour is only used on a terminal anyway)
  -h, --help           this help;  --version  print the version

Without --accounts-file or --expect, expected accounts come from /var/cpanel/users or the
DirectAdmin user list. If neither exists, account coverage is UNVERIFIED (exit 1) unless you
pass --archives-only or --allow-unverified. A fresh backup in any series counts toward
coverage, so to require coverage per source server, run once per source directory.
Series are grouped by folder below DIR (dated folder names collapsed to @date) plus the file
name without dates, so the same account name from two sources stays two separate series.
```

## How we tested it

AlmaLinux 9.8 with DirectAdmin 1.712 (lab test, 6 Oct 2026); AlmaLinux 9.8 with cPanel & WHM 11.138 (lab test, 5 Oct 2026); Ubuntu 24.04 (Bash 5.2, GNU tar 1.35, zstd 1.5.5) against cPanel-style, DirectAdmin-style and mysqldump fixture trees; 2.1.0 also against fixtures for a missing account list, missing accounts, two sources with the same account name and dated cPanel folders (container tests, not yet run on a production server)

## Changes and licence

What changed in each version: [CHANGELOG.md](CHANGELOG.md). Releases are tagged `backup-verify/vX.Y.Z`.

MIT licence. If you copy, share or adapt the script, keep its header and credit [srvScripts.com](https://srvscripts.com/scripts/backup-verify/).
