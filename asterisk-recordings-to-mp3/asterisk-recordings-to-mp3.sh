#!/usr/bin/env bash
# Asterisk Recordings to MP3: Bulk Convert FreePBX Call Recordings (v1.2.2) - from srvScripts.com
# Source, docs and updates: https://srvscripts.com/scripts/asterisk-recordings-to-mp3/
# Copyright (c) 2026 srvScripts.com. MIT licence: if you copy, share or adapt this script, keep this notice and credit srvScripts.com.
# asterisk-recordings-to-mp3.sh — convert Asterisk / FreePBX / Issabel call recordings to MP3 from cron
# https://srvscripts.com/scripts/asterisk-recordings-to-mp3/   License: MIT
#
# Finds finished recordings (.wav, .WAV/wav49, .gsm, .ulaw, .alaw, .sln...) under the monitor folder, converts
# each one to mono MP3 with ffmpeg (or sox + lame), copies the owner and timestamp, decodes the MP3 back to check
# its length matches the original and, only if asked, points the FreePBX call log (asteriskcdrdb.cdr.recordingfile)
# at the new file and deletes the original. Files still being written (modified in the last --older-than minutes,
# always at least 60 seconds, or held open) are skipped. Safe to run every few minutes: a lock stops two runs
# overlapping and finished files are never converted twice.
# The original is deleted only when encoding, read-back, owner/time copy, rename and (with --update-cdr) the call
# log update of at least one row all succeeded. On any failure the original is kept, the MP3 is removed (so the
# next run retries the file), an ERROR line is printed and the run exits 1. Without ffprobe or sox the MP3 cannot
# be read back, so the script only converts: originals are kept and the call log is left alone.
#   bash asterisk-recordings-to-mp3.sh --dry-run
#   bash asterisk-recordings-to-mp3.sh --older-than 5 --delete-original --update-cdr
#   */10 * * * * root /usr/local/bin/asterisk-recordings-to-mp3.sh --delete-original --update-cdr >>/var/log/recordings-mp3.log 2>&1
# Run as root (the cron line above) or as the recordings owner (e.g. asterisk; then MYSQL_ARGS must give that user
# access to the call log). Root needs setpriv (util-linux) to drop to the owner.
# Exit codes: 0 all converted (or nothing to do), 1 some files failed, 2 usage error, no encoder, or another run active.
# Version 1.2.2 (2026-10-10): if a folder (or a link to a folder) appeared at the MP3's name during conversion, 1.2.1
#   put the MP3 inside that folder and carried on as if it had succeeded, so --update-cdr and --delete-original could
#   act on a recording whose MP3 was not where the call log points. The MP3 is now linked to the exact name only
#   (ln -T) and checked to be a regular file before the call log or the original is touched. Found in an independent
#   review (NEW-AST-DIR).
# Version 1.2.1 (2026-10-10): an interrupted run can no longer leave a partial MP3 that later runs skip. The MP3 is
#   written completely to a hidden temporary file next to its final name and then hard-linked into place (never over an
#   existing file or link); stale temporary files are cleaned up after 30 minutes. Found in an independent review (EVE-10).
# Version 1.2.0 (2026-10-09): output files are never written through links or over existing files. Each recording is
#   copied into a private work folder (mktemp -d) and encoded and checked there; when run as root, the recording is read
#   and the MP3 created, timed and (if asked) the original deleted as the recording's owner, so a link or file planted
#   in the recordings folder cannot make root write, read or delete anything else. A final .mp3 that already exists
#   (or is a link, even a broken one), or appears during conversion, is left untouched and reported; no .mp3.part is
#   used any more. Root-owned recordings are converted only in folders that only root can change. Lock file
#   default for root is /run/asterisk-recordings-to-mp3.lock, opened without truncating and never through a link.
# Version 1.1.0 (2026-10-07): originals are kept unless every step succeeded, including the call log update (1.0.0
#   deleted them after a failed UPDATE); MP3s are decoded and must match the original's length (zero-length or
#   truncated output is rejected); owner/time/rename failures count as errors; open recordings are skipped.
# Version 1.0.0: first release.
set -uo pipefail
export LC_ALL=C

