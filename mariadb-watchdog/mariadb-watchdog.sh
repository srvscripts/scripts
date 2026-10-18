#!/usr/bin/env bash
# MariaDB Watchdog: Restart MariaDB or MySQL Only When It Is Really Hung (v1.0.0) - from srvScripts.com
# Source, docs and updates: https://srvscripts.com/scripts/mariadb-watchdog/
# Copyright (c) 2026 srvScripts.com. MIT licence: if you copy, share or adapt this script, keep this notice and credit srvScripts.com.
#
# mariadb-watchdog.sh
# Checks that MariaDB or MySQL answers a real query (SELECT 1) within a time
# limit. A server that is running but does not answer is "hung". After a
# number of failed checks in a row it saves diagnostics and, only when you
# pass --restart, restarts the service and waits until it answers again.
#
# Report-only by default: without --restart it never restarts or starts anything.
#
# Safety guards before any restart:
#   - the failure must repeat on --fails consecutive runs (default 3)
#   - no restart within --grace seconds of the server starting (crash recovery)
#   - no restart while systemd says the service is starting or stopping
#   - no restart while a backup tool is running (mariadb-backup, xtrabackup,
#     mysqldump, mariadb-dump, mydumper) unless --ignore-backups
#   - at most --max-restarts restarts per --window seconds, then alert only
#   - "Too many connections" is reported, not treated as a hang, unless
#     --restart-on-busy; "Access denied" is a configuration error and never
#     causes a restart
#
# Exit codes: 0 = healthy, 1 = failing but below --fails (or guarded),
#             2 = restart done, needed (report-only) or refused by the limit,
#             3 = usage, environment or credential error, or restart failed.

set -uo pipefail

VERSION="1.0.0"
TIMEOUT=10
FAILS=3
RESTART=0
START_IF_DOWN=0
RESTART_ON_BUSY=0
IGNORE_BACKUPS=0
GRACE=300
MAX_RESTARTS=2
WINDOW=3600
WAIT_UP=300
STOP_TIMEOUT=300
SERVICE=""
RESTART_CMD=""
STATE_DIR="/var/lib/mariadb-watchdog"
LOG_DIR="/var/log/mariadb-watchdog"
DEFAULTS_FILE=""
SOCKET=""
EMAIL=""
WEBHOOK=""
INTERVAL=0
QUIET=0

usage() {
    cat <<'EOF'
Usage: mariadb-watchdog.sh [options]

Checks that MariaDB/MySQL answers SELECT 1 in time. Report-only unless --restart.

Options:
  --restart              Restart the service when it is hung (default: report only)
  --start-if-down        With --restart, also start a server that is not running
  --fails N              Failed checks in a row before acting (default: 3)
  --timeout SEC          Seconds to wait for an answer per check (default: 10)
  --grace SEC            No restart within SEC of the server starting (default: 300)
  --max-restarts N       At most N restarts per --window (default: 2)
  --window SEC           Window for --max-restarts (default: 3600)
  --wait-up SEC          After a restart, wait up to SEC for an answer (default: 300)
  --stop-timeout SEC     A hung server that has not stopped after SEC is killed (default: 300)
  --service NAME         systemd unit (default: auto: mariadb, mysql or mysqld)
  --restart-cmd CMD      Run CMD instead of "systemctl restart <unit>"
  --restart-on-busy      Treat "Too many connections" as a failure too
  --ignore-backups       Allow a restart while a backup tool is running
  --defaults-file FILE   Client option file with the login (passed as --defaults-extra-file)
  --socket PATH          Server socket to connect to
  --state-dir DIR        Failure counter and restart history (default: /var/lib/mariadb-watchdog)
  --log-dir DIR          Diagnostics saved before a restart (default: /var/log/mariadb-watchdog)
  --email ADDR           Mail alerts to ADDR (needs mail or sendmail)
  --webhook URL          POST alerts as JSON to URL (Slack, Discord, Teams-style; needs curl)
  --interval SEC         Keep running and check every SEC seconds (default: run once)
  --quiet                Print only problems and actions
  -h, --help             Show this help
  -V, --version          Show script version

Examples:
  mariadb-watchdog.sh                                  # one check, report only
  mariadb-watchdog.sh --restart --email ops@example.com
  * * * * * root /usr/local/sbin/mariadb-watchdog.sh --restart --quiet   # cron, every minute
  mariadb-watchdog.sh --defaults-file /usr/local/directadmin/conf/my.cnf --restart
EOF
}

