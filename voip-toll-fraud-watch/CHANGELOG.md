# Changelog: VoIP Toll Fraud Watch: Alert on International and After-Hours Calls in Asterisk

File: `voip-toll-fraud-watch.sh`. Page: <https://srvscripts.com/scripts/voip-toll-fraud-watch/>

Newest first. Each version is tagged `voip-toll-fraud-watch/vX.Y.Z` in this repository.

Tested on: 1.0.1 and 1.0.0 on Debian 12 with FreePBX 17.0.33 and Asterisk 22.11 (lab test, 16 Oct 2026): simulated international bursts, after-hours calls and normal domestic calls through a test carrier

## 1.0.1

On FreePBX, or with --source db, an unreadable CDR database is UNKNOWN (exit 3) instead of a fallback to Master.csv. Skipped transit check shown. Alerts retried until delivered. Found in an independent review.

## 1.0.0

Initial release
