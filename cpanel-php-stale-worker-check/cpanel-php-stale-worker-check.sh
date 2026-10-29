#!/usr/bin/env bash
# cPanel PHP Stale-Worker Check (v1.1.1) - from srvScripts.com
# Source, docs and updates: https://srvscripts.com/scripts/cpanel-php-stale-worker-check/
# Copyright (c) 2026 srvScripts.com. MIT licence: if you copy, share or adapt this script, keep this notice and credit srvScripts.com.
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
# PID it prints the exact recycle command for YOU to run and watch. The normal-state
# audit has been validated on a live cPanel server (EA-PHP + CloudLinux alt-php, many
# PHP-FPM masters); stale-worker DETECTION is validated through controlled fixtures.
# Automated termination stays out of this release by design, so recycling a worker is
# always a deliberate step you take and watch.
#
#   bash cpanel-php-stale-worker-check.sh                  # read-only audit
#   bash cpanel-php-stale-worker-check.sh --csv stale.csv  # also write a CSV
#   bash cpanel-php-stale-worker-check.sh --repair-plan     # print recommended fixes (no change)
#   bash cpanel-php-stale-worker-check.sh --repair --pid 12345   # print the exact command for one PID
#   bash cpanel-php-stale-worker-check.sh --pkg                  # + read-only package/repo diagnostics
#   bash cpanel-php-stale-worker-check.sh --pkg --check-updates  # + query dnf for available EA-PHP updates
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
# no signals and no service calls are made under SRVS_ROOT. The --pkg diagnostics
# read fixtures too: installed packages from $SRVS_ROOT/rpm-ea-php.txt
# (EPOCH<TAB>NAME<TAB>VERSION<TAB>RELEASE<TAB>VENDOR per line), repo files from
# $SRVS_ROOT/etc/yum.repos.d/*.repo, dnf exclusions from $SRVS_ROOT/etc/dnf/dnf.conf
# and $SRVS_ROOT/etc/yum.conf, available updates from $SRVS_ROOT/dnf-checkupdate.txt
# (and dnf-checkupdate-hardened.txt); an empty $SRVS_ROOT/dnf-nonet file simulates no
# network. No dnf or rpm is executed under SRVS_ROOT.
set -uo pipefail
export LC_ALL=C

VERSION=1.1.1
R=${SRVS_ROOT:-}
TESTMODE=0; [[ -n $R ]] && TESTMODE=1

CSV=""; COLOR=1; MODE=audit; TARGET_PID=""; REDACT=0; PKG=0; CHECKUPD=0

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
  --redact          show "uid:N" instead of account names in all output (executable
                    paths are still shown — review output before sharing)
  --pkg             also run read-only package/repository diagnostics: installed
                    EA-PHP branches and versions, RPM epoch, the Imunify360 hardened
                    repo and its enabled state, and dnf exclusions. Reads only; it
                    changes no installed package, repo config or service (a --csv
                    export is the one file it writes).
  --check-updates   with --pkg, also query dnf for available EA-PHP updates (needs
                    network). Read-only: it runs "dnf check-update" (which may refresh
                    dnf's own cache/logs) and never installs, upgrades or enables a repo.
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
    --csv=*)       CSV=${1#*=}; [[ -n $CSV && ( $CSV != -* || $CSV == - ) ]] || { echo "--csv needs a file name" >&2; exit 4; } ;;
    --repair-plan) MODE=plan ;;
    --repair)      MODE=repair ;;
    --pid)         TARGET_PID=${2:-}; shift ;;
    --pid=*)       TARGET_PID=${1#*=} ;;
    --redact)      REDACT=1 ;;
    --pkg)         PKG=1 ;;
    --check-updates) PKG=1; CHECKUPD=1 ;;
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
    [[ -f $R/ps.txt ]] || return 3        # a missing fixture is a failed snapshot, not "no workers"
    cat "$R/ps.txt"
  else
    command -v ps >/dev/null 2>&1 || return 3
    # etimes = seconds since the process started; comm = short name; args = full cmdline
    ps -eo pid=,ppid=,uid=,etimes=,comm=,args= 2>/dev/null \
      | awk '{ pid=$1; ppid=$2; uid=$3; et=$4; comm=$5; $1=$2=$3=$4=$5=""; sub(/^ +/,""); printf "%s\t%s\t%s\t%s\t%s\t%s\n", pid, ppid, uid, et, comm, $0 }'
    local pstat=( "${PIPESTATUS[@]}" )    # capture BOTH stages before the next command clobbers PIPESTATUS
    (( pstat[0] != 0 )) && return "${pstat[0]}"   # ps failed
    (( ${pstat[1]:-0} != 0 )) && return 3         # awk formatter failed -> incomplete, never a silent empty list
    return 0
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

