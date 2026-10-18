# Server Security Audit Script

A read-only server security audit script for Linux: SSH, firewall, brute-force protection, updates, ports, sudo and filesystem checks as PASS/WARN lines. Checks it cannot run are SKIP, never PASS.

**Full documentation, example output and troubleshooting:** <https://srvscripts.com/scripts/server-security-audit/>

Version 2.3.0 · updated 2026-10-07 · Lab-tested

## Download, verify and run

```bash
curl -fsSLO https://scr.srvscripts.com/server-security-audit/server-security-audit.sh
curl -fsSLO https://scr.srvscripts.com/server-security-audit/server-security-audit.sh.sha256
sha256sum -c server-security-audit.sh.sha256
bash server-security-audit.sh --help
```

Read the script before you run it, and try it on a test server first.

## Requirements

Bash 4+, root for full coverage
AlmaLinux/Rocky 8-9, Ubuntu 22.04+, Debian 12
Optional: csf, fail2ban, whmapi1, imunify360-agent, needs-restarting (dnf-utils)

## Usage

```text
Usage: server-security-audit.sh [--brief] [--allow-skipped] [--no-color]
  --brief          print only WARN and SKIP lines plus the summary
  --allow-skipped  exit 0 even if some checks could not run (e.g. not root)
  --no-color       no colours (colour is only used on a terminal anyway)
  -h, --help       this help;  --version  print the version
```

## How we tested it

2.3.0 on Debian 12 with FreePBX 17 (fail2ban only, ACCEPT policy: WARN; with a TCP ACCEPT inserted before a TCP DROP: WARN UNVERIFIED, where 2.2.1 said PASS), AlmaLinux 9.8 with DirectAdmin 1.712 and CSF (PASS) and AlmaLinux 9.8 with cPanel & WHM 11.138 nftables (WARN UNVERIFIED) (lab test, 7 Oct 2026); 61 iptables/nft parser fixtures under gawk and mawk; AlmaLinux 9.8 with DirectAdmin 1.712 (lab test, 6 Oct 2026); AlmaLinux 9.8 with cPanel & WHM 11.138 (lab test, 5 Oct 2026); Ubuntu 24.04 as root and as an unprivileged user; dnf, apt-get, needs-restarting, whmapi1 and csf failure paths tested with stub commands; 2.2.0 firewall evaluation tested with 15 iptables and nft rule fixtures (accept-all before drop, accept-only, policy drop, CSF, ufw and firewalld-style user chains, RETURN, unrelated chains, unreadable rules) under gawk and mawk, and with real iptables-nft and nftables rules in a network namespace; systemctl, Imunify360 and fail2ban states with stub commands (container tests, not yet run on a production server)

## Changes and licence

What changed in each version: [CHANGELOG.md](CHANGELOG.md). Releases are tagged `server-security-audit/vX.Y.Z`.

MIT licence. If you copy, share or adapt the script, keep its header and credit [srvScripts.com](https://srvscripts.com/scripts/server-security-audit/).
