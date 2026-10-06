#!/usr/bin/env bash
# Backup Verify Script (v2.1.1) - from srvScripts.com
# Source, docs and updates: https://srvscripts.com/scripts/backup-verify/
# Copyright (c) 2026 srvScripts.com. MIT licence: if you copy, share or adapt this script, keep this notice and credit srvScripts.com.
# backup-verify.sh — prove every backup series exists, is fresh, is not shrinking, and opens
# https://srvscripts.com/scripts/backup-verify/   License: MIT
# Version: 2.1.0
#
# Works on any directory of backup files (cPanel /backup/DATE/accounts, DirectAdmin
# admin_backups, JetBackup local destinations, mysqldump .sql.gz, tar, zip). Read-only.
#   bash backup-verify.sh /backup                       # cPanel/DirectAdmin: accounts read from the panel
#   bash backup-verify.sh /backup --deep --all          # list every archive (slow)
#   bash backup-verify.sh /srv/offsite --accounts-file accounts.txt --require-coverage
#   bash backup-verify.sh /srv/offsite --archives-only  # archive checks only, no account coverage
#   bash backup-verify.sh /backup -q                    # only problems (for cron)
# Exit: 0 = every check that ran passed (the summary says which checks ran),
#       1 = any FAIL or UNVERIFIED, including account coverage that could not be checked,
#       2 = usage error.
set -uo pipefail
export LC_ALL=C
VERSION=2.1.1

usage() {
  cat <<'EOF'
Usage: backup-verify.sh DIR [options]

  --max-age H          newest file of every series must be younger than H hours (26)
  --shrink PCT         FAIL when a series' newest file is PCT% smaller than its previous one (20)
  --min-size BYTES     FAIL for backup files smaller than this (1024)
  --min-count N        FAIL when fewer than N backup files are found (1)
  --depth N            how deep to search under DIR (5)
  --deep               list every archive with tar/unzip and check SQL dump trailers
  --all                test every file of every series, not only the newest
  --accounts-file F    expected account names, one per line (# comments allowed)
  --expect "u1 u2"     expected account names on the command line
  --require-coverage   FAIL (not just UNVERIFIED) when there is no list of expected accounts
  --archives-only      check the archives only; account coverage is skipped and the summary
                       says so (--no-coverage is accepted as the old name)
  --allow-unverified   do not count UNVERIFIED (tool missing, unreadable dir) as a problem
  -q, --quiet          print only problems and the summary line when there are any
  --no-color           no colours (colour is only used on a terminal anyway)
  -h, --help           this help;  --version  print the version

Without --accounts-file or --expect, expected accounts come from /var/cpanel/users or the
DirectAdmin user list. If neither exists, account coverage is UNVERIFIED (exit 1) unless you
pass --archives-only or --allow-unverified. A fresh backup in any series counts toward
coverage, so to require coverage per source server, run once per source directory.
Series are grouped by folder below DIR (dated folder names collapsed to @date) plus the file
name without dates, so the same account name from two sources stays two separate series.
EOF
}

DIR=""; MAXAGE=26; SHRINK=20; MINSIZE=1024; MINCOUNT=1; DEPTH=5
DEEP=0; ALL=0; QUIET=0; COLOR=1; ALLOW_UNV=0; REQ_COV=0; NO_COV=0; ACCT_FILE=""; EXPECT=""
die() { echo "backup-verify: $*" >&2; exit 2; }
num() { [[ ${2:-} =~ ^[0-9]+$ ]] || die "$1 needs a whole number, got '${2:-}'"; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --max-age)   num "$1" "${2:-}"; MAXAGE=$2; shift 2 ;;
    --shrink)    num "$1" "${2:-}"; SHRINK=$2; shift 2 ;;
    --min-size)  num "$1" "${2:-}"; MINSIZE=$2; shift 2 ;;
    --min-count) num "$1" "${2:-}"; MINCOUNT=$2; shift 2 ;;
    --depth)     num "$1" "${2:-}"; DEPTH=$2; shift 2 ;;
    --accounts-file) [[ -n ${2:-} ]] || die "$1 needs a file"; ACCT_FILE=$2; shift 2 ;;
    --expect)    [[ -n ${2:-} ]] || die "$1 needs a list of accounts"; EXPECT="$EXPECT ${2//,/ }"; shift 2 ;;
    --deep) DEEP=1; shift ;;
    --all) ALL=1; shift ;;
    --require-coverage) REQ_COV=1; shift ;;
    --no-coverage|--archives-only) NO_COV=1; shift ;;
    --allow-unverified) ALLOW_UNV=1; shift ;;
    -q|--quiet) QUIET=1; shift ;;
    --no-color) COLOR=0; shift ;;
    -h|--help) usage; exit 0 ;;
    --version) echo "backup-verify $VERSION"; exit 0 ;;
    -*) echo "Unknown option $1" >&2; usage >&2; exit 2 ;;
    *) [[ -z $DIR ]] || die "only one directory can be checked per run"; DIR=$1; shift ;;
  esac
