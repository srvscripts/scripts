# MariaDB Slow Query Log Summary

Summarises the MariaDB slow query log without Percona tools: groups queries by fingerprint, ranks them by total time, count and rows examined, and prints the commands to turn logging on.

**Full documentation, example output and troubleshooting:** <https://srvscripts.com/scripts/mariadb-slow-query-summary/>

Version 1.0.0 · updated 2026-10-06 · Lab-tested

## Download, verify and run

```bash
curl -fsSLO https://scr.srvscripts.com/mariadb-slow-query-summary/mariadb-slow-query-summary.sh
curl -fsSLO https://scr.srvscripts.com/mariadb-slow-query-summary/mariadb-slow-query-summary.sh.sha256
sha256sum -c mariadb-slow-query-summary.sh.sha256
bash mariadb-slow-query-summary.sh --help
```

Read the script before you run it, and try it on a test server first.

## Requirements

Bash 4+, awk (gawk or mawk)
Read access to the slow log (usually root)
Optional: mysql or mariadb client, for the server settings

## Usage

```text
Usage: mariadb-slow-query-summary.sh [options]
  --log FILE        slow log to read (default: ask the server for @@slow_query_log_file)
  --top N           how many fingerprints to show (default 10)
  --sort KEY        total | count | avg | max | ratio (default total = total Query_time)
  --tail LINES      only parse the last LINES lines of the log (fast on huge logs)
  --width N         truncate fingerprints to N characters (default 400)
  --no-db           do not connect to the server (only parse --log)
  -h, --help        this help
Environment: MYSQL_ARGS extra arguments for the mysql client, e.g. "-u admin -p"
```

## How we tested it

AlmaLinux 9.8 with cPanel & WHM 11.138 (lab test, 5 Oct 2026); MariaDB 10.11 on Ubuntu 24.04, MySQL 8.0 log format

## Changes and licence

What changed in each version: [CHANGELOG.md](CHANGELOG.md). Releases are tagged `mariadb-slow-query-summary/vX.Y.Z`.

MIT licence. If you copy, share or adapt the script, keep its header and credit [srvScripts.com](https://srvscripts.com/scripts/mariadb-slow-query-summary/).
