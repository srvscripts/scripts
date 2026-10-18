# VoIP Toll Fraud Watch: Alert on International and After-Hours Calls in Asterisk

A Bash script that reads the Asterisk or FreePBX call records every few minutes and raises an alarm on the patterns of toll fraud: bursts of international or premium-rate calls, long international talk time, calls outside office hours, one extension making far more calls than usual, and transit calls that come in on a trunk and go straight back out.

**Full documentation, example output and troubleshooting:** <https://srvscripts.com/scripts/voip-toll-fraud-watch/>

Version 1.0.1 · updated 2026-10-17 · Lab-tested

## Download, verify and run

```bash
curl -fsSLO https://scr.srvscripts.com/voip-toll-fraud-watch/voip-toll-fraud-watch.sh
curl -fsSLO https://scr.srvscripts.com/voip-toll-fraud-watch/voip-toll-fraud-watch.sh.sha256
sha256sum -c voip-toll-fraud-watch.sh.sha256
bash voip-toll-fraud-watch.sh --help
```

Read the script before you run it, and try it on a test server first.

## Requirements

Bash 4+, awk; GNU awk (gawk) when reading Master.csv
FreePBX CDR database (asteriskcdrdb in MariaDB/MySQL) with the mysql client, or Asterisk cdr-csv Master.csv
Optional: mail for --mail, curl for --webhook

## Usage

```text
Usage: voip-toll-fraud-watch.sh [options]
  --minutes N            look at calls that started in the last N minutes (default 60)
  --max-intl-calls N     alarm when more than N international/premium calls were made (default 5)
  --max-intl-minutes N   alarm when international talk time is above N minutes (default 30)
  --max-ext-calls N      warn when one source made more than N outbound calls (default 40)
  --hours HH-HH          office hours, e.g. 08-18; outbound calls outside them are warnings (default: off)
  --days D-D             office days 1-7 (Mon=1) for --hours (default 1-5)
  --intl-regex RE        what counts as international (default '^(\+|00|011|9011|900|9900)')
  --allow-regex RE       destinations that are never suspicious (e.g. your own office abroad: '^01144207946')
  --source db|csv|auto   CDR source (default auto: the FreePBX database if reachable, else Master.csv)
  --db NAME              CDR database (default asteriskcdrdb)     --csv FILE  cdr-csv file
  --json                 JSON output            -q, --quiet   print only when something is suspicious
  --mail ADDR            e-mail alarms (needs 'mail')            --webhook URL  POST JSON alarms
  --every-time           send mail/webhook on every suspicious run (default: only when the findings change)
  -h, --help             this help
If it fires: disable the route or trunk (FreePBX: Connectivity > Outbound Routes), change the secret of the source
extension, check 'pjsip show contacts' for unknown IPs, and ask your SIP provider to block international calls.
Environment: MYSQL_ARGS extra mysql client arguments (FreePBX root works without any)
```

## How we tested it

1.0.1 and 1.0.0 on Debian 12 with FreePBX 17.0.33 and Asterisk 22.11 (lab test, 16 Oct 2026): simulated international bursts, after-hours calls and normal domestic calls through a test carrier

## Changes and licence

What changed in each version: [CHANGELOG.md](CHANGELOG.md). Releases are tagged `voip-toll-fraud-watch/vX.Y.Z`.

MIT licence. If you copy, share or adapt the script, keep its header and credit [srvScripts.com](https://srvscripts.com/scripts/voip-toll-fraud-watch/).