# ---- package / repository diagnostics (opt-in with --pkg) -------------------
# Read-only: it inspects rpm metadata, repo files and dnf config, and (only with
# --check-updates) runs `dnf check-update`, which may refresh dnf's own cache/logs
# but changes no installed package, repo configuration or service. It never enables
# a repo, installs or upgrades; it prints the recommended commands for YOU to run.
pkg_list_eaphp() {            # EPOCH<TAB>NAME<TAB>VERSION<TAB>RELEASE<TAB>VENDOR
  if (( TESTMODE )); then
    [[ -f $R/rpm-ea-php.txt ]] || return 3
    cat "$R/rpm-ea-php.txt"
  else
    command -v rpm >/dev/null 2>&1 || return 3
    rpm -qa --qf '%{EPOCH}\t%{NAME}\t%{VERSION}\t%{RELEASE}\t%{VENDOR}\n' 'ea-php*' 2>/dev/null
  fi
}
pkg_repo_cat() {              # all repo files concatenated (fixture-aware)
  local d f
  if (( TESTMODE )); then d="$R/etc/yum.repos.d"; else d=/etc/yum.repos.d; fi
  for f in "$d"/*.repo; do [[ -e $f ]] || continue; printf '## %s\n' "$f"; cat "$f"; done 2>/dev/null
}
pkg_exclude_lines() {         # any exclude= lines in dnf/yum config or repo files
  local files f
  if (( TESTMODE )); then files=( "$R/etc/dnf/dnf.conf" "$R/etc/yum.conf" )
  else files=( /etc/dnf/dnf.conf /etc/yum.conf ); fi
  { for f in "${files[@]}"; do [[ -f $f ]] && grep -HnE '^[[:space:]]*(exclude|excludepkgs)[[:space:]]*=' "$f"; done
    pkg_repo_cat | grep -nE '^[[:space:]]*(exclude|excludepkgs)[[:space:]]*='; } 2>/dev/null
}
dnf_checkupdate() {           # $1 = repo-id to --enablerepo (or ""); prints lines
  if (( TESTMODE )); then     # rc: 0/100 ok, 3 no dnf, 7 no network, other skip
    [[ -f $R/dnf-nonet ]] && return 7
    if [[ -n $1 ]]; then [[ -f $R/dnf-checkupdate-hardened.txt ]] && cat "$R/dnf-checkupdate-hardened.txt"
    else [[ -f $R/dnf-checkupdate.txt ]] && cat "$R/dnf-checkupdate.txt"; fi
    return 0
  fi
  command -v dnf >/dev/null 2>&1 || return 3
  # DNF_DISABLE_ALIASES stops a custom dnf alias (e.g. check-update aliased to an
  # upgrade) from turning this read-only query into a package transaction.
  if [[ -n $1 ]]; then DNF_DISABLE_ALIASES=1 timeout 90 dnf --enablerepo="$1" -q check-update 'ea-php*' 2>/dev/null
  else DNF_DISABLE_ALIASES=1 timeout 90 dnf -q check-update 'ea-php*' 2>/dev/null; fi
}

pkg_hard_block() {            # stdin = repo text; $1 = exact section header "[id]" to match,
  awk -v want="$1" '          # or "" to match any section id containing "hardened". Prints ID=.. then enabled=..
    /^\[/{
      inblk=0; hdr=$0
      if (want != "") { if (hdr==want) inblk=1 }
      else if (hdr ~ /[Hh]ardened/) inblk=1
      if (inblk) { id=hdr; gsub(/[][]/,"",id); print "ID="id }
      next
    }
    inblk && /^[[:space:]]*enabled[[:space:]]*=/{ l=$0; gsub(/[[:space:]]/,"",l); print l; }
  '
}

pkg_diag() {
  hr "Package & repository diagnostics (read-only)"
  local list lrc; list=$(pkg_list_eaphp); lrc=$?
  if (( lrc != 0 )) || [[ -z $list ]]; then
    st INFO "no EA-PHP RPM data (rpm unavailable, or no ea-php* packages installed) — nothing to diagnose"
    return
  fi

  echo "Installed EA-PHP runtime packages (epoch:version-release):"
  local hardened_installed=0 has_epoch1=0 ep name ver rel vendor e flag any=0
  while IFS=$'\t' read -r ep name ver rel vendor; do
    [[ -n $name ]] || continue
    [[ $name =~ ^ea-php[0-9]+-php$ ]] || continue      # the per-branch runtime package
    e=$ep; { [[ $ep == "(none)" ]] || [[ -z $ep ]]; } && e=0
    [[ $e =~ ^[0-9]+$ ]] || e=0        # defensive: any non-numeric epoch -> 0
    (( e >= 1 )) && has_epoch1=1       # a real epoch>=1 is tracked apart from vendor/release provenance
    flag=""
    if (( e >= 1 )) || [[ $rel == *cloudlinux* ]] || [[ $vendor == *CloudLinux* ]]; then
      flag=" [hardened]"; hardened_installed=1
    fi
    printf '  %-18s %s:%s-%s%s\n' "$name" "$e" "$ver" "$rel" "$flag"; any=1
  done <<<"$list"
  (( any )) || echo "  (no ea-phpNN-php runtime package matched; only components installed)"

  hr "Imunify360 hardened PHP repository"
  local repos hard_block enabled_raw enabled_lc rid hard_disabled=0
  repos=$(pkg_repo_cat)
  # Prefer the exact imunify360-ea-php-hardened repo; only fall back to any *hardened*
  # id when the real one is absent, so a "…-hardened-beta" never gets selected over it.
  hard_block=$(pkg_hard_block '[imunify360-ea-php-hardened]' <<<"$repos")
  [[ -z $hard_block ]] && hard_block=$(pkg_hard_block '' <<<"$repos")
  rid=$(sed -n 's/^ID=//p' <<<"$hard_block" | head -1)
  if [[ -z $hard_block ]]; then
    if (( hardened_installed )); then
      st WARN "hardened EA-PHP packages are installed, but no *hardened* repo file was found — their updates may be unavailable until the repo is restored"
    else
      st INFO "no Imunify360 hardened PHP repository configured (standard EA4 packaging)"
    fi
  else
    enabled_raw=$(sed -n 's/^enabled=//p' <<<"$hard_block" | head -1)
    enabled_lc=$(printf '%s' "$enabled_raw" | tr 'A-Z' 'a-z')
    case $enabled_lc in
      0|false|no|off) hard_disabled=1
        st WARN "hardened repo '$rid' is present but DISABLED (enabled=$enabled_raw) — the hardened PHP updates it ships are hidden from a normal 'dnf update'" ;;
      1|true|yes|on)
        st OK "hardened repo '$rid' is present and enabled" ;;
      *)
        st INFO "hardened repo '$rid' is present but its enabled= value ('$enabled_raw') is not a recognised boolean — check it by hand" ;;
    esac
  fi

  if (( has_epoch1 )); then
    hr "RPM epoch"
    echo "At least one installed hardened EA-PHP package carries RPM epoch >= 1. Epoch is"
    echo "compared BEFORE version, so a standard EA4 package (epoch 0) can never replace it,"
    echo "even with a higher version number -- which is why 'dnf update' can report nothing"
    echo "while a newer hardened build exists. Update from the hardened repo (see below); do"
    echo "NOT force a switch to standard EA4 with --allowerasing: that strips the hardening"
    echo "and can break dependencies."
  elif (( hardened_installed )); then
    hr "RPM epoch"
    echo "Some installed EA-PHP packages look hardened by vendor/release (CloudLinux) but"
    echo "show epoch 0. The epoch-before-version blocking below applies only when an"
    echo "installed package's epoch is actually >= 1 -- verify the real epoch and package"
    echo "source before changing anything."
  fi

  local ex; ex=$(pkg_exclude_lines)
  if [[ -n $ex ]]; then
    hr "Package exclusions (can silently block PHP updates)"
    echo "$ex"
    st INFO "an 'exclude=' covering ea-php* makes dnf skip those updates without a word — review the lines above"
  fi

  if (( CHECKUPD )); then
    hr "Available EA-PHP updates (dnf check-update — read-only)"
    local out rc
    out=$(dnf_checkupdate ""); rc=$?
    case $rc in
      3) st INFO "dnf not available — cannot query updates" ;;
      7) st INFO "no network / repo metadata unreachable — update query skipped" ;;
      0|100)
        if [[ -n $out ]]; then
          echo "From the currently ENABLED repos:"; echo "$out"
        else
          st OK "no EA-PHP updates from the currently enabled repos"
          if (( hardened_installed )) && [[ -n $rid ]] && (( hard_disabled )); then
            local ho hrc; ho=$(dnf_checkupdate "$rid"); hrc=$?
            if { [[ $hrc == 0 ]] || [[ $hrc == 100 ]]; } && [[ -n $ho ]]; then
              hr "Hidden by the disabled hardened repo"
              echo "With --enablerepo=$rid, dnf WOULD offer:"; echo "$ho"
            elif (( hrc == 7 )); then
              st INFO "could not query the disabled hardened repo '$rid' (no network) — enable it and re-check"
            elif (( hrc != 0 && hrc != 100 )); then
              st INFO "could not query the disabled hardened repo '$rid' (dnf exit $hrc) — check it by hand"
            fi
          fi
        fi ;;
      *) st INFO "dnf check-update did not complete (exit $rc) — skipped" ;;
    esac
  fi

  hr "Recommended update workflow (run and watch these yourself)"
  local hid; hid=$rid; [[ -n $hid ]] || hid=imunify360-ea-php-hardened
  if (( hardened_installed )); then
    printf '%s\n' \
      "Preview first (changes nothing):" \
      "    dnf --enablerepo=$hid upgrade --assumeno 'ea-php*'" \
      "If the transaction looks right, apply it:" \
      "    dnf --enablerepo=$hid upgrade 'ea-php*'" \
      "The 'ea-php*' wildcard updates eligible INSTALLED EA-PHP packages and components;" \
      "it does not install new PHP major versions. Keep the hardened packaging — do not" \
      "switch to standard EA4 just to force a higher number."
  else
    printf '%s\n' \
      "Preview first (changes nothing):" \
      "    dnf upgrade --assumeno 'ea-php*'" \
      "If the transaction looks right, apply it:" \
      "    dnf upgrade 'ea-php*'" \
      "The 'ea-php*' wildcard updates eligible INSTALLED EA-PHP packages and components;" \
      "it does not install new PHP major versions."
  fi
  echo
  echo "After updating, recycle any stale workers (re-run this script's default audit) and"
  echo "confirm the version actually served with an uncached phpinfo on the affected site."
}

# ---- 1. installed PHP binaries ---------------------------------------------
hr "Installed PHP versions"
installed=""
while IFS= read -r b; do
  [[ -n $b ]] || continue
  rp=${b#"$R"}
  v=$(php_ver_from_path "$rp")
  tag=$(sed -E 's#.*/opt/cpanel/(ea-php[0-9]+)/.*#\1#; t; s#.*/opt/alt/(php[0-9]+)/.*#alt-\1#; t; s#.*#?#' <<<"$rp")
  [[ -n $v && $tag != "?" ]] || continue   # skip non-versioned PHP paths (e.g. an alt php-fpm dir)
  installed+="$tag=$v"$'\n'
done < <(find "$R/opt/cpanel" "$R/opt/alt" -maxdepth 5 -type f \( -name lsphp -o -name php \) \
            \( -path '*/ea-php[0-9]*/*' -o -path '*/alt/php[0-9]*/*' \) 2>/dev/null | sort -u)
installed=$(printf '%s' "$installed" | sort -u | grep -v '^$' | tr '\n' ' ')
if [[ -n $installed ]]; then
  echo "On disk: $installed"
else
  st INFO "no EA-PHP / Alt-PHP binaries found under /opt (unusual on a cPanel box)"
fi

# ---- 2. running workers + /proc inspection ---------------------------------
hr "PHP workers"
# Collect the process snapshot ONCE and tell a real collection failure (ps
# missing, or an unreadable fixture) apart from a genuinely empty worker list —
# a failed snapshot must never be reported as "no stale workers".
snap=$(ps_snapshot); snap_rc=$?
if (( snap_rc != 0 )); then
  st INFO "could not read the process list (ps unavailable or the snapshot failed) — cannot determine worker state; re-run as root on a cPanel server"
  if (( PKG )); then pkg_diag; fi
  exit 3
fi

# Collect worker rows: pid ppid uid etimes kind exepath deleted(0/1)
workers=""
master_pids=""   # pids classified as php-fpm masters, to validate a leaf worker's parent
while IFS=$'\t' read -r pid ppid uid et comm args; do
  [[ -n $pid ]] || continue
  # Identify a real PHP worker by its process NAME (comm = the executable's own
  # basename, as the kernel reports it) — never by loose command-line text. A
  # monitor, shell or editor whose arguments merely mention "php-fpm" or "lsphp"
  # must not be classified as a worker (and so can never be offered for --repair).
  case $comm in
    lsphp|lsphp[0-9]*|php-fpm|php-fpm[0-9.]*) : ;;
    *) continue ;;
  esac
  exe=$(read_exe "$pid")
  deleted=0; [[ $exe == *" (deleted)" ]] && deleted=1
  exepath=${exe% (deleted)}
  # When /proc/PID/exe is readable, confirm the executable really is an
  # lsphp/php-fpm binary; a process that only shares the comm name is skipped.
  if [[ -n $exepath ]]; then
    case ${exepath##*/} in
      lsphp|php-fpm) : ;;
      *) continue ;;
    esac
  fi
  # The FPM master is managed, not a stale leaf. Identify it by TWO signals so a
  # mis-titled master can never fall through to a leaf (and so never be offered a
  # kill): the "master process" args title, OR a php-fpm whose parent is init/systemd
  # (ppid 1) — leaf workers are forked from the master and have its pid as ppid.
  if   [[ $args == *"master process"* ]];                   then kind="php-fpm(master)"
  elif [[ $comm == php-fpm* ]] && [[ $ppid == 1 ]];         then kind="php-fpm(master)"
  elif [[ $comm == php-fpm* ]];                             then kind="php-fpm"
  else                                                           kind="lsphp"; fi
  [[ $kind == "php-fpm(master)" ]] && master_pids+="$pid "
  [[ -z $exepath ]] && exepath="-"   # sentinel: a tab IFS in read() would otherwise drop an empty field
  workers+="$pid"$'\t'"$ppid"$'\t'"$uid"$'\t'"$et"$'\t'"$kind"$'\t'"$exepath"$'\t'"$deleted"$'\n'
