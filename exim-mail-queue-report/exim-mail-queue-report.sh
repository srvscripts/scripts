#!/usr/bin/env bash
# Exim Mail Queue Report (v1.0.0) - from srvScripts.com
# Source, docs and updates: https://srvscripts.com/scripts/exim-mail-queue-report/
# Copyright (c) 2026 srvScripts.com. MIT licence: if you copy, share or adapt this script, keep this notice and credit srvScripts.com.
# exim-mail-queue-report.sh — find out what is filling the Exim queue on a cPanel server
# https://srvscripts.com/scripts/exim-mail-queue-report/   License: MIT
#
# Read-only by default. Shows queue size, frozen count, top senders, top recipients,
# top authenticated users and top sending scripts (from the last 24h of exim_mainlog).
#   bash exim-mail-queue-report.sh                 # report
#   bash exim-mail-queue-report.sh --purge-frozen  # also delete frozen messages (asks first)
#   bash exim-mail-queue-report.sh --purge-frozen --yes
set -u
[[ $EUID -ne 0 ]] && { echo "Run as root." >&2; exit 1; }
command -v exim >/dev/null 2>&1 || { echo "exim not found." >&2; exit 1; }

PURGE=0; YES=0; N=10
for a in "$@"; do case "$a" in --purge-frozen) PURGE=1 ;; --yes) YES=1 ;; --top=*) N=${a#--top=} ;; esac; done

LOG=/var/log/exim_mainlog; [[ -r $LOG ]] || LOG=/var/log/exim4/mainlog
hr() { printf '\n== %s ==\n' "$*"; }

hr "Queue"
total=$(exim -bpc 2>/dev/null)
frozen=$(exim -bpr 2>/dev/null | grep -c '\*\*\* frozen \*\*\*')
echo "Messages in queue: ${total:-0}   Frozen: $frozen"
oldest=$(exim -bpr 2>/dev/null | awk '/^ *[0-9]+[hdm] /{print $1; exit}')
[[ -n "$oldest" ]] && echo "Oldest message age: $oldest"

hr "Top $N senders in queue"
exim -bpr 2>/dev/null | grep -Eo '<[^>]+>' | sort | uniq -c | sort -rn | head -n "$N"

hr "Top $N recipient domains in queue"
exim -bpr 2>/dev/null | awk '/^ +[^ ]+@/{print $1}' | awk -F@ '{print $2}' | sort | uniq -c | sort -rn | head -n "$N"

if [[ -r $LOG ]]; then
  since=$(date -d '24 hours ago' '+%Y-%m-%d %H' 2>/dev/null)
  recent() { awk -v s="$since" 'substr($0,1,13) >= s' "$LOG"; }

  hr "Top $N authenticated senders, last 24h (compromised mailbox check)"
  recent | grep -Eo 'A=(dovecot|courier|login|plain)[^ ]*:[^ ]+' | awk -F: '{print $2}' | sort | uniq -c | sort -rn | head -n "$N"

  hr "Top $N scripts sending mail, last 24h (cwd=)"
  recent | grep -Eo 'cwd=[^ ]+' | grep -v 'cwd=/$' | sort | uniq -c | sort -rn | head -n "$N"

  hr "Top $N local users sending via PHP/sendmail, last 24h (U=)"
  recent | grep -E '<= ' | grep -Eo ' U=[^ ]+' | sort | uniq -c | sort -rn | head -n "$N"

  hr "Deferred / bounced in last 24h"
  printf 'Deferred (==): %s   Bounced (**): %s   Completed: %s\n' \
    "$(recent | grep -c ' == ')" "$(recent | grep -c ' \*\* ')" "$(recent | grep -c 'Completed')"

  hr "Most common delivery errors, last 24h"
  recent | grep -E ' (==|\*\*) ' | sed -E 's/.* (==|\*\*) [^ ]+ //; s/[0-9a-zA-Z.-]+\[[0-9.]+\]//g; s/[0-9]{3}[- ]/ /g' | cut -c1-110 | sort | uniq -c | sort -rn | head -n 8
else
  echo "exim_mainlog not readable; skipping 24h analysis."
fi

if (( PURGE )) && (( frozen > 0 )); then
  hr "Purge frozen"
  if (( ! YES )); then read -rp "Delete $frozen frozen messages? [y/N] " a; [[ "$a" =~ ^[Yy]$ ]] || { echo "Skipped."; exit 0; }; fi
  exim -bpr | grep '\*\*\* frozen \*\*\*' | awk '{print $3}' | xargs -r exim -Mrm >/dev/null
  echo "Done. Queue now: $(exim -bpc)"
fi