die() { echo "Error: $*" >&2; exit 3; }
need_num() {
    if ! [[ "$2" =~ ^[0-9]+$ ]] || [[ "$2" -lt "$3" ]]; then die "$1 needs a whole number >= $3"; fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --restart) RESTART=1; shift ;;
        --start-if-down) START_IF_DOWN=1; shift ;;
        --restart-on-busy) RESTART_ON_BUSY=1; shift ;;
        --ignore-backups) IGNORE_BACKUPS=1; shift ;;
        --fails)        need_num "$1" "${2:-}" 1; FAILS="$2"; shift 2 ;;
        --timeout)      need_num "$1" "${2:-}" 1; TIMEOUT="$2"; shift 2 ;;
        --grace)        need_num "$1" "${2:-}" 0; GRACE="$2"; shift 2 ;;
        --max-restarts) need_num "$1" "${2:-}" 0; MAX_RESTARTS="$2"; shift 2 ;;
        --window)       need_num "$1" "${2:-}" 60; WINDOW="$2"; shift 2 ;;
        --wait-up)      need_num "$1" "${2:-}" 5; WAIT_UP="$2"; shift 2 ;;
        --stop-timeout) need_num "$1" "${2:-}" 10; STOP_TIMEOUT="$2"; shift 2 ;;
        --interval)     need_num "$1" "${2:-}" 10; INTERVAL="$2"; shift 2 ;;
        --service)      [[ "${2:-}" =~ ^[A-Za-z0-9@._-]+$ ]] || die "--service needs a unit name"; SERVICE="$2"; shift 2 ;;
        --restart-cmd)  [[ -n "${2:-}" ]] || die "--restart-cmd needs a command"; RESTART_CMD="$2"; shift 2 ;;
        --defaults-file) [[ -r "${2:-}" ]] || die "--defaults-file needs a readable file"; DEFAULTS_FILE="$2"; shift 2 ;;
        --socket)       [[ -n "${2:-}" ]] || die "--socket needs a path"; SOCKET="$2"; shift 2 ;;
        --state-dir)    [[ -n "${2:-}" ]] || die "--state-dir needs a directory"; STATE_DIR="${2%/}"; shift 2 ;;
        --log-dir)      [[ -n "${2:-}" ]] || die "--log-dir needs a directory"; LOG_DIR="${2%/}"; shift 2 ;;
        --email)        [[ "${2:-}" == *@* ]] || die "--email needs an address"; EMAIL="$2"; shift 2 ;;
        --webhook)      [[ "${2:-}" =~ ^https?:// ]] || die "--webhook needs an http(s) URL"; WEBHOOK="$2"; shift 2 ;;
        --quiet) QUIET=1; shift ;;
        -h|--help) usage; exit 0 ;;
        -V|--version) echo "mariadb-watchdog.sh $VERSION"; exit 0 ;;
        *) usage >&2; die "unknown option: $1" ;;
    esac
done

command -v timeout >/dev/null || die "timeout (GNU coreutils) is required"
CLIENT="$(command -v mariadb || command -v mysql || true)"
[[ -n "$CLIENT" ]] || die "no mariadb or mysql client found"
mkdir -p "$STATE_DIR" "$LOG_DIR" 2>/dev/null || die "cannot create $STATE_DIR or $LOG_DIR (run as root, or use --state-dir/--log-dir)"
chmod 700 "$STATE_DIR" "$LOG_DIR" 2>/dev/null || true
FAILFILE="$STATE_DIR/failures"
HISTFILE="$STATE_DIR/restarts"
LOCKFILE="$STATE_DIR/lock"

CONN=()
[[ -n "$DEFAULTS_FILE" ]] && CONN+=("--defaults-extra-file=$DEFAULTS_FILE")
[[ -n "$SOCKET" ]] && CONN+=("--socket=$SOCKET")

