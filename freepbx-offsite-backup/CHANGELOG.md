# Changelog: FreePBX Off-Site Backup Script: Databases, Config and Voicemail over rsync

File: `freepbx-offsite-backup.sh`. Page: <https://srvscripts.com/scripts/freepbx-offsite-backup/>

Newest first. Each version is tagged `freepbx-offsite-backup/vX.Y.Z` in this repository.

Tested on: 1.0.1 and 1.0.0 on Debian 12 with FreePBX 17.0.33 and Asterisk 22.11 (lab test, 16 Oct 2026): local and rsync/SSH destinations, verification, pruning and a test restore into a scratch database

## 1.0.1

A failed verification run, an unreadable database server, a missing FreePBX database or a missing sqlite3 are failures; no local pruning after a failed copy. Found in an independent review (V17-01, V17-04).

## 1.0.0

Initial release
