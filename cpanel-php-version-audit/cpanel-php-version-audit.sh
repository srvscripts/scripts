#!/usr/bin/env bash
# cPanel PHP Version Audit (v1.0.0) - from srvScripts.com
# Source, docs and updates: https://srvscripts.com/scripts/cpanel-php-version-audit/
# Copyright (c) 2026 srvScripts.com. MIT licence: if you copy, share or adapt this script, keep this notice and credit srvScripts.com.
# cpanel-php-version-audit.sh — every domain's PHP version on a cPanel server, with end-of-life flags
# https://srvscripts.com/scripts/cpanel-php-version-audit/   License: MIT
#
# Read-only. Lists the PHP version each virtual host runs under EasyApache 4
# MultiPHP, counts domains per version and flags end-of-life and security-only
# versions. Uses whmapi1 php_get_vhost_versions, or the userdata files if the
# API is unavailable.
#   bash cpanel-php-version-audit.sh
#   bash cpanel-php-version-audit.sh --csv php-audit.csv
#   bash cpanel-php-version-audit.sh --eol-below=8.1 --security-below=8.3
# Exit codes: 0 = OK, 1 = at least one site on end-of-life PHP, 2 = usage/dependency error.
#
# Testing only: SRVS_ROOT=/some/dir prefixes every cPanel path the script reads,
# and whmapi1 output is then read from $SRVS_ROOT/whmapi1/<function>.yaml.
set -uo pipefail
export LC_ALL=C

R=${SRVS_ROOT:-}
CSV=""; SOURCE=auto; COLOR=1
# php.net supported versions as of October 2026: 8.1 and older are end-of-life,
# 8.2 and 8.3 receive security fixes only, 8.4 and 8.5 are in active support.
EOL_BELOW=8.2; SEC_BELOW=8.4

usage() {
  cat <<'EOF'
Usage: cpanel-php-version-audit.sh [options]

Shows every domain's PHP version (EasyApache 4 MultiPHP), counts domains per
version and lists sites on end-of-life PHP. Read-only. Run as root.

Options:
  --csv FILE            also write every vhost to FILE as CSV ("-" = stdout)
  --eol-below=X.Y       versions below X.Y count as end-of-life (default 8.2)
  --security-below=X.Y  versions below X.Y count as security-only (default 8.4)
  --source=api|files    force whmapi1 or the userdata files (default: api, then files)
  --no-color            plain output even on a terminal
  -h, --help            this help

Exit codes: 0 = OK, 1 = a site runs end-of-life PHP, 2 = usage/dependency error.
EOF
}

while (( $# )); do
  case $1 in
    --csv)              CSV=${2:-}; [[ -n $CSV ]] || { echo "--csv needs a file name" >&2; exit 2; }; shift ;;
    --csv=*)            CSV=${1#*=} ;;
    --eol-below=*)      EOL_BELOW=${1#*=} ;;
    --security-below=*) SEC_BELOW=${1#*=} ;;
    --source=api|--source=files) SOURCE=${1#*=} ;;
    --no-color)         COLOR=0 ;;
    -h|--help)          usage; exit 0 ;;
    *) echo "Unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
  shift
done
for v in "$EOL_BELOW" "$SEC_BELOW"; do
  [[ $v =~ ^[0-9]+\.[0-9]+$ ]] || { echo "Version must look like 8.2, got: '$v'" >&2; exit 2; }
done

[[ -d $R/usr/local/cpanel ]] || { echo "cPanel not found ($R/usr/local/cpanel is missing). This script is for cPanel/WHM servers." >&2; exit 2; }
if [[ -z $R && $EUID -ne 0 ]]; then echo "Run as root." >&2; exit 2; fi

if (( COLOR )) && [[ -t 1 ]]; then
  C_OK=$'\e[32m'; C_WARN=$'\e[33m'; C_FAIL=$'\e[31m'; C_OFF=$'\e[0m'
else
  C_OK=; C_WARN=; C_FAIL=; C_OFF=
