#!/usr/bin/env bash
# FreePBX Off-Site Backup: Databases, Config, Voicemail and Prompts over rsync/SSH, Verified (v1.0.1) - from srvScripts.com
# Source, docs and updates: https://srvscripts.com/scripts/freepbx-offsite-backup/
# Copyright (c) 2026 srvScripts.com. MIT licence: if you copy, share or adapt this script, keep this notice and credit srvScripts.com.
#
# A backup of a FreePBX/Asterisk server that does not depend on the FreePBX Backup module: it dumps the asterisk and
# asteriskcdrdb databases (one consistent transaction each), copies the Asterisk internal database (astdb) safely
# with sqlite3 .backup, archives /etc/asterisk, the FreePBX settings, custom sounds and music on hold, voicemail and
# phone provisioning files (recordings only with --with-recordings), writes a manifest with versions and SHA-256
# checksums, checks every archive can be read back, then copies the set to another server over rsync/SSH (or to a
# local/NFS folder) and verifies the copy. Old sets are pruned locally and, if allowed, on the destination.
#
#   bash freepbx-offsite-backup.sh --dest backup@203.0.113.20:/srv/pbx-backups --key /root/.ssh/pbx_backup
#   bash freepbx-offsite-backup.sh --dest /mnt/nas/pbx --keep 14 --with-recordings
#   15 2 * * * root /usr/local/bin/freepbx-offsite-backup.sh --dest backup@host:/srv/pbx --key /root/.ssh/pbx_backup --quiet --mail ops@example.com
#
# Restore outline (also written into each set as RESTORE.txt): install the same FreePBX major version, stop it
# (fwconsole stop), import asterisk.sql.gz and asteriskcdrdb.sql.gz, extract files.tar.gz from /, put astdb.sqlite3
# back in /var/lib/asterisk, then fwconsole chown && fwconsole reload && fwconsole start.
# Exit codes: 0 backup made and copy verified, 1 made but the copy or pruning failed, 2 backup failed, 3 bad option.
# Version 1.0.1 (2026-10-17): a failed verification run, a database server that cannot be queried, a missing
#   FreePBX database or a missing sqlite3 are now failures (1.0.0 could report success); no local pruning after a
#   failed copy. Found in an independent review.
# Version 1.0.0 (2026-10-17): first release. Tested on FreePBX 17.0.33 / Asterisk 22.11 (Debian 12): backup to a
#   local folder and over rsync/SSH, verification, pruning, and a test restore of both databases and the files.
set -uo pipefail
export LC_ALL=C
umask 077

DEST=""; KEY=""; PORT=22; KEEP=7; REMOTE_KEEP=1; WORK=/var/backups/freepbx-offsite; RECORDINGS=0; QUIET=0; MAIL_TO=""
NAME_PREFIX=$(hostname -s 2>/dev/null || echo pbx); BWLIMIT=0
read -ra MA <<<"${MYSQL_ARGS:-}"

usage() {
  cat <<'EOF'
Usage: freepbx-offsite-backup.sh --dest DEST [options]
  --dest DEST          user@host:/path (rsync over SSH) or /local/or/nfs/path
  --key FILE           SSH private key for the destination (recommended: a dedicated key)
  --port N             SSH port (default 22)
  --keep N             keep N backup sets locally and on the destination (default 7)
  --no-remote-prune    never delete old sets on the destination (for append-only or restricted accounts)
  --work DIR           local folder for the sets (default /var/backups/freepbx-offsite)
  --with-recordings    also back up /var/spool/asterisk/monitor (can be large)
  --bwlimit KBPS       limit upload bandwidth (rsync --bwlimit)
  --name PREFIX        set name prefix (default: short hostname)
  -q, --quiet          print only errors and the final line
  --mail ADDR          e-mail a report when something fails (needs 'mail')
  -h, --help           this help
Environment: MYSQL_ARGS extra mysql/mysqldump arguments (FreePBX root works without any)
EOF
}
die() { echo "ERROR: $*" >&2; exit 3; }
while [ $# -gt 0 ]; do
  case "$1" in
    --dest) DEST="${2:-}"; shift 2 ;;
    --key) KEY="${2:-}"; [ -r "$KEY" ] || die "--key: cannot read $KEY"; shift 2 ;;
    --port) [[ "${2:-}" =~ ^[0-9]+$ ]] || die "--port needs a number"; PORT=$2; shift 2 ;;
    --keep) [[ "${2:-}" =~ ^[1-9][0-9]*$ ]] || die "--keep needs a number >= 1"; KEEP=$2; shift 2 ;;
    --no-remote-prune) REMOTE_KEEP=0; shift ;;
    --work) WORK="${2:-}"; shift 2 ;;
    --with-recordings) RECORDINGS=1; shift ;;
    --bwlimit) [[ "${2:-}" =~ ^[0-9]+$ ]] || die "--bwlimit needs a number"; BWLIMIT=$2; shift 2 ;;
    --name) NAME_PREFIX="${2:-}"; [[ "$NAME_PREFIX" =~ ^[A-Za-z0-9_.-]+$ ]] || die "--name: letters, digits, . _ - only"; shift 2 ;;
    -q|--quiet) QUIET=1; shift ;;
    --mail) MAIL_TO="${2:-}"; [[ "$MAIL_TO" == *@* ]] || die "--mail needs an address"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
