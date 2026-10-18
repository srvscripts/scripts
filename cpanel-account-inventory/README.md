# cPanel Account Inventory

A cPanel account inventory in one command: domain, addon and parked counts, IP, package, owner, disk, inodes, mailboxes, databases, PHP version, creation date and suspension for every account.

**Full documentation, example output and troubleshooting:** <https://srvscripts.com/scripts/cpanel-account-inventory/>

Version 1.0.0 · updated 2026-10-06 · Lab-tested

## Download, verify and run

```bash
curl -fsSLO https://scr.srvscripts.com/cpanel-account-inventory/cpanel-account-inventory.sh
curl -fsSLO https://scr.srvscripts.com/cpanel-account-inventory/cpanel-account-inventory.sh.sha256
sha256sum -c cpanel-account-inventory.sh.sha256
bash cpanel-account-inventory.sh --help
```

Read the script before you run it, and try it on a test server first.

## Requirements

cPanel/WHM, Bash 4+, root
perl with JSON::PP for database counts (cPanel ships its own)

## Usage

```text
Usage: cpanel-account-inventory.sh [options]

Prints one row per cPanel account: user, main domain, addon and parked domain
counts, IP, package, owner, disk used, inodes, email accounts, databases, PHP
version of the main domain, creation date and suspension flag. Read-only.

Options:
  --csv FILE    write CSV to FILE instead of the table ("-" = stdout)
  -h, --help    this help

Exit codes: 0 = OK, 2 = usage/dependency error.
```

## How we tested it

AlmaLinux 9.8 with cPanel & WHM 11.138 (lab test, 5 Oct 2026); Parsing verified on sample cPanel data; written for cPanel on AlmaLinux 8/9 and CloudLinux 8/9

## Changes and licence

What changed in each version: [CHANGELOG.md](CHANGELOG.md). Releases are tagged `cpanel-account-inventory/vX.Y.Z`.

MIT licence. If you copy, share or adapt the script, keep its header and credit [srvScripts.com](https://srvscripts.com/scripts/cpanel-account-inventory/).
