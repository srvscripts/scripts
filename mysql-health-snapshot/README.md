# MySQL Health Snapshot Script: Free 10-Second MariaDB Check

One page of the numbers that matter on a MariaDB or MySQL server: connections vs limit, buffer pool hit ratio, tmp tables on disk, slow queries, largest tables, leftover MyISAM and anything running longer than five seconds. Read-only.

**Full documentation, example output and troubleshooting:** <https://srvscripts.com/scripts/mysql-health-snapshot/>

Version 1.0.0 · updated 2026-10-06 · Lab-tested

## Download, verify and run

```bash
curl -fsSLO https://scr.srvscripts.com/mysql-health-snapshot/mysql-health-snapshot.sh
curl -fsSLO https://scr.srvscripts.com/mysql-health-snapshot/mysql-health-snapshot.sh.sha256
sha256sum -c mysql-health-snapshot.sh.sha256
bash mysql-health-snapshot.sh --help
```

Read the script before you run it, and try it on a test server first.

## Requirements

mysql client with access (root via /root/.my.cnf on cPanel, or MYSQL_ARGS)
MariaDB 10.3+ or MySQL 5.7+

## How we tested it

AlmaLinux 9.8 with cPanel & WHM 11.138 (lab test, 5 Oct 2026); MariaDB 10.6 and 10.11 on cPanel, MySQL 8.0 on Ubuntu 24.04

## Changes and licence

What changed in each version: [CHANGELOG.md](CHANGELOG.md). Releases are tagged `mysql-health-snapshot/vX.Y.Z`.

MIT licence. If you copy, share or adapt the script, keep its header and credit [srvScripts.com](https://srvscripts.com/scripts/mysql-health-snapshot/).
