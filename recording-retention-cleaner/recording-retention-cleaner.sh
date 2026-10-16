#!/usr/bin/env bash
# Asterisk Call Recording Retention Cleaner: Delete or Archive Old FreePBX Recordings (v1.0.1) - from srvScripts.com
# Source, docs and updates: https://srvscripts.com/scripts/recording-retention-cleaner/
# Copyright (c) 2026 srvScripts.com. MIT licence: if you copy, share or adapt this script, keep this notice and credit srvScripts.com.
#
# Default is a DRY RUN: it only lists what it would remove and how much space that frees.
# Nothing is deleted unless you pass --apply. With --archive DIR, old recordings are moved
# into a dated .tar.gz archive instead of being deleted.
#
# Version 1.0.1 (2026-10-17): open-file exclusion fixed (when every old file was open, 1.0.0 kept the full list
#   and could remove them); open files are now found in /proc instead of fuser; each file is re-checked (age,
#   link, open) right before removal; NUL-safe file names;
#   a failed CDR update is reported (exit 2). Found in an independent review.
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
VERSION=1.0.1
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
    -h|--help) sed -n '2,42p' "$0"; exit 0 ;;
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
RDIR=$(readlink -f "$DIR")
# Open files are found by reading every process's open file descriptors in /proc (no fuser needed: its exit
# code cannot tell "not in use" from an error). Run as root so all processes are visible; Asterisk writes
# recordings as the asterisk user, so running as that user also sees them.
declare -A OPEN=()
open_scan() {
  OPEN=(); local l
  while IFS= read -r -d '' l; do OPEN[$l]=1; done < <(find /proc/[0-9]*/fd -maxdepth 1 -type l -lname "$RDIR/*" -printf '%l\0' 2>/dev/null)
}
is_open() { [ -n "${OPEN[$1]:-}" ]; }
open_scan
# still_eligible FILE: re-checked immediately before removal: regular file (not a link), still old enough by
# age AND by last change, and not open.
still_eligible() {
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  [ -n "$(find "$1" -maxdepth 0 -mtime +"$((DAYS-1))" -mmin +"$MINAGE" 2>/dev/null)" ] || return 1
  ! is_open "$1"
}
# Candidates (NUL-separated, so unusual file names are safe): old enough, not changed in the last MINAGE
# minutes, a recording extension, and not open by any process.
files=(); sizes=(); skipped_open=0
while IFS=$'\t' read -r -d '' sz f; do
  if is_open "$f"; then skipped_open=$((skipped_open+1)); continue; fi
  files+=("$f"); sizes+=("$sz")
done < <(find "$RDIR" -xdev -type f -mtime +"$((DAYS-1))" -mmin +"$MINAGE" -regextype posix-extended \
           -regex ".*\.($EXTS)$" -printf '%s\t%p\0' | sort -z -t$'\t' -k2)
