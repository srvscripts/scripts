#!/usr/bin/env bash
# Process Hog Report: Which Account Is Using the CPU, RAM and Disk (v1.0.0) - from srvScripts.com
# Source, docs and updates: https://srvscripts.com/scripts/process-hog-report/
# Copyright (c) 2026 srvScripts.com. MIT licence: if you copy, share or adapt this script, keep this notice and credit srvScripts.com.
# process-hog-report.sh — which hosting accounts and processes are using CPU, memory and disk right now
# https://srvscripts.com/scripts/process-hog-report/   License: MIT
#
# Read-only. Samples /proc twice (default 5 seconds apart) and reports per account (Linux user)
# and per process: CPU, memory, disk reads and writes, plus load, I/O wait and stuck (D state)
# processes. On cPanel and DirectAdmin it shows each account's main domain.
#   bash process-hog-report.sh                  # 5-second sample, top 10
#   bash process-hog-report.sh --interval=15 --top=20
#   bash process-hog-report.sh --user=site1     # one account only
#   bash process-hog-report.sh --if-load=4      # cron: print only when the 1-min load is >= 4
set -uo pipefail
export LC_ALL=C

VERSION="1.0.0"
INTERVAL=5
TOP=10
ONLY_USER=""
IF_LOAD=""
COLOR=auto

usage() {
  cat <<'EOF'
Usage: process-hog-report.sh [options]

Options:
  --interval=SEC   seconds between the two samples (default 5, 1-300)
  --top=N          lines in each process list (default 10)
  --user=NAME      only this Linux user / hosting account
  --if-load=N      print nothing and exit 0 unless the 1-minute load is >= N
                   (for cron: you only get mail when the server is busy)
  --no-color       plain output even on a terminal
  -V, --version    print the version
  -h, --help       show this help

CPU % is a share of ONE core (a busy 4-core server can show up to 400 %).
Memory is RSS; shared pages are counted once per process, so per-user totals
can be higher than the real use. Disk figures need root. A process that ends
during the sample is not listed; Linux adds its disk I/O to the parent that
collected it (often PID 1, crond or the web server).
EOF
}

for arg in "$@"; do
  case "$arg" in
    --interval=*) INTERVAL="${arg#*=}" ;;
    --top=*)      TOP="${arg#*=}" ;;
    --user=*)     ONLY_USER="${arg#*=}" ;;
    --if-load=*)  IF_LOAD="${arg#*=}" ;;
    --no-color)   COLOR=never ;;
    -V|--version) echo "process-hog-report $VERSION"; exit 0 ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "Unknown option: $arg (see --help)" >&2; exit 2 ;;
  esac
done

case "$INTERVAL" in ''|*[!0-9]*) echo "--interval must be a whole number of seconds" >&2; exit 2 ;; esac
case "$TOP" in ''|*[!0-9]*) echo "--top must be a number" >&2; exit 2 ;; esac
[ "$INTERVAL" -ge 1 ] && [ "$INTERVAL" -le 300 ] || { echo "--interval must be 1-300" >&2; exit 2; }
if [ -n "$IF_LOAD" ]; then
  case "$IF_LOAD" in *[!0-9.]*|'') echo "--if-load must be a number" >&2; exit 2 ;; esac
fi
[ -r /proc/loadavg ] || { echo "This script needs Linux /proc." >&2; exit 1; }

read -r L1 L5 L15 _ < /proc/loadavg
if [ -n "$IF_LOAD" ] && awk -v l="$L1" -v t="$IF_LOAD" 'BEGIN { exit !(l < t) }'; then
  exit 0
fi

if [ "$COLOR" = auto ] && [ -t 1 ]; then
  B=$'\e[1m'; R=$'\e[31m'; Y=$'\e[33m'; G=$'\e[32m'; N=$'\e[0m'
else
  B=""; R=""; Y=""; G=""; N=""
fi
[ "$(id -u)" -eq 0 ] || echo "${Y}Note: not running as root; other users' disk I/O and some command lines are hidden.${N}" >&2

CORES=$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo 1)
HZ=$(getconf CLK_TCK 2>/dev/null || echo 100)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/phr.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

# One line per process: pid uid state cputicks read_bytes write_bytes rss_kb comm
snapshot() {
  local p line rest uid rss rb wb k v _a _b
  for p in /proc/[0-9]*; do
    p=${p#/proc/}
    read -r line 2>/dev/null < "/proc/$p/stat" || continue
    rest=${line##*) }
    comm=${line#*(}; comm=${comm%)*}; comm=${comm// /_}
    set -- $rest
    # rest: 1 state ... 12 utime 13 stime
    local state=$1 ut=${12} st=${13}
    uid=""; rss=0
    while read -r k v _a; do
      case "$k" in
        Uid:) uid=$v ;;
        VmRSS:) rss=$v; break ;;
      esac
    done 2>/dev/null < "/proc/$p/status"
    [ -n "$uid" ] || continue
    rb=0; wb=0
    if [ -r "/proc/$p/io" ]; then
      while read -r k v; do
        case "$k" in
          read_bytes:) rb=$v ;;
          write_bytes:) wb=$v ;;
        esac
      done 2>/dev/null < "/proc/$p/io"
    fi
    echo "$p $uid $state $((ut + st)) $rb $wb $rss $comm"
  done
}

