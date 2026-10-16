#!/usr/bin/env bash
# Asterisk Call Recording Retention Cleaner: Delete or Archive Old FreePBX Recordings (v1.0.0) - from srvScripts.com
# Source, docs and updates: https://srvscripts.com/scripts/recording-retention-cleaner/
# Copyright (c) 2026 srvScripts.com. MIT licence: if you copy, share or adapt this script, keep this notice and credit srvScripts.com.
#
# Default is a DRY RUN: it only lists what it would remove and how much space that frees.
# Nothing is deleted unless you pass --apply. With --archive DIR, old recordings are moved
# into a dated .tar.gz archive instead of being deleted.
#
# Version 1.0.0 (2026-10-17): first release. Tested on FreePBX 17.0.33 / Asterisk 22.11 (Debian 12) with 100 test
#   recordings spread over 150 days: dry run, archive + delete, CDR unlink, restore from the archive.
# Should work on any Asterisk box that stores recordings as files (FreePBX layout
# /var/spool/asterisk/monitor/YYYY/MM/DD/*.wav|*.mp3|*.gsm).
#
# BEFORE YOU RUN WITH --apply
#   1. Run it without --apply and read the list.
#   2. Check your legal / contract retention period first (call recording rules differ by country).
#   3. If you might need the files later, use --archive /path instead of plain delete, or back up:
#        tar -czf /root/recordings-backup-$(date +%F).tar.gz -C /var/spool/asterisk monitor
#   4. With --update-cdr, back up the CDR table too:
#        mysqldump asteriskcdrdb cdr | gzip > /root/cdr-backup-$(date +%F).sql.gz
# REVERT
#   Deleted files cannot be undone by this script. Restore from your backup or archive:
#        tar -xzpf ARCHIVE.tar.gz -C /          (archives store absolute paths without the leading /)
#   CDR links:  zcat /root/cdr-backup-DATE.sql.gz | mysql asteriskcdrdb
#
# Usage: recording-retention-cleaner.sh [options]
#   --days N           keep recordings newer than N days (default 90)
#   --dir PATH         recordings folder (default /var/spool/asterisk/monitor)
#   --apply            actually delete (or archive). Without it: dry run
#   --archive DIR      move old files into DIR/recordings-YYYYmmdd-HHMMSS.tar.gz, then delete originals
#   --only-if-disk P   do nothing unless the filesystem is at least P% full
#   --update-cdr       blank cdr.recordingfile for removed files (FreePBX CDR reports stop linking them)
#   --min-age-min M    never touch files modified in the last M minutes (default 30; protects live calls)
#   --list N           show up to N file names (default 20)
#   --quiet            print only the summary line
#   --json             machine-readable summary
#   -h | --help
# Exit codes: 0 ok / nothing to do, 1 disk still above --only-if-disk after cleaning, 2 error
set -euo pipefail
VERSION=1.0.0
DIR=/var/spool/asterisk/monitor
DAYS=90; APPLY=0; ARCHIVE=""; DISKP=""; UPDCDR=0; MINAGE=30; LIST=20; QUIET=0; JSON=0
EXTS='wav|WAV|mp3|gsm|ogg|opus|wav49|sln|g729'

die(){ echo "ERROR: $*" >&2; exit 2; }
say(){ [ "$QUIET" = 1 ] || [ "$JSON" = 1 ] || echo "$@"; }
human(){ numfmt --to=iec --suffix=B "${1:-0}" 2>/dev/null || echo "${1}B"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --days) DAYS=${2:?}; shift ;;
    --dir) DIR=${2:?}; shift ;;
    --apply) APPLY=1 ;;
    --archive) ARCHIVE=${2:?}; shift ;;
    --only-if-disk) DISKP=${2:?}; shift ;;
    --update-cdr) UPDCDR=1 ;;
    --min-age-min) MINAGE=${2:?}; shift ;;
    --list) LIST=${2:?}; shift ;;
    --quiet) QUIET=1 ;;
    --json) JSON=1 ;;
    -h|--help) sed -n '2,44p' "$0"; exit 0 ;;
    --version) echo "$VERSION"; exit 0 ;;
    *) die "unknown option $1 (see --help)" ;;
  esac; shift