done
[[ -n $DIR ]] || { usage >&2; exit 2; }
[[ -d $DIR ]] || die "not a directory: $DIR"
[[ $DIR == /* ]] || DIR="./$DIR"          # paths never start with '-' when handed to tools
(( DEPTH >= 1 )) || die "--depth must be at least 1"
[[ -z $ACCT_FILE || -r $ACCT_FILE ]] || die "cannot read accounts file: $ACCT_FILE"

# ---- output helpers ---------------------------------------------------------------------
if (( COLOR )) && [[ -t 1 ]]; then R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; N=$'\e[0m'; else R=""; G=""; Y=""; N=""; fi
PROBLEMS=0
line()  { printf '  %s%-10s%s %s\n' "$1" "$2" "$N" "$3"; }
ok()    { (( QUIET )) || line "$G" OK "$*"; }
info()  { (( QUIET )) || line "" INFO "$*"; }
fail()  { PROBLEMS=$((PROBLEMS+1)); line "$R" FAIL "$*"; }
unver() { (( ALLOW_UNV )) || PROBLEMS=$((PROBLEMS+1)); line "$Y" UNVERIFIED "$*"; }
warn()  { line "$Y" WARN "$*"; }
section() { (( QUIET )) || printf '\n== %s ==\n' "$*"; }
human() { numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "$1 B"; }
need()  { command -v "$1" >/dev/null 2>&1; }

# ---- find backup files ------------------------------------------------------------------
EXTS=(tar.gz tgz tar.zst tar.xz tar.bz2 tbz2 tar zip sql.gz sql.zst sql gz zst xz bz2)
name_args=(); for e in "${EXTS[@]}"; do name_args+=(-o -name "*.$e"); done
TMPD=$(mktemp -d) || die "mktemp failed"; trap 'rm -rf "$TMPD"' EXIT
mapfile -d '' -t recs < <(find "$DIR" -maxdepth "$DEPTH" -type f \( "${name_args[@]:1}" \) \
                              -printf '%T@\t%s\t%p\0' 2>"$TMPD/find.err" | sort -z -n)
now=$(date +%s)

# Series key = basename with the extension and any date/time stamps removed, plus the
# extension:  user.tar.gz, db_2026-09-28.sql.gz -> db.sql.gz, backup-9.28.2026_14-05-33_bob.tar.gz -> backup-bob.tar.gz
# Each pattern is (non-digit or start)(STAMP)(non-digit or end); group 2 is removed.
RE_ISO='(^|[^0-9])((19|20)[0-9]{2}[-_.]?(0[1-9]|1[0-2])[-_.]?(0[1-9]|[12][0-9]|3[01])([T_ .-]?[0-2][0-9][-_:.]?[0-5][0-9]([-_:.]?[0-5][0-9])?)?)($|[^0-9])'
RE_DMY='(^|[^0-9])((0?[1-9]|[12][0-9]|3[01])[-.](0?[1-9]|[12][0-9]|3[01])[-.](19|20)[0-9]{2}([_ -][0-2][0-9][-_:.][0-5][0-9]([-_:.][0-5][0-9])?)?)($|[^0-9])'
RE_EPOCH='(^|[^0-9])(1[0-9]{9})($|[^0-9])'
RE_SEP2='[-_. ][-_. ]'; RE_SEPL='^[-_. ]'; RE_SEPR='[-_. ]$'
strip_stamps() {                        # sets STRIPPED: $1 without date/time stamps and stray separators
  local b=$1 re
  for re in "$RE_ISO" "$RE_DMY" "$RE_EPOCH"; do
    while [[ $b =~ $re ]]; do b=${b/"${BASH_REMATCH[2]}"/}; done
  done
  while [[ $b =~ $RE_SEP2 ]]; do b=${b/"${BASH_REMATCH[0]}"/${BASH_REMATCH[0]:0:1}}; done
  while [[ $b =~ $RE_SEPL ]]; do b=${b:1}; done
  while [[ $b =~ $RE_SEPR ]]; do b=${b:0:${#b}-1}; done
  STRIPPED=$b
}
series_key() {                          # sets KEY_STEM and KEY_EXT
  local b=$1 e
  KEY_EXT=""
  for e in "${EXTS[@]}"; do [[ $b == *."$e" ]] && { KEY_EXT=$e; b=${b%."$e"}; break; }; done
  strip_stamps "$b"
  KEY_STEM=${STRIPPED:-[date-named]}
}
# Folder part of the series key: the path below DIR with dated folder names collapsed to @date,
# so /backup/2026-09-28/accounts and /backup/2026-09-29/accounts are one source, while
# /offsite/serverA and /offsite/serverB (or cPanel weekly/ and monthly/) stay separate.
series_dir() {                          # sets KEY_DIR
  local rel=${1#"$DIR"} c out="" parts=()
  rel=${rel#/}; KEY_DIR=""
  [[ $rel == */* ]] || return 0
  IFS=/ read -r -a parts <<<"${rel%/*}"
  for c in "${parts[@]}"; do
    [[ -n $c ]] || continue
    strip_stamps "$c"; [[ -n $STRIPPED ]] || STRIPPED=@date
    out+="${out:+/}$STRIPPED"
  done
  KEY_DIR=$out
}

