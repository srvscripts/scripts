#!/usr/bin/env bash
# VoIP Toll Fraud Watch: Alert on International, Premium and After-Hours Calls from Asterisk/FreePBX CDR (v1.0.1) - from srvScripts.com
# Source, docs and updates: https://srvscripts.com/scripts/voip-toll-fraud-watch/
# Copyright (c) 2026 srvScripts.com. MIT licence: if you copy, share or adapt this script, keep this notice and credit srvScripts.com.
#
# Reads the call detail records (FreePBX/Asterisk asteriskcdrdb.cdr in MariaDB/MySQL, or cdr-csv Master.csv) for the
# last N minutes and raises an alarm on the patterns seen in toll fraud: bursts of international or premium-rate
# calls, many minutes to one country, calls outside office hours, one extension making far more calls than usual,
# and calls that come in on a trunk and go straight back out (transit fraud). Run it from cron every 5-15 minutes
# with --mail or --webhook. It only reads the CDR; it never blocks anything itself (see --help for what to do).
#
#   bash voip-toll-fraud-watch.sh --minutes 60
#   bash voip-toll-fraud-watch.sh --minutes 15 --max-intl-calls 3 --hours 08-18 --mail ops@example.com
#   */10 * * * * root /usr/local/bin/voip-toll-fraud-watch.sh --minutes 10 --quiet --mail ops@example.com
#
# Exit codes: 0 nothing suspicious, 1 warning, 2 alarm, 3 could not read the CDR or bad option.
# Version 1.0.1 (2026-10-17): on FreePBX (or with --source db) a CDR database that cannot be queried is UNKNOWN (exit 3);
#   1.0.0 could fall back to an old Master.csv and report OK. A skipped transit check is shown. Notification state
#   is saved per channel only after delivery. Found in an independent review.
# Version 1.0.0 (2026-10-17): first release. Tested on FreePBX 17.0.33 / Asterisk 22.11 (Debian 12) with simulated
#   international bursts, after-hours calls and normal domestic traffic through a test carrier.
set -uo pipefail
export LC_ALL=C

MIN=60; MAX_INTL=5; MAX_INTL_MIN=30; MAX_EXT=40; HOURS=""; DAYS="1-5"; INTL_RE='^(\+|00|011|9011|900|9900)'
PREMIUM_RE='^1?(900|976)[0-9]{7}$'; ALLOW_RE=""; SOURCE=auto; CSV=/var/log/asterisk/cdr-csv/Master.csv
DB=asteriskcdrdb; JSON=0; QUIET=0; MAIL_TO=""; WEBHOOK=""; STATE_DIR=/var/lib/voip-toll-fraud-watch; NOTIFY_CHANGE=1
read -ra MA <<<"${MYSQL_ARGS:-}"

