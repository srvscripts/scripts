# Changelog: Asterisk Recordings to MP3: Bulk Convert FreePBX Call Recordings

File: `asterisk-recordings-to-mp3.sh`. Page: <https://srvscripts.com/scripts/asterisk-recordings-to-mp3/>

Newest first. Each version is tagged `asterisk-recordings-to-mp3/vX.Y.Z` in this repository.

Tested on: 1.2.0 on Debian 12 with FreePBX 17 and Asterisk 22.11 (lab test, 9 Oct 2026): wav and gsm recordings converted as root with ffmpeg and with sox+lame (MP3s owned by asterisk, original time kept); a planted .mp3.part link to a root-only test file and a dangling link at the final MP3 name left the test file unchanged and created nothing at the link target. 18 stand-in-program regression checks run in CI before every release (1.1.0 fails them). Version 1.1.0 was tested on the same server on 7 Oct 2026.

## 1.2.0

Output files are never written through links or over existing files. Each recording is copied into a private work folder (mktemp -d), encoded and verified there; as root, the recording is read, its MP3 created with exclusive creation and the original deleted as the recording's owner (setpriv). An MP3 that already exists, is a link (even dangling) or appears during the run is left untouched and reported. The .mp3.part file and mv -f are gone. Root-owned recordings are converted only in folders only root can change. Root's lock file moved to /run and is opened without truncation, never through a link. Found in an independent review (FRESH-02); regression fixtures added to CI.

## 1.1.0

Originals are deleted only when encoding, full read-back (positive length matching the original within 1 s or 2%), owner/time copy, rename and, with --update-cdr, a call-log update of at least one row all succeeded. Any failure keeps the original, removes the MP3 for a retry next run and exits 1 (1.0.0 deleted the original after a failed CDR update). Without ffprobe or sox nothing is deleted. Recordings changed in the last 60 seconds or still open are skipped. Found in an external review (PROD7-03).

## 1.0.0

Initial release