declare -A S_IDX=() S_STEM=()
F_TS=(); F_SIZE=(); F_PATH=()
for i in "${!recs[@]}"; do
  IFS=$'\t' read -r ts size path <<<"${recs[i]}"
  F_TS[i]=${ts%.*}; F_SIZE[i]=$size; F_PATH[i]=$path
  series_key "${path##*/}"; series_dir "$path"
  k="${KEY_DIR:+$KEY_DIR/}$KEY_STEM.$KEY_EXT"; S_IDX[$k]+="$i "; S_STEM[$k]=$KEY_STEM
done
KEYS=(); (( ${#S_IDX[@]} )) && mapfile -t KEYS < <(printf '%s\n' "${!S_IDX[@]}" | sort)

section "Backup files"
info "Directory: $DIR   Depth: $DEPTH   Files: ${#recs[@]}   Series: ${#KEYS[@]}   Free space: $(df -hP "$DIR" 2>/dev/null | awk 'NR==2{print $4}')"
if [[ -s $TMPD/find.err ]]; then
  SCAN="INCOMPLETE"; unver "find could not read part of $DIR, files there were NOT checked: $(head -1 "$TMPD/find.err")"
fi
if (( ${#recs[@]} < MINCOUNT || ${#recs[@]} == 0 )); then
  fail "Only ${#recs[@]} backup file(s) found under $DIR (depth $DEPTH), expected at least $(( MINCOUNT > 0 ? MINCOUNT : 1 ))"
else
  last=$(( ${#recs[@]} - 1 ))
  info "Newest file: ${F_PATH[last]} ($(( (now - F_TS[last]) / 3600 ))h old)"
fi

# ---- integrity of one file: sets RES (OK|FAIL|UNVERIFIED) and MSG -----------------------
list_tar() {   # decompress (if needed) and list; pipefail makes any failing stage the status
  if [[ -n $1 ]]; then "$1" -dc "$2" 2>/dev/null | tar -tf - 2>/dev/null; else tar -tf "$2" 2>/dev/null; fi
}
tail_of() {    # last 400 bytes of the (decompressed) file
  if [[ -n $1 ]]; then "$1" -dc "$2" 2>/dev/null | tail -c 400 | tr -d '\000'; else tail -c 400 "$2" | tr -d '\000'; fi
}
verify_file() {
  local f=$1 dec="" kind=raw n t
  case "$f" in
    *.tar.gz|*.tgz) dec=gzip; kind=tar ;;   *.tar.zst) dec=zstd; kind=tar ;;
    *.tar.xz) dec=xz; kind=tar ;;           *.tar.bz2|*.tbz2) dec=bzip2; kind=tar ;;
    *.tar) kind=tar ;;                      *.zip) dec=unzip; kind=zip ;;
    *.sql.gz) dec=gzip; kind=sql ;;         *.sql.zst) dec=zstd; kind=sql ;;
    *.sql) kind=sql ;;
    *.gz) dec=gzip ;; *.zst) dec=zstd ;; *.xz) dec=xz ;; *.bz2) dec=bzip2 ;;
  esac
  if [[ ! -r $f ]]; then RES=UNVERIFIED; MSG="file is not readable by this user, integrity NOT tested"; return; fi
  if [[ -n $dec ]] && ! need "$dec"; then RES=UNVERIFIED; MSG="$dec is not installed, integrity NOT tested"; return; fi
  if [[ $kind == tar ]] && ! need tar; then RES=UNVERIFIED; MSG="tar is not installed, integrity NOT tested"; return; fi
  if [[ $kind == zip ]]; then       # unzip -t checks the CRC of every member
    if unzip -tqq "$f" >/dev/null 2>&1; then RES=OK; MSG="unzip -t OK"; else RES=FAIL; MSG="unzip -t FAILED"; fi
    return
  fi
  if [[ $kind == tar ]] && { (( DEEP )) || [[ -z $dec ]]; }; then
    if ! n=$(list_tar "$dec" "$f" | wc -l); then RES=FAIL; MSG="archive listing FAILED (${dec:+$dec/}tar returned an error)"; return; fi
    if (( n == 0 )); then RES=FAIL; MSG="archive lists 0 entries"; return; fi
    RES=OK; MSG="${dec:+$dec + }tar listing OK, $n entries"; return
  fi
  if [[ $kind == sql ]] && { (( DEEP )) || [[ -z $dec ]]; }; then
    if ! t=$(tail_of "$dec" "$f"); then RES=FAIL; MSG="${dec:-read} FAILED while reading the dump"; return; fi
    if [[ $t == *"Dump completed"* || $t == *"database dump complete"* ]]; then RES=OK; MSG="dump trailer found${dec:+, $dec stream OK}"
    else RES=FAIL; MSG="dump has no 'Dump completed' trailer (truncated, or dumped with --skip-comments)"; fi
    return
  fi
  if "$dec" -t "$f" >/dev/null 2>&1; then RES=OK; MSG="$dec -t OK"; else RES=FAIL; MSG="$dec -t FAILED"; fi
}