done <<<"$snap"
workers=${workers%$'\n'}

if [[ -z $workers ]]; then
  st INFO "no lsphp or php-fpm workers are running right now"
  echo
  st OK "nothing to recycle"
  if (( PKG )); then pkg_diag; fi
  exit 0
fi

now=$(now_epoch)
fail=0; warn=0; unknown=0; master_stale=0; uncertain=0
confirmed_pids=""   # leaf workers on a "(deleted)" binary — the only PIDs --repair will act on
mismatch_pids=""    # leaf workers whose binary mtime is newer than their start, NOT deleted (unverified)
declare -A ROW_KIND ROW_DACCT ROW_EXE ROW_AGE ROW_VERDICT

printf '%-8s %-15s %-16s %-9s %-10s %s\n' PID HANDLER ACCOUNT AGE VERDICT EXECUTABLE
while IFS=$'\t' read -r pid ppid uid et kind exepath deleted; do
  [[ -n $pid ]] || continue
  acct=$(uid_name "$uid")
  dacct=$acct; (( REDACT )) && dacct="uid:$uid"
  age=$(human_age "$et")
  verdict="ok"
  if [[ $kind == "php-fpm(master)" ]]; then
    # Keep the master identity in the HANDLER column, but an unreadable master is
    # inconclusive (we cannot tell whether it is stale) — count it as unknown so the
    # scan is reported INCOMPLETE, exactly like an unreadable leaf worker.
    if   [[ $exepath == "-" ]]; then verdict="master?"; unknown=$(( unknown+1 ))
    elif (( deleted ));         then verdict="master*"; master_stale=$(( master_stale+1 ))
    else                             verdict="master"; fi
  elif (( deleted )); then
    # A php-fpm leaf is only safe to CONFIRM (and later offer to --repair) when its
    # parent is a detected FPM master. A php-fpm on a replaced binary whose parent is
    # neither a detected master nor init (pid 1) may itself be a mis-titled master, so
    # withhold it from --repair rather than print a kill for it. (lsphp is spawned by
    # the web server, not forked from an FPM master, so it stays a confirmable leaf.)
    if [[ $kind == php-fpm ]] && [[ $ppid != 1 ]] && [[ " $master_pids " != *" $ppid "* ]]; then
      verdict="stale?"; uncertain=$(( uncertain+1 ))
    else
      verdict="STALE"; fail=$(( fail+1 )); confirmed_pids+="$pid "
    fi
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
  ROW_KIND[$pid]=$kind; ROW_DACCT[$pid]=$dacct
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
if (( uncertain > 0 )); then
  st WARN "$uncertain php-fpm worker(s) on a replaced binary whose parent is not a detected FPM master — NOT offered for recycling (one could be a mis-titled master). Restart the owning FPM service, or verify the process tree before acting."