cpu_line() { local a; read -r a < /proc/stat; echo "$a"; }

C0=$(cpu_line); snapshot > "$TMP/a"
sleep "$INTERVAL"
C1=$(cpu_line); snapshot > "$TMP/b"

# Command lines for the final sample (truncated, NUL -> space)
for p in $(awk '{print $1}' "$TMP/b"); do
  if [ -r "/proc/$p/cmdline" ]; then
    c=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | cut -c1-90)
    [ -n "$c" ] && printf '%s\t%s\n' "$p" "$c"
  fi
done > "$TMP/cmd"

getent passwd 2>/dev/null | awk -F: '{print $3, $1}' > "$TMP/users"

# Account -> main domain (cPanel, DirectAdmin)
: > "$TMP/domains"
if [ -r /etc/trueuserdomains ]; then
  awk -F': *' 'NF==2 {print $2, $1}' /etc/trueuserdomains >> "$TMP/domains"
fi
if [ -d /usr/local/directadmin/data/users ]; then
  for f in /usr/local/directadmin/data/users/*/user.conf; do
    [ -r "$f" ] || continue
    u=${f%/user.conf}; u=${u##*/}
    d=$(awk -F= '$1=="domain" {print $2; exit}' "$f")
    [ -n "$d" ] && echo "$u $d"
  done >> "$TMP/domains"
fi

# I/O wait and total CPU over the interval
read -r IOW BUSY < <(awk -v a="$C0" -v b="$C1" 'BEGIN {
  n = split(a, x, " "); split(b, y, " ")
  for (i = 2; i <= n; i++) { d[i] = y[i] - x[i]; tot += d[i] }
  if (tot <= 0) { print 0, 0; exit }
  printf "%.1f %.1f\n", d[6] * 100 / tot, (tot - d[5] - d[6]) * 100 / tot }')

read -r MT MA ST SF < <(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} /^SwapTotal:/{st=$2} /^SwapFree:/{sf=$2} END {print t, a, st, sf}' /proc/meminfo)

HOST=$(hostname 2>/dev/null || cat /proc/sys/kernel/hostname)
echo "${B}Process hog report${N} — $HOST — $(date '+%Y-%m-%d %H:%M:%S %Z') — ${INTERVAL}s sample"
LCOL=$G; awk -v l="$L1" -v c="$CORES" 'BEGIN { exit !(l >= c) }' && LCOL=$R
echo "Load ${LCOL}$L1${N} $L5 $L15 on $CORES cores | CPU busy ${BUSY}% | I/O wait ${IOW}%"
awk -v t="$MT" -v a="$MA" -v st="$ST" -v sf="$SF" 'BEGIN {
  printf "Memory %.0f MB used of %.0f MB (%.0f MB available) | Swap used %.0f MB of %.0f MB\n",
         (t - a) / 1024, t / 1024, a / 1024, (st - sf) / 1024, st / 1024 }'
echo

awk -v hz="$HZ" -v iv="$INTERVAL" -v top="$TOP" -v only="$ONLY_USER" -v B="$B" -v N="$N" -v R="$R" -v Y="$Y" \
    -v tmpdir="$TMP" -v self="$$" '
