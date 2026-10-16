# Changelog: PJSIP Health Check: Monitor Asterisk Trunks, Registrations and Phones

File: `pjsip-health-check.sh`. Page: <https://srvscripts.com/scripts/pjsip-health-check/>

Newest first. Each version is tagged `pjsip-health-check/vX.Y.Z` in this repository.

Tested on: 1.0.1 and 1.0.0 on Debian 12 with FreePBX 17.0.33 and Asterisk 22.11 (lab test, 16 Oct 2026): trunk up, trunk taken down, JSON output, unreachable phones

## 1.0.1

A failed or malformed CLI query is UNKNOWN (exit 3); 1.0.0 could report OK with zero objects. Endpoints without a caller ID are counted. New --require-trunk. Alert state saved per channel only after delivery. Found in an independent review (V17-03).

## 1.0.0

Initial release