fi
if (( fail == 0 && warn == 0 && master_stale == 0 && uncertain == 0 )); then
  if (( unknown > 0 )); then
    st INFO "no stale worker was confirmed, but the scan is INCOMPLETE — $unknown worker(s) could not be read (see above); this is not a clean result, re-run as root"
  else
    st OK "no worker is running a stale binary"
  fi
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
  elif [[ -L $CSV ]]; then echo "Refusing to write the CSV to a symlink: $CSV" >&2
  elif [[ -e $CSV && ! -f $CSV ]]; then echo "Refusing to write the CSV to a non-regular file: $CSV" >&2
  elif ( umask 077; csv_out > "$CSV" ); then st INFO "CSV written to $CSV (owner-only) — it contains account names and executable paths; treat it as sensitive server metadata and use --redact before sharing it"
  else echo "Could not write $CSV" >&2; fi
fi

# ---- package / repository diagnostics (opt-in) -----------------------------
if (( PKG )); then pkg_diag; fi

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
      - the whole handler, when several of its workers are affected (briefly disrupts
        every site on that handler; use a maintenance window). The command differs by
        handler, so match it to yours:
            Apache / mod_lsapi:  systemctl restart httpd   # recycles its lsphp workers
            LiteSpeed:           a web-server restart ("systemctl restart lsws" or
                                 "lswsctrl restart") does NOT reliably recycle lsphp
                                 run in detached/external mode (the usual LiteSpeed
                                 setup) -- detached lsphp can survive it. Use
                                 LiteSpeed's own PHP restart instead: WebAdmin console
                                 > Actions > Restart PHP, or recycle the single
                                 confirmed PID as above.
        An independently managed PHP-FPM service is restarted separately (see MASTER above):
            systemctl restart ea-phpNN-php-fpm

  Do NOT reboot the server just to refresh PHP workers, and do NOT run
  "killall lsphp" on a shared host — that drops every account's in-flight requests.
  Afterwards, confirm the served version with an uncached phpinfo on the affected site.