DIR=/var/spool/asterisk/monitor; OLDER=2; BITRATE=32; EXTS="wav,WAV,wav49,gsm"; DELETE=0; CDR=0
DRY=0; DAYS=0; ENCODER=auto; QUIET=0; CDRDB=asteriskcdrdb
if [ "$EUID" -eq 0 ]; then LOCK=${RECORDINGS_MP3_LOCK:-/run/asterisk-recordings-to-mp3.lock}; else LOCK=${RECORDINGS_MP3_LOCK:-/run/lock/asterisk-recordings-to-mp3.lock}; fi

usage() {
  cat <<'EOF'
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
EOF
}
die() { echo "ERROR: $*" >&2; exit 2; }
log() { [ "$QUIET" = 1 ] || echo "$*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dir) DIR="${2:-}"; shift 2 ;;
    --older-than) OLDER="${2:-}"; shift 2 ;;
    --days) DAYS="${2:-}"; shift 2 ;;
    --bitrate) BITRATE="${2:-}"; shift 2 ;;
    --ext) EXTS="${2:-}"; shift 2 ;;
    --delete-original) DELETE=1; shift ;;
    --update-cdr) CDR=1; shift ;;
    --cdr-db) CDRDB="${2:-}"; shift 2 ;;
    --encoder) ENCODER="${2:-}"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -q|--quiet) QUIET=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

[[ "$OLDER" =~ ^[0-9]+$ ]] || die "--older-than needs a number of minutes"
[[ "$DAYS" =~ ^[0-9]+$ ]] || die "--days needs a number"
case "$BITRATE" in 16|24|32|48|64) ;; *) die "--bitrate must be 16, 24, 32, 48 or 64" ;; esac
[[ "$CDRDB" =~ ^[A-Za-z0-9_]+$ ]] || die "--cdr-db: letters, digits and _ only"
[ -d "$DIR" ] || die "folder not found: $DIR"

have() { command -v "$1" >/dev/null 2>&1; }
if [ "$ENCODER" = auto ]; then
  if have ffmpeg; then ENCODER=ffmpeg; elif have sox && have lame; then ENCODER=sox; else ENCODER=none; fi
fi
case "$ENCODER" in
  ffmpeg) have ffmpeg || die "ffmpeg not found" ;;
  sox) { have sox && have lame; } || die "sox and lame are both needed (dnf install sox lame / apt install sox lame)" ;;
  *) die "no encoder: install ffmpeg, or sox and lame (on EL: dnf install epel-release, then dnf install sox lame)" ;;
esac
# Reading the MP3 back needs ffprobe (ffmpeg package) or sox. Without one nothing is verified: convert only.
if have ffprobe; then PROBE=ffprobe; elif have sox; then PROBE=sox; else PROBE=none; fi
if [ "$PROBE" = none ] && [ "$DRY" = 0 ] && { [ "$DELETE" = 1 ] || [ "$CDR" = 1 ]; }; then
  echo "WARN: no ffprobe or sox to read the MP3s back: converting only, originals are kept and the call log is not changed" >&2
  DELETE=0; CDR=0
fi
if [ "$CDR" = 1 ] && [ "$DRY" = 0 ]; then
  MYSQL=$(command -v mysql || command -v mariadb) || die "--update-cdr needs the mysql or mariadb client"
  # shellcheck disable=SC2086
  "$MYSQL" ${MYSQL_ARGS:-} -N -B -e "SELECT 1 FROM \`$CDRDB\`.cdr LIMIT 1" >/dev/null 2>&1 || die "cannot read $CDRDB.cdr (set MYSQL_ARGS or /root/.my.cnf)"
fi

