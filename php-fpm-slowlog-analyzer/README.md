# PHP-FPM Slow Log Analyzer

Turns a PHP-FPM slow log into answers: slow requests grouped by script, stack frame, function and WordPress plugin, plus pm.max_children hits and timeouts per pool next to each pool's settings.

**Full documentation, example output and troubleshooting:** <https://srvscripts.com/scripts/php-fpm-slowlog-analyzer/>

Version 1.0.0 · updated 2026-10-06 · Lab-tested

## Download, verify and run

```bash
curl -fsSLO https://scr.srvscripts.com/php-fpm-slowlog-analyzer/php-fpm-slowlog-analyzer.sh
curl -fsSLO https://scr.srvscripts.com/php-fpm-slowlog-analyzer/php-fpm-slowlog-analyzer.sh.sha256
sha256sum -c php-fpm-slowlog-analyzer.sh.sha256
bash php-fpm-slowlog-analyzer.sh --help
```

Read the script before you run it, and try it on a test server first.

## Requirements

Bash 4+, awk (gawk or mawk), GNU coreutils
Root or read access to the FPM logs and pool configs
request_slowlog_timeout set on the pools you want traced

## Usage

```text
Usage: php-fpm-slowlog-analyzer.sh [options]

Options:
  --log FILE        slow log to read (repeatable; disables auto-detection of slow logs)
  --error-log FILE  FPM error log to read (repeatable; disables auto-detection of error logs)
  --since=DUR       only entries newer than DUR: 30m, 2h, 7d (default: everything in the files)
  --top=N           lines per section (default 10)
  --all-pools       list every pool in the settings table, not only busy ones
  --no-color        plain output even on a terminal
  -h, --help        show this help

Exit codes: 0 nothing found, 1 slow requests or max_children/timeouts found,
            2 usage error or no PHP-FPM logs to read
```

## How we tested it

AlmaLinux 9.8 with cPanel & WHM 11.138 (lab test, 5 Oct 2026); Ubuntu 24.04 (bash 5.2, mawk) with cPanel ea-php81 and Debian-style pool configs, slow logs and error logs as fixtures

## Changes and licence

What changed in each version: [CHANGELOG.md](CHANGELOG.md). Releases are tagged `php-fpm-slowlog-analyzer/vX.Y.Z`.

MIT licence. If you copy, share or adapt the script, keep its header and credit [srvScripts.com](https://srvscripts.com/scripts/php-fpm-slowlog-analyzer/).
