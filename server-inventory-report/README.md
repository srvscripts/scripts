# Server Inventory Report

A one-page server inventory report for Linux: OS, hardware, disks, IPs, control panel, web server, PHP, database and mail versions, firewall, backups, open ports and pending updates.

**Full documentation, example output and troubleshooting:** <https://srvscripts.com/scripts/server-inventory-report/>

Version 1.0.1 · updated 2026-10-06 · Lab-tested

## Download, verify and run

```bash
curl -fsSLO https://scr.srvscripts.com/server-inventory-report/server-inventory-report.sh
curl -fsSLO https://scr.srvscripts.com/server-inventory-report/server-inventory-report.sh.sha256
sha256sum -c server-inventory-report.sh.sha256
bash server-inventory-report.sh --help
```

Read the script before you run it, and try it on a test server first.

## Requirements

Bash 4+, coreutils, iproute2 (ip, ss)
Root for process names and firewall rules
Optional: lsblk, lscpu, systemd-detect-virt

## Usage

```text
Usage: server-inventory-report.sh [options]
  --markdown     Markdown tables (tickets, wikis, handover notes)
  --json         JSON object: { "section": { "item": "value" } }
  --no-updates   skip the pending-updates count (it reads the dnf/yum/apt cache)
  --no-color     plain text output
  -h, --help     this help
```

## How we tested it

AlmaLinux 9.8 with DirectAdmin 1.712 (lab test, 6 Oct 2026); AlmaLinux 9.8 with cPanel & WHM 11.138 (lab test, 5 Oct 2026); Ubuntu 24.04

## Changes and licence

What changed in each version: [CHANGELOG.md](CHANGELOG.md). Releases are tagged `server-inventory-report/vX.Y.Z`.

MIT licence. If you copy, share or adapt the script, keep its header and credit [srvScripts.com](https://srvscripts.com/scripts/server-inventory-report/).