FILENAME == tmpdir "/users"   { uname[$1] = $2; next }
FILENAME == tmpdir "/domains" { dom[$1] = $2; next }
FILENAME == tmpdir "/cmd"     { i = index($0, "\t"); cmd[substr($0, 1, i - 1)] = substr($0, i + 1); next }
FILENAME == tmpdir "/a"       { t0[$1] = $4; r0[$1] = $5; w0[$1] = $6; next }
FILENAME == tmpdir "/b" {
  pid = $1; if (pid == self) next
  u = ($2 in uname) ? uname[$2] : $2
  if (only != "" && u != only) next
  dt = (pid in t0) ? $4 - t0[pid] : $4      # new process: all of its CPU so far
  if (dt < 0) dt = 0
  rd = (pid in r0) ? $5 - r0[pid] : 0; if (rd < 0) rd = 0
  wr = (pid in w0) ? $6 - w0[pid] : 0; if (wr < 0) wr = 0
  cpu = dt * 100 / (hz * iv)
  P[pid] = 1; PU[pid] = u; PC[pid] = cpu; PR[pid] = $7; PS[pid] = $3; PN[pid] = $8
  PIO[pid] = rd + wr
  UC[u] += cpu; UR[u] += $7; UN[u]++; URD[u] += rd; UWR[u] += wr
  if ($3 == "D") { D[pid] = 1; nd++ }
  if ($3 == "Z") nz++
  next
}
function name(pid) { return (pid in cmd) ? cmd[pid] : "[" PN[pid] "]" }
function hdr(t) { print B t N }
END {
  # Accounts by CPU
  hdr("Accounts / users by CPU (" iv "s average, % of one core)")
  printf "%-16s %7s %9s %6s %9s %9s  %s\n", "USER", "CPU%", "RSS MB", "PROCS", "READ MB", "WRITE MB", "DOMAIN"
  n = 0; for (u in UC) n++
  for (k = 1; k <= n && k <= top; k++) {
    best = ""; for (u in UC) if (!(u in done) && (best == "" || UC[u] > UC[best])) best = u
    done[best] = 1
    printf "%-16s %7.1f %9.1f %6d %9.1f %9.1f  %s\n", substr(best, 1, 16), UC[best], UR[best] / 1024, UN[best], URD[best] / 1048576, UWR[best] / 1048576, (best in dom) ? dom[best] : ""
  }
  print ""

  # Accounts by disk I/O (only when someone did at least 1 MB)
  m = 0; for (u in UC) if (URD[u] + UWR[u] >= 1048576) m++
  if (m > 0) {
    hdr("Accounts / users by disk I/O (" iv "s)")
    printf "%-16s %9s %9s  %s\n", "USER", "READ MB", "WRITE MB", "DOMAIN"
    for (k = 1; k <= m && k <= top; k++) {
      best = ""; for (u in UC) if (!(u in dio) && URD[u] + UWR[u] >= 1048576 && (best == "" || URD[u] + UWR[u] > URD[best] + UWR[best])) best = u
      if (best == "") break
      dio[best] = 1
      printf "%-16s %9.1f %9.1f  %s\n", substr(best, 1, 16), URD[best] / 1048576, UWR[best] / 1048576, (best in dom) ? dom[best] : ""
    }
    print ""
  }

  hdr("Top processes by CPU")
  printf "%7s %-12s %6s %8s %1s  %s\n", "PID", "USER", "CPU%", "RSS MB", "S", "COMMAND"
  for (k = 1; k <= top; k++) {
    best = ""; for (p in P) if (!(p in dc) && (best == "" || PC[p] > PC[best])) best = p
    if (best == "" || PC[best] < 0.1) break
    dc[best] = 1
    printf "%7s %-12s %6.1f %8.1f %1s  %s\n", best, substr(PU[best], 1, 12), PC[best], PR[best] / 1024, PS[best], name(best)
  }
  print ""

  hdr("Top processes by memory (RSS)")
  printf "%7s %-12s %8s %6s  %s\n", "PID", "USER", "RSS MB", "CPU%", "COMMAND"
  for (k = 1; k <= top; k++) {
    best = ""; for (p in P) if (!(p in dm) && (best == "" || PR[p] > PR[best])) best = p
    if (best == "") break
    dm[best] = 1
    printf "%7s %-12s %8.1f %6.1f  %s\n", best, substr(PU[best], 1, 12), PR[best] / 1024, PC[best], name(best)
  }
  print ""

  hdr("Top processes by disk I/O (read + write during the sample)")
  shown = 0
  for (k = 1; k <= top; k++) {
    best = ""; for (p in P) if (!(p in di) && (best == "" || PIO[p] > PIO[best])) best = p
    if (best == "" || PIO[best] < 1048576) break
    if (!shown) { printf "%7s %-12s %9s  %s\n", "PID", "USER", "MB", "COMMAND"; shown = 1 }
    di[best] = 1
    printf "%7s %-12s %9.1f  %s\n", best, substr(PU[best], 1, 12), PIO[best] / 1048576, name(best)
  }
  if (!shown) print "No process read or wrote 1 MB or more."
  print ""

  if (nd > 0) {
    hdr(R "Processes waiting for disk (state D): " nd N)
    for (p in D) printf "%7s %-12s  %s\n", p, substr(PU[p], 1, 12), name(p)
    print ""
  }
  if (nz > 0) print Y "Zombie processes: " nz " (harmless unless the number keeps growing)" N
}' "$TMP/users" "$TMP/domains" "$TMP/cmd" "$TMP/a" "$TMP/b"

# Short hints
if awk -v i="$IOW" 'BEGIN { exit !(i >= 20) }'; then
  echo "${Y}Hint:${N} I/O wait is ${IOW}%: the disk is the bottleneck. Look at the disk I/O list, backups and D-state processes."
fi
if awk -v l="$L1" -v c="$CORES" -v b="$BUSY" 'BEGIN { exit !(l >= c && b < 50) }'; then
  echo "${Y}Hint:${N} load is high but the CPUs are not busy: processes are waiting, usually for disk or NFS."
fi
exit 0
