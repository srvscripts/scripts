# Changelog: SIPp Call Load Test for Asterisk and FreePBX, Checked Against the CDR

File: `sipp-call-load-test.sh`. Page: <https://srvscripts.com/scripts/sipp-call-load-test/>

Newest first. Each version is tagged `sipp-call-load-test/vX.Y.Z` in this repository.

Tested on: 1.0.1 and 1.0.0 on Debian 12 with FreePBX 17.0.33 and Asterisk 22.11 (lab test, 16-17 Oct 2026) with SIPp 3.6.1 and a SIPp test carrier: 30 calls, 200 calls (60 at once), the false-success case, an interrupted run, 0.5 calls per second, a wrong password and --no-cdr; 27 automated fixtures

## 1.0.1

An incomplete run (SIPp stopped by its time limit, fewer calls started than requested, counters missing) is reported as INCOMPLETE instead of OK; carrier delivery counts only calls answered on the FreePBX trunk list or --carrier, within the test's start and end time, and late call records are waited for; fractional rates such as 0.5 work, and impossible plans are refused before any call. Found in an independent review.

## 1.0.0

Initial release