# trusted_dir DIR: DIR and every folder above it belong to root and no other user can rename or replace entries
# in them (not group/world writable, or sticky like /tmp). Used for the work folder and for root-owned recordings.
trusted_dir() {
  local d="$1" u a
  while :; do
    [ -L "$d" ] && return 1
    read -r u a < <(stat -c '%u %a' -- "$d" 2>/dev/null) || return 1
    [ "$u" = 0 ] || return 1
    if (( (8#$a & 8#022) != 0 && (8#$a & 8#1000) == 0 )); then return 1; fi
    [ "$d" = / ] && return 0
    d=$(dirname -- "$d")
  done
}
# as_owner CMD...: run CMD as the current recording's owner ($OU:$OG) when we are root, as ourselves otherwise.
# Everything that touches the recordings folder goes through this, so a planted link only reaches what the owner
# could already change.
OU=0; OG=0
as_owner() {
  if [ "$EUID" -eq 0 ] && [ "$OU" != 0 ]; then setpriv --reuid="$OU" --regid="$OG" --clear-groups -- "$@"; else "$@"; fi
}
TO=(); have timeout && TO=(timeout 600)

if [ "$DRY" = 0 ]; then
  [ "$EUID" -ne 0 ] || have setpriv || die "running as root needs setpriv (util-linux) to act as the recordings owner"
  # One run at a time. Opened for append (never truncates) and never through a link.
  mkdir -p "$(dirname "$LOCK")" 2>/dev/null
  [ -L "$LOCK" ] && die "lock file $LOCK is a link, refusing to use it"
  exec 9>>"$LOCK" || die "cannot open lock file $LOCK"
  flock -n 9 || { echo "Another run is still active, exiting." >&2; exit 2; }
  # Private work folder: encoding and the read-back check happen here, never in the recordings folder.
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/recordings-mp3.XXXXXXXX") || die "cannot create a work folder in ${TMPDIR:-/tmp}"
  trap 'rm -rf -- "$WORK"' EXIT
  [ "$EUID" -ne 0 ] || trusted_dir "$(dirname -- "$WORK")" || die "work folder parent $(dirname -- "$WORK") can be changed by other users; set TMPDIR to a root-only folder"
fi

# Input options for headerless formats.
ff_in() {
  case "${1,,}" in
    gsm) echo "-f gsm -ar 8000 -ac 1" ;;
    ulaw|ul|mu|pcmu) echo "-f mulaw -ar 8000 -ac 1" ;;
    alaw|al|pcma) echo "-f alaw -ar 8000 -ac 1" ;;
    sln|slin|raw) echo "-f s16le -ar 8000 -ac 1" ;;
    sln12) echo "-f s16le -ar 12000 -ac 1" ;; sln16) echo "-f s16le -ar 16000 -ac 1" ;;
    sln24) echo "-f s16le -ar 24000 -ac 1" ;; sln32) echo "-f s16le -ar 32000 -ac 1" ;;
    sln48) echo "-f s16le -ar 48000 -ac 1" ;;
    g722) echo "-f g722" ;; g729) echo "-f g729" ;;
    mp3) echo "-f mp3" ;; # read-back of our own MP3 in the work folder
    *) echo "" ;;
  esac
}
sox_in() {
  case "${1,,}" in
    gsm) echo "-t gsm -r 8000 -c 1" ;;
    ulaw|ul|mu|pcmu) echo "-t ul -r 8000 -c 1" ;;
    alaw|al|pcma) echo "-t al -r 8000 -c 1" ;;
    sln|slin|raw) echo "-t raw -e signed -b 16 -r 8000 -c 1" ;;
    sln16) echo "-t raw -e signed -b 16 -r 16000 -c 1" ;;
    sln48) echo "-t raw -e signed -b 16 -r 48000 -c 1" ;;
    wav|wav49) echo "-t wav" ;;
    mp3) echo "-t mp3" ;;
    g722|g729) echo "UNSUPPORTED" ;;
    *) echo "" ;;
  esac
}
convert() { # $1 input copy  $2 output MP3 (both in the private work folder)  $3 extension
  local in="$1" out="$2" ext="$3" opts
  if [ "$ENCODER" = ffmpeg ]; then
    opts=$(ff_in "$ext")
    # shellcheck disable=SC2086
    nice -n 15 ffmpeg -nostdin -hide_banner -loglevel error -y $opts -i "$in" -vn -ac 1 -c:a libmp3lame -b:a "${BITRATE}k" -f mp3 "$out"
  else
    opts=$(sox_in "$ext")
    [ "$opts" = UNSUPPORTED ] && { echo "sox cannot decode .$ext, use --encoder ffmpeg" >&2; return 1; }
    # shellcheck disable=SC2086
    nice -n 15 sox -q $opts "$in" -t wav -c 1 -b 16 - 2>/dev/null | nice -n 15 lame --quiet -m m -b "$BITRATE" - "$out"
  fi
}
duration() { # $1 file  $2 extension: seconds of audio found by decoding every frame, nothing if unreadable
  local opts
  if [ "$PROBE" = ffprobe ]; then # header durations are not trusted: a truncated MP3 keeps its full-length Xing header
    opts=$(ff_in "$2")
    # shellcheck disable=SC2086
    nice -n 15 ffprobe -v error $opts -select_streams a:0 -show_entries stream=sample_rate:frame=nb_samples -of default=nw=1 "$1" 2>&1 \
      | awk -F= '$1=="nb_samples" {n+=$2; next} $1=="sample_rate" {r=$2; next} {bad=1} END {if (!bad && r>0) printf "%.2f\n", n/r}'
  else
    opts=$(sox_in "$2"); [ "$opts" = UNSUPPORTED ] && return 1
    # shellcheck disable=SC2086
    nice -n 15 sox $opts "$1" -n stat 2>&1 | awk '/^sox FAIL/ {bad=1} /^Length \(seconds\)/ {d=$3} END {if (!bad && d!="") print d}'
  fi
}
verify() { # $1 mp3  $2 original  $3 extension: both decode to the same positive length (within 1 s or 2%)
  local a b
  [ -s "$1" ] || { why="empty MP3"; return 1; }
  b=$(duration "$1" mp3); a=$(duration "$2" "$3")
  awk -v a="${a:-0}" -v b="${b:-0}" 'BEGIN {t=a*0.02; if (t<1) t=1; d=a-b; if (d<0) d=-d; exit !(a>0 && b>0 && d<=t)}' \
    || { why="MP3 reads back as ${b:-unreadable}${b:+ s}, the original as ${a:-unreadable}${a:+ s}"; return 1; }
}
sql_escape() { printf "%s" "$1" | sed "s/\\\\/\\\\\\\\/g; s/'/\\\\'/g"; }
cdr_sql() { # shellcheck disable=SC2086
  "$MYSQL" ${MYSQL_ARGS:-} -N -B -e "$1"; }