done
[ -n "$DEST" ] || { usage >&2; die "--dest is required"; }
[ "$EUID" -eq 0 ] || die "run as root"
for c in mysqldump tar gzip sha256sum; do command -v "$c" >/dev/null 2>&1 || die "$c is not installed"; done
REMOTE=0; [[ "$DEST" == *:* ]] && REMOTE=1
[ "$REMOTE" = 1 ] && { command -v rsync >/dev/null 2>&1 || die "rsync is not installed (apt/dnf install rsync)"; }

LOG=$(mktemp) || exit 2
log() { echo "$(date '+%F %T') $*" >> "$LOG"; [ "$QUIET" = 1 ] || echo "$*"; }
fail() { echo "$(date '+%F %T') ERROR: $*" >> "$LOG"; echo "ERROR: $*" >&2; }
notify() { [ -n "$MAIL_TO" ] && command -v mail >/dev/null 2>&1 && mail -s "[FreePBX backup] $1 on $(hostname -f 2>/dev/null || hostname)" "$MAIL_TO" < "$LOG"; }

mkdir -p "$WORK" && chmod 700 "$WORK" || { echo "ERROR: cannot create $WORK" >&2; exit 2; }
exec 9>"$WORK/.lock"; flock -n 9 || { echo "ERROR: another backup is running" >&2; exit 2; }
STAMP=$(date +%Y%m%d-%H%M%S); SET="$NAME_PREFIX-$STAMP"; D="$WORK/$SET.partial"
mkdir -p "$D" || { echo "ERROR: cannot create $D" >&2; exit 2; }
start=$(date +%s); err=0

# 1. Databases (FreePBX config + call records), one consistent transaction each.
# A failed query is an error, never "database absent". On FreePBX (/etc/freepbx.conf) both databases are required.
FREEPBX=0; [ -f /etc/freepbx.conf ] && FREEPBX=1
dblist=""; dbq=1
if command -v mysql >/dev/null 2>&1; then
  if dblist=$(mysql "${MA[@]}" -N -B -e "SHOW DATABASES" 2>>"$LOG"); then dbq=0
  else fail "cannot query the database server (mysql exit $?): check that MariaDB/MySQL runs and MYSQL_ARGS"; err=1; fi
elif [ "$FREEPBX" = 1 ]; then fail "mysql client not installed, cannot back up the FreePBX databases"; err=1; fi
for db in asterisk asteriskcdrdb; do
  [ "$dbq" = 0 ] || continue
  if ! grep -qx "$db" <<<"$dblist"; then
    if [ "$FREEPBX" = 1 ]; then fail "database $db is missing on this FreePBX server"; err=1
    else log "database $db: not present (plain Asterisk), skipped"; fi
    continue
  fi
  if mysqldump "${MA[@]}" --single-transaction --quick --routines --events --triggers --hex-blob --default-character-set=utf8mb4 --databases "$db" 2>>"$LOG" | gzip -6 > "$D/$db.sql.gz" \
     && [ "$(zcat "$D/$db.sql.gz" | tail -1 | grep -c 'Dump completed')" = 1 ]; then log "database $db: $(du -h "$D/$db.sql.gz" | cut -f1)"
  else fail "dump of $db failed"; err=1; fi