usage() {
  cat <<'EOF'
Usage: voip-toll-fraud-watch.sh [options]
  --minutes N            look at calls that started in the last N minutes (default 60)
  --max-intl-calls N     alarm when more than N international/premium calls were made (default 5)
  --max-intl-minutes N   alarm when international talk time is above N minutes (default 30)
  --max-ext-calls N      warn when one source made more than N outbound calls (default 40)
  --hours HH-HH          office hours, e.g. 08-18; outbound calls outside them are warnings (default: off)
  --days D-D             office days 1-7 (Mon=1) for --hours (default 1-5)
  --intl-regex RE        what counts as international (default '^(\+|00|011|9011|900|9900)')
  --allow-regex RE       destinations that are never suspicious (e.g. your own office abroad: '^01144207946')
  --source db|csv|auto   CDR source (default auto: the FreePBX database if reachable, else Master.csv)
  --db NAME              CDR database (default asteriskcdrdb)     --csv FILE  cdr-csv file
  --json                 JSON output            -q, --quiet   print only when something is suspicious
  --mail ADDR            e-mail alarms (needs 'mail')            --webhook URL  POST JSON alarms
  --every-time           send mail/webhook on every suspicious run (default: only when the findings change)
  -h, --help             this help
If it fires: disable the route or trunk (FreePBX: Connectivity > Outbound Routes), change the secret of the source
extension, check 'pjsip show contacts' for unknown IPs, and ask your SIP provider to block international calls.
Environment: MYSQL_ARGS extra mysql client arguments (FreePBX root works without any)
EOF
}
die() { echo "UNKNOWN: $*" >&2; exit 3; }
num() { [[ "$2" =~ ^[0-9]+$ ]] || die "$1 needs a whole number"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --minutes) num "$1" "${2:-}"; MIN=$2; shift 2 ;;
    --max-intl-calls) num "$1" "${2:-}"; MAX_INTL=$2; shift 2 ;;
    --max-intl-minutes) num "$1" "${2:-}"; MAX_INTL_MIN=$2; shift 2 ;;
    --max-ext-calls) num "$1" "${2:-}"; MAX_EXT=$2; shift 2 ;;
    --hours) [[ "${2:-}" =~ ^([01][0-9]|2[0-3])-([01][0-9]|2[0-4])$ ]] || die "--hours needs HH-HH, e.g. 08-18"; HOURS=$2; shift 2 ;;
    --days) [[ "${2:-}" =~ ^[1-7]-[1-7]$ ]] || die "--days needs D-D, e.g. 1-5"; DAYS=$2; shift 2 ;;
    --intl-regex) INTL_RE="${2:-}"; shift 2 ;;
    --allow-regex) ALLOW_RE="${2:-}"; shift 2 ;;
    --source) SOURCE="${2:-}"; [[ "$SOURCE" =~ ^(db|csv|auto)$ ]] || die "--source is db, csv or auto"; shift 2 ;;
    --db) DB="${2:-}"; [[ "$DB" =~ ^[A-Za-z0-9_]+$ ]] || die "--db: invalid name"; shift 2 ;;
    --csv) CSV="${2:-}"; shift 2 ;;
    --json) JSON=1; shift ;;
    -q|--quiet) QUIET=1; shift ;;
    --mail) MAIL_TO="${2:-}"; [[ "$MAIL_TO" == *@* ]] || die "--mail needs an address"; shift 2 ;;
    --webhook) WEBHOOK="${2:-}"; [[ "$WEBHOOK" =~ ^https?:// ]] || die "--webhook needs an http(s) URL"; shift 2 ;;
    --every-time) NOTIFY_CHANGE=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
done
for re in "$INTL_RE" "$PREMIUM_RE" "${ALLOW_RE:-x}"; do echo | grep -Eq -- "$re" 2>/dev/null; [ $? -le 1 ] || die "invalid regular expression: $re"; done

# ---- collect outbound-looking calls as TSV: start  src  dst  disposition  billsec  channel  dstchannel ----
TMP=$(mktemp -d) || die "mktemp failed"; trap 'rm -rf "$TMP"' EXIT
rows=$TMP/rows
since=$(date -d "-$MIN minutes" '+%F %T')
# On FreePBX the CDR lives in the database: if that database cannot be queried, stop with UNKNOWN (exit 3) instead of
# quietly reading an old or empty Master.csv and reporting "nothing suspicious".
dbok=0; dberr=""
if [ "$SOURCE" != csv ] && command -v mysql >/dev/null 2>&1; then
  if dberr=$(mysql "${MA[@]}" -N -B "$DB" -e "SELECT 1" 2>&1 >/dev/null); then dbok=1; fi
fi
if [ "$dbok" = 0 ] && [ "$SOURCE" != csv ] && { [ "$SOURCE" = db ] || [ -f /etc/freepbx.conf ]; }; then
  die "cannot query the CDR database $DB ($(head -1 <<<"${dberr:-mysql client not installed}" | cut -c1-100)); check MariaDB and MYSQL_ARGS"
fi
if [ "$dbok" = 1 ]; then
  src=db
  mysql "${MA[@]}" -N -B "$DB" -e "SELECT calldate, src, dst, disposition, billsec, channel, dstchannel, WEEKDAY(calldate)+1, HOUR(calldate) FROM cdr
    WHERE calldate >= '$since' AND dstchannel <> '' AND dstchannel NOT LIKE 'Local/%' ORDER BY calldate" > "$rows" 2>/dev/null \
    || die "query on $DB.cdr failed"
elif [ "$SOURCE" != db ] && [ -r "$CSV" ]; then
  src=csv
  command -v gawk >/dev/null 2>&1 || die "reading $CSV needs gawk (apt install gawk / dnf install gawk)"
  # Master.csv: accountcode,src,dst,dcontext,clid,channel,dstchannel,lastapp,lastdata,start,answer,end,duration,billsec,disposition,amaflags,...
  tail -n 200000 "$CSV" | gawk -v since="$since" -v FPAT='([^,]*)|("[^"]*")' 'BEGIN{OFS="\t"} {for(i=1;i<=NF;i++) gsub(/^"|"$/,"",$i)}
    $10>=since && $7!="" && $7 !~ /^Local\// { t=$10; gsub(/[-:]/," ",t); e=mktime(t); print $10,$2,$3,$15,$14,$6,$7,strftime("%u",e),strftime("%H",e)+0 }' > "$rows" \
    || die "cannot parse $CSV"
else
  die "no CDR source: the $DB database is not reachable and $CSV is not readable (use --source/--db/--csv)"
fi

# ---- classify ----
# regexes go through the environment so awk does not reinterpret their backslashes
export INTL_RE PREMIUM_RE ALLOW_RE
read -r intl_calls intl_secs total after < <(awk -F'\t' -v hours="$HOURS" -v days="$DAYS" '
  BEGIN{split(hours,h,"-"); split(days,d,"-"); ire=ENVIRON["INTL_RE"]; pre=ENVIRON["PREMIUM_RE"]; are=ENVIRON["ALLOW_RE"]}
  { dst=$3; gsub(/[^0-9+*#]/,"",dst); total++
    if (are!="" && dst ~ are) next
    if (dst ~ ire || dst ~ pre) { ic++; is+=$5 }
    if (hours!="") { hh=$9+0; wd=$8+0
      if (hh < h[1]+0 || hh >= h[2]+0 || wd < d[1]+0 || wd > d[2]+0) ah++ } }
  END{printf "%d %d %d %d\n", ic, is, total, ah}' "$rows")
intl_min=$(( (intl_secs + 59) / 60 ))

top_dst=$(awk -F'\t' 'BEGIN{ire=ENVIRON["INTL_RE"]; pre=ENVIRON["PREMIUM_RE"]; are=ENVIRON["ALLOW_RE"]
    n=split("20 27 30 31 32 33 34 36 39 40 41 43 44 45 46 47 48 49 51 52 53 54 55 56 57 58 60 61 62 63 64 65 66 81 82 84 86 90 91 92 93 94 95 98",cc," "); for(i=1;i<=n;i++) two[cc[i]]=1}
  {d=$3; gsub(/[^0-9+]/,"",d); if (are!="" && d ~ are) next
   if (d ~ pre) { c["premium " substr(d,1,4)]++; next }
   if (d ~ ire) { p=d; sub(/^(\+|9?011|9?00|9900)/,"",p); k=substr(p,1,1); if (k!="1" && k!="7") k=(substr(p,1,2) in two) ? substr(p,1,2) : substr(p,1,3); c["+" k]++ } }
  END{for(k in c) print c[k], k}' "$rows" | sort -rn | head -6)
top_src=$(awk -F'\t' '{c[$2]++} END{for(k in c) print c[k], k}' "$rows" | sort -rn | head -5)
failed=$(awk -F'\t' 'BEGIN{ire=ENVIRON["INTL_RE"]} {d=$3; gsub(/[^0-9+]/,"",d)} d ~ ire && $4 != "ANSWERED" {n++} END{print n+0}' "$rows")

# Transit: the call came in on a trunk (channel = a trunk) and left on a trunk
trunks=""; transit_note=""
if [ "$src" = db ] && mysql "${MA[@]}" -N -B asterisk -e "SELECT 1" >/dev/null 2>&1; then
  if tl=$(mysql "${MA[@]}" -N -B asterisk -e "SELECT channelid FROM trunks WHERE disabled <> 'on'" 2>/dev/null); then
    trunks=$(sed -E 's#.*@##; s#^[A-Z0-9]+/##; s#[/$].*##' <<<"$tl" | grep -E '^[A-Za-z0-9_.-]+$' | sort -u | paste -sd'|')
  else transit_note="transit check skipped: the FreePBX trunk list could not be read"; fi
else transit_note="transit check skipped: no FreePBX trunk list (plain Asterisk or CSV source)"; fi
transit=0
[ -n "$trunks" ] && transit=$(awk -F'\t' -v t="$trunks" '$6 ~ "^(PJSIP|SIP|IAX2)/(" t ")-" {n++} END{print n+0}' "$rows")

STATUS=0; FIND=()
add() { case "$1" in ALARM) STATUS=2 ;; WARN) [ "$STATUS" -lt 1 ] && STATUS=1 ;; esac; FIND+=("$1 $2"); }
[ "$intl_calls" -gt "$MAX_INTL" ] && add ALARM "$intl_calls international/premium calls in $MIN min (limit $MAX_INTL)"
[ "$intl_min" -gt "$MAX_INTL_MIN" ] && add ALARM "$intl_min international minutes in $MIN min (limit $MAX_INTL_MIN)"
[ "$transit" -gt 0 ] && add ALARM "$transit call(s) came in on a trunk and went straight back out (transit fraud pattern)"
[ "$failed" -gt 10 ] && add WARN "$failed unanswered international attempts (someone testing destinations?)"
[ -n "$HOURS" ] && [ "$after" -gt 0 ] && add WARN "$after outbound call(s) outside office hours $HOURS (days $DAYS)"
while read -r n s; do [ -n "${n:-}" ] && [ "$n" -gt "$MAX_EXT" ] && add WARN "source $s made $n outbound calls (limit $MAX_EXT)"; done <<<"$top_src"

label=(OK WARNING ALARM); host=$(hostname -f 2>/dev/null || hostname)
summary="${label[$STATUS]}: $total outbound call(s) in the last $MIN min, $intl_calls international/premium ($intl_min min), source $src"
js() { local s=${1//\\/\\\\}; s=${s//\"/\\\"}; printf '"%s"' "${s//$'\n'/; }"; }
json() {
  printf '{"host":%s,"status":%s,"window_minutes":%s,"outbound_calls":%s,"intl_calls":%s,"intl_minutes":%s,"after_hours":%s,"transit":%s,"findings":[' \
    "$(js "$host")" "$(js "${label[$STATUS]}")" "$MIN" "$total" "$intl_calls" "$intl_min" "${after:-0}" "$transit"
  local i; for i in "${!FIND[@]}"; do [ "$i" -gt 0 ] && printf ','; js "${FIND[$i]}"; done
  printf '],"top_country_prefixes":%s,"top_sources":%s,"text":%s}\n' "$(js "$top_dst")" "$(js "$top_src")" "$(js "$host $summary")"
}
report() {
  echo "Toll fraud watch on $host, calls since $since ($src)"
  local x; for x in "${FIND[@]}"; do echo "  $x"; done
  if [ "$intl_calls" -gt 0 ]; then echo "  International/premium by country code (calls, code):"; sed 's/^/    /' <<<"$top_dst"; fi
  if [ "$total" -gt 0 ]; then echo "  Top sources (calls, caller):"; sed 's/^/    /' <<<"$top_src"; fi
  [ -n "$transit_note" ] && echo "  note: $transit_note"
  echo "$summary"
}
if [ "$JSON" = 1 ]; then json; elif [ "$QUIET" = 0 ] || [ "$STATUS" -gt 0 ]; then report; fi

# Notifications: per channel; with change detection the state is saved only after that channel delivered, so a
# failed mail or webhook is retried on the next run. Unchanged findings are re-sent after 2 hours.
if [ -n "$MAIL_TO$WEBHOOK" ] && [ "$STATUS" -gt 0 ]; then
  sig=$(printf '%s\n' "${FIND[@]}" | sed -E 's/[0-9]+//g' | sha256sum | cut -c1-16)
  [ "$NOTIFY_CHANGE" = 1 ] && { mkdir -p "$STATE_DIR" 2>/dev/null && chmod 700 "$STATE_DIR" 2>/dev/null; }
  for ch in mail webhook; do
    [ "$ch" = mail ] && [ -z "$MAIL_TO" ] && continue
    [ "$ch" = webhook ] && [ -z "$WEBHOOK" ] && continue
    if [ "$NOTIFY_CHANGE" = 1 ] && [ "$sig" = "$(cat "$STATE_DIR/last.$ch" 2>/dev/null)" ] && [ -n "$(find "$STATE_DIR/last.$ch" -mmin -120 2>/dev/null)" ]; then continue; fi
    ok=1
    if [ "$ch" = mail ]; then
      if command -v mail >/dev/null 2>&1; then report | mail -s "[TOLL FRAUD] ${label[$STATUS]} on $host" "$MAIL_TO" || ok=0
      else echo "voip-toll-fraud-watch: 'mail' command not found" >&2; ok=0; fi
    else json | curl -fsS -m 15 -H 'Content-Type: application/json' --data-binary @- "$WEBHOOK" >/dev/null || ok=0; fi
    if [ "$ok" = 1 ]; then [ "$NOTIFY_CHANGE" = 1 ] && echo "$sig" > "$STATE_DIR/last.$ch" 2>/dev/null
    else echo "voip-toll-fraud-watch: $ch delivery failed; it will be retried on the next run" >&2; fi
  done
fi
exit "$STATUS"
