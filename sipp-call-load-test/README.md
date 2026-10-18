# SIPp Call Load Test for Asterisk and FreePBX, Checked Against the CDR

A Bash wrapper around SIPp that registers as one of your extensions, places a controlled burst of calls through Asterisk or FreePBX and then reads the call records, so calls the PBX answered itself are reported as false successes instead of delivered calls.

**Full documentation, example output and troubleshooting:** <https://srvscripts.com/scripts/sipp-call-load-test/>

Version 1.0.1 · updated 2026-10-17 · Lab-tested

## Download, verify and run

```bash
curl -fsSLO https://scr.srvscripts.com/sipp-call-load-test/sipp-call-load-test.sh
curl -fsSLO https://scr.srvscripts.com/sipp-call-load-test/sipp-call-load-test.sh.sha256
sha256sum -c sipp-call-load-test.sh.sha256
bash sipp-call-load-test.sh --help
```

Read the script before you run it, and try it on a test server first.

## Requirements

Bash 4+, SIPp 3.6 or newer (Debian/Ubuntu: apt install sip-tester)
On the PBX for the checks: mysql client with access to the FreePBX CDR (asteriskcdrdb) and trunk list (asterisk.trunks), asterisk CLI; on plain Asterisk give your trunk with --carrier
An extension password without ; [ ] or spaces (use a dedicated test extension)

## Usage

```text
Usage: sipp-call-load-test.sh --ext EXT --number NUMBER [options]
  --ext EXT            extension SIPp registers as (its password: env SIPP_SECRET or --secret-file)
  --secret-file FILE   file holding only the extension password (keep it mode 600)
  --number NUMBER      number to dial (a test number or test carrier; see the cost warning)
  --calls N            total calls (default 20, max 5000)
  --rate R             new calls per second, 0.01-1000, e.g. 0.5 (default 2)
  --max M              at most M calls at the same time (default 10)
  --hold SEC           seconds each answered call stays up (default 5)
  --pbx HOST[:PORT]    PBX to call through (default 127.0.0.1:5060, i.e. run this on the PBX)
  --local-ip IP        source address for SIPp (default: the address used to reach the PBX)
  --carrier REGEX      count a call as delivered only if its CDR dstchannel matches REGEX (e.g. '^PJSIP/mytrunk-');
                       default: the trunks in the FreePBX trunk list (needed on plain Asterisk)
  --no-cdr             skip the CDR check (remote PBX); delivery to the carrier is then not verified
  --yes                do not ask for confirmation
  -h, --help           this help
Environment: SIPP_SECRET (extension password), MYSQL_ARGS (extra mysql arguments), ASTERISK_BIN,
  CDR_WAIT (seconds to wait for late call records, default 20)
Needs: sipp (Debian/Ubuntu: apt install sip-tester), plus mysql and asterisk on the PBX for the checks.
```

## How we tested it

1.0.1 and 1.0.0 on Debian 12 with FreePBX 17.0.33 and Asterisk 22.11 (lab test, 16-17 Oct 2026) with SIPp 3.6.1 and a SIPp test carrier: 30 calls, 200 calls (60 at once), the false-success case, an interrupted run, 0.5 calls per second, a wrong password and --no-cdr; 27 automated fixtures

## Changes and licence

What changed in each version: [CHANGELOG.md](CHANGELOG.md). Releases are tagged `sipp-call-load-test/vX.Y.Z`.

MIT licence. If you copy, share or adapt the script, keep its header and credit [srvScripts.com](https://srvscripts.com/scripts/sipp-call-load-test/).
