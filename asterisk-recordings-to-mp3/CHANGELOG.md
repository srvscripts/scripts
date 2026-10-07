# Changelog: Asterisk Recordings to MP3: Bulk Convert FreePBX Call Recordings

File: `asterisk-recordings-to-mp3.sh`. Page: <https://srvscripts.com/scripts/asterisk-recordings-to-mp3/>

Newest first. Each version is tagged `asterisk-recordings-to-mp3/vX.Y.Z` in this repository.

Tested on: 1.1.0 on Debian 12 with FreePBX 17 and Asterisk 22.11 (lab test, 7 Oct 2026): wav and gsm converted with --delete-original --update-cdr and the call log updated; a recording with no call-log row kept its original (exit 1); unreadable CDR database stops before any change; 16 failure fixtures (CDR error/0 rows, zero-length and truncated MP3, rename/owner/time failures, open files); Debian 12 with FreePBX 17.0 and Asterisk 22.11 (lab test with real MixMonitor recordings, 6 Oct 2026); Ubuntu 24.04 with ffmpeg 6.1, SoX 14.4.2 and LAME 3.100, sample Asterisk recordings (wav, WAV49, gsm, ulaw, sln16)

## 1.1.0

Originals are deleted only when encoding, full read-back (positive length matching the original within 1 s or 2%), owner/time copy, rename and, with --update-cdr, a call-log update of at least one row all succeeded. Any failure keeps the original, removes the MP3 for a retry next run and exits 1 (1.0.0 deleted the original after a failed CDR update). Without ffprobe or sox nothing is deleted. Recordings changed in the last 60 seconds or still open are skipped. Found in an external review (PROD7-03).

## 1.0.0

Initial release
