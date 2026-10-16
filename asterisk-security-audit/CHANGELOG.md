# Changelog: Asterisk Security Audit: Check FreePBX for Toll Fraud Risks and Exposed Ports

File: `asterisk-security-audit.sh`. Page: <https://srvscripts.com/scripts/asterisk-security-audit/>

Newest first. Each version is tagged `asterisk-security-audit/vX.Y.Z` in this repository.

Tested on: 1.0.1 and 1.0.0 on Debian 12 with FreePBX 17.0.33 and Asterisk 22.11 (lab test, 16 Oct 2026): fresh open-source install, deliberately weakened settings, then fixed

## 1.0.1

Failed CLI or database queries are UNKNOWN (exit 3) instead of PASS; an unreadable FreePBX database is reported. Found in an independent review.

## 1.0.0

Initial release