done

# 2. astdb (call forwarding, DND, follow-me...) copied with sqlite3 so a half-written file is never saved
if [ -f /var/lib/asterisk/astdb.sqlite3 ]; then
  if ! command -v sqlite3 >/dev/null 2>&1; then
    fail "sqlite3 is not installed, so astdb cannot be copied safely while Asterisk runs (apt install sqlite3 / dnf install sqlite)"; err=1
  elif sqlite3 /var/lib/asterisk/astdb.sqlite3 ".backup '$D/astdb.sqlite3'" 2>>"$LOG" \
       && [ "$(sqlite3 "$D/astdb.sqlite3" 'PRAGMA integrity_check' 2>>"$LOG")" = ok ]; then
    log "astdb: copied ($(sqlite3 "$D/astdb.sqlite3" 'SELECT COUNT(*) FROM astdb' 2>/dev/null) keys, integrity ok)"
  else fail "astdb copy failed or did not pass the integrity check"; err=1; fi
fi

# 3. Files
paths=(); for p in /etc/asterisk /etc/freepbx.conf /etc/amportal.conf /etc/odbc.ini /var/lib/asterisk/moh /var/lib/asterisk/sounds/custom \
  /var/lib/asterisk/agi-bin /var/lib/asterisk/bin /var/spool/asterisk/voicemail /tftpboot /var/lib/tftpboot /etc/asterisk/keys; do [ -e "$p" ] && paths+=("${p#/}"); done
[ "$RECORDINGS" = 1 ] && [ -d /var/spool/asterisk/monitor ] && paths+=("var/spool/asterisk/monitor")
if tar -C / -czf "$D/files.tar.gz" --warning=no-file-changed "${paths[@]}" 2>>"$LOG"; rc=$?; [ "$rc" -le 1 ]; then
  log "files: $(du -h "$D/files.tar.gz" | cut -f1) (${#paths[@]} paths$([ "$RECORDINGS" = 1 ] && echo ', with recordings'))"
else fail "tar of the files failed (exit $rc)"; err=1; fi

# 4. Manifest, restore notes, checksums, read-back test
{
  echo "set=$SET"; echo "created=$(date -u '+%F %T UTC')"; echo "host=$(hostname -f 2>/dev/null || hostname)"
  echo "freepbx=$(fwconsole -V 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)+' | head -1)"
  echo "asterisk=$(asterisk -rx 'core show version' 2>/dev/null | awk '{print $2; exit}')"
  echo "os=$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")"
  echo "paths=${paths[*]}"
} > "$D/MANIFEST.txt"
fwconsole ma list 2>/dev/null | awk -F'|' 'NF>4 && $2 !~ /Module/ {gsub(/ /,"",$2); gsub(/ /,"",$3); gsub(/^ +| +$/,"",$4); print $2, $3, $4}' > "$D/modules.txt" 2>/dev/null
cat > "$D/RESTORE.txt" <<'EOF'
Restore a FreePBX server from this set (srvScripts freepbx-offsite-backup)
1. Install the same FreePBX major version on a fresh server (MANIFEST.txt shows the versions).
2. fwconsole stop
3. zcat asterisk.sql.gz | mysql          (the dump recreates and fills the asterisk database)
   zcat asteriskcdrdb.sql.gz | mysql
