# Disk and Inode Alert

A disk and inode alert for cron: checks every real filesystem for space and inode use, estimates days until full from growth between runs, and lists the largest directories when a threshold is crossed.

**Full documentation, example output and troubleshooting:** <https://srvscripts.com/scripts/disk-inode-alert/>

Version 1.0.0 · updated 2026-10-06 · Lab-tested

## Download, verify and run

```bash
curl -fsSLO https://scr.srvscripts.com/disk-inode-alert/disk-inode-alert.sh
curl -fsSLO https://scr.srvscripts.com/disk-inode-alert/disk-inode-alert.sh.sha256
sha256sum -c disk-inode-alert.sh.sha256
bash disk-inode-alert.sh --help
```

Read the script before you run it, and try it on a test server first.

## Requirements

Bash 4+, GNU coreutils 8.22+ (df --output, du --inodes)
Root to write the state file and scan every directory
Optional: mail or sendmail for --mail

## Usage

```text
Usage: disk-inode-alert.sh [options]
  --warn PCT         warning threshold for space and inodes (default 80)
  --crit PCT         critical threshold for space and inodes (default 90)
  --days N           also warn when a filesystem is estimated to fill within N days (default 7, 0 = off)
  --state FILE       state file for growth tracking (default /var/lib/srvscripts/disk-inode-alert.state)
  --no-state         do not read or write the state file
  --no-scan          do not run du on filesystems over threshold
  --du-timeout SEC   time limit for each du scan (default 60)
  --mail ADDRESS     mail the report to ADDRESS when there is a problem (needs mail or sendmail)
  -q, --quiet        print nothing when everything is OK
  --no-color         plain output
  -h, --help         this help
```

## How we tested it

AlmaLinux 9.8 with cPanel & WHM 11.138 (lab test, 5 Oct 2026); Ubuntu 24.04

## Changes and licence

What changed in each version: [CHANGELOG.md](CHANGELOG.md). Releases are tagged `disk-inode-alert/vX.Y.Z`.

MIT licence. If you copy, share or adapt the script, keep its header and credit [srvScripts.com](https://srvscripts.com/scripts/disk-inode-alert/).
