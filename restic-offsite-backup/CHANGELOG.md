# Changelog: Restic Backup Script for Offsite Backups

File: `restic-offsite-backup.sh`. Page: <https://srvscripts.com/scripts/restic-offsite-backup/>

Newest first. Each version is tagged `restic-offsite-backup/vX.Y.Z` in this repository.

Tested on: 1.2.0 on AlmaLinux 9.8 with cPanel & WHM 11.138, MariaDB 10.11.19 and restic 0.19.1 (lab test, 7 Oct 2026): init, two nightly runs with 4 databases, foreign files in DUMP_DIR kept byte-for-byte, dump restored from the snapshot, retention, integrity check and restore test; 10 safety fixtures (planted .part symlink, name collisions, failed and interrupted dumps); restic 0.16.4 with a local repository and MariaDB 10.11.14 on Ubuntu 24.04 (container): complete backup, database dump restored and imported, retention, restore test, and refusal of an unmarked DUMP_DIR; 1.1.0 safety cases (populated or symlinked DUMP_DIR, system paths, failed dump, restic exit 3, missing path, interruption, dry run) with stub commands. Not yet run on a production server.

## 1.2.0

Each run dumps into its own new DUMP_DIR/run.XXXXXX workspace: dumps are created exclusively (no overwrite, no symlink following) and only that run's own files are deleted, so an unrelated file such as appdb.sql in DUMP_DIR is never overwritten or removed (1.1.0 could). Database names changed by sanitising get a short hash so two databases can never share a file. Found in an external review (PROD7-02).

## 1.2.0

Restore tip: dumps are now at DUMP_DIR/run.XXXXXX/.sql inside snapshots; find them with restic ls latest | grep '\.sql$'.

## 1.1.0

DUMP_DIR must be new, empty or created by this script (marker file); symlinks, system paths and directories writable by others are refused, and only the dump files a run wrote are deleted, including after an interruption.

## 1.1.0

Retention (forget --prune) is skipped when a path is missing, a dump fails or restic could not read every file; such snapshots are tagged "incomplete". ALLOW_PARTIAL_PRUNE=yes restores the old behaviour.

## 1.1.0

--version; dumps are written to a .part file and renamed when complete.

## 1.0.0

Initial release