done

[[ "$DAYS" =~ ^[0-9]+$ ]] && [ "$DAYS" -ge 1 ] || die "--days must be a whole number of 1 or more"
[[ "$MINAGE" =~ ^[0-9]+$ ]] || die "--min-age-min must be a number"
[ -z "$DISKP" ] || [[ "$DISKP" =~ ^[0-9]+$ && "$DISKP" -le 100 ]] || die "--only-if-disk must be 0-100"
[ -d "$DIR" ] || die "$DIR does not exist"
case "$(readlink -f "$DIR")" in /|/etc|/etc/*|/usr|/usr/*|/var|/root|/home) die "refusing to clean $DIR";; esac
[ "$(id -u)" = 0 ] || [ -w "$DIR" ] || die "run as root (or as the asterisk user)"

exec 9>/run/lock/srvs-recording-cleaner.lock 2>/dev/null || exec 9>/tmp/srvs-recording-cleaner.lock
flock -n 9 || die "another run is in progress"

usedpct(){ df -P "$DIR" | awk 'NR==2{gsub("%","",$5);print $5}'; }
before_pct=$(usedpct)
if [ -n "$DISKP" ] && [ "$before_pct" -lt "$DISKP" ]; then
  say "Disk is ${before_pct}% full (threshold ${DISKP}%): nothing to do."
  [ "$JSON" = 1 ] && printf '{"version":"%s","action":"skipped","disk_used_pct":%s,"threshold_pct":%s}\n' "$VERSION" "$before_pct" "$DISKP"
  exit 0
fi

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
# Old enough by age, AND not touched in the last MINAGE minutes, AND a recording extension
find "$DIR" -xdev -type f -mtime +"$((DAYS-1))" -mmin +"$MINAGE" -regextype posix-extended \
  -regex ".*\.($EXTS)$" -printf '%s\t%p\n' | sort -k2 > "$tmp/list"
# Skip anything still open by a process (a call in progress)
if command -v fuser >/dev/null && [ -s "$tmp/list" ]; then
  cut -f2 "$tmp/list" | while IFS= read -r f; do fuser -s "$f" 2>/dev/null && printf '%s\n' "$f"; done > "$tmp/open" || true
  [ -s "$tmp/open" ] && grep -vFf "$tmp/open" "$tmp/list" > "$tmp/l2" && mv "$tmp/l2" "$tmp/list"
fi
count=$(wc -l < "$tmp/list"); bytes=$(awk -F'\t' '{s+=$1}END{print s+0}' "$tmp/list")
total_count=$(find "$DIR" -xdev -type f -regextype posix-extended -regex ".*\.($EXTS)$" | wc -l)
total_bytes=$(du -sb "$DIR" | cut -f1)
oldest=$(find "$DIR" -xdev -type f -regextype posix-extended -regex ".*\.($EXTS)$" -printf '%TY-%Tm-%Td\n' | sort | head -1)

mode="dry run"; [ "$APPLY" = 1 ] && mode=$([ -n "$ARCHIVE" ] && echo "archive" || echo "delete")
say "Recording retention ($mode) - $(hostname -f 2>/dev/null || hostname)"
say "  folder:        $DIR"
say "  recordings:    $total_count files, $(human "$total_bytes"), oldest ${oldest:-none}"
say "  disk used:     ${before_pct}%"
say "  policy:        keep $DAYS days (files older than $(date -d "-$DAYS days" +%F)), skip files changed in the last $MINAGE min"
say "  to remove:     $count files, $(human "$bytes")"
if [ "$count" -gt 0 ] && [ "$LIST" -gt 0 ]; then
  head -n "$LIST" "$tmp/list" | while IFS=$'\t' read -r s p; do say "    $(date -r "$p" +%F)  $(human "$s")  ${p#"$DIR"/}"; done
  [ "$count" -gt "$LIST" ] && say "    ... and $((count-LIST)) more"
fi

removed=0; archived_to=""; cdr_rows=0
if [ "$APPLY" = 1 ] && [ "$count" -gt 0 ]; then
  if [ -n "$ARCHIVE" ]; then
    [ -d "$ARCHIVE" ] || { mkdir -p "$ARCHIVE" && chmod 700 "$ARCHIVE"; }; [ -w "$ARCHIVE" ] || die "cannot write to $ARCHIVE"
    archived_to="$ARCHIVE/recordings-$(date +%Y%m%d-%H%M%S).tar.gz"
    cut -f2 "$tmp/list" | sed 's|^/||' > "$tmp/names"
    ( umask 077; tar -C / -czf "$archived_to" -T "$tmp/names" ) || die "archive failed; nothing deleted"
    tar -tzf "$archived_to" | sort > "$tmp/in_archive"
    sort "$tmp/names" | cmp -s - "$tmp/in_archive" || die "archive check failed; nothing deleted ($archived_to kept)"
    say "  archive:       $archived_to ($(human "$(stat -c %s "$archived_to")"), verified)"
  fi
  cut -f2 "$tmp/list" | tr '\n' '\0' | xargs -0 -r rm -f --
  removed=$(cut -f2 "$tmp/list" | while IFS= read -r f; do [ -e "$f" ] || echo x; done | wc -l)
  find "$DIR" -xdev -mindepth 1 -type d -empty -delete 2>/dev/null || true
  if [ "$UPDCDR" = 1 ] && command -v mysql >/dev/null; then
    cut -f2 "$tmp/list" | xargs -r -n1 basename | sed "s/'/''/g; s/.*/'&'/" | paste -sd, > "$tmp/in"
    if [ -s "$tmp/in" ]; then
      cdr_rows=$(mysql -N asteriskcdrdb -e "UPDATE cdr SET recordingfile='' WHERE recordingfile IN ($(cat "$tmp/in")); SELECT ROW_COUNT();" 2>/dev/null || echo 0)
    fi
    say "  CDR rows unlinked: $cdr_rows"
  fi
  logger -t srvs-recording-cleaner "removed $removed recordings ($(human "$bytes")) older than $DAYS days from $DIR${archived_to:+, archived to $archived_to}" || true
