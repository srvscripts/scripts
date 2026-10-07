#!/usr/bin/env bash
# Restic Backup Script for Offsite Backups (v1.2.0) - from srvScripts.com
# Source, docs and updates: https://srvscripts.com/scripts/restic-offsite-backup/
# Copyright (c) 2026 srvScripts.com. MIT licence: if you copy, share or adapt this script, keep this notice and credit srvScripts.com.
# restic-offsite-backup.sh — cron-safe restic wrapper: MySQL dumps, backup, retention, periodic integrity check
# https://srvscripts.com/scripts/restic-offsite-backup/   License: MIT
# Version: 1.2.0
#
# Reads /etc/srvscripts/restic.conf (KEY=value lines, never executed), optionally dumps every
# MariaDB/MySQL database, runs `restic backup`, `restic forget --prune` with your keep policy and,
# every CHECK_EVERY_DAYS, `restic check --read-data-subset`. One run at a time (flock). Logs to
# /var/log/restic-offsite-backup.log. The repository password is only ever read by restic itself.
#   bash restic-offsite-backup.sh --init           # create the repository (asks first)
#   bash restic-offsite-backup.sh --dry-run        # show what would be backed up and pruned
#   bash restic-offsite-backup.sh                  # the nightly run (put this in cron)
#   bash restic-offsite-backup.sh --list           # snapshots
#   bash restic-offsite-backup.sh --restore-test   # restore one random file and compare checksums
# Safety: DUMP_DIR must be a directory this script created (it holds a .srvscripts-restic-dump marker)
# or an empty one. Each run dumps into its own new DUMP_DIR/run.XXXXXX workspace without overwriting
# anything and deletes only files it created there (or that a killed earlier run recorded in its own
# workspace); nothing else in DUMP_DIR is changed or deleted. If any requested path or
# database dump is missing, or restic could not read every file, retention (forget --prune) is skipped
# so older complete snapshots are kept; set ALLOW_PARTIAL_PRUNE=yes to override.
# Exit codes: 0 OK, 1 backup/prune/check/restore problem or another run holds the lock, 2 config error.
# 1.2.0: dumps go to a per-run workspace DUMP_DIR/run.XXXXXX, are created exclusively (no overwrite, no
#        symlink following) and only this run's own files are deleted; sanitised DB file names get a hash.
set -uo pipefail
export LC_ALL=C
unset RESTIC_PASSWORD RESTIC_PASSWORD_COMMAND        # the password comes from RESTIC_PASSWORD_FILE only

SCRIPT_VERSION=1.2.0
CONF=/etc/srvscripts/restic.conf; MODE=backup; DRY=0; YES=0; VERBOSE=0
STATE_DIR=/var/lib/srvscripts; TAG=srvscripts; HOST=$(hostname)

usage() {
  cat <<'EOF'
Usage: restic-offsite-backup.sh [mode] [options]
Modes (default: backup):
  --init            create the restic repository (asks unless --yes)
  --list            list this host's snapshots
  --restore-test    restore one random file from the latest snapshot and verify its checksum
  --check           run the integrity check now (normally every CHECK_EVERY_DAYS days)
Options:
  --config FILE     config file (default /etc/srvscripts/restic.conf)
  --dry-run         backup mode: show what would be saved and forgotten, change nothing
  --yes             do not ask for confirmation (--init)
  -v, --verbose     also print restic's own output (it always goes to the log)
  -h, --help        this help;  --version  print the version
EOF
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --init) MODE=init; shift ;;
    --list) MODE=list; shift ;;
    --restore-test) MODE=restore; shift ;;
    --check) MODE=check; shift ;;
    --config) [[ -n "${2:-}" ]] || { echo "--config needs a file" >&2; exit 2; }; CONF=$2; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --yes) YES=1; shift ;;
    -v|--verbose) VERBOSE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --version) echo "restic-offsite-backup $SCRIPT_VERSION"; exit 0 ;;
    *) echo "Unknown option: $1 (try --help)" >&2; exit 2 ;;
  esac
