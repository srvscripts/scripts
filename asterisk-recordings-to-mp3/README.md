# Asterisk Recordings to MP3: Bulk Convert FreePBX Call Recordings

Converts Asterisk, FreePBX and Issabel call recordings (WAV, WAV49, GSM, µ-law, SLN) to small mono MP3 files from cron, verifies each file and keeps the FreePBX call log player working.

**Full documentation, example output and troubleshooting:** <https://srvscripts.com/scripts/asterisk-recordings-to-mp3/>

Version 1.2.2 · updated 2026-10-10 · Lab-tested

## Download, verify and run

```bash
curl -fsSLO https://scr.srvscripts.com/asterisk-recordings-to-mp3/asterisk-recordings-to-mp3.sh
curl -fsSLO https://scr.srvscripts.com/asterisk-recordings-to-mp3/asterisk-recordings-to-mp3.sh.sha256
sha256sum -c asterisk-recordings-to-mp3.sh.sha256
bash asterisk-recordings-to-mp3.sh --help
```

Read the script before you run it, and try it on a test server first.

## Requirements

Bash 4+, GNU findutils and coreutils, flock (util-linux)
ffmpeg with libmp3lame, or sox and lame
Optional: mysql or mariadb client for --update-cdr (FreePBX)

## Usage

```text
Usage: asterisk-recordings-to-mp3.sh [options]
  --dir DIR            recordings folder (default /var/spool/asterisk/monitor), searched recursively
  --older-than MIN     skip files modified in the last MIN minutes, still recording (default 2;
                       files changed in the last 60 seconds or held open are always skipped)
  --days N             only files modified in the last N days (default 0 = all)
  --bitrate KBPS       MP3 bit rate: 16, 24, 32, 48 or 64 (default 32)
  --ext LIST           extensions to convert, comma separated (default wav,WAV,wav49,gsm;
                       also: ulaw,alaw,sln,sln16,g722,g729 with ffmpeg)
  --delete-original    delete each original after its MP3 is verified (default: keep both;
                       needs ffprobe or sox to read the MP3 back, otherwise originals are kept)
  --update-cdr         FreePBX: change recordingfile in asteriskcdrdb.cdr to the .mp3 name; a file
                       whose update fails or matches no row keeps its original and is retried next run
  --cdr-db NAME        CDR database name (default asteriskcdrdb)
  --encoder NAME       auto | ffmpeg | sox (default auto: ffmpeg if installed, else sox + lame)
  --dry-run            only list what would be converted
  -q, --quiet          print only the summary and errors
  -h, --help           this help
Environment: MYSQL_ARGS extra arguments for the mysql client (FreePBX root can use /root/.my.cnf)
             RECORDINGS_MP3_LOCK lock file (default /run/asterisk-recordings-to-mp3.lock for root,
                                 /run/lock/asterisk-recordings-to-mp3.lock otherwise)
             TMPDIR              parent of the private work folder (default /tmp)
```

## How we tested it

1.2.2 on Debian 12 with FreePBX 17 and Asterisk 22.11 (lab test, 10 Oct 2026): a recording converted as root with ffmpeg and --delete-original (4.39 s MP3 owned by asterisk, original deleted), and a recording whose MP3 name was already a folder was skipped with nothing written into the folder and the original kept. 29 stand-in-program regression checks run in CI before every release, including a folder and a link to a folder created at the MP3 name during conversion (refused, original kept, call log not updated; 1.2.1 fails these) and a run killed half-way through writing the MP3.

## Changes and licence

What changed in each version: [CHANGELOG.md](CHANGELOG.md). Releases are tagged `asterisk-recordings-to-mp3/vX.Y.Z`.

MIT licence. If you copy, share or adapt the script, keep its header and credit [srvScripts.com](https://srvscripts.com/scripts/asterisk-recordings-to-mp3/).
