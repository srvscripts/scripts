# Changelog: PBX Support Bundle for Asterisk and FreePBX: Share Diagnostics Without Passwords

File: `pbx-support-bundle.sh`. Page: <https://srvscripts.com/scripts/pbx-support-bundle/>

Newest first. Each version is tagged `pbx-support-bundle/vX.Y.Z` in this repository.

Tested on: 1.0.1 and 1.0.0 on Debian 12 with FreePBX 17.0.33 and Asterisk 22.11 (lab test, 16-17 Oct 2026): full run, dry run, independent leak check against the real passwords, a planted manager password, spaced Digest header and Bearer token; 20 automated fixtures

## 1.0.1

Digest values with spaces or on folded lines, Proxy-Authorization, Authentication-Info and Bearer credentials are masked; known passwords are read whole, spaces included; the scan list shows file, line and rule but never the value; no archive is made while the scan finds something (new --pack option scans again and packs after a fix); a failed archive is an error (exit 2). Found in an independent review.

## 1.0.0

Initial release
