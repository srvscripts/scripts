# Inode Usage Report: Top Directories by File Count per Account

The inode usage report script inode-usage-report.sh counts inodes (files and folders) for every hosting account on a cPanel, DirectAdmin or plain Linux server, marks each account OK, WARN or CRIT against thresholds you set, and lists the directories inside each account that hold the most files. If du could not measure an account fully, the account is marked INCOMPLETE or UNKNOWN instead, and the script exits 3. It uses du --inodes at low priority, changes nothing, and can print CSV for spreadsheets or monitoring.

**Full documentation, example output and troubleshooting:** <https://srvscripts.com/scripts/inode-usage-report/>

Version 1.1.0 · updated 2026-10-07 · Lab-tested

## Download, verify and run

```bash
curl -fsSLO https://scr.srvscripts.com/inode-usage-report/inode-usage-report.sh
curl -fsSLO https://scr.srvscripts.com/inode-usage-report/inode-usage-report.sh.sha256
sha256sum -c inode-usage-report.sh.sha256
bash inode-usage-report.sh --help
```

Read the script before you run it, and try it on a test server first.

## Requirements

Bash 4+, GNU coreutils 8.22+ (du --inodes); run as root to scan all accounts. cPanel, DirectAdmin or plain Linux.

## Usage

```text
Usage: inode-usage-report.sh [options]

Counts inodes per account home and shows the directories holding the most files.
If du reports an error for an account, its status is INCOMPLETE (count shown as
a lower bound, e.g. 12345+) or UNKNOWN (no total), and the script exits 3.

Options:
  --top N          Directories to list per account (default: 10)
  --depth N        Directory depth below the home to rank (default: 2)
  --warn N         Account total that triggers WARN (default: 200000)
  --crit N         Account total that triggers CRIT (default: 400000)
  --user NAME      Only this account (repeatable)
  --path DIR       Treat DIR as one account home (repeatable; skips panel detection)
  --summary        Only print the per-account totals table
  --csv            CSV output: account,home,total,status,directory,inodes,percent
  --no-nice        Do not lower CPU/I/O priority
  -h, --help       Show this help
  -V, --version    Show script version

Examples:
  inode-usage-report.sh --summary
  inode-usage-report.sh --user bob --top 20 --depth 3
  inode-usage-report.sh --warn 150000 --crit 250000 --csv > inodes.csv
```

## How we tested it

1.1.0 on AlmaLinux 9.8 with cPanel & WHM 11.138 (lab test, 7 Oct 2026); 14 fixtures (unreadable subtree, vanished directory, I/O error, missing total); Run on 6 Oct 2026 on AlmaLinux 9.8 with cPanel & WHM 11.138 (3 accounts) and AlmaLinux 9.8 with DirectAdmin 1.712 (1 account, 3 domains), including summary, threshold and CSV modes; bash -n and ShellCheck 0.9.0 clean.

## Changes and licence

What changed in each version: [CHANGELOG.md](CHANGELOG.md). Releases are tagged `inode-usage-report/vX.Y.Z`.

MIT licence. If you copy, share or adapt the script, keep its header and credit [srvScripts.com](https://srvscripts.com/scripts/inode-usage-report/).