count=${#files[@]}; bytes=0; for sz in "${sizes[@]}"; do bytes=$((bytes+sz)); done
total_count=$(find "$DIR" -xdev -type f -regextype posix-extended -regex ".*\.($EXTS)$" -printf x | wc -c)
total_bytes=$(du -sb "$DIR" | cut -f1)
oldest=$(find "$DIR" -xdev -type f -regextype posix-extended -regex ".*\.($EXTS)$" -printf '%TY-%Tm-%Td\n' | sort | head -1)

mode="dry run"; [ "$APPLY" = 1 ] && mode=$([ -n "$ARCHIVE" ] && echo "archive" || echo "delete")
say "Recording retention ($mode) - $(hostname -f 2>/dev/null || hostname)"
say "  folder:        $DIR"
say "  recordings:    $total_count files, $(human "$total_bytes"), oldest ${oldest:-none}"
say "  disk used:     ${before_pct}%"
say "  policy:        keep $DAYS days (files older than $(date -d "-$DAYS days" +%F)), skip files changed in the last $MINAGE min"
[ "$(id -u)" = 0 ] || say "  note:          not running as root: files held open by other users' processes are not visible"
[ "$skipped_open" -gt 0 ] && say "  skipped:       $skipped_open old file(s) still open by a process (call in progress?)"
say "  to remove:     $count files, $(human "$bytes")"
if [ "$count" -gt 0 ] && [ "$LIST" -gt 0 ]; then
  for ((i=0; i<count && i<LIST; i++)); do
    say "    $(date -r "${files[$i]}" +%F)  $(human "${sizes[$i]}")  $(printf '%q' "${files[$i]#"$DIR"/}" | sed "s/^'\(.*\)'$/\1/")"
  done
  [ "$count" -gt "$LIST" ] && say "    ... and $((count-LIST)) more"
fi

removed=0; changed=0; archived_to=""; cdr_rows=0; cdr_err=0
if [ "$APPLY" = 1 ] && [ "$count" -gt 0 ]; then
  if [ -n "$ARCHIVE" ]; then
    [ -d "$ARCHIVE" ] || { mkdir -p "$ARCHIVE" && chmod 700 "$ARCHIVE"; }; [ -w "$ARCHIVE" ] || die "cannot write to $ARCHIVE"
    archived_to="$ARCHIVE/recordings-$(date +%Y%m%d-%H%M%S).tar.gz"
    printf '%s\0' "${files[@]#/}" > "$tmp/names"
    ( umask 077; tar -C / --null -czf "$archived_to" -T "$tmp/names" ) || die "archive failed; nothing deleted"
    n_in=$(tar -tzf "$archived_to" | wc -l) || die "archive cannot be read back; nothing deleted ($archived_to kept)"
    [ "$n_in" -eq "$count" ] || die "archive holds $n_in of $count files; nothing deleted ($archived_to kept)"
    say "  archive:       $archived_to ($(human "$(stat -c %s "$archived_to")"), $n_in files, read back)"
  fi
  : > "$tmp/removed"
  open_scan   # fresh view of open files right before removal
  for f in "${files[@]}"; do
    if still_eligible "$f"; then
      if rm -f -- "$f" && [ ! -e "$f" ]; then removed=$((removed+1)); printf '%s\0' "${f##*/}" >> "$tmp/removed"; fi
    else changed=$((changed+1)); fi
  done
  [ "$changed" -gt 0 ] && say "  kept:          $changed file(s) changed, opened or vanished since the scan"
  find "$DIR" -xdev -mindepth 1 -type d -empty -delete 2>/dev/null || true
  if [ "$UPDCDR" = 1 ] && [ "$removed" -gt 0 ]; then
    if command -v mysql >/dev/null 2>&1; then
      in=$(while IFS= read -r -d '' b; do [[ "$b" == *$'\n'* ]] && continue; b=${b//\\/\\\\}; printf "'%s'," "${b//\'/\'\'}"; done < "$tmp/removed")
      if [ -n "$in" ] && cdr_rows=$(mysql -N asteriskcdrdb -e "UPDATE cdr SET recordingfile='' WHERE recordingfile IN (${in%,}); SELECT ROW_COUNT();" 2>>"$tmp/sqlerr"); then
        say "  CDR rows unlinked: $cdr_rows"
      else cdr_err=1; cdr_rows=0; say "  ERROR: the CDR update failed ($(head -1 "$tmp/sqlerr" 2>/dev/null)); recordings were removed but the call log still links them"; fi
    else cdr_err=1; say "  ERROR: mysql client not found; --update-cdr was not applied"; fi
  fi
  logger -t srvs-recording-cleaner "removed $removed recordings ($(human "$bytes")) older than $DAYS days from $DIR${archived_to:+, archived to $archived_to}" || true
fi

after_pct=$(usedpct); rc=0; [ "$cdr_err" = 1 ] && rc=2
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