HAVE_SYSTEMD=0
if command -v systemctl >/dev/null && [[ -d /run/systemd/system ]]; then HAVE_SYSTEMD=1; fi
if [[ -z "$SERVICE" && $HAVE_SYSTEMD -eq 1 ]]; then
    for u in mariadb mysql mysqld; do
        if systemctl list-unit-files "$u.service" --no-legend 2>/dev/null | grep -q "^$u\.service"; then SERVICE="$u"; break; fi
    done
fi

say()  { [[ $QUIET -eq 1 ]] || echo "$*"; }
note() { echo "$*"; command -v logger >/dev/null && logger -t mariadb-watchdog -- "$*" 2>/dev/null; return 0; }

alert() {
    local host msg
    host="$(hostname -f 2>/dev/null || hostname)"
    msg="[$host] mariadb-watchdog: $1"
    if [[ -n "$EMAIL" ]]; then
        if command -v mail >/dev/null; then
            printf '%s\n' "$msg" | mail -s "mariadb-watchdog on $(hostname)" "$EMAIL" 2>/dev/null || note "alert mail failed"
        elif command -v sendmail >/dev/null; then
            printf 'To: %s\nSubject: mariadb-watchdog on %s\n\n%s\n' "$EMAIL" "$(hostname)" "$msg" | sendmail -t 2>/dev/null || note "alert mail failed"
        else note "no mail or sendmail command: alert not mailed"; fi
    fi
    if [[ -n "$WEBHOOK" ]]; then
        local j; j="$(printf '%s' "$msg" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\000-\037')"
        curl -fsS -m 15 -H 'Content-Type: application/json' -d "{\"text\":\"$j\",\"content\":\"$j\"}" "$WEBHOOK" >/dev/null 2>&1 || note "webhook alert failed"
    fi
}

server_pid() { pgrep -o -x mariadbd 2>/dev/null || pgrep -o -x mysqld 2>/dev/null || true; }
unit_state() {
    local st=""
    [[ $HAVE_SYSTEMD -eq 1 && -n "$SERVICE" ]] && st="$(systemctl is-active "$SERVICE" 2>/dev/null | head -n1)"
    echo "${st:-unknown}"
}

# probe: sets STATUS (OK|HUNG|BUSY|ERROR|DOWN|DENIED) and DETAIL
probe() {
    local pid out rc err
    pid="$(server_pid)"
    if [[ -z "$pid" ]]; then STATUS="DOWN"; DETAIL="no mariadbd or mysqld process (systemd: $(unit_state))"; return; fi
    err="$(mktemp)"
    out="$(timeout -k 3 "$TIMEOUT" "$CLIENT" "${CONN[@]+"${CONN[@]}"}" --connect-timeout="$TIMEOUT" -N -B -e 'SELECT 1' 2>"$err")"; rc=$?
    local first; first="$(head -n1 "$err")"; rm -f "$err"
    local pst; pst="$(ps -o stat= -p "$pid" 2>/dev/null | tr -d ' ')"
    if [[ $rc -eq 0 && "$out" == "1" ]]; then STATUS="OK"; DETAIL="answered SELECT 1 (pid $pid)"
    elif [[ $rc -eq 124 || $rc -eq 137 ]]; then STATUS="HUNG"; DETAIL="no answer within ${TIMEOUT}s (pid $pid, process state ${pst:-?})"
    elif [[ "$first" == *"1040"* || "$first" == *"Too many connections"* ]]; then STATUS="BUSY"; DETAIL="too many connections (pid $pid): $first"
    elif [[ "$first" == *"1045"* || "$first" == *"Access denied"* ]]; then STATUS="DENIED"; DETAIL="$first"
    else STATUS="ERROR"; DETAIL="query failed, exit $rc (pid $pid, state ${pst:-?}): ${first:-no error text}"; fi
}

backup_running() { pgrep -a -f '(^|/)(mariadb-backup|mariabackup|xtrabackup|innobackupex|mysqldump|mariadb-dump|mydumper)( |$)' 2>/dev/null | head -n1; }

