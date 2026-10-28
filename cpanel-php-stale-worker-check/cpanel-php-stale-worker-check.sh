#!/usr/bin/env bash
# cpanel-php-stale-worker-check.sh — find PHP workers still running a replaced (stale) binary
# https://srvscripts.com/scripts/cpanel-php-stale-worker-check/   License: MIT
#
# After a PHP package update (yum/dnf update, EasyApache, CloudLinux alt-php), the
# RPM and `php -v` show the new version, but a site can keep reporting the old one.
# The usual cause: a long-running LSAPI (lsphp) or PHP-FPM worker is still executing
# the OLD on-disk binary, which Linux keeps mapped in memory after the file was
# replaced — the kernel then shows the path with " (deleted)" after it.
#
# This script is READ-ONLY by default. It lists installed EA-PHP / Alt-PHP versions,
# finds running lsphp and php-fpm workers, inspects /proc/PID/exe, and reports which
# workers run a replaced binary (confirmed stale) versus one whose binary was merely
# updated after the worker started (unverified — worth a closer look). It never
# restarts Apache, LiteSpeed or PHP-FPM, and never kills processes on its own.
#
# This release is AUDIT-ONLY: it never terminates a process, restarts a service, or
# changes anything. --repair does not kill anything either; given one confirmed-stale
# PID it prints the exact recycle command for YOU to run and watch. Automated
# termination is intentionally withheld until this tool has been validated on a
# production cPanel/LiteSpeed server, not just the controlled fixtures used so far.
#
#   bash cpanel-php-stale-worker-check.sh                  # read-only audit
#   bash cpanel-php-stale-worker-check.sh --csv stale.csv  # also write a CSV
#   bash cpanel-php-stale-worker-check.sh --repair-plan     # print recommended fixes (no change)
#   bash cpanel-php-stale-worker-check.sh --repair --pid 12345   # print the exact command for one PID
#
# Exit codes: 0 = no stale workers, 1 = unverified mismatch(es) only (WARN),
#             2 = confirmed stale worker(s) (FAIL), 3 = a check was skipped for
#             lack of evidence/tools, 4 = usage/precondition error.
#
# Testing only: SRVS_ROOT=/dir prefixes every path the script reads (/opt/cpanel,
# /opt/alt, /etc/passwd ...). In that mode the process list is read from
# $SRVS_ROOT/ps.txt, each worker's /proc/PID/exe target from
# $SRVS_ROOT/proc/<pid>/exe (a plain file holding the readlink string), and a
# binary's version from $SRVS_ROOT/binver/<path-with-slashes-as-%>.txt. No root,
# no signals and no service calls are made under SRVS_ROOT.
set -uo pipefail
export LC_ALL=C

VERSION=1.0.0
R=${SRVS_ROOT:-}
TESTMODE=0; [[ -n $R ]] && TESTMODE=1

CSV=""; COLOR=1; MODE=audit; TARGET_PID=""; REDACT=0

usage() {
  cat <<'EOF'
Usage: cpanel-php-stale-worker-check.sh [options]

Finds PHP (lsphp / php-fpm) workers still running a binary that was replaced on
disk — the reason a site can keep reporting the old PHP version after an update.
AUDIT-ONLY: it never kills a process or restarts a service. Run as root for a
complete process view.

Options:
  --csv FILE        also write every worker found to FILE as CSV ("-" = stdout)
                    (CSV holds account names and executable paths — treat it as
                    sensitive server metadata; use --redact before sharing it)
  --repair-plan     print recommended fixes for what was found, then exit (no change)
  --repair --pid N  print the exact recycle command for ONE confirmed-stale PID
                    (prints only; this release does not terminate anything)
  --redact          show "uid:N" instead of account names (safe to paste in tickets)
  --no-color        plain output even on a terminal
  -h, --help        this help
  -V, --version     print version

Exit codes: 0 none, 1 unverified mismatch only, 2 confirmed stale worker(s),
            3 skipped (no evidence/tools), 4 usage/precondition.
EOF
}

