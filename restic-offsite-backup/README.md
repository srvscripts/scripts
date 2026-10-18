# Restic Backup Script for Offsite Backups

A restic backup script for cron: dumps every MariaDB/MySQL database, backs up to any restic repository, applies daily/weekly/monthly retention, checks integrity and test-restores a random file.

**Full documentation, example output and troubleshooting:** <https://srvscripts.com/scripts/restic-offsite-backup/>

Version 1.3.0 · updated 2026-10-13 · Production-tested

## Download, verify and run

```bash
curl -fsSLO https://scr.srvscripts.com/restic-offsite-backup/restic-offsite-backup.sh
curl -fsSLO https://scr.srvscripts.com/restic-offsite-backup/restic-offsite-backup.sh.sha256
sha256sum -c restic-offsite-backup.sh.sha256
bash restic-offsite-backup.sh --help
```

Read the script before you run it, and try it on a test server first.

## Requirements

Bash 4+, root, flock (util-linux)
restic 0.12 or newer (0.14+ recommended for compression)
Optional: mysql/mariadb client and mysqldump/mariadb-dump for MYSQL_DUMP=yes

## Usage

```text
Usage: restic-offsite-backup.sh [mode] [options]
Modes (default: backup):
  --init            create the restic repository (asks unless --yes)
  --list            list this host's snapshots
  --restore-test    restore one random file from the latest snapshot and verify its checksum
  --check           run the integrity check now (normally every CHECK_EVERY_DAYS days)
Options:
  --config FILE     config file (default /etc/srvscripts/restic.conf)
  --dry-run         backup mode: show what would be saved and forgotten, change nothing
  --yes             do not ask for confirmation (--init)
  -v, --verbose     also print restic's own output (it always goes to the log)
  -h, --help        this help;  --version  print the version
```

## How we tested it

In production since 7 Oct 2026 on the srvScripts.com server (DirectAdmin, MariaDB, SFTP repository on a second server): nightly backup, retention, weekly integrity check, and an isolated restore on a third server with the database imported and row counts and plugin files identical to the live site. 1.2.0 on AlmaLinux 9.8 with cPanel & WHM 11.138, MariaDB 10.11.19 and restic 0.19.1 (lab test, 7 Oct 2026): init, two nightly runs with 4 databases, foreign files in DUMP_DIR kept byte-for-byte, dump restored from the snapshot, retention, integrity check and restore test; 10 safety fixtures (planted .part symlink, name collisions, failed and interrupted dumps); restic 0.16.4 with a local repository and MariaDB 10.11.14 on Ubuntu 24.04 (container): complete backup, database dump restored and imported, retention, restore test, and refusal of an unmarked DUMP_DIR; 1.1.0 safety cases (populated or symlinked DUMP_DIR, system paths, failed dump, restic exit 3, missing path, interruption, dry run) with stub commands. 1.3.0: regression fixtures for RETENTION=no/yes, an invalid RETENTION value and URL password masking (local repository, restic 0.19.1)

## Changes and licence

What changed in each version: [CHANGELOG.md](CHANGELOG.md). Releases are tagged `restic-offsite-backup/vX.Y.Z`.

MIT licence. If you copy, share or adapt the script, keep its header and credit [srvScripts.com](https://srvscripts.com/scripts/restic-offsite-backup/).
