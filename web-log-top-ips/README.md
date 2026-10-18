# Access Log Top IPs and Bots Report

An access log top IPs report for Apache, LiteSpeed and Nginx: top IPs, agents, URLs, fake Googlebots, 404/5xx and wp-login or xmlrpc floods for the last minutes or hours, across all vhosts.

**Full documentation, example output and troubleshooting:** <https://srvscripts.com/scripts/web-log-top-ips/>

Version 1.0.0 · updated 2026-10-06 · Lab-tested

## Download, verify and run

```bash
curl -fsSLO https://scr.srvscripts.com/web-log-top-ips/web-log-top-ips.sh
curl -fsSLO https://scr.srvscripts.com/web-log-top-ips/web-log-top-ips.sh.sha256
sha256sum -c web-log-top-ips.sh.sha256
bash web-log-top-ips.sh --help
```

Read the script before you run it, and try it on a test server first.

## Requirements

Bash 4+, awk (gawk or mawk), GNU coreutils and findutils
Root or read access to the web server logs
Optional: dig, host or getent for --verify-bots; gzip for rotated logs

## Usage

```text
Usage: web-log-top-ips.sh [options]

Options:
  --since=DUR      time window: 30s, 15m, 2h, 1d (default 1h)
  --top=N          lines per section (default 10)
  --log FILE       read this access log (repeatable; .gz is fine)
  --dir DIR        read every access log in DIR (repeatable)
  --verify-bots    reverse + forward DNS check of IPs claiming Googlebot/bingbot
  --flood=N        POSTs to wp-login.php or xmlrpc.php from one IP that count as
                   a flood (default 50)
  --no-color       plain output even on a terminal
  -h, --help       show this help

Without --log/--dir the script looks in cPanel domlogs, DirectAdmin
/var/log/httpd/domains, /var/log/nginx, /usr/local/lsws/logs and the stock
Apache log directories. Only files changed inside the window are read.

Exit codes: 0 nothing unusual, 1 flood / fake bots / high 5xx rate, 2 usage error
```

## How we tested it

AlmaLinux 9.8 with cPanel & WHM 11.138 (lab test, 5 Oct 2026); Ubuntu 24.04 (bash 5.2, mawk) with generated cPanel-style domlogs and an Nginx log in a different time zone

## Changes and licence

What changed in each version: [CHANGELOG.md](CHANGELOG.md). Releases are tagged `web-log-top-ips/vX.Y.Z`.

MIT licence. If you copy, share or adapt the script, keep its header and credit [srvScripts.com](https://srvscripts.com/scripts/web-log-top-ips/).
