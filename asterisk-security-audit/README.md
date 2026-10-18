# Asterisk Security Audit: Check FreePBX for Toll Fraud Risks and Exposed Ports

A read-only Bash audit for Asterisk and FreePBX that finds the settings behind toll fraud and hijacked PBXs: unsupported versions, public AMI or IAX2, weak SIP passwords, anonymous SIP, trusted IPs in internal contexts, a blind fail2ban jail and unprotected international routes, each with a one-line fix.

**Full documentation, example output and troubleshooting:** <https://srvscripts.com/scripts/asterisk-security-audit/>

Version 1.0.1 · updated 2026-10-17 · Lab-tested

## Download, verify and run

```bash
curl -fsSLO https://scr.srvscripts.com/asterisk-security-audit/asterisk-security-audit.sh
curl -fsSLO https://scr.srvscripts.com/asterisk-security-audit/asterisk-security-audit.sh.sha256
sha256sum -c asterisk-security-audit.sh.sha256
bash asterisk-security-audit.sh --help
```

Read the script before you run it, and try it on a test server first.

## Requirements

Bash 4+, Asterisk 18 or newer (FreePBX 15-17, VitalPBX, Issabel or plain Asterisk)
Root (reads /etc/asterisk, the FreePBX database and the firewall rules)
ss (iproute2); optional: fail2ban-client, nft or iptables, mysql client for the FreePBX route checks

## Usage

```text
Usage: asterisk-security-audit.sh [options]
  --json            print findings as JSON
  --fails-only      print FAIL lines only (plus the summary)
  --min-secret N    minimum SIP/AMI password length (default 12)
  --conf DIR        Asterisk config folder (default /etc/asterisk)
  -h, --help        this help
Environment: ASTERISK_BIN (default asterisk), MYSQL_ARGS extra mysql client arguments for the FreePBX database
```

## How we tested it

1.0.1 and 1.0.0 on Debian 12 with FreePBX 17.0.33 and Asterisk 22.11 (lab test, 16 Oct 2026): fresh open-source install, deliberately weakened settings, then fixed

## Changes and licence

What changed in each version: [CHANGELOG.md](CHANGELOG.md). Releases are tagged `asterisk-security-audit/vX.Y.Z`.

MIT licence. If you copy, share or adapt the script, keep its header and credit [srvScripts.com](https://srvscripts.com/scripts/asterisk-security-audit/).
