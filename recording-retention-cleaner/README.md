# Call Recording Retention Cleaner: Delete or Archive Old FreePBX Recordings

A Bash script that enforces a retention period on Asterisk and FreePBX call recordings. It is a dry run by default, can archive old recordings into a verified tar.gz before deleting them, skips calls still being recorded, can stop the FreePBX call log linking to removed files, and can run only when the disk is filling up.

**Full documentation, example output and troubleshooting:** <https://srvscripts.com/scripts/recording-retention-cleaner/>

Version 1.0.1 · updated 2026-10-17 · Lab-tested

## Download, verify and run

```bash
curl -fsSLO https://scr.srvscripts.com/recording-retention-cleaner/recording-retention-cleaner.sh
curl -fsSLO https://scr.srvscripts.com/recording-retention-cleaner/recording-retention-cleaner.sh.sha256
sha256sum -c recording-retention-cleaner.sh.sha256
bash recording-retention-cleaner.sh --help
```

Read the script before you run it, and try it on a test server first.

## Requirements

Bash 4+, GNU findutils and coreutils, tar, gzip, flock (util-linux), Linux /proc
Run as root (or as the user that writes the recordings) so open files are visible
Optional: mysql client for --update-cdr (FreePBX)

## How we tested it

1.0.1 and 1.0.0 on Debian 12 with FreePBX 17.0.33 and Asterisk 22.11 (lab test, 16 Oct 2026): 100 test recordings spread over 150 days; dry run, archive and delete, CDR unlink, restore from the archive

## Changes and licence

What changed in each version: [CHANGELOG.md](CHANGELOG.md). Releases are tagged `recording-retention-cleaner/vX.Y.Z`.

MIT licence. If you copy, share or adapt the script, keep its header and credit [srvScripts.com](https://srvscripts.com/scripts/recording-retention-cleaner/).