# ---- per-series checks ------------------------------------------------------------------
if (( DEEP )); then TEST_LEVEL="deep test: archives listed, SQL dump trailers checked"
else TEST_LEVEL="quick test: compression streams and zip CRCs only, archive contents not listed (use --deep)"; fi
section "Series (age limit ${MAXAGE}h, shrink limit ${SHRINK}%, $( (( DEEP )) && echo deep || echo quick) test)"
S_OK=0; S_FAIL=0; S_UNV=0
declare -A ACCT_TS=() ACCT_PATH=()
for k in "${KEYS[@]}"; do
  read -r -a idx <<<"${S_IDX[$k]}"
  cnt=${#idx[@]}; nw=${idx[cnt-1]}; age=$(( now - F_TS[nw] ))
  nfail=0; nunv=0; detail=""
  # remember the newest file per account-like name for the coverage check
  a=${S_STEM[$k]}
  if [[ $a =~ ^(backup|cpmove)[-_.](.+)$ ]]; then a=${BASH_REMATCH[2]}
  elif [[ $a =~ ^(user|reseller|admin)\.[^.]+\.(.+)$ ]]; then a=${BASH_REMATCH[2]}; fi   # DirectAdmin user.CREATOR.NAME, reseller.CREATOR.NAME, admin.root.NAME
  if [[ -z ${ACCT_TS[$a]:-} ]] || (( F_TS[nw] > ACCT_TS[$a] )); then ACCT_TS[$a]=${F_TS[nw]}; ACCT_PATH[$a]=${F_PATH[nw]}; fi

  if (( age > MAXAGE * 3600 )); then fail "$k: newest file is $(( age / 3600 ))h old (limit ${MAXAGE}h): ${F_PATH[nw]}"; nfail=$((nfail+1)); fi
  if (( cnt > 1 )); then
    pv=${idx[cnt-2]}
    if (( F_SIZE[pv] > 0 )); then
      drop=$(( (F_SIZE[pv] - F_SIZE[nw]) * 100 / F_SIZE[pv] ))
      if (( drop > SHRINK )); then
        fail "$k: newest is ${drop}% smaller than the previous run ($(human "${F_SIZE[pv]}") -> $(human "${F_SIZE[nw]}")): ${F_PATH[nw]}"; nfail=$((nfail+1))
      fi
    fi
    detail="prev $(human "${F_SIZE[pv]}"), "
  fi
  if (( ALL )); then todo=("${idx[@]}"); else todo=("$nw"); fi
  vmsg=""
  for j in "${todo[@]}"; do
    if (( F_SIZE[j] < MINSIZE )); then fail "$k: only ${F_SIZE[j]} bytes: ${F_PATH[j]}"; nfail=$((nfail+1)); continue; fi
    verify_file "${F_PATH[j]}"
    case $RES in
      OK) [[ $j == "$nw" ]] && vmsg=$MSG ;;
      FAIL) fail "$k: $MSG: ${F_PATH[j]}"; nfail=$((nfail+1)) ;;
      *) unver "$k: $MSG: ${F_PATH[j]}"; nunv=$((nunv+1)) ;;
    esac
  done
  if (( nfail )); then S_FAIL=$((S_FAIL+1))
  elif (( nunv )); then S_UNV=$((S_UNV+1))
  else
    S_OK=$((S_OK+1))
    ok "$k: $cnt file(s), newest $(( age / 3600 ))h old, $(human "${F_SIZE[nw]}") (${detail}$vmsg$( (( ALL && cnt > 1 )) && echo ", all $cnt tested"))"
  fi