restarts_in_window() {
    local now n=0 t; now="$(date +%s)"
    [[ -f "$HISTFILE" ]] || { echo 0; return; }
    while read -r t; do [[ "$t" =~ ^[0-9]+$ ]] && (( now - t < WINDOW )) && n=$((n + 1)); done < "$HISTFILE"
    echo "$n"
}

diagnostics() {
    local d; d="$LOG_DIR/$(date +%Y%m%d-%H%M%S)"; mkdir -p "$d" && chmod 700 "$d"
    local pid; pid="$(server_pid)"
    {
        echo "status: $STATUS - $DETAIL"; date
        [[ -n "$pid" ]] && ps -o pid,stat,etimes,rss,vsz,pcpu,nlwp,cmd -p "$pid"
        echo; uptime; echo; free -m 2>/dev/null; echo; df -h /var/lib/mysql 2>/dev/null
    } > "$d/system.txt" 2>&1
    timeout -k 2 5 "$CLIENT" "${CONN[@]+"${CONN[@]}"}" --connect-timeout=5 -e 'SHOW FULL PROCESSLIST' > "$d/processlist.txt" 2>&1 || echo "(no answer)" >> "$d/processlist.txt"
    timeout -k 2 5 "$CLIENT" "${CONN[@]+"${CONN[@]}"}" --connect-timeout=5 -e 'SHOW ENGINE INNODB STATUS\G' > "$d/innodb-status.txt" 2>&1 || echo "(no answer)" >> "$d/innodb-status.txt"
    if [[ $HAVE_SYSTEMD -eq 1 && -n "$SERVICE" ]]; then timeout 10 journalctl -u "$SERVICE" -n 200 --no-pager > "$d/journal.txt" 2>&1 || true; fi
    for f in /var/log/mysqld.log /var/log/mariadb/mariadb.log /var/log/mysql/error.log "/var/lib/mysql/$(hostname).err"; do
        [[ -r "$f" ]] && tail -n 200 "$f" > "$d/error-log-$(basename "$f").txt" 2>/dev/null
    done
    { dmesg -T 2>/dev/null || dmesg 2>/dev/null; } | grep -iE 'out of memory|oom|killed process|mysqld|mariadbd' | tail -n 30 > "$d/kernel.txt" 2>/dev/null || true
    echo "$d"
}

do_restart() {
    local what="$1" rc=0
    date +%s >> "$HISTFILE"
    # 9>&-: a daemon started from here must not inherit (and hold) the watchdog lock
    if [[ -n "$RESTART_CMD" ]]; then timeout 900 bash -c "$RESTART_CMD" 9>&-; rc=$?
    elif [[ $HAVE_SYSTEMD -eq 1 && -n "$SERVICE" ]]; then
        if [[ "$what" == "restart" ]]; then
            # A hung server may never finish a clean shutdown, and the unit's own stop timeout can be 15 minutes.
            timeout "$STOP_TIMEOUT" systemctl stop "$SERVICE" 9>&- || true
            if [[ -n "$(server_pid)" ]]; then
                note "server did not stop within ${STOP_TIMEOUT}s: killing it (InnoDB runs crash recovery on the next start)"
                systemctl kill --signal=SIGKILL "$SERVICE" 2>/dev/null || kill -9 "$(server_pid)" 2>/dev/null
                local k=0; while [[ -n "$(server_pid)" && $k -lt 30 ]]; do sleep 1; k=$((k + 1)); done
                [[ -z "$(server_pid)" ]] || { note "server process survived SIGKILL; not starting a second copy"; return 3; }
            fi
        fi
        timeout 900 systemctl start "$SERVICE" 9>&-; rc=$?
    else note "no systemd unit found: use --service or --restart-cmd"; return 3; fi
    [[ $rc -eq 0 ]] || { note "$what command failed with exit $rc"; return 3; }
    local waited=0
    while (( waited < WAIT_UP )); do
        sleep 5; waited=$((waited + 5)); probe
        [[ "$STATUS" == "OK" ]] && { note "server answers again after ${waited}s"; return 0; }
    done
    note "server still not answering ${WAIT_UP}s after $what ($STATUS: $DETAIL)"; return 3
}

