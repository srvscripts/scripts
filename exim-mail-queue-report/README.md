# Exim Mail Queue Report

Find out what is filling the Exim queue on a cPanel server: top senders, recipient domains, authenticated users, sending scripts and delivery errors from the last 24 hours, with an optional frozen-message purge.

**Full documentation, example output and troubleshooting:** <https://srvscripts.com/scripts/exim-mail-queue-report/>

Version 1.0.0 · updated 2026-10-06 · Lab-tested

## Download, verify and run

```bash
curl -fsSLO https://scr.srvscripts.com/exim-mail-queue-report/exim-mail-queue-report.sh
curl -fsSLO https://scr.srvscripts.com/exim-mail-queue-report/exim-mail-queue-report.sh.sha256
sha256sum -c exim-mail-queue-report.sh.sha256
bash exim-mail-queue-report.sh --help
```

Read the script before you run it, and try it on a test server first.

## Requirements

cPanel/WHM with Exim, root
GNU date (for the 24h window)

## How we tested it

AlmaLinux 9.8 with cPanel & WHM 11.138 (lab test, 5 Oct 2026); cPanel 118–126 on AlmaLinux 8/9, CloudLinux 9

## Changes and licence

What changed in each version: [CHANGELOG.md](CHANGELOG.md). Releases are tagged `exim-mail-queue-report/vX.Y.Z`.

MIT licence. If you copy, share or adapt the script, keep its header and credit [srvScripts.com](https://srvscripts.com/scripts/exim-mail-queue-report/).
