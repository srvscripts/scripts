#!/usr/bin/env bash
# Asterisk Recordings to MP3: Bulk Convert FreePBX Call Recordings (v1.0.0) - from srvScripts.com
# Source, docs and updates: https://srvscripts.com/scripts/asterisk-recordings-to-mp3/
# Copyright (c) 2026 srvScripts.com. MIT licence: if you copy, share or adapt this script, keep this notice and credit srvScripts.com.
# asterisk-recordings-to-mp3.sh — convert Asterisk / FreePBX / Issabel call recordings to MP3 from cron
# https://srvscripts.com/scripts/asterisk-recordings-to-mp3/   License: MIT
#
# Finds finished recordings (.wav, .WAV/wav49, .gsm, .ulaw, .alaw, .sln...) under the monitor folder, converts
# each one to mono MP3 with ffmpeg (or sox + lame), copies the owner and timestamp, verifies the result and,
# only if asked, deletes the original and points the FreePBX call log (asteriskcdrdb.cdr.recordingfile) at the
# new file. Files still being written (modified in the last --older-than minutes) are skipped. Safe to run
# every few minutes: a lock stops two runs overlapping and finished files are never converted twice.
#   bash asterisk-recordings-to-mp3.sh --dry-run
#   bash asterisk-recordings-to-mp3.sh --older-than 5 --delete-original --update-cdr
#   */10 * * * * root /usr/local/bin/asterisk-recordings-to-mp3.sh --delete-original --update-cdr >>/var/log/recordings-mp3.log 2>&1
# Exit codes: 0 all converted (or nothing to do), 1 some files failed, 2 usage error, no encoder, or another run active.
set -uo pipefail
export LC_ALL=C

DIR=/var/spool/asterisk/monitor; OLDER=2; BITRATE=32; EXTS="wav,WAV,wav49,gsm"; DELETE=0; CDR=0
DRY=0; DAYS=0; ENCODER=auto; QUIET=0; LOCK=/run/lock/asterisk-recordings-to-mp3.lock; CDRDB=asteriskcdrdb