check_once() {
    probe
    local fails=0
    [[ -f "$FAILFILE" ]] && read -r fails < "$FAILFILE" 2>/dev/null
    [[ "$fails" =~ ^[0-9]+$ ]] || fails=0

    case "$STATUS" in
        OK)
            if [[ $fails -gt 0 ]]; then note "recovered after $fails failed check(s): $DETAIL"; else say "OK: $DETAIL"; fi
            echo 0 > "$FAILFILE"; return 0 ;;
        DENIED)
            note "login refused, check the credentials (never a reason to restart): $DETAIL"
            echo 0 > "$FAILFILE"; return 3 ;;
        BUSY)
            if [[ $RESTART_ON_BUSY -eq 0 ]]; then
                note "BUSY: $DETAIL (not a hang; raise max_connections or find the client that holds connections)"
                echo 0 > "$FAILFILE"; return 1
            fi ;;
    esac

    fails=$((fails + 1)); echo "$fails" > "$FAILFILE"
    note "$STATUS ($fails/$FAILS): $DETAIL"
    [[ $fails -lt $FAILS ]] && return 1

    local action="restart"
    if [[ "$STATUS" == "DOWN" ]]; then
        if [[ $START_IF_DOWN -eq 0 || $RESTART -eq 0 ]]; then
            note "server is DOWN and was not started (that needs --restart --start-if-down)"
            alert "server is DOWN: $DETAIL (not starting it: needs --restart --start-if-down)"; return 2
        fi
        action="start"
    fi

    local pid up st bk
    pid="$(server_pid)"
    if [[ -n "$pid" ]]; then
        up="$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ')"
        if [[ "$up" =~ ^[0-9]+$ && $up -lt $GRACE ]]; then note "server started ${up}s ago (grace ${GRACE}s): not restarting during startup or crash recovery"; return 1; fi
    fi
    st="$(unit_state)"
    if [[ "$st" == "activating" || "$st" == "deactivating" || "$st" == "reloading" ]]; then note "systemd says $SERVICE is $st: not interfering"; return 1; fi
    if [[ $IGNORE_BACKUPS -eq 0 ]]; then
        bk="$(backup_running)"
        if [[ -n "$bk" ]]; then note "a backup is running ($bk): not restarting (use --ignore-backups to allow)"; alert "$STATUS for $fails checks, restart held because a backup is running: $DETAIL"; return 1; fi
    fi
    local done_n; done_n="$(restarts_in_window)"
    if [[ $done_n -ge $MAX_RESTARTS ]]; then
        note "restart limit reached ($done_n in ${WINDOW}s): alerting only"
        alert "$STATUS for $fails checks and the restart limit is reached ($done_n in ${WINDOW}s): $DETAIL. Needs a person."; return 2
    fi

    local dir; dir="$(diagnostics)"
    if [[ $RESTART -eq 0 ]]; then
        note "would $action $SERVICE now (report-only mode; add --restart). Diagnostics: $dir"
        alert "$STATUS for $fails checks: $DETAIL. Report-only mode, nothing restarted. Diagnostics: $dir"; return 2
    fi
    note "${action}ing ${SERVICE:-the server} after $fails failed checks. Diagnostics: $dir"
    if do_restart "$action"; then
        echo 0 > "$FAILFILE"
        alert "$STATUS for $fails checks ($DETAIL). ${action^} done and the server answers again. Diagnostics: $dir"; return 2
    fi
    alert "$STATUS for $fails checks ($DETAIL). ${action^} did NOT bring it back. Diagnostics: $dir"; return 3
}

exec 9>"$LOCKFILE" || die "cannot open $LOCKFILE"
if ! flock -n 9; then say "another mariadb-watchdog run is still going: skipping"; exit 1; fi

if [[ $INTERVAL -gt 0 ]]; then
    say "mariadb-watchdog $VERSION: checking every ${INTERVAL}s (restart: $([[ $RESTART -eq 1 ]] && echo on || echo off))"
    while true; do check_once; sleep "$INTERVAL"; done
fi
check_once
exit $?