4. tar -C / -xzpf files.tar.gz           (restores /etc/asterisk, freepbx.conf, sounds, voicemail ...)
5. cp astdb.sqlite3 /var/lib/asterisk/astdb.sqlite3
6. Reinstall any commercial modules listed in modules.txt, then: fwconsole chown && fwconsole reload && fwconsole start
7. Check: asterisk -rx "pjsip show registrations"; place a test call in and out.
EOF
( cd "$D" && sha256sum ./*.gz ./*.sqlite3 MANIFEST.txt modules.txt RESTORE.txt 2>/dev/null > SHA256SUMS )
for g in "$D"/*.gz; do gzip -t "$g" 2>>"$LOG" || { fail "$(basename "$g") does not read back"; err=1; }; done
tar -tzf "$D/files.tar.gz" >/dev/null 2>>"$LOG" || { fail "files.tar.gz cannot be listed"; err=1; }
if [ "$err" = 1 ]; then fail "backup set incomplete; kept as $D for inspection"; notify FAILED; rm -f "$LOG"; exit 2; fi
mv "$D" "$WORK/$SET" && D="$WORK/$SET"
log "set $SET ready: $(du -sh "$D" | cut -f1)"

# 5. Copy and verify
copy_rc=0
if [ "$REMOTE" = 1 ]; then
  SSH=(ssh -p "$PORT" -o BatchMode=yes -o ConnectTimeout=20); [ -n "$KEY" ] && SSH+=(-i "$KEY" -o IdentitiesOnly=yes)
  RS=(rsync -a --partial --timeout=120 -e "${SSH[*]}"); [ "$BWLIMIT" -gt 0 ] && RS+=(--bwlimit="$BWLIMIT")
  rpath=${DEST#*:}; rpath=${rpath%/}
  if "${RS[@]}" "$D/" "$DEST/$SET.partial/" 2>>"$LOG"; then
    # verification: a checksum dry run must succeed AND find nothing left to send. A failed run is a failure,
    # never "0 differences".
    vout=$("${RS[@]}" --checksum --dry-run --itemize-changes "$D/" "$DEST/$SET.partial/" 2>>"$LOG"); vrc=$?
    diffs=$(grep -v '^\.d' <<<"$vout" | grep -c . || true)
    if [ "$vrc" -ne 0 ]; then fail "verification run failed (rsync exit $vrc); the copy is NOT verified"; copy_rc=1
    elif [ "$diffs" = 0 ]; then
      if "${SSH[@]}" "${DEST%%:*}" "mv '$rpath/$SET.partial' '$rpath/$SET'" 2>>"$LOG"; then log "copied to $DEST/$SET and verified (checksums match)"
      else log "copied to $DEST/$SET.partial and verified (could not rename on the destination; restricted account?)"; fi
    else fail "verification found $diffs file(s) that differ on $DEST"; copy_rc=1; fi
  else fail "rsync to $DEST failed"; copy_rc=1; fi
else
  mkdir -p "$DEST" && cp -a "$D" "$DEST/$SET.partial" && ( cd "$DEST/$SET.partial" && sha256sum -c --quiet SHA256SUMS ) 2>>"$LOG" \
    && mv "$DEST/$SET.partial" "$DEST/$SET" && log "copied to $DEST/$SET and verified (sha256sum -c)" || { fail "copy to $DEST failed"; copy_rc=1; }
fi

# 6. Retention (sets are folders named <prefix>-YYYYmmdd-HHMMSS). After a failed off-site copy nothing is pruned
# locally, so the last good local sets stay available.
prune_local() { local dir=$1; find "$dir" -maxdepth 1 -type d -name "$NAME_PREFIX-[0-9]*-[0-9]*" ! -name '*.partial' -printf '%f\n' | sort | head -n -"$KEEP"; }
if [ "$copy_rc" = 0 ]; then
  for old in $(prune_local "$WORK"); do rm -rf "${WORK:?}/$old" && log "pruned local $old"; done
else log "local pruning skipped because the off-site copy failed"; fi
if [ "$copy_rc" = 0 ] && [ "$REMOTE_KEEP" = 1 ]; then
  if [ "$REMOTE" = 1 ]; then
    if ! "${SSH[@]}" "${DEST%%:*}" "cd '$rpath' && ls -1d $NAME_PREFIX-[0-9]*-[0-9]* 2>/dev/null | grep -v partial | sort | head -n -$KEEP | while read -r o; do rm -rf -- \"\$o\" && echo \"pruned remote \$o\"; done" >> "$LOG" 2>&1; then
      log "note: remote pruning not possible (restricted account?); prune on the destination instead"
    fi
  else for old in $(prune_local "$DEST"); do rm -rf "${DEST:?}/$old" && log "pruned $old on $DEST"; done; fi
fi

secs=$(( $(date +%s) - start ))
if [ "$copy_rc" = 0 ]; then echo "OK: $SET backed up and copied in ${secs}s ($(du -sh "$D" | cut -f1))"; rm -f "$LOG"; exit 0
else echo "WARNING: $SET made locally ($D) but the off-site copy failed"; notify "COPY FAILED"; rm -f "$LOG"; exit 1; fi
