#!/usr/bin/env bash
# cPanel Account Inventory (v1.0.0) - from srvScripts.com
# Source, docs and updates: https://srvscripts.com/scripts/cpanel-account-inventory/
# Copyright (c) 2026 srvScripts.com. MIT licence: if you copy, share or adapt this script, keep this notice and credit srvScripts.com.
# cpanel-account-inventory.sh — one row per cPanel account: domains, IP, package, owner, disk, mail, databases, PHP
# https://srvscripts.com/scripts/cpanel-account-inventory/   License: MIT
#
# Read-only. Builds an inventory of every cPanel account from /var/cpanel/users,
# /etc/trueuserowners, the userdata files, the database map and whmapi1 listaccts
# (disk and inode figures). Prints an aligned table or writes CSV.
#   bash cpanel-account-inventory.sh                       # table
#   bash cpanel-account-inventory.sh --csv accounts.csv    # CSV file for a spreadsheet
#   bash cpanel-account-inventory.sh --csv - | tail -n +2 | sort -t, -k8,8nr   # biggest first
# Exit codes: 0 = OK, 2 = usage/dependency error.
#
# Testing only: SRVS_ROOT=/some/dir prefixes every cPanel path the script reads,
# and whmapi1 output is then read from $SRVS_ROOT/whmapi1/<function>.yaml.
set -uo pipefail
export LC_ALL=C

R=${SRVS_ROOT:-}
CSV=""

usage() {
  cat <<'EOF'
Usage: cpanel-account-inventory.sh [options]

Prints one row per cPanel account: user, main domain, addon and parked domain
counts, IP, package, owner, disk used, inodes, email accounts, databases, PHP
version of the main domain, creation date and suspension flag. Read-only.

Options:
  --csv FILE    write CSV to FILE instead of the table ("-" = stdout)
  -h, --help    this help

Exit codes: 0 = OK, 2 = usage/dependency error.
EOF
}

