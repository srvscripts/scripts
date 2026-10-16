# Changelog: Call Recording Retention Cleaner: Delete or Archive Old FreePBX Recordings

File: `recording-retention-cleaner.sh`. Page: <https://srvscripts.com/scripts/recording-retention-cleaner/>

Newest first. Each version is tagged `recording-retention-cleaner/vX.Y.Z` in this repository.

Tested on: 1.0.1 and 1.0.0 on Debian 12 with FreePBX 17.0.33 and Asterisk 22.11 (lab test, 16 Oct 2026): 100 test recordings spread over 150 days; dry run, archive and delete, CDR unlink, restore from the archive

## 1.0.1

Open files found in /proc (when every old file was open, 1.0.0 could remove them); each file re-checked right before removal; NUL-safe names; failed CDR update is exit 2. Found in an independent review (V17-02).

## 1.0.0

Initial release