fi
hr() { printf '\n== %s ==\n' "$*"; }
st() { # st STATUS message
  local c=
  case $1 in OK) c=$C_OK ;; WARN) c=$C_WARN ;; FAIL) c=$C_FAIL ;; esac
  printf '%s%-4s%s %s\n' "$c" "$1" "$C_OFF" "$2"
}

whmapi() { # whmapi FUNCTION [args] — WHM API 1 call, default YAML output
  local fn=$1; shift
  if [[ -n $R ]]; then cat "$R/whmapi1/$fn.yaml" 2>/dev/null; return; fi
  local bin=/usr/local/cpanel/bin/whmapi1
  [[ -x $bin ]] || bin=$(command -v whmapi1) || return 1
  "$bin" "$fn" "$@" 2>/dev/null
}

# yaml_list KEY... — one tab-separated row per list item of whmapi1 YAML on stdin.
# Only keys at the item's own indentation are read; nested maps are ignored.
yaml_list() {
  awk -v keys="$*" -v dind=-1 '
    BEGIN { n = split(keys, k, " ") }
    function flush(   i, row) {
      if (!have) return
      row = ""
      for (i = 1; i <= n; i++) row = row (i > 1 ? "\t" : "") ((k[i] in v) ? v[k[i]] : "")
      print row; delete v; have = 0
    }
    {
      match($0, /^ */); cur = RLENGTH
      if ($0 ~ /^ *-( |$)/ && (dind < 0 || cur == dind)) {
        flush(); have = 1; ind = -1; dind = cur
        if ($0 ~ /^ *- *$/) next
        sub(/-/, " "); match($0, /^ */); cur = RLENGTH
      }
      if (!have) next
      if (ind < 0) ind = cur
      if (cur < ind) { flush(); next }
      if (cur == ind && $0 ~ /^ *[A-Za-z0-9_]+:/) {
        key = $0; sub(/^ */, "", key); sub(/:.*/, "", key)
        val = $0; sub(/^ *[A-Za-z0-9_]+: */, "", val); gsub(/^["\047]|["\047]$/, "", val)
        if (val == "~") val = ""
        v[key] = val
      }
    }
    END { flush() }'
}

# System default PHP from the EA4 MultiPHP config ("default: ea-php83").
DEFAULT=$(awk '/^default:/ {print $2}' "$R/etc/cpanel/ea4/php.conf" 2>/dev/null)
DEFAULT=${DEFAULT:-unknown}

# rows: vhost <TAB> account <TAB> handler package <TAB> fpm(0/1)
rows=""
if [[ $SOURCE != files ]]; then
  out=$(whmapi php_get_vhost_versions)
  if grep -q '^ *result: 1' <<<"$out"; then
    rows=$(yaml_list vhost account version php_fpm <<<"$out" | awk -F'\t' '$1 != ""')
    SRC="whmapi1 php_get_vhost_versions"
  elif [[ $SOURCE == api ]]; then
    echo "whmapi1 php_get_vhost_versions failed (EasyApache 4 required)." >&2; exit 2
  fi
fi
if [[ -z $rows ]]; then
  SRC="/var/cpanel/userdata files"
  # One file per vhost; skip SSL twins, caches and helper files. A vhost with no
  # "phpversion:" line inherits the system default.
  for f in "$R"/var/cpanel/userdata/*/*; do
    [[ -f $f ]] || continue
    name=${f##*/}; acct=${f%/*}; acct=${acct##*/}
    [[ $acct == nobody || $name == main || $name == cache || $name == *_SSL ]] && continue
    [[ $name == *.cache || $name == *.json || $name == *.yaml || $name == *.db || $name == *.lock ]] && continue
    grep -q '^servername:' "$f" 2>/dev/null || continue
    ver=$(awk '/^phpversion:/ {print $2}' "$f"); ver=${ver:-inherit}
    [[ $ver == inherit ]] && ver=$DEFAULT
    fpm=0; [[ -f $R/opt/cpanel/$ver/root/etc/php-fpm.d/$name.conf ]] && fpm=1
    rows+="$name"$'\t'"$acct"$'\t'"$ver"$'\t'"$fpm"$'\n'
  done
  rows=${rows%$'\n'}