fi

after_pct=$(usedpct); rc=0
if [ "$APPLY" = 1 ]; then
  say "  result:        removed $removed of $count files, disk now ${after_pct}%"
  [ -n "$DISKP" ] && [ "$after_pct" -ge "$DISKP" ] && { say "  WARN: disk is still at or above ${DISKP}%; lower --days or add storage"; rc=1; }
else
  say "  result:        dry run, nothing changed. Add --apply to remove (or --apply --archive DIR to keep a copy)."
fi
if [ "$QUIET" = 1 ] && [ "$JSON" = 0 ]; then
  echo "recordings: $mode, $count file(s) $(human "$bytes") older than $DAYS days, removed $removed, disk ${before_pct}%->${after_pct}%"
fi
if [ "$JSON" = 1 ]; then
  printf '{"version":"%s","mode":"%s","dir":"%s","keep_days":%s,"total_files":%s,"total_bytes":%s,"candidates":%s,"candidate_bytes":%s,"removed":%s,"archive":"%s","cdr_rows_unlinked":%s,"disk_used_pct_before":%s,"disk_used_pct_after":%s}\n' \
    "$VERSION" "$mode" "$DIR" "$DAYS" "$total_count" "$total_bytes" "$count" "$bytes" "$removed" "$archived_to" "${cdr_rows:-0}" "$before_pct" "$after_pct"
fi
exit $rc
