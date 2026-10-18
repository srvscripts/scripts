# SSL Expiry Check Script: Free Network Test for Web and Mail

Checks the live TLS certificate on any list of hosts — web, mail with STARTTLS, or every domain on a cPanel server — and warns before they expire. One line per host, cron-friendly exit codes.

**Full documentation, example output and troubleshooting:** <https://srvscripts.com/scripts/ssl-expiry-check/>

Version 1.1.0 · updated 2026-10-06 · Lab-tested

## Download, verify and run

```bash
curl -fsSLO https://scr.srvscripts.com/ssl-expiry-check/ssl-expiry-check.sh
curl -fsSLO https://scr.srvscripts.com/ssl-expiry-check/ssl-expiry-check.sh.sha256
sha256sum -c ssl-expiry-check.sh.sha256
bash ssl-expiry-check.sh --help
```

Read the script before you run it, and try it on a test server first.

## Requirements

Bash, openssl, coreutils
No root needed (except --cpanel, which reads /etc/userdomains)

## How we tested it

AlmaLinux 9.8 with cPanel & WHM 11.138 (lab test, 5 Oct 2026); AlmaLinux 9, Ubuntu 24.04, macOS 14 (BSD date supported)

## Changes and licence

What changed in each version: [CHANGELOG.md](CHANGELOG.md). Releases are tagged `ssl-expiry-check/vX.Y.Z`.

MIT licence. If you copy, share or adapt the script, keep its header and credit [srvScripts.com](https://srvscripts.com/scripts/ssl-expiry-check/).
