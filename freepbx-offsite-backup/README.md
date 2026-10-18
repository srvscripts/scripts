# FreePBX Off-Site Backup Script: Databases, Config and Voicemail over rsync

A Bash script that backs up a FreePBX or Asterisk server without the FreePBX Backup module: both databases, the Asterisk internal database, configuration, voicemail, prompts and provisioning files, with checksums, a read-back check, an rsync/SSH copy to another server that is verified, and pruning of old sets.

**Full documentation, example output and troubleshooting:** <https://srvscripts.com/scripts/freepbx-offsite-backup/>

Version 1.0.1 · updated 2026-10-17 · Lab-tested

## Download, verify and run

```bash
curl -fsSLO https://scr.srvscripts.com/freepbx-offsite-backup/freepbx-offsite-backup.sh
curl -fsSLO https://scr.srvscripts.com/freepbx-offsite-backup/freepbx-offsite-backup.sh.sha256
sha256sum -c freepbx-offsite-backup.sh.sha256
bash freepbx-offsite-backup.sh --help
```

Read the script before you run it, and try it on a test server first.

## Requirements

Bash 4+, mysql and mysqldump (MariaDB/MySQL client), sqlite3 (required for a safe astdb copy), tar, gzip, sha256sum, flock
rsync and ssh on both servers for a remote destination
Root on the PBX; a dedicated SSH key and user on the backup server

## Usage

```text
Usage: freepbx-offsite-backup.sh --dest DEST [options]
  --dest DEST          user@host:/path (rsync over SSH) or /local/or/nfs/path
  --key FILE           SSH private key for the destination (recommended: a dedicated key)
  --port N             SSH port (default 22)
  --keep N             keep N backup sets locally and on the destination (default 7)
  --no-remote-prune    never delete old sets on the destination (for append-only or restricted accounts)
  --work DIR           local folder for the sets (default /var/backups/freepbx-offsite)
  --with-recordings    also back up /var/spool/asterisk/monitor (can be large)
  --bwlimit KBPS       limit upload bandwidth (rsync --bwlimit)
  --name PREFIX        set name prefix (default: short hostname)
  -q, --quiet          print only errors and the final line
  --mail ADDR          e-mail a report when something fails (needs 'mail')
  -h, --help           this help
Environment: MYSQL_ARGS extra mysql/mysqldump arguments (FreePBX root works without any)
```

## How we tested it

1.0.1 and 1.0.0 on Debian 12 with FreePBX 17.0.33 and Asterisk 22.11 (lab test, 16 Oct 2026): local and rsync/SSH destinations, verification, pruning and a test restore into a scratch database

## Changes and licence

What changed in each version: [CHANGELOG.md](CHANGELOG.md). Releases are tagged `freepbx-offsite-backup/vX.Y.Z`.

MIT licence. If you copy, share or adapt the script, keep its header and credit [srvScripts.com](https://srvscripts.com/scripts/freepbx-offsite-backup/).
