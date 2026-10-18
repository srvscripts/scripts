# PBX Support Bundle for Asterisk and FreePBX: Share Diagnostics Without Passwords

A Bash script that collects what a consultant or your SIP provider asks for (versions, PJSIP transports, endpoints, registrations, selected configs and recent logs) into a private archive, with passwords, digest values, keys, e-mail addresses, public IPs and phone numbers masked. Nothing is uploaded.

**Full documentation, example output and troubleshooting:** <https://srvscripts.com/scripts/pbx-support-bundle/>

Version 1.0.4 · updated 2026-10-18 · Lab-tested

## Download, verify and run

```bash
curl -fsSLO https://scr.srvscripts.com/pbx-support-bundle/pbx-support-bundle.sh
curl -fsSLO https://scr.srvscripts.com/pbx-support-bundle/pbx-support-bundle.sh.sha256
sha256sum -c pbx-support-bundle.sh.sha256
bash pbx-support-bundle.sh --help
```

Read the script before you run it, and try it on a test server first.

## Requirements

Bash 4+, perl and tar (part of every Debian, Ubuntu and RHEL-family base system)
Run as root on the PBX so it can use the Asterisk CLI and read the logs
FreePBX is optional: on plain Asterisk the FreePBX sections are simply empty

## Usage

```text
Usage: pbx-support-bundle.sh [options]
  --out DIR            where to write the bundle (default /root)
  --lines N            last N lines of the Asterisk "full" log (default 2000, 0 = none)
  --conf DIR           Asterisk config folder (default /etc/asterisk)
  --logdir DIR         Asterisk log folder (default /var/log/asterisk)
  --mask-private-ips   also mask private (RFC 1918) addresses; by default they are kept, they help with NAT problems
  --keep-ips           do not mask any IP address (public addresses are masked by default)
  --keep-host          keep this server's host and domain name (masked as pbx.example.com by default)
  --keep-numbers       keep phone numbers (7 to 15 digits are masked by default, last 2 digits kept)
  --dry-run            list what would be collected and exit
  --pack DIR           after you edited a bundle folder: scan it again and create the archive if it is clean
  -h, --help           this help
```

## How we tested it

1.0.4 (comment-only change of 1.0.3), 1.0.3, 1.0.2, 1.0.1 and 1.0.0 on Debian 12 with FreePBX 17.0.33 and Asterisk 22.11 (lab test, 16-17 Oct 2026): full run, dry run, independent leak check against the real passwords, a planted manager password, SDES key, ICE password, spaced Digest header and Bearer token; 40 automated checks

## Changes and licence

What changed in each version: [CHANGELOG.md](CHANGELOG.md). Releases are tagged `pbx-support-bundle/vX.Y.Z`.

MIT licence. If you copy, share or adapt the script, keep its header and credit [srvScripts.com](https://srvscripts.com/scripts/pbx-support-bundle/).
