#!/usr/bin/env bash
# cPanel Disk Usage Report (v1.0.0) - from srvScripts.com
# Source, docs and updates: https://srvscripts.com/scripts/cpanel-disk-usage-report/
# Copyright (c) 2026 srvScripts.com. MIT licence: if you copy, share or adapt this script, keep this notice and credit srvScripts.com.
# cpanel-disk-usage-report.sh — per-account disk usage on a cPanel/WHM server
# https://srvscripts.com/scripts/cpanel-disk-usage-report/   License: MIT
#
# Shows every cPanel account with home size, mail size, MySQL size and quota,
# sorted by total. Read-only. Run as root.
#   bash cpanel-disk-usage-report.sh              # table
#   bash cpanel-disk-usage-report.sh --top 15     # top 15 only
#   bash cpanel-disk-usage-report.sh --csv        # CSV for a spreadsheet
set -u
[[ $EUID -ne 0 ]] && { echo "Run as root." >&2; exit 1; }
[[ -d /var/cpanel/users ]] || { echo "This does not look like a cPanel server (/var/cpanel/users missing)." >&2; exit 1; }

TOP=0; CSV=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --top) TOP=${2:-0}; shift 2 ;;
    --csv) CSV=1; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

mb() { # bytes -> MB with one decimal
  awk -v b="${1:-0}" 'BEGIN{printf "%.1f", b/1048576}'
}

rows=()
for f in /var/cpanel/users/*; do
  u=$(basename "$f")
  [[ "$u" == "system" || "$u" == "nobody" ]] && continue
  home=$(awk -F= '/^HOMEDIRPATHS=/{print $2}' "$f"); home=${home:-/home/$u}
  [[ -d "$home" ]] || continue
  files=$(du -sb --exclude=mail --exclude=.trash "$home" 2>/dev/null | cut -f1)
  mail=$(du -sb "$home/mail" 2>/dev/null | cut -f1); mail=${mail:-0}
  db=0
  # MySQL: sum datadir dirs owned by this user's prefix
  datadir=$(mysql -Nse 'SELECT @@datadir' 2>/dev/null)
  if [[ -n "$datadir" ]]; then
    prefix=${u:0:16}
    db=$(du -sbc "$datadir"/"${prefix}"_* "$datadir"/"${u}" 2>/dev/null | tail -1 | cut -f1); db=${db:-0}
  fi
  quota=$(awk -F= '/^DISK_BLOCK_LIMIT=/{print $2}' "$f"); quota=${quota:-0}  # KB blocks
  quota_mb=$(( quota / 1024 ))
  total=$(( ${files:-0} + mail + db ))
  rows+=("$total|$u|$(mb "${files:-0}")|$(mb "$mail")|$(mb "$db")|$(mb "$total")|$quota_mb")
done

sorted=$(printf '%s\n' "${rows[@]}" | sort -t'|' -k1,1nr)
[[ $TOP -gt 0 ]] && sorted=$(echo "$sorted" | head -n "$TOP")

if (( CSV )); then
  echo "account,files_mb,mail_mb,mysql_mb,total_mb,quota_mb"
  echo "$sorted" | awk -F'|' '{printf "%s,%s,%s,%s,%s,%s\n",$2,$3,$4,$5,$6,($7==0?"unlimited":$7)}'
else
  printf '%-18s %10s %10s %10s %10s %10s\n' ACCOUNT FILES_MB MAIL_MB MYSQL_MB TOTAL_MB QUOTA_MB
  echo "$sorted" | awk -F'|' '{printf "%-18s %10s %10s %10s %10s %10s\n",$2,$3,$4,$5,$6,($7==0?"unlimited":$7)}'
  echo
  echo "$sorted" | awk -F'|' '{t+=$6} END{printf "Accounts: %d   Total: %.1f GB\n", NR, t/1024}'
  df -hP /home | awk 'NR==2{printf "/home: %s used of %s (%s)\n",$3,$2,$5}'
fi
