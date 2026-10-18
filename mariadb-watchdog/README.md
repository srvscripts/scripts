# MariaDB Watchdog Script: Restart MariaDB or MySQL Only When It Is Really Hung

The MariaDB watchdog mariadb-watchdog.sh is a free Bash script that checks every minute whether MariaDB or MySQL still answers a real query (SELECT 1) within a time limit. A server that is running but does not answer is treated as hung. After three failed checks in a row it saves diagnostics and, only if you added --restart, restarts the service and waits until the server answers again. Without --restart it only reports. It never restarts during startup or crash recovery, while a backup is running, or more than twice an hour, and it never restarts because of a wrong password or "Too many connections".

**Full documentation, example output and troubleshooting:** <https://srvscripts.com/scripts/mariadb-watchdog/>

Version 1.0.0 · updated 2026-10-18 · Fixture-tested

## Download, verify and run

```bash
curl -fsSLO https://scr.srvscripts.com/mariadb-watchdog/mariadb-watchdog.sh
curl -fsSLO https://scr.srvscripts.com/mariadb-watchdog/mariadb-watchdog.sh.sha256
sha256sum -c mariadb-watchdog.sh.sha256
bash mariadb-watchdog.sh --help
```

Read the script before you run it, and try it on a test server first.

## Requirements

Bash 4+, GNU coreutils (timeout), procps (pgrep, ps), util-linux (flock), the mariadb or mysql client
Run as root on the database server; systemd for the default restart, or your own command with --restart-cmd
Optional: mail or sendmail for e-mail alerts, curl for webhook alerts

## Usage

```text
Usage: mariadb-watchdog.sh [options]

Checks that MariaDB/MySQL answers SELECT 1 in time. Report-only unless --restart.

Options:
  --restart              Restart the service when it is hung (default: report only)
  --start-if-down        With --restart, also start a server that is not running
  --fails N              Failed checks in a row before acting (default: 3)
  --timeout SEC          Seconds to wait for an answer per check (default: 10)
  --grace SEC            No restart within SEC of the server starting (default: 300)
  --max-restarts N       At most N restarts per --window (default: 2)
  --window SEC           Window for --max-restarts (default: 3600)
  --wait-up SEC          After a restart, wait up to SEC for an answer (default: 300)
  --stop-timeout SEC     A hung server that has not stopped after SEC is killed (default: 300)
  --service NAME         systemd unit (default: auto: mariadb, mysql or mysqld)
  --restart-cmd CMD      Run CMD instead of "systemctl restart <unit>"
  --restart-on-busy      Treat "Too many connections" as a failure too
  --ignore-backups       Allow a restart while a backup tool is running
  --defaults-file FILE   Client option file with the login (passed as --defaults-extra-file)
  --socket PATH          Server socket to connect to
  --state-dir DIR        Failure counter and restart history (default: /var/lib/mariadb-watchdog)
  --log-dir DIR          Diagnostics saved before a restart (default: /var/log/mariadb-watchdog)
  --email ADDR           Mail alerts to ADDR (needs mail or sendmail)
  --webhook URL          POST alerts as JSON to URL (Slack, Discord, Teams-style; needs curl)
  --interval SEC         Keep running and check every SEC seconds (default: run once)
  --quiet                Print only problems and actions
  -h, --help             Show this help
  -V, --version          Show script version

Examples:
  mariadb-watchdog.sh                                  # one check, report only
  mariadb-watchdog.sh --restart --email ops@example.com
  * * * * * root /usr/local/sbin/mariadb-watchdog.sh --restart --quiet   # cron, every minute
  mariadb-watchdog.sh --defaults-file /usr/local/directadmin/conf/my.cnf --restart
```

## How we tested it

1.0.0 in a test container on 18 Oct 2026: Ubuntu 24.04 with MariaDB 10.11.14; the hang was real (server process frozen with SIGSTOP), systemctl replaced by a stand-in script, so the systemd path on a real server was not part of the test; 42 checks passed (report-only, grace period, backup hold, stop timeout then kill and start, restart limit, down server left alone, too many connections, wrong login, overlapping runs, webhook); 14 more with a fake client run in CI; bash -n and ShellCheck 0.9.0 clean.

## Changes and licence

What changed in each version: [CHANGELOG.md](CHANGELOG.md). Releases are tagged `mariadb-watchdog/vX.Y.Z`.

MIT licence. If you copy, share or adapt the script, keep its header and credit [srvScripts.com](https://srvscripts.com/scripts/mariadb-watchdog/).