while (( $# )); do
  case $1 in
    --csv)         CSV=${2:-}; [[ -n $CSV && ( $CSV != -* || $CSV == - ) ]] || { echo "--csv needs a file name" >&2; exit 4; }; shift ;;
    --csv=*)       CSV=${1#*=} ;;
    --repair-plan) MODE=plan ;;
    --repair)      MODE=repair ;;
    --pid)         TARGET_PID=${2:-}; shift ;;
    --pid=*)       TARGET_PID=${1#*=} ;;
    --redact)      REDACT=1 ;;
    --no-color)    COLOR=0 ;;
    -h|--help)     usage; exit 0 ;;
    -V|--version)  echo "$VERSION"; exit 0 ;;
    *) echo "Unknown option: $1 (see --help)" >&2; exit 4 ;;
  esac
  shift
done

if (( COLOR )) && [[ -t 1 ]]; then
  C_OK=$'\e[32m'; C_WARN=$'\e[33m'; C_FAIL=$'\e[31m'; C_INFO=$'\e[36m'; C_OFF=$'\e[0m'
else
  C_OK=; C_WARN=; C_FAIL=; C_INFO=; C_OFF=
fi
hr() { printf '\n== %s ==\n' "$*"; }
st() { # st STATUS message
  local c=
  case $1 in OK) c=$C_OK ;; WARN) c=$C_WARN ;; FAIL) c=$C_FAIL ;; INFO) c=$C_INFO ;; esac
  printf '%s%-4s%s %s\n' "$c" "$1" "$C_OFF" "$2"
}

# ---- precondition checks ----------------------------------------------------
[[ -d $R/opt/cpanel || -d $R/usr/local/cpanel || $TESTMODE -eq 1 ]] || {
  echo "cPanel not found ($R/usr/local/cpanel is missing). This script is for cPanel/WHM servers." >&2; exit 4; }
if (( ! TESTMODE )) && [[ $EUID -ne 0 ]]; then
  echo "Run as root — a non-root user cannot see other accounts' PHP workers or /proc/PID/exe." >&2; exit 4
fi

# ---- fixture-aware primitives ----------------------------------------------
# A process snapshot: pid<TAB>ppid<TAB>uid<TAB>etimes<TAB>comm<TAB>args
ps_snapshot() {
  if (( TESTMODE )); then
    cat "$R/ps.txt" 2>/dev/null
  else
    # etimes = seconds since the process started; comm = short name; args = full cmdline
    ps -eo pid=,ppid=,uid=,etimes=,comm=,args= 2>/dev/null \
      | awk '{ pid=$1; ppid=$2; uid=$3; et=$4; comm=$5; $1=$2=$3=$4=$5=""; sub(/^ +/,""); printf "%s\t%s\t%s\t%s\t%s\t%s\n", pid, ppid, uid, et, comm, $0 }'
  fi
}

# Raw target of /proc/PID/exe, including a trailing " (deleted)" when the kernel adds it.
read_exe() {
  local pid=$1
  if (( TESTMODE )); then
    cat "$R/proc/$pid/exe" 2>/dev/null
  else
    readlink "/proc/$pid/exe" 2>/dev/null
  fi
}

# Major.minor from a PHP path (/opt/cpanel/ea-php83/... -> 8.3, /opt/alt/php82/... -> 8.2).
# Parsed from the path on purpose: the script never executes a discovered binary.
php_ver_from_path() {
  local n
  n=$(sed -n 's#.*/ea-php\([0-9][0-9]\)/.*#\1#p; s#.*/opt/alt/php\([0-9][0-9]\)/.*#\1#p' <<<"$1" | head -1)
  [[ -n $n ]] || { echo ""; return; }
  echo "${n:0:1}.${n:1}"
}

# Real account name for a UID ("uid:N" only when it genuinely cannot be resolved).
# --redact is applied at display time, not here, so repair can still resolve the owner.
uid_name() {
  local uid=$1 name=""
  if (( TESTMODE )); then
    name=$(awk -F: -v u="$uid" '$3==u{print $1; exit}' "$R/etc/passwd" 2>/dev/null)
  else
    name=$(getent passwd "$uid" 2>/dev/null | cut -d: -f1)
  fi
  echo "${name:-uid:$uid}"
}