fi
[[ -n $rows ]] || { echo "No virtual hosts found (checked $SRC)." >&2; exit 2; }

# Add the numeric version and status: ea-php74 / alt-php74 -> 7.4.
table=$(awk -F'\t' -v OFS='\t' -v eol="$EOL_BELOW" -v sec="$SEC_BELOW" -v def="$DEFAULT" '
  function num(s) { split(s, p, "."); return p[1] * 100 + p[2] }
  {
    h = ($3 == "" || $3 == "inherit") ? def : $3
    v = h; if (!sub(/^(ea|alt)-php/, "", v) || v !~ /^[0-9][0-9]+$/) v = "?"
    else v = substr(v, 1, 1) "." substr(v, 2)
    s = (v == "?") ? "UNKNOWN" : (num(v) < num(eol) ? "EOL" : (num(v) < num(sec) ? "SECURITY" : "ACTIVE"))
    print $1, $2, h, v, s, ($4 == 1 ? "fpm" : "-")
  }' <<<"$rows" | sort -t$'\t' -k4,4 -k2,2 -k1,1)

hr "PHP on this server"
echo "Source: $SRC"
echo "System default: $DEFAULT"
installed=$(find "$R/opt/cpanel" "$R/opt/alt" -maxdepth 1 -type d \( -name 'ea-php[0-9]*' -o -name 'php[0-9][0-9]' \) 2>/dev/null | sed 's|.*/opt/alt/|alt-|; s|.*/||' | sort | tr '\n' ' ')
echo "Installed: ${installed:-none found}"
echo "Policy: below $EOL_BELOW = EOL, below $SEC_BELOW = security fixes only"

hr "Domains per PHP version"
printf '%-8s %-9s %8s %9s\n' VERSION STATUS DOMAINS ACCOUNTS
awk -F'\t' '{ k = $4 "\t" $5; d[k]++; if (!((k, $2) in seen)) { seen[k, $2] = 1; a[k]++ } }
  END { for (k in d) { split(k, p, "\t"); printf "%-8s %-9s %8d %9d\n", p[1], p[2], d[k], a[k] } }' <<<"$table" | sort -V
total=$(wc -l <<<"$table")
eol=$(awk -F'\t' '$5 == "EOL"' <<<"$table" | wc -l)
secn=$(awk -F'\t' '$5 == "SECURITY"' <<<"$table" | wc -l)
echo "Total vhosts: $total"

hr "Sites on end-of-life PHP"
if (( eol == 0 )); then
  st OK "no site runs a PHP version below $EOL_BELOW"
else
  printf '%-40s %-16s %-10s %-8s %s\n' VHOST ACCOUNT HANDLER VERSION FPM
  awk -F'\t' '$5 == "EOL" { printf "%-40s %-16s %-10s %-8s %s\n", $1, $2, $3, $4, $6 }' <<<"$table"
  st FAIL "$eol site(s) on end-of-life PHP; no security fixes are published for these versions"
fi
if (( secn > 0 )); then st WARN "$secn site(s) on security-only PHP (below $SEC_BELOW); plan the upgrade"; fi
unk=$(awk -F'\t' '$5 == "UNKNOWN"' <<<"$table" | wc -l)
(( unk > 0 )) && st INFO "$unk vhost(s) with an unrecognised handler name (see CSV)"

if [[ -n $CSV ]]; then
  csv_out() { echo "vhost,account,handler,version,status,fpm"; tr '\t' ',' <<<"$table"; }
  if [[ $CSV == - ]]; then echo; csv_out
  elif csv_out > "$CSV"; then echo; st INFO "CSV written to $CSV ($total rows)"
  else echo "Could not write $CSV" >&2; exit 2; fi
fi

echo
(( eol > 0 )) && exit 1
exit 0
