#!/usr/bin/env bash
# SSL Expiry Check Script: Free Network Test for Web and Mail (v1.1.0) - from srvScripts.com
# Source, docs and updates: https://srvscripts.com/scripts/ssl-expiry-check/
# Copyright (c) 2026 srvScripts.com. MIT licence: if you copy, share or adapt this script, keep this notice and credit srvScripts.com.
# ssl-expiry-check.sh — warn before TLS certificates expire, and flag certificates browsers would reject
# https://srvscripts.com/scripts/ssl-expiry-check/   License: MIT   Version 1.1.0
#
# Checks live certificates over the network (so it catches what visitors actually see,
# including CDN/proxy certs), not files on disk. Needs openssl. No root required.
# Also verifies the chain and the host name (self-signed, untrusted, wrong host = problem);
# use --allow-untrusted to report those without counting them as problems.
#   bash ssl-expiry-check.sh example.com mail.example.com:993 imap.example.net:143
#   bash ssl-expiry-check.sh -f domains.txt -w 14           # warn under 14 days
#   bash ssl-expiry-check.sh -f domains.txt -w 14 -q        # quiet: only print problems (cron)
#   bash ssl-expiry-check.sh --cpanel                        # every domain on this cPanel server
# domains.txt: one host[:port] per line, # comments allowed. Port 25/110/143/587 use STARTTLS.
set -u
WARN=21; QUIET=0; FILE=""; CPANEL=0; TIMEOUT=8; HOSTS=(); ALLOWU=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -w) WARN=$2; shift 2 ;;
    -f) FILE=$2; shift 2 ;;
    -q) QUIET=1; shift ;;
    -t) TIMEOUT=$2; shift 2 ;;
    --cpanel) CPANEL=1; shift ;;
    --allow-untrusted) ALLOWU=1; shift ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) HOSTS+=("$1"); shift ;;
  esac
done
command -v openssl >/dev/null || { echo "openssl not found" >&2; exit 2; }

if [[ -n "$FILE" ]]; then
  while IFS= read -r l; do l=${l%%#*}; l=${l//[[:space:]]/}; [[ -n "$l" ]] && HOSTS+=("$l"); done < "$FILE"
fi
if (( CPANEL )); then
  [[ -r /etc/userdomains ]] || { echo "/etc/userdomains not readable (not cPanel or not root)" >&2; exit 2; }
  while IFS=: read -r d _; do [[ "$d" == "*" || "$d" == \*.* ]] && continue; HOSTS+=("$d"); done < /etc/userdomains
fi
[[ ${#HOSTS[@]} -eq 0 ]] && { echo "No hosts given. See --help." >&2; exit 2; }

problems=0; now=$(date +%s)
# Trust store: pass the system CA bundle explicitly where we know it (some openssl builds have no default path).
CAOPT=(); for f in /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/certs/ca-certificates.crt /etc/ssl/cert.pem; do [[ -r $f ]] && { CAOPT=(-CAfile "$f"); break; }; done
HNOK=0; openssl s_client -help 2>&1 | grep -q -- '-verify_hostname' && HNOK=1
for h in "${HOSTS[@]}"; do
  host=${h%%:*}; port=443; [[ "$h" == *:* ]] && port=${h##*:}
  st=""; case $port in 25|587) st="-starttls smtp" ;; 110) st="-starttls pop3" ;; 143) st="-starttls imap" ;; 21) st="-starttls ftp" ;; esac
  vh=(); if (( HNOK )); then if [[ $host =~ ^[0-9.]+$ || $host == *:* ]]; then vh=(-verify_ip "$host"); else vh=(-verify_hostname "$host"); fi; fi
  raw=$(timeout "$TIMEOUT" openssl s_client -servername "$host" -connect "$host:$port" $st ${CAOPT[@]+"${CAOPT[@]}"} ${vh[@]+"${vh[@]}"} </dev/null 2>/dev/null)
  cert=$(printf '%s\n' "$raw" | openssl x509 -noout -enddate -subject -issuer 2>/dev/null)
  vrc=$(printf '%s\n' "$raw" | sed -n 's/^ *Verify return code: \([0-9]*\) (\(.*\))/\1|\2/p' | tail -1)
  if [[ -z "$cert" ]]; then
    printf '%-40s  %s\n' "$h" "ERROR  could not fetch certificate"; problems=$((problems+1)); continue
  fi
  end=$(echo "$cert" | awk -F= '/^notAfter/{print $2}')
  ends=$(date -d "$end" +%s 2>/dev/null || date -j -f '%b %d %T %Y %Z' "$end" +%s 2>/dev/null)
  days=$(( (ends - now) / 86400 ))
  issuer=$(echo "$cert" | sed -n 's/^issuer=.*O *= *\([^,/]*\).*/\1/p' | head -1)
  [[ -z $issuer ]] && issuer=$(echo "$cert" | sed -n 's/^issuer=.*CN *= *\([^,/]*\).*/\1/p' | head -1)
  code=${vrc%%|*}; why=${vrc#*|}; note=""
  case $code in
    ''|0) ;;
    18|19) note=" self-signed" ;;
    62) note=" wrong host name" ;;
    10) ;;                                  # expired: reported by the date check below
    *) note=" untrusted: $why" ;;
  esac
  if (( days < 0 )); then state="EXPIRED"; problems=$((problems+1))
  elif [[ -n $note ]] && (( ! ALLOWU )); then state="BAD"; problems=$((problems+1))
  elif (( days <= WARN )); then state="WARN"; problems=$((problems+1))
  else state="OK"; fi
  mismatch=${note:+ <-$note}
  if (( ! QUIET )) || [[ "$state" != "OK" ]]; then
    printf '%-40s  %-7s %4d days  %s  [%s]%s\n' "$h" "$state" "$days" "$(date -d "@$ends" +%Y-%m-%d 2>/dev/null)" "${issuer:-?}" "$mismatch"
  fi
done
(( QUIET )) && (( problems == 0 )) && exit 0
echo "Checked ${#HOSTS[@]} host(s); $problems problem(s)."
exit $(( problems > 0 ? 1 : 0 ))