# Build the find expression from the extension list (case-sensitive: Asterisk's .WAV is WAV49, .wav is PCM).
NAMES=(); IFS=',' read -r -a EXT_LIST <<<"$EXTS"
for e in "${EXT_LIST[@]}"; do
  e="${e#.}"; [[ "$e" =~ ^[A-Za-z0-9]+$ ]] || die "bad extension: $e"
  [ "${e,,}" = mp3 ] && die "mp3 cannot be a source extension"
  [ ${#NAMES[@]} -gt 0 ] && NAMES+=(-o); NAMES+=(-name "*.$e")
done
FIND=(find "$DIR" -type f \( "${NAMES[@]}" \) -mmin "+$OLDER")
[ "$DAYS" -gt 0 ] && FIND+=(-mtime "-$DAYS")
FIND+=(-printf '%U %G %m %T@\0%p\0') # owner, group, mode and time of the file itself (never of a link target)

# publish SRC DST MODE MTIME: as the owner, write the complete MP3 to a new hidden file next to DST (mktemp: a fresh,
# exclusively created name), set its mode and time, then hard-link it to DST and drop the temporary name. link() never
# replaces anything: it fails if DST exists, even as a dangling link. A run killed half-way therefore leaves only a hidden
# .NAME.mp3.XXXXXX.part file (removed by a later run after 30 minutes), never a partial DST that later runs would skip.
# ln -T links to the exact name: a folder (or a link to one) at DST is an existing name and is refused, never entered.
# Exit 0 ok, 3 write/mode/time/link failed (nothing left at DST), 4 DST already existed or appeared (untouched).
publish() {
  as_owner sh -c 'umask 077; d=$(dirname -- "$1"); b=$(basename -- "$1")
    t=$(mktemp -- "$d/.$b.XXXXXX.part" 2>/dev/null) || exit 3
    if ! { cat >"$t" && chmod "$2" -- "$t" && touch -d "@$3" -- "$t"; }; then rm -f -- "$t"; exit 3; fi
    if ln -T -- "$t" "$1" 2>/dev/null; then
      if [ -f "$1" ] && [ ! -L "$1" ] && [ "$1" -ef "$t" ]; then rm -f -- "$t"; exit 0; fi
      rm -f -- "$t"; exit 4
    fi
    rm -f -- "$t"; if [ -e "$1" ] || [ -L "$1" ]; then exit 4; fi; exit 3' \
    sh "$2" "$3" "$4" <"$1"
}
# Leftovers of an interrupted publish (hidden .NAME.mp3.XXXXXX.part older than 30 minutes) are removed as the owner.
clean_parts() {
  local d b; d=$(dirname -- "$1"); b=$(basename -- "$1")
  case "$b" in *[][*?\\]*) return 0 ;; esac
  as_owner find "$d" -maxdepth 1 -type f -name ".$b.??????.part" -mmin +30 -delete 2>/dev/null || true
}

ok=0; skip=0; busy=0; fail=0; before=0; after=0; start=$(date +%s)
log "$(date '+%F %T') converting with $ENCODER at ${BITRATE} kbps in $DIR$([ "$DRY" = 1 ] && echo ' (dry run)')"
while IFS= read -r -d '' meta && IFS= read -r -d '' f; do
  read -r OU OG mode mt <<<"$meta"; mt=${mt%%.*}
  ext="${f##*.}"; base="${f%.*}"; mp3="$base.mp3"
  if [ -L "$mp3" ]; then echo "WARN: ${mp3#"$DIR"/} is a link, not an MP3: skipped, nothing changed" >&2; skip=$((skip+1)); continue; fi
  [ "$DRY" = 1 ] || clean_parts "$mp3"
  if [ -e "$mp3" ]; then skip=$((skip+1)); continue; fi
  # Still being written: changed in the last minute (whatever --older-than says) or held open by Asterisk.
  m0=$(stat -c %Y:%s -- "$f" 2>/dev/null) || continue
  if [ $(( $(date +%s) - ${m0%%:*} )) -lt 60 ] || { have fuser && fuser -s "$f" 2>/dev/null; }; then
    log "skip (still recording): ${f#"$DIR"/}"; busy=$((busy+1)); continue
  fi
  if [ "$DRY" = 1 ]; then log "would convert: $f"; ok=$((ok+1)); continue; fi
  if [ "$EUID" -eq 0 ] && [ "$OU" = 0 ] && ! trusted_dir "$(dirname -- "$f")"; then
    echo "ERROR: ${f#"$DIR"/}: owned by root in a folder other users can change; not converted, original kept" >&2; fail=$((fail+1)); continue
  fi
  why=""; in="$WORK/in.$ext"; out="$WORK/out.mp3"; rm -f -- "$in" "$out"
  # The owner reads the recording (a link swapped in reaches only what the owner can read); we write the private copy.
  if ! as_owner ${TO[@]+"${TO[@]}"} cat -- "$f" >"$in" 2>/dev/null; then why="cannot read the recording"
  elif ! convert "$in" "$out" "$ext"; then why="encoder failed"
  elif [ "$(stat -c %Y:%s -- "$f" 2>/dev/null)" != "$m0" ]; then
    log "skip (changed while converting): ${f#"$DIR"/}"; busy=$((busy+1)); continue
  elif [ "$PROBE" != none ]; then verify "$out" "$in" "$ext"
  elif [ ! -s "$out" ]; then why="empty MP3"
  fi
  if [ -z "$why" ]; then
    publish "$out" "$mp3" "$mode" "$mt"; rc=$?
    if [ "$rc" = 3 ]; then why="cannot write ${mp3##*/} (or set its mode and time)"
    elif [ "$rc" = 4 ]; then why="${mp3##*/} appeared while converting and was left untouched"
    elif [ "$rc" != 0 ]; then why="writing ${mp3##*/} was interrupted (exit $rc); nothing was left at that name, next run retries"
    elif [ ! -f "$mp3" ] || [ -L "$mp3" ]; then why="${mp3##*/} is not a regular file after writing; left untouched"; fi
  fi
  if [ -z "$why" ] && [ "$CDR" = 1 ]; then
    old=$(sql_escape "${f##*/}"); new=$(sql_escape "${mp3##*/}")
    rows=$(cdr_sql "UPDATE \`$CDRDB\`.cdr SET recordingfile=REPLACE(recordingfile,'$old','$new') WHERE recordingfile LIKE '%$old'; SELECT ROW_COUNT()") || rows=""
    if ! [[ "$rows" =~ ^[0-9]+$ ]] || [ "$rows" -lt 1 ]; then
      why="call log update failed"; [[ "$rows" =~ ^[0-9]+$ ]] && why="call log update matched $rows rows"
      # Keep the MP3 only if the call log already names it (playback must work); otherwise remove it so the next run retries.
      if [[ "$(cdr_sql "SELECT COUNT(*) FROM \`$CDRDB\`.cdr WHERE recordingfile LIKE '%$new'")" =~ ^[1-9] ]]; then
        why="$why, but the call log already names ${mp3##*/} (kept both files, check by hand)"
      else as_owner rm -f -- "$mp3"; fi
    fi
  fi
  if [ -n "$why" ]; then
    echo "ERROR: ${f#"$DIR"/}: $why; original kept" >&2; fail=$((fail+1)); continue
  fi
  sz_in=$(stat -c %s -- "$f"); sz_out=$(stat -c %s -- "$mp3"); before=$((before+sz_in)); after=$((after+sz_out))
  if [ "$DELETE" = 1 ] && ! as_owner rm -f -- "$f"; then
    echo "ERROR: ${f#"$DIR"/}: converted but the original could not be deleted" >&2; fail=$((fail+1)); continue
  fi
  log "ok  ${f#"$DIR"/} -> ${mp3##*/} ($((sz_in/1024)) KB -> $((sz_out/1024)) KB)$([ "$PROBE" = none ] && echo ', not verified')"
  ok=$((ok+1))
done < <("${FIND[@]}" 2>/dev/null)

hs() { if [ "$1" -ge 1048576 ]; then echo "$(( $1 / 1048576 )) MB"; else echo "$(( $1 / 1024 )) KB"; fi; }
saved=""; [ "$after" -gt 0 ] && saved=", $(hs "$before") -> $(hs "$after")"
echo "$(date '+%F %T') done: $ok $([ "$DRY" = 1 ] && echo 'to convert' || echo converted), $skip already had an MP3, $busy still recording, $fail failed in $(( $(date +%s) - start )) s$saved"
[ "$fail" -eq 0 ] || exit 1
exit 0