EOF
}

if [[ $MODE == plan ]]; then
  hr "Repair plan (no changes made)"
  cp=${confirmed_pids% }; mp=${mismatch_pids% }
  if [[ -n $cp || -n $mp ]] || (( master_stale > 0 )); then
    (( master_stale > 0 )) && echo "Stale php-fpm MASTER(s) present: restart the affected version's FPM service (see below) — a per-worker kill will NOT help a master."
    [[ -n $cp ]] && echo "Confirmed-stale leaf worker PID(s) (--repair --pid N prints the exact command for one): $cp"
    [[ -n $mp ]] && echo "Unverified mismatch PID(s) (confirm the served version first; not eligible for --repair): $mp"
    remediation_text
  elif (( unknown > 0 || uncertain > 0 )); then
    st INFO "nothing confirmed to recycle, but the scan is INCOMPLETE ($unknown unreadable, $uncertain unverified-parent) — investigate the process tree / re-run as root before concluding"
  else
    st OK "nothing to recycle"
  fi
  (( fail > 0 || master_stale > 0 )) && exit 2; (( warn > 0 )) && exit 1; (( unknown > 0 || uncertain > 0 )) && exit 3; exit 0
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
  acct=${ROW_DACCT[$TARGET_PID]:-unknown}   # honour --redact in advisory output too
  echo "This build is AUDIT-ONLY and does NOT terminate the process for you. The normal-state"
  echo "audit is verified on a live cPanel server; stale-worker detection is validated through"
  echo "controlled fixtures. Recycling stays a deliberate step you run and watch."
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
(( unknown > 0 || uncertain > 0 )) && exit 3
exit 0