# mtime (epoch) of an on-disk file, or "" when absent.
file_mtime() {
  local f=$1
  (( TESTMODE )) && f="$R$f"
  [[ -e $f ]] || { echo ""; return; }
  stat -c %Y "$f" 2>/dev/null
}

now_epoch() {
  if (( TESTMODE )) && [[ -f $R/now.txt ]]; then cat "$R/now.txt"; else date +%s; fi
}

human_age() { # seconds -> "2d 3h", "4h 10m", "7m", "<1m"
  local s=$1 d h m
  [[ $s =~ ^[0-9]+$ ]] || { echo "?"; return; }
  d=$(( s/86400 )); h=$(( (s%86400)/3600 )); m=$(( (s%3600)/60 ))
  if   (( d > 0 )); then echo "${d}d ${h}h"
  elif (( h > 0 )); then echo "${h}h ${m}m"
  elif (( m > 0 )); then echo "${m}m"
  else echo "<1m"; fi
}

# ---- 1. installed PHP binaries ---------------------------------------------
hr "Installed PHP versions"
installed=""
while IFS= read -r b; do
  [[ -n $b ]] || continue
  rp=${b#"$R"}
  v=$(php_ver_from_path "$rp")
  tag=$(sed -E 's#.*/opt/cpanel/(ea-php[0-9]+)/.*#\1#; t; s#.*/opt/alt/(php[0-9]+)/.*#alt-\1#; t; s#.*#?#' <<<"$rp")
  installed+="$tag=${v:-?}"$'\n'
done < <(find "$R/opt/cpanel" "$R/opt/alt" -maxdepth 5 -type f \( -name lsphp -o -name php \) \
            \( -path '*/ea-php*/*' -o -path '*/alt/php*/*' \) 2>/dev/null | sort -u)
installed=$(printf '%s' "$installed" | sort -u | grep -v '^$' | tr '\n' ' ')
if [[ -n $installed ]]; then
  echo "On disk: $installed"
else
  st INFO "no EA-PHP / Alt-PHP binaries found under /opt (unusual on a cPanel box)"
fi

# ---- 2. running workers + /proc inspection ---------------------------------
hr "PHP workers"
# Collect worker rows: pid ppid uid etimes comm exe deleted(0/1) state
workers=""
while IFS=$'\t' read -r pid ppid uid et comm args; do
  [[ $comm == lsphp || $comm == php-fpm* || $args == *"/lsphp"* || $args == *"php-fpm"* ]] || continue
  # the FPM master (ppid 1, "master process" in args) is managed, not a stale leaf
  if   [[ $args == *"master process"* ]]; then kind="php-fpm(master)"
  elif [[ $comm == php-fpm* ]];           then kind="php-fpm"
  else                                         kind="lsphp"; fi
  exe=$(read_exe "$pid")
  deleted=0; [[ $exe == *" (deleted)" ]] && deleted=1
  exepath=${exe% (deleted)}
  [[ -z $exepath ]] && exepath="-"   # sentinel: a tab IFS in read() would otherwise drop an empty field
  workers+="$pid"$'\t'"$ppid"$'\t'"$uid"$'\t'"$et"$'\t'"$kind"$'\t'"$exepath"$'\t'"$deleted"$'\n'
done < <(ps_snapshot)
workers=${workers%$'\n'}

if [[ -z $workers ]]; then
  st INFO "no lsphp or php-fpm workers are running right now"
  echo
  st OK "nothing to recycle"
  exit 0
fi

now=$(now_epoch)
fail=0; warn=0; unknown=0; master_stale=0
confirmed_pids=""   # leaf workers on a "(deleted)" binary — the only PIDs --repair will act on
mismatch_pids=""    # leaf workers whose binary mtime is newer than their start, NOT deleted (unverified)
declare -A ROW_KIND ROW_ACCT ROW_DACCT ROW_EXE ROW_AGE ROW_VERDICT

printf '%-8s %-15s %-16s %-9s %-10s %s\n' PID HANDLER ACCOUNT AGE VERDICT EXECUTABLE
while IFS=$'\t' read -r pid ppid uid et kind exepath deleted; do
  [[ -n $pid ]] || continue
  acct=$(uid_name "$uid")
  dacct=$acct; (( REDACT )) && dacct="uid:$uid"
  age=$(human_age "$et")
  verdict="ok"
  if [[ $kind == "php-fpm(master)" ]]; then
    verdict="master"                          # the FPM master is managed; a per-worker kill won't help it
    (( deleted )) && { verdict="master*"; master_stale=$(( master_stale+1 )); }
  elif (( deleted )); then
    verdict="STALE"; fail=$(( fail+1 )); confirmed_pids+="$pid "
  elif [[ $exepath == "-" ]]; then
    verdict="unknown"; unknown=$(( unknown+1 ))   # could not read /proc/PID/exe (perms/race)
  elif [[ $et =~ ^[0-9]+$ ]]; then
    # not flagged deleted: was the on-disk binary replaced AFTER this worker started?
    # (guard $et is numeric BEFORE the arithmetic, or set -u would abort on odd input)
    bmt=$(file_mtime "$exepath")
    if [[ -n $bmt && $bmt -gt $(( now - et )) ]]; then
      verdict="mismatch?"; warn=$(( warn+1 )); mismatch_pids+="$pid "
    fi
  fi
  disp_exe=$exepath; [[ $exepath == "-" ]] && disp_exe="(unreadable)"
  (( deleted )) && disp_exe="$disp_exe (deleted)"
  ROW_KIND[$pid]=$kind; ROW_ACCT[$pid]=$acct; ROW_DACCT[$pid]=$dacct
  ROW_EXE[$pid]=$disp_exe
  ROW_AGE[$pid]=$age; ROW_VERDICT[$pid]=$verdict
  printf '%-8s %-15s %-16s %-9s %-10s %s\n' "$pid" "$kind" "$dacct" "$age" "$verdict" "$disp_exe"
done <<<"$workers"

hr "Result"
if (( fail > 0 )); then
  st FAIL "$fail worker(s) running a replaced binary (marked \"(deleted)\"): a new request to that app keeps the old PHP until the worker is recycled"
fi
if (( warn > 0 )); then
  st WARN "$warn worker(s) whose on-disk binary was updated after they started but is not flagged deleted — verify the served version before acting (could be an in-place rebuild, not a version change)"
fi
if (( master_stale > 0 )); then
  st FAIL "$master_stale php-fpm master(s) running a replaced binary: every forked worker in that pool keeps serving the old PHP. Recycle the FPM service to pick up the update (e.g. systemctl restart ea-phpNN-php-fpm); a per-worker kill will NOT help a master."
fi
if (( unknown > 0 )); then
  st INFO "$unknown worker(s) whose /proc/PID/exe could not be read (permissions or the process exited) — re-run as root"
fi
if (( fail == 0 && warn == 0 && master_stale == 0 )); then
  st OK "no worker is running a stale binary"
fi
echo
echo "Note: a \"(deleted)\" executable proves only that the running file was replaced on disk — usually a PHP update, but also e.g. an in-place package rebuild that did not change the version. It does not by itself prove the worker is running an OLDER release. Confirm the version actually served with an uncached phpinfo on the site (a response header like X-Powered-By may be disabled, stripped or cached) before assuming it is wrong."

# ---- CSV --------------------------------------------------------------------
if [[ -n $CSV ]]; then
  csv_out() {
    echo '"pid","handler","account","age","verdict","executable"'
    for pid in "${!ROW_KIND[@]}"; do
      printf '"%s","%s","%s","%s","%s","%s"\n' "$pid" "${ROW_KIND[$pid]}" "${ROW_DACCT[$pid]}" "${ROW_AGE[$pid]}" "${ROW_VERDICT[$pid]}" "${ROW_EXE[$pid]}"
    done | sort -t, -k5,5
  }
  if [[ $CSV == - ]]; then echo; csv_out
  elif csv_out > "$CSV"; then st INFO "CSV written to $CSV — it contains account names and executable paths; treat it as sensitive server metadata and use --redact before sharing it"
  else echo "Could not write $CSV" >&2; fi
fi

# ---- remediation (plan / repair) -------------------------------------------
remediation_text() {
  cat <<EOF

Remediation is handler-specific — match it to the row's HANDLER:

  * A stale php-fpm MASTER (verdict master*): restart that version's FPM SERVICE.
    A per-worker kill will NOT help — the pool's workers are forked from the master.
         systemctl restart ea-phpNN-php-fpm      # e.g. ea-php83-php-fpm

  * A stale lsphp / php-fpm POOL worker (verdict STALE): either recycle just that
    worker, or restart the web server if several are affected.
      - one worker (least disruptive):
            kill -TERM <PID>
        SIGTERM is not guaranteed graceful for every handler configuration.
        See: https://srvscripts.com/guides/litespeed-stuck-lsphp-processes/
      - web server (recycles its workers in one step, briefly disrupts every site;
        use a maintenance window). Note this recycles the server's OWN workers; an
        independently managed PHP-FPM service is restarted separately (above):
            systemctl restart httpd        # Apache
            # or: systemctl restart lsws   # LiteSpeed Enterprise

  Do NOT reboot the server just to refresh PHP workers, and do NOT run
  "killall lsphp" on a shared host — that drops every account's in-flight requests.
  Afterwards, confirm the served version with an uncached phpinfo on the affected site.
EOF
}

if [[ $MODE == plan ]]; then
  hr "Repair plan (no changes made)"
  cp=${confirmed_pids% }; mp=${mismatch_pids% }
  if [[ -z $cp && -z $mp ]]; then
    st OK "nothing to recycle"
  else
    [[ -n $cp ]] && echo "Confirmed-stale leaf worker PID(s) (--repair --pid N prints the exact command for one): $cp"
    [[ -n $mp ]] && echo "Unverified mismatch PID(s) (confirm the served version first; not eligible for --repair): $mp"
    remediation_text
  fi
  (( fail > 0 || master_stale > 0 )) && exit 2; (( warn > 0 )) && exit 1; exit 0
fi

if [[ $MODE == repair ]]; then
  hr "Repair — advisory only (this release does not terminate anything)"
  [[ -n $TARGET_PID ]] || { echo "--repair needs --pid N (the confirmed-stale worker to advise on)." >&2; exit 4; }
  [[ $TARGET_PID =~ ^[0-9]+$ ]] || { echo "--pid must be a number." >&2; exit 4; }
  # Only a confirmed-stale leaf worker ("(deleted)" exe) qualifies — never an unverified
  # mtime mismatch and never a master (a stale master needs its FPM service restarted).
  case " ${confirmed_pids% } " in
    *" $TARGET_PID "*) : ;;
    *) echo "PID $TARGET_PID is not a confirmed-stale leaf worker in this scan (only workers whose executable is marked \"(deleted)\" qualify). Re-run the audit." >&2; exit 4 ;;
  esac
  acct=${ROW_ACCT[$TARGET_PID]:-unknown}
  echo "This build is AUDIT-ONLY: it has been checked against controlled fixtures but not yet"
  echo "on a production cPanel/LiteSpeed server, so it does NOT terminate the process for you."
  echo "For the confirmed-stale worker PID $TARGET_PID (${ROW_KIND[$TARGET_PID]}, account $acct), run and watch:"
  echo
  echo "    kill -TERM $TARGET_PID"
  echo
  echo "Before you run it, re-check that the PID is still the same stale worker (a PID can be"
  echo "reused between this scan and your command):"
  echo "    readlink /proc/$TARGET_PID/exe      # must still end in ' (deleted)'"
  echo "    cat /proc/$TARGET_PID/comm          # must still be lsphp or php-fpm"
  echo
  echo "SIGTERM is not guaranteed graceful for every handler; it may cut off the request in flight."
  echo "LiteSpeed/Apache (or the PHP-FPM master) then starts a fresh worker from the current on-disk"
  echo "binary on the next request. Do NOT 'killall lsphp' on a shared host. Afterwards, confirm the"
  echo "served version with an UNCACHED phpinfo on the affected site (a response header such as"
  echo "X-Powered-By may be disabled, stripped or cached, so it is not a reliable check)."
  exit 0
fi

# ---- default audit exit codes ----------------------------------------------
(( fail > 0 || master_stale > 0 )) && exit 2
(( warn > 0 )) && exit 1
(( unknown > 0 )) && exit 3
exit 0