usage() {
  cat <<'EOF'
Usage: asterisk-recordings-to-mp3.sh [options]
  --dir DIR            recordings folder (default /var/spool/asterisk/monitor), searched recursively
  --older-than MIN     skip files modified in the last MIN minutes, still recording (default 2)
  --days N             only files modified in the last N days (default 0 = all)
  --bitrate KBPS       MP3 bit rate: 16, 24, 32, 48 or 64 (default 32)
  --ext LIST           extensions to convert, comma separated (default wav,WAV,wav49,gsm;
                       also: ulaw,alaw,sln,sln16,g722,g729 with ffmpeg)
  --delete-original    delete each original after its MP3 is verified (default: keep both)
  --update-cdr         FreePBX: change recordingfile in asteriskcdrdb.cdr to the .mp3 name
  --cdr-db NAME        CDR database name (default asteriskcdrdb)
  --encoder NAME       auto | ffmpeg | sox (default auto: ffmpeg if installed, else sox + lame)
  --dry-run            only list what would be converted
  -q, --quiet          print only the summary and errors
  -h, --help           this help
Environment: MYSQL_ARGS extra arguments for the mysql client (FreePBX root can use /root/.my.cnf)
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
if [ "$CDR" = 1 ] && [ "$DRY" = 0 ]; then
  MYSQL=$(command -v mysql || command -v mariadb) || die "--update-cdr needs the mysql or mariadb client"
  # shellcheck disable=SC2086
  "$MYSQL" ${MYSQL_ARGS:-} -N -B -e "SELECT 1 FROM \`$CDRDB\`.cdr LIMIT 1" >/dev/null 2>&1 || die "cannot read $CDRDB.cdr (set MYSQL_ARGS or /root/.my.cnf)"
fi

# One run at a time.
if [ "$DRY" = 0 ]; then
  mkdir -p "$(dirname "$LOCK")" 2>/dev/null
  exec 9>"$LOCK" || die "cannot open lock file $LOCK"
  flock -n 9 || { echo "Another run is still active, exiting." >&2; exit 2; }
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
    g722|g729) echo "UNSUPPORTED" ;;
    *) echo "" ;;
  esac
}
convert() { # $1 input  $2 output.part  $3 extension
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
duration() { # seconds of audio in an MP3, 0 if unreadable
  if have ffprobe; then ffprobe -v error -show_entries format=duration -of csv=p=0 "$1" 2>/dev/null | cut -d. -f1
  elif have soxi; then soxi -D "$1" 2>/dev/null | cut -d. -f1
  else [ -s "$1" ] && echo 1 || echo 0; fi
}
verify() { local d; [ -s "$1" ] || return 1; d=$(duration "$1"); [[ "$d" =~ ^[0-9]+$ ]]; }
sql_escape() { printf "%s" "$1" | sed "s/\\\\/\\\\\\\\/g; s/'/\\\\'/g"; }

# Build the find expression from the extension list (case-sensitive: Asterisk's .WAV is WAV49, .wav is PCM).
NAMES=(); IFS=',' read -r -a EXT_LIST <<<"$EXTS"
for e in "${EXT_LIST[@]}"; do
  e="${e#.}"; [[ "$e" =~ ^[A-Za-z0-9]+$ ]] || die "bad extension: $e"
  [ "${e,,}" = mp3 ] && die "mp3 cannot be a source extension"
  [ ${#NAMES[@]} -gt 0 ] && NAMES+=(-o); NAMES+=(-name "*.$e")
done
FIND=(find "$DIR" -type f \( "${NAMES[@]}" \) -mmin "+$OLDER")
[ "$DAYS" -gt 0 ] && FIND+=(-mtime "-$DAYS")

ok=0; skip=0; fail=0; before=0; after=0; start=$(date +%s)
log "$(date '+%F %T') converting with $ENCODER at ${BITRATE} kbps in $DIR$([ "$DRY" = 1 ] && echo ' (dry run)')"
while IFS= read -r -d '' f; do
  ext="${f##*.}"; base="${f%.*}"; mp3="$base.mp3"
  if [ -e "$mp3" ]; then skip=$((skip+1)); continue; fi
  if [ "$DRY" = 1 ]; then log "would convert: $f"; ok=$((ok+1)); continue; fi
  part="$base.mp3.part"
  if convert "$f" "$part" "$ext" && verify "$part"; then
    chown --reference="$f" "$part" 2>/dev/null; chmod --reference="$f" "$part" 2>/dev/null; touch -r "$f" "$part"
    mv -f "$part" "$mp3"
    sz_in=$(stat -c %s "$f"); sz_out=$(stat -c %s "$mp3"); before=$((before+sz_in)); after=$((after+sz_out))
    if [ "$CDR" = 1 ]; then
      old=$(sql_escape "${f##*/}"); new=$(sql_escape "${mp3##*/}")
      # shellcheck disable=SC2086
      "$MYSQL" ${MYSQL_ARGS:-} -e "UPDATE \`$CDRDB\`.cdr SET recordingfile=REPLACE(recordingfile,'$old','$new') WHERE recordingfile LIKE '%$old'" \
        || echo "WARN: call log not updated for ${f##*/}" >&2
    fi
    if [ "$DELETE" = 1 ]; then rm -f -- "$f"; fi
    log "ok  ${f#"$DIR"/} -> ${mp3##*/} ($((sz_in/1024)) KB -> $((sz_out/1024)) KB)"
    ok=$((ok+1))
  else
    rm -f -- "$part"; echo "FAIL ${f#"$DIR"/}" >&2; fail=$((fail+1))
  fi
done < <("${FIND[@]}" -print0 2>/dev/null)

hs() { if [ "$1" -ge 1048576 ]; then echo "$(( $1 / 1048576 )) MB"; else echo "$(( $1 / 1024 )) KB"; fi; }
saved=""; [ "$after" -gt 0 ] && saved=", $(hs "$before") -> $(hs "$after")"
echo "$(date '+%F %T') done: $ok $([ "$DRY" = 1 ] && echo 'to convert' || echo converted), $skip already had an MP3, $fail failed in $(( $(date +%s) - start )) s$saved"
[ "$fail" -eq 0 ] || exit 1
exit 0