while (( $# )); do
  case $1 in
    --csv)     CSV=${2:-}; [[ -n $CSV ]] || { echo "--csv needs a file name" >&2; exit 2; }; shift ;;
    --csv=*)   CSV=${1#*=} ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
  shift
done

[[ -d $R/usr/local/cpanel ]] || { echo "cPanel not found ($R/usr/local/cpanel is missing). This script is for cPanel/WHM servers." >&2; exit 2; }
if [[ -z $R && $EUID -ne 0 ]]; then echo "Run as root." >&2; exit 2; fi
[[ -d $R/var/cpanel/users ]] || { echo "$R/var/cpanel/users is missing." >&2; exit 2; }

whmapi() { # whmapi FUNCTION [args] — WHM API 1 call, default YAML output
  local fn=$1; shift
  if [[ -n $R ]]; then cat "$R/whmapi1/$fn.yaml" 2>/dev/null; return; fi
  local bin=/usr/local/cpanel/bin/whmapi1
  [[ -x $bin ]] || bin=$(command -v whmapi1) || return 1
  "$bin" "$fn" "$@" 2>/dev/null
}

# yaml_list KEY... — one tab-separated row per list item of whmapi1 YAML on stdin.
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

kv() { awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$2" 2>/dev/null; }

# ---------------------------------------------------------------- lookups done once
# Disk (MB) and inodes per user from listaccts; sizes arrive as "812M" or "1.5G".
declare -A DISK=() INODES=()
if out=$(whmapi listaccts) && grep -q '^ *result: 1' <<<"$out"; then
  while IFS=$'\t' read -r u used inodes; do
    [[ -n $u ]] || continue
    DISK[$u]=$(awk -v s="$used" 'BEGIN { n = s + 0; if (s ~ /[Gg]$/) n *= 1024; else if (s ~ /[Kk]$/) n /= 1024; printf "%.0f", n }')
    INODES[$u]=${inodes:--}
  done < <(yaml_list user diskused inodesused <<<"$out")
else
  echo "Note: whmapi1 listaccts failed; disk and inode columns will show '-'." >&2
fi

# Database count per user from cPanel's database map (/var/cpanel/databases/USER.json).
declare -A DBS=()
PERL=/usr/local/cpanel/3rdparty/bin/perl; [[ -x $PERL ]] || PERL=$(command -v perl || true)
if [[ -n $PERL ]] && compgen -G "$R/var/cpanel/databases/*.json" >/dev/null; then
  while read -r u n; do DBS[$u]=$n; done < <("$PERL" -MJSON::PP -e '
    for my $f (@ARGV) {
      my ($u) = $f =~ m{([^/]+)\.json$} or next;
      open(my $fh, "<", $f) or next; local $/; my $j = eval { decode_json(<$fh>) } or next;
      my $dbs = $j->{MYSQL}{dbs}; print "$u ", (ref $dbs eq "HASH" ? scalar(keys %$dbs) : 0), "\n";
    }' "$R"/var/cpanel/databases/*.json 2>/dev/null)
fi

DEFAULT_PHP=$(awk '/^default:/ {print $2}' "$R/etc/cpanel/ea4/php.conf" 2>/dev/null)

# ---------------------------------------------------------------- one row per account
# Fields: user domain addons parked ip package owner disk_mb inodes email dbs php created suspended
rows=()
for f in "$R"/var/cpanel/users/*; do
  [[ -f $f ]] || continue
  u=${f##*/}
  [[ $u == system || $u == nobody || $u == *.* ]] && continue
  domain=$(kv DNS "$f"); ip=$(kv IP "$f"); plan=$(kv PLAN "$f")
  owner=$(awk -F': *' -v u="$u" '$1 == u {print $2; exit}' "$R/etc/trueuserowners" 2>/dev/null)
  owner=${owner:-$(kv OWNER "$f")}

  # Addon and parked counts: entries under each key of userdata/USER/main
  # (addon_domains is a map, parked_domains a list; "{}" / "[]" when empty).
  main=$R/var/cpanel/userdata/$u/main
  if [[ -r $main ]]; then
    read -r addons parked < <(awk '
      /^[^ ]/ { sec = $1 }
      /^ / && sec == "addon_domains:"  { a++ }
      /^ / && sec == "parked_domains:" { p++ }
      END { print a + 0, p + 0 }' "$main")
  else
    addons=-; parked=-
  fi

  # Email accounts: one line per mailbox in ~/etc/DOMAIN/passwd.
  home=$(awk -F: -v u="$u" '$1 == u {print $6; exit}' "$R/etc/passwd" 2>/dev/null); home=${home:-/home/$u}
  email=0
  for p in "$R$home"/etc/*/passwd; do
    [[ -f $p ]] && email=$(( email + $(grep -c . "$p") ))
  done

  # PHP of the main domain: "phpversion:" in its userdata file, else the system default.
  php=$(awk '/^phpversion:/ {print $2}' "$R/var/cpanel/userdata/$u/$domain" 2>/dev/null)
  php=${php:-$DEFAULT_PHP}; php=${php#ea-php}; php=${php#alt-php}
  [[ $php =~ ^[0-9]{2}$ ]] && php="${php:0:1}.${php:1}"

  start=$(kv STARTDATE "$f")
  if [[ $start =~ ^[0-9]+$ ]]; then created=$(date -d "@$start" +%F 2>/dev/null); else created=-; fi
  susp=no; [[ -e $R/var/cpanel/suspended/$u ]] && susp=yes

  rows+=("$u|${domain:--}|$addons|$parked|${ip:--}|${plan:--}|${owner:--}|${DISK[$u]:--}|${INODES[$u]:--}|$email|${DBS[$u]:--}|${php:--}|${created:--}|$susp")
done
(( ${#rows[@]} )) || { echo "No cPanel accounts found." >&2; exit 0; }

HEADER="user|domain|addons|parked|ip|package|owner|disk_mb|inodes|email|dbs|php|created|suspended"
if [[ -n $CSV ]]; then
  # Quote a field only when it holds a comma or quote, so plain `sort -t,` still works.
  csv_out() { printf '%s\n' "$HEADER" "${rows[@]}" | awk -F'|' -v OFS=, '{ $1 = $1; for (i = 1; i <= NF; i++) if ($i ~ /[",]/) { gsub(/"/, "\"\"", $i); $i = "\"" $i "\"" } print }'; }
  if [[ $CSV == - ]]; then csv_out; exit 0; fi
  csv_out > "$CSV" || { echo "Could not write $CSV" >&2; exit 2; }
  echo "Wrote ${#rows[@]} accounts to $CSV"
  exit 0
fi

fmt='%-14s %-28s %6s %6s %-15s %-18s %-10s %9s %9s %5s %4s %-4s %-10s %-4s\n'
# shellcheck disable=SC2059  # $fmt is our own fixed format string
printf "$fmt" USER DOMAIN ADDONS PARKED IP PACKAGE OWNER DISK_MB INODES EMAIL DBS PHP CREATED SUSP
printf '%s\n' "${rows[@]}" | sort | awk -F'|' -v fmt="$fmt" '{
  printf fmt, substr($1, 1, 14), substr($2, 1, 28), $3, $4, $5, substr($6, 1, 18), substr($7, 1, 10), $8, $9, $10, $11, $12, $13, $14 }'
echo
printf '%s\n' "${rows[@]}" | awk -F'|' '
  { n++; if ($14 == "yes") s++; if ($8 ~ /^[0-9]+$/) d += $8; e += $10; if ($11 ~ /^[0-9]+$/) db += $11 }
  END { printf "Accounts: %d   Suspended: %d   Disk: %.1f GB   Email accounts: %d   Databases: %d\n", n, s, d / 1024, e, db }'
exit 0
