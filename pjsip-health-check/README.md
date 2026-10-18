# PJSIP Health Check: Monitor Asterisk Trunks, Registrations and Phones

A read-only Bash script that checks Asterisk and FreePBX PJSIP trunks, outbound registrations, contact round-trip times, phones and active calls, with Nagios-style exit codes, JSON output and mail or webhook alerts when something changes.

**Full documentation, example output and troubleshooting:** <https://srvscripts.com/scripts/pjsip-health-check/>

Version 1.0.1 · updated 2026-10-17 · Lab-tested

## Download, verify and run

```bash
curl -fsSLO https://scr.srvscripts.com/pjsip-health-check/pjsip-health-check.sh
curl -fsSLO https://scr.srvscripts.com/pjsip-health-check/pjsip-health-check.sh.sha256
sha256sum -c pjsip-health-check.sh.sha256
bash pjsip-health-check.sh --help
```

Read the script before you run it, and try it on a test server first.

## Requirements

Bash 4+, Asterisk 18 or newer with chan_pjsip (FreePBX 16/17, VitalPBX, Issabel 5 or plain Asterisk)
Run as root or a user allowed to use asterisk -rx
Optional: mail (mailutils or s-nail) for --mail, curl for --webhook

## Usage

```text
Usage: pjsip-health-check.sh [options]
  --rtt-warn MS        warn when a reachable contact's round-trip time is above MS (default 200)
  --rtt-crit MS        critical above MS (default 800)
  --max-calls N        warn when more than N calls are active (default 0 = no limit). A sudden jump is a
                       common sign of toll fraud.
  --phones-warn        treat unreachable phones as WARNING (default: listed only)
  --ignore REGEX       skip endpoints whose name matches REGEX (e.g. '^(9[0-9]{3}|test)')
  --json               print the report as JSON
  -q, --quiet          print nothing when everything is OK; problems only
  --mail ADDR          e-mail the report (needs a working 'mail' command) when the status is not OK
  --webhook URL        POST the JSON report to URL (Slack/Discord/Teams-compatible "text" field included)
  --notify-on-change   only send mail/webhook when the set of problems changes (state in /var/lib/pjsip-health-check)
  --state-dir DIR      where the change-detection state is kept
  --require-trunk LIST comma-separated trunk names that must exist; a missing one is CRITICAL (catches a trunk
                       that disappeared from the configuration, which would otherwise just lower the counts)
  --timeout SEC        seconds to wait for each Asterisk CLI command (default 10)
  -h, --help           this help
Environment: ASTERISK_BIN path to the asterisk binary (default: asterisk in PATH)
```

## How we tested it

1.0.1 and 1.0.0 on Debian 12 with FreePBX 17.0.33 and Asterisk 22.11 (lab test, 16 Oct 2026): trunk up, trunk taken down, JSON output, unreachable phones

## Changes and licence

What changed in each version: [CHANGELOG.md](CHANGELOG.md). Releases are tagged `pjsip-health-check/vX.Y.Z`.

MIT licence. If you copy, share or adapt the script, keep its header and credit [srvScripts.com](https://srvscripts.com/scripts/pjsip-health-check/).