done

# ---- account coverage -------------------------------------------------------------------
section "Account coverage"
declare -A SEEN=(); EXP=(); src=""
add_exp() { local u; for u in "$@"; do [[ -n $u && -z ${SEEN[$u]:-} ]] && { SEEN[$u]=1; EXP+=("$u"); }; done; }
if (( NO_COV )); then
  info "Account coverage not checked (--archives-only)"; COVERAGE="not checked (--archives-only)"
else
  if [[ -n $ACCT_FILE ]]; then
    while IFS= read -r l || [[ -n $l ]]; do l=${l%%#*}; read -r -a w <<<"$l"; add_exp "${w[@]}"; done <"$ACCT_FILE"
    src="$ACCT_FILE"
  fi
  if [[ -n ${EXPECT// /} ]]; then read -r -a w <<<"$EXPECT"; add_exp "${w[@]}"; src="${src:+$src + }--expect"; fi
  if [[ -z $src && -d /var/cpanel/users ]]; then
    for p in /var/cpanel/users/*; do [[ -f $p ]] || continue; u=${p##*/}; [[ $u == system || $u == .* ]] || add_exp "$u"; done
    src=/var/cpanel/users
  elif [[ -z $src && -d /usr/local/directadmin/data/users ]]; then
    for p in /usr/local/directadmin/data/users/*/; do [[ -d $p ]] || continue; u=${p%/}; add_exp "${u##*/}"; done
    src=/usr/local/directadmin/data/users
  fi
  if (( ${#EXP[@]} == 0 )); then
    msg="account coverage NOT checked: no list of expected accounts${src:+ ($src is empty)} - use --accounts-file or --expect, or --archives-only"
    if (( REQ_COV )); then fail "$msg"; else unver "$msg"; fi
    COVERAGE="UNVERIFIED (no list of expected accounts)"
  else
    info "Expected accounts: ${#EXP[@]} (from $src); each needs a file newer than ${MAXAGE}h"
    covered=0
    for u in "${EXP[@]}"; do
      if [[ -z ${ACCT_TS[$u]:-} ]]; then fail "$u: no backup file at all under $DIR"
      elif (( now - ACCT_TS[$u] > MAXAGE * 3600 )); then fail "$u: missing from the latest run, newest backup is $(( (now - ACCT_TS[$u]) / 3600 ))h old: ${ACCT_PATH[$u]}"
      else covered=$((covered+1)); fi
    done
    (( covered == ${#EXP[@]} )) && ok "All ${#EXP[@]} expected accounts have a fresh backup"
    COVERAGE="$covered/${#EXP[@]} (from $src)"
  fi
fi

# ---- summary ----------------------------------------------------------------------------
if (( QUIET && PROBLEMS == 0 )); then exit 0; fi
section "Summary"
printf 'Series checked: %d   OK: %d   FAIL: %d   UNVERIFIED: %d   Scan: %s\n' \
  "${#KEYS[@]}" "$S_OK" "$S_FAIL" "$S_UNV" "${SCAN:-complete}"
printf 'Test level: %s\nAccount coverage: %s\n' "$TEST_LEVEL" "${COVERAGE:-not checked}"
if (( PROBLEMS )); then printf '%d problem(s).\n' "$PROBLEMS"; exit 1; fi
# Success wording names exactly what was checked; it never claims more.
if (( S_UNV )); then msg="No failures, but $S_UNV series were NOT verified (--allow-unverified)."
else msg="All ${#KEYS[@]} series passed the archive checks (${TEST_LEVEL%%:*})."; fi
case ${COVERAGE:-} in
  [0-9]*) msg+=" Every expected account has a fresh backup." ;;
  *) msg+=" Account coverage was not verified." ;;
esac
echo "$msg"
exit 0