done
command -v restic >/dev/null || { echo "restic not installed (dnf install restic from EPEL, or apt install restic)" >&2; exit 2; }
command -v flock >/dev/null || { echo "flock not installed (util-linux)" >&2; exit 2; }

# ---- config: parsed as data, never sourced -----------------------------------------------------
declare -A CFG=([KEEP_DAILY]=7 [KEEP_WEEKLY]=4 [KEEP_MONTHLY]=6 [CHECK_EVERY_DAYS]=7 [CHECK_SUBSET]=5%
                [MYSQL_DUMP]=no [DUMP_DIR]=/var/backups/restic-mysql [LOG_FILE]=/var/log/restic-offsite-backup.log
                [ALLOW_PARTIAL_PRUNE]=no)
SCRIPT_KEYS=" BACKUP_PATHS EXCLUDES EXCLUDE_FILE KEEP_DAILY KEEP_WEEKLY KEEP_MONTHLY MYSQL_DUMP MYSQL_ARGS DUMP_DIR ALLOW_PARTIAL_PRUNE CHECK_EVERY_DAYS CHECK_SUBSET LOG_FILE LIMIT_UPLOAD "
ENV_KEYS=" RESTIC_REPOSITORY RESTIC_PASSWORD_FILE RESTIC_CACHE_DIR RESTIC_COMPRESSION AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION B2_ACCOUNT_ID B2_ACCOUNT_KEY AZURE_ACCOUNT_NAME AZURE_ACCOUNT_KEY GOOGLE_PROJECT_ID GOOGLE_APPLICATION_CREDENTIALS "
[[ -r "$CONF" ]] || { echo "Cannot read config $CONF (see --help and the example on the script page)" >&2; exit 2; }
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
  if [[ ! "$line" =~ ^[[:space:]]*([A-Z0-9_]+)[[:space:]]*=[[:space:]]*(.*)$ ]]; then echo "config: ignoring line: $line" >&2; continue; fi
  key=${BASH_REMATCH[1]}; val=${BASH_REMATCH[2]}
  val=${val%"${val##*[![:space:]]}"}                                     # trim trailing spaces
  if [[ "$val" =~ ^\"(.*)\"$ || "$val" =~ ^\'(.*)\'$ ]]; then val=${BASH_REMATCH[1]}; fi
  if [[ "$SCRIPT_KEYS" == *" $key "* ]]; then CFG[$key]=$val
  elif [[ "$ENV_KEYS" == *" $key "* ]]; then export "$key=$val"
  elif [[ "$key" == RESTIC_PASSWORD ]]; then echo "config: RESTIC_PASSWORD is not supported, use RESTIC_PASSWORD_FILE" >&2
  else echo "config: unknown key $key (ignored)" >&2; fi
done < "$CONF"

LOG=${CFG[LOG_FILE]}
: "${RESTIC_REPOSITORY:?RESTIC_REPOSITORY is not set in $CONF}"
: "${RESTIC_PASSWORD_FILE:?RESTIC_PASSWORD_FILE is not set in $CONF}"
[[ -r "$RESTIC_PASSWORD_FILE" ]] || { echo "Cannot read password file $RESTIC_PASSWORD_FILE" >&2; exit 2; }
for k in KEEP_DAILY KEEP_WEEKLY KEEP_MONTHLY CHECK_EVERY_DAYS; do
  [[ "${CFG[$k]}" =~ ^[0-9]+$ ]] || { echo "config: $k must be a number" >&2; exit 2; }
done
perm_warn() { local m; m=$(stat -c '%a' "$1" 2>/dev/null) || return; (( 8#$m & 8#044 )) && echo "WARN: $1 is readable by other users (mode $m); chmod 600 it" >&2; }
perm_warn "$RESTIC_PASSWORD_FILE"; perm_warn "$CONF"

# ---- helpers -----------------------------------------------------------------------------------------
OUT=$(mktemp) || exit 2
RESTORE_TMP=""; CREATED=(); RUN_DIR=""
MARKER=.srvscripts-restic-dump
RUN_MARKER=.srvscripts-restic-run           # in each run workspace: header line, then the dump names that run created
RUN_FLAG=.srvscripts-restic-incomplete      # present while a run is still dumping; restic skips such workspaces
cleanup() {   # removes only files this run created inside its own run workspace: never anything else in DUMP_DIR
  local f
  rm -f "$OUT"
  [[ -n "$RESTORE_TMP" ]] && rm -rf "$RESTORE_TMP"
  [[ -n "$RUN_DIR" && -d "$RUN_DIR" && ! -L "$RUN_DIR" ]] || return 0
  for f in "${CREATED[@]}"; do [[ "$f" == "$RUN_DIR/"* && -f "$f" && ! -L "$f" ]] && rm -f -- "$f"; done
  rmdir -- "$RUN_DIR" 2>/dev/null || log "WARN kept $RUN_DIR: it holds files this run did not create"
}
trap cleanup EXIT
trap 'exit 1' INT TERM HUP     # so cleanup also runs when cron or an admin stops the run
touch "$LOG" 2>/dev/null || LOG=/dev/null
log() { printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG"; }
rr() {   # run restic, keep its output in $OUT and the log, show it with --verbose
  printf '%s $ restic %s\n' "$(date '+%F %T')" "$*" >> "$LOG"
  restic "$@" > "$OUT" 2>&1; local rc=$?
  cat "$OUT" >> "$LOG"
  (( VERBOSE )) && cat "$OUT"
  grep -q 'repository is already locked' "$OUT" &&
    log "HINT: another restic process holds the repository lock; if none is running, run: restic unlock"
  return $rc
}
confirm() { (( YES )) && return 0; local a; read -r -p "$1 [y/N] " a; [[ "$a" =~ ^[Yy] ]]; }
LOCKFILE=/run/lock/restic-offsite-backup.lock; [[ -d /run/lock ]] || LOCKFILE=/tmp/restic-offsite-backup.lock
take_lock() {
  exec 9>"$LOCKFILE" || { echo "Cannot open lock file $LOCKFILE" >&2; exit 2; }
  flock -n 9 || { log "ERROR another restic-offsite-backup run is in progress (lock $LOCKFILE)"; exit 1; }
}
repo_ok() { restic cat config >/dev/null 2>&1; }

# ---- modes ---------------------------------------------------------------------------------------------
do_init() {
  take_lock
  if repo_ok; then echo "Repository already initialised: $RESTIC_REPOSITORY"; return 0; fi
  confirm "Create a new restic repository at $RESTIC_REPOSITORY?" || { echo "Aborted."; return 1; }
  if rr init; then log "OK repository created at $RESTIC_REPOSITORY"; echo "Keep a copy of $RESTIC_PASSWORD_FILE somewhere else: without it the backups cannot be read."
  else log "FAIL restic init (see $LOG)"; tail -3 "$OUT"; return 1; fi
}

do_list() { restic snapshots --host "$HOST"; }

# DUMP_DIR must be a dedicated directory: an absolute path with no symlinks, not a system
# directory, owned by the user running this script and not writable by others, and either created
# by this script (marker file present) or empty. A populated directory is never cleared.
dumpdir_ok() {
  local dir=$1 real owner mode n
  [[ "$dir" =~ ^/[^/]+/[^/]+ ]] || { log "FAIL DUMP_DIR must be a dedicated directory at least two levels deep, got '$dir'"; return 1; }
  real=$(realpath -m -- "$dir" 2>/dev/null) || { log "FAIL cannot resolve DUMP_DIR '$dir'"; return 1; }
  [[ "$real" == "$dir" ]] || { log "FAIL DUMP_DIR '$dir' contains a symlink, '..' or a trailing slash (resolves to '$real'); use the real path"; return 1; }
  case "$real/" in
    /etc/*|/usr/*|/bin/*|/sbin/*|/lib/*|/lib64/*|/boot/*|/proc/*|/sys/*|/dev/*|/run/*|/var/lib/mysql/*|/var/lib/mariadb/*|/home/*/public_html/*)
      log "FAIL DUMP_DIR '$dir' is inside a system or data directory; use e.g. /var/backups/restic-mysql"; return 1 ;;
  esac
  if [[ -e "$dir" || -L "$dir" ]]; then
    [[ -d "$dir" && ! -L "$dir" ]] || { log "FAIL DUMP_DIR '$dir' exists but is not a plain directory"; return 1; }
    owner=$(stat -c %u -- "$dir") mode=$(stat -c %a -- "$dir")
    [[ "$owner" == "$EUID" ]] || { log "FAIL DUMP_DIR '$dir' is owned by uid $owner, not by the user running this script"; return 1; }
    (( 8#$mode & 8#022 )) && { log "FAIL DUMP_DIR '$dir' is writable by group or others (mode $mode)"; return 1; }
    [[ -L "$dir/$MARKER" ]] && { log "FAIL $dir/$MARKER is a symlink; this script never creates one"; return 1; }
    if [[ ! -f "$dir/$MARKER" ]]; then
      n=$(find "$dir" -mindepth 1 -maxdepth 1 2>/dev/null | head -n 1)
      [[ -z "$n" ]] || { log "FAIL DUMP_DIR '$dir' already contains files and was not created by this script (no $MARKER marker); choose an empty or new directory. Nothing was deleted."; return 1; }
    fi
  fi
  return 0
}

# Workspaces left by an earlier run that was killed (power loss, kill -9): only directories named
# run.XXXXXX that carry our run marker are touched, only the dump names that marker lists are deleted,
# and the directory is removed only if nothing else is left in it.
clean_stale_runs() {
  local dir=$1 d prev rest
  for d in "$dir"/run.*; do
    [[ "$d" != "$RUN_DIR" && "${d##*/}" =~ ^run\.[A-Za-z0-9]{6}$ && -d "$d" && ! -L "$d" ]] || continue
    [[ -f "$d/$RUN_MARKER" && ! -L "$d/$RUN_MARKER" && "$(stat -c %u -- "$d")" == "$EUID" ]] ||
      { log "WARN $d has no run marker of this script; left alone"; continue; }
    while IFS= read -r prev; do
      [[ "$prev" =~ ^[A-Za-z0-9._-]+\.sql(\.part)?$ && -f "$d/$prev" && ! -L "$d/$prev" ]] && rm -f -- "$d/$prev"
    done < "$d/$RUN_MARKER"
    rest=$(find "$d" -mindepth 1 -maxdepth 1 ! -name "$RUN_MARKER" ! -name "$RUN_FLAG" 2>/dev/null | head -n 1)
    if [[ -z "$rest" ]]; then
      [[ -f "$d/$RUN_FLAG" && ! -L "$d/$RUN_FLAG" ]] && rm -f -- "$d/$RUN_FLAG"
      rm -f -- "$d/$RUN_MARKER"; rmdir -- "$d" 2>/dev/null && log "INFO removed workspace of an interrupted earlier run: $d"
    else log "WARN $d (interrupted earlier run) holds files this script did not create; left alone"; fi
  done
}

dump_mysql() {   # dump every database into a new run workspace DUMP_DIR/run.XXXXXX, one .sql per database
  local client dumper db f name n why ok=0 bad=0 dir=${CFG[DUMP_DIR]}
  local -a margs dbs
  local -A seen=()
  client=$(command -v mariadb || command -v mysql) || { log "FAIL MYSQL_DUMP=yes but no mysql/mariadb client"; return 1; }
  dumper=$(command -v mariadb-dump || command -v mysqldump) || { log "FAIL MYSQL_DUMP=yes but no mysqldump/mariadb-dump"; return 1; }
  dumpdir_ok "$dir" || return 1
  read -ra margs <<< "${CFG[MYSQL_ARGS]:-}"
  mapfile -t dbs < <("$client" "${margs[@]}" -N -B -e 'SHOW DATABASES' 2>>"$LOG" | grep -Ev '^(information_schema|performance_schema|sys)$')
  (( ${#dbs[@]} )) || { log "FAIL cannot list databases (check MYSQL_ARGS or /root/.my.cnf)"; return 1; }
  if (( DRY )); then log "DRY-RUN would dump ${#dbs[@]} database(s) to a new workspace $dir/run.XXXXXX"; return 0; fi
  if [[ ! -d "$dir" ]]; then mkdir -p -- "$dir" || { log "FAIL cannot create $dir"; return 1; }; fi
  chmod 700 -- "$dir" && { [[ -f "$dir/$MARKER" && ! -L "$dir/$MARKER" ]] ||
    ( set -o noclobber; printf 'Created by restic-offsite-backup.sh (srvscripts.com). Each run works in its own run.XXXXXX directory; nothing else here is deleted.\n' > "$dir/$MARKER" ); } ||
    { log "FAIL cannot write the marker in $dir"; return 1; }
  [[ -e "$dir/$MARKER.files" ]] && log "WARN $dir/$MARKER.files was left by an interrupted 1.1.x run; the dumps it lists are no longer deleted automatically, check and remove them yourself"
  clean_stale_runs "$dir"
  n=$(find "$dir" -mindepth 1 -maxdepth 1 ! -name "$MARKER" 2>/dev/null | wc -l)
  (( n )) && log "WARN $dir contains $n item(s) this run did not create; they are never changed or deleted and are included in the backup"
  # the run workspace: a new directory only this run uses (mktemp creates it exclusively, mode 700)
  RUN_DIR=$(mktemp -d "$dir/run.XXXXXX") && [[ "$RUN_DIR" == "$dir"/run.* && -d "$RUN_DIR" && ! -L "$RUN_DIR" ]] ||
    { log "FAIL cannot create a run workspace in $dir"; RUN_DIR=""; return 1; }
  ( set -o noclobber; : > "$RUN_DIR/$RUN_FLAG" ) 2>>"$LOG" && CREATED+=("$RUN_DIR/$RUN_FLAG") &&
  ( set -o noclobber; printf 'restic-offsite-backup %s run workspace (pid %s, %s); dump files it created:\n' "$SCRIPT_VERSION" "$$" "$(date '+%F %T')" > "$RUN_DIR/$RUN_MARKER" ) 2>>"$LOG" &&
    CREATED+=("$RUN_DIR/$RUN_MARKER") || { log "FAIL cannot write the run marker in $RUN_DIR"; return 1; }
  for db in "${dbs[@]}"; do
    name=$(printf '%s' "$db" | tr -c 'A-Za-z0-9._-' '_')
    # sanitising is lossy ('a b' and 'a?b' both give a_b): a changed name gets a hash of the real one
    [[ "$name" == "$db" ]] || name="$name-$(printf '%s' "$db" | sha256sum | cut -c1-8)"
    f="$RUN_DIR/$name.sql"
    why=""
    if [[ -n "${seen[$name]:-}" ]]; then why="database '${seen[$name]}' already uses $name.sql"
    elif [[ -e "$f" || -L "$f" || -e "$f.part" || -L "$f.part" ]]; then why="$name.sql or $name.sql.part already exists"; fi
    [[ -z "$why" ]] || { bad=$((bad + 1)); log "WARN database '$db' NOT dumped: $why; nothing was overwritten"; continue; }
    seen[$name]=$db
    # exclusive create: noclobber refuses any existing file or symlink (the -e/-L test above covers fifos/devices)
    set -o noclobber
    if { exec 8>"$f.part"; } 2>>"$LOG"; then
      set +o noclobber; CREATED+=("$f.part"); printf '%s\n' "$name.sql.part" >> "$RUN_DIR/$RUN_MARKER"
      if "$dumper" "${margs[@]}" --single-transaction --quick --routines --events --triggers --databases "$db" >&8 2>>"$LOG" &&
         exec 8>&- && mv -n -T -- "$f.part" "$f" 2>>"$LOG" && [[ ! -e "$f.part" && ! -L "$f.part" && -f "$f" && ! -L "$f" ]]; then
        CREATED+=("$f"); printf '%s\n' "$name.sql" >> "$RUN_DIR/$RUN_MARKER"; ok=$((ok + 1))
      else exec 8>&-; bad=$((bad + 1)); [[ -f "$f.part" && ! -L "$f.part" ]] && rm -f -- "$f.part"; log "WARN dump of database '$db' failed (details in $LOG)"; fi
    else set +o noclobber; bad=$((bad + 1)); log "WARN database '$db' NOT dumped: cannot create $f.part exclusively; nothing was overwritten"; fi
  done
  rm -f -- "$RUN_DIR/$RUN_FLAG"     # finished: only complete dumps are left in the workspace
  log "INFO dumped $ok of ${#dbs[@]} database(s) to $RUN_DIR ($(du -sh "$RUN_DIR" | cut -f1))"
  (( bad == 0 ))
}

do_backup() {
  local rc status=0 partial p last now
  local -a all=() paths=() excl=() args=() keep=()
  take_lock
  [[ $EUID -eq 0 ]] || log "WARN not running as root: files other users own may be skipped"
  repo_ok || { log "FAIL cannot open repository $RESTIC_REPOSITORY (wrong password, no network, or run --init first)"; return 1; }
  (( DRY )) || rr unlock      # removes only stale locks left by a killed restic; a live one is kept
  read -ra all <<< "${CFG[BACKUP_PATHS]:-}"
  for p in "${all[@]}"; do
    if [[ -e "$p" ]]; then paths+=("$p"); else log "WARN backup path does not exist, skipped: $p"; status=1; fi
  done
  if [[ "${CFG[MYSQL_DUMP],,}" =~ ^(yes|1|true)$ ]]; then
    if dump_mysql; then (( DRY )) || paths+=("${CFG[DUMP_DIR]}")
    else status=1; [[ -d "${CFG[DUMP_DIR]}" && -f "${CFG[DUMP_DIR]}/$MARKER" ]] && (( ! DRY )) && paths+=("${CFG[DUMP_DIR]}"); fi
  fi
  (( ${#paths[@]} )) || { log "FAIL BACKUP_PATHS is empty in $CONF"; return 2; }

  read -ra excl <<< "${CFG[EXCLUDES]:-}"                 # read -a splits on spaces and never expands globs
  args=(backup --tag "$TAG" --host "$HOST")
  for p in "${excl[@]}"; do args+=(--exclude "$p"); done
  [[ -n "${CFG[EXCLUDE_FILE]:-}" ]] && args+=(--exclude-file "${CFG[EXCLUDE_FILE]}")
  [[ -n "${CFG[LIMIT_UPLOAD]:-}" ]] && args+=(--limit-upload "${CFG[LIMIT_UPLOAD]}")
  [[ "${CFG[MYSQL_DUMP],,}" =~ ^(yes|1|true)$ ]] && args+=(--exclude-if-present "$RUN_FLAG")   # skips workspaces of killed runs
  (( DRY )) && args+=(--dry-run -v)
  (( status )) && args+=(--tag incomplete)     # visible in --list; such a snapshot never triggers pruning
  log "INFO backup of ${paths[*]} to $RESTIC_REPOSITORY$( (( DRY )) && echo ' (dry run)')"
  rr "${args[@]}" "${paths[@]}"; rc=$?
  case $rc in
    0) log "OK $(grep -E '^(snapshot .* saved|Added to the repository|Would add to the repository)' "$OUT" | tr '\n' ' ')" ;;
    3) log "WARN snapshot saved but some files could not be read (see $LOG)"; status=1 ;;
    *) log "FAIL restic backup exited with $rc"; tail -5 "$OUT"; return 1 ;;
  esac

  partial=$status
  keep=(--keep-daily "${CFG[KEEP_DAILY]}" --keep-weekly "${CFG[KEEP_WEEKLY]}" --keep-monthly "${CFG[KEEP_MONTHLY]}")
  if (( DRY )); then
    (( partial )) && [[ ! "${CFG[ALLOW_PARTIAL_PRUNE],,}" =~ ^(yes|1|true)$ ]] && log "DRY-RUN this run is incomplete, so a real run would skip retention"
    rr forget --dry-run --host "$HOST" --tag "$TAG" "${keep[@]}"; (( VERBOSE )) || cat "$OUT"
    return $status
  fi
  if (( partial )) && [[ ! "${CFG[ALLOW_PARTIAL_PRUNE],,}" =~ ^(yes|1|true)$ ]]; then
    log "WARN retention skipped: this run was incomplete (missing path, failed dump or unreadable files), so older snapshots are kept. Fix the cause; the next complete run applies retention."
  elif rr forget --prune --host "$HOST" --tag "$TAG" "${keep[@]}"; then
    log "OK retention applied (daily ${CFG[KEEP_DAILY]}, weekly ${CFG[KEEP_WEEKLY]}, monthly ${CFG[KEEP_MONTHLY]})"
  else log "FAIL restic forget --prune (see $LOG)"; status=1; fi

  # integrity check: a random CHECK_SUBSET of the data every CHECK_EVERY_DAYS days
  last=$(cat "$STATE_DIR/restic-offsite-backup.lastcheck" 2>/dev/null || echo 0); now=$(date +%s)
  [[ "$last" =~ ^[0-9]+$ ]] || last=0
  if (( now - last >= CFG[CHECK_EVERY_DAYS] * 86400 )); then do_check || status=1; fi
  return $status
}

do_check() {
  mkdir -p "$STATE_DIR" 2>/dev/null
  if rr check --read-data-subset="${CFG[CHECK_SUBSET]}"; then
    log "OK restic check --read-data-subset=${CFG[CHECK_SUBSET]} passed"
    date +%s > "$STATE_DIR/restic-offsite-backup.lastcheck" 2>/dev/null
  else log "FAIL restic check reported errors (see $LOG)"; return 1; fi
}

do_restore_test() {
  local json id stime sepoch pick size path restored a b how
  take_lock
  json=$(restic snapshots --json --host "$HOST" --tag "$TAG" latest 2>/dev/null)
  id=$(grep -o '"short_id":"[^"]*"' <<< "$json" | head -1 | cut -d'"' -f4)
  stime=$(grep -o '"time":"[^"]*"' <<< "$json" | head -1 | cut -d'"' -f4)
  [[ -n "$id" ]] || { log "FAIL no snapshot for host $HOST with tag $TAG"; return 1; }
  sepoch=$(date -d "$stime" +%s 2>/dev/null || echo 0)
  # regular files of 1 byte..100 MB whose names contain no glob characters (they would confuse --include)
  pick=$(restic ls -l "$id" 2>/dev/null | awk '$1 ~ /^-/ && $4 > 0 && $4 < 104857600 {
           p = $0; sub(/^[^\/]*/, "", p); if (p !~ /[][*?\\]/) print $4 "\t" p }' |
         if command -v shuf >/dev/null; then shuf -n 1; else awk 'BEGIN{srand()} { if (rand() * NR < 1) l = $0 } END{ print l }'; fi)
  [[ -n "$pick" ]] || { log "FAIL snapshot $id has no suitable file to restore"; return 1; }
  IFS=$'\t' read -r size path <<< "$pick"
  RESTORE_TMP=$(mktemp -d) || return 1
  log "INFO restore test: $path ($size bytes) from snapshot $id"
  rr restore "$id" --target "$RESTORE_TMP" --include "$path" || { log "FAIL restic restore (see $LOG)"; return 1; }
  restored="$RESTORE_TMP$path"
  [[ -f "$restored" ]] || { log "FAIL restored file not found at $restored"; return 1; }
  a=$(sha256sum < "$restored" | cut -d' ' -f1)
  if [[ -f "$path" ]] && (( $(stat -c %Y "$path") <= sepoch )); then
    b=$(sha256sum < "$path" | cut -d' ' -f1); how="the live file (unchanged since the snapshot)"
  else
    b=$(restic dump "$id" "$path" 2>/dev/null | sha256sum | cut -d' ' -f1); how="restic dump (live file changed or missing)"
  fi
  if [[ "$a" == "$b" ]]; then log "OK restored file matches $how: sha256 ${a:0:16}..."
  else log "FAIL checksum mismatch against $how: restored ${a:0:16}... expected ${b:0:16}..."; return 1; fi
}

case $MODE in
  init) do_init ;;
  list) do_list ;;
  restore) do_restore_test ;;
  check) take_lock; if repo_ok; then do_check; else log "FAIL cannot open repository $RESTIC_REPOSITORY"; false; fi ;;
  backup) do_backup ;;
esac
rc=$?
(( rc > 2 )) && rc=1
exit $rc
