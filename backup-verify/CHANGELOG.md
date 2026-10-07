# Changelog: Backup Verify Script

File: `backup-verify.sh`. Page: <https://srvscripts.com/scripts/backup-verify/>

Newest first. Each version is tagged `backup-verify/vX.Y.Z` in this repository.

Tested on: AlmaLinux 9.8 with DirectAdmin 1.712 (lab test, 6 Oct 2026); AlmaLinux 9.8 with cPanel & WHM 11.138 (lab test, 5 Oct 2026); Ubuntu 24.04 (Bash 5.2, GNU tar 1.35, zstd 1.5.5) against cPanel-style, DirectAdmin-style and mysqldump fixture trees; 2.1.0 also against fixtures for a missing account list, missing accounts, two sources with the same account name and dated cPanel folders (container tests, not yet run on a production server)

## 2.1.1

DirectAdmin admin-level and reseller backups (admin.root.NAME, reseller.CREATOR.NAME) now count toward account coverage; 2.1.0 reported those accounts as missing (found on a DirectAdmin 1.712 test server).

## 2.1.0

Without a list of expected accounts, account coverage is UNVERIFIED (exit 1) instead of a warning followed by "All backups verified"; new --archives-only mode.

## 2.1.0

The summary states the test level (quick or deep) and the coverage result; the success line only claims the checks that ran.

## 2.1.0

Series are keyed by folder as well as file name (dated folders collapse to @date), so the same account from two sources is no longer merged.

## 2.0.0

Recursive search (--depth, default 5) so cPanel DATE/accounts/USER.tar.gz layouts are found.

## 2.0.0

Checks run per series (same account or database across runs) instead of on the single newest file; size is compared with the previous run of the same series.

## 2.0.0

Account coverage works off-site with --accounts-file / --expect, reads DirectAdmin users too, requires a fresh file, and warns (or fails with --require-coverage) when it cannot run.

## 2.0.0

A missing zstd, xz, bzip2, unzip or gzip, or an unreadable directory, is reported as UNVERIFIED and sets exit 1 unless --allow-unverified.

## 2.0.0

--deep checks the exit status of every pipeline stage; .tar.bz2 and .sql.zst support; summary counts; --all, --min-size, --no-color, --help, --version.

## 1.0.0

Initial release.
