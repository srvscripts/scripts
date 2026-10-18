# cPanel Disk Usage Report

Per-account disk usage on a cPanel/WHM server, split into files, mail and MySQL, sorted by total and compared to quota. Table or CSV output. Read-only.

**Full documentation, example output and troubleshooting:** <https://srvscripts.com/scripts/cpanel-disk-usage-report/>

Version 1.0.0 · updated 2026-10-06 · Lab-tested

## Download, verify and run

```bash
curl -fsSLO https://scr.srvscripts.com/cpanel-disk-usage-report/cpanel-disk-usage-report.sh
curl -fsSLO https://scr.srvscripts.com/cpanel-disk-usage-report/cpanel-disk-usage-report.sh.sha256
sha256sum -c cpanel-disk-usage-report.sh.sha256
bash cpanel-disk-usage-report.sh --help
```

Read the script before you run it, and try it on a test server first.

## Requirements

cPanel/WHM, root
mysql client with root access via /root/.my.cnf (standard on cPanel)

## How we tested it

AlmaLinux 9.8 with cPanel & WHM 11.138 (lab test, 5 Oct 2026); cPanel 118–126 on AlmaLinux 8/9, CloudLinux 8/9

## Changes and licence

What changed in each version: [CHANGELOG.md](CHANGELOG.md). Releases are tagged `cpanel-disk-usage-report/vX.Y.Z`.

MIT licence. If you copy, share or adapt the script, keep its header and credit [srvScripts.com](https://srvscripts.com/scripts/cpanel-disk-usage-report/).
