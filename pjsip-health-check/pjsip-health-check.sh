#!/usr/bin/env bash
# PJSIP Health Check: Trunks, Registrations, Phones and Call Load for Asterisk and FreePBX (v1.0.1) - from srvScripts.com
# Source, docs and updates: https://srvscripts.com/scripts/pjsip-health-check/
# Copyright (c) 2026 srvScripts.com. MIT licence: if you copy, share or adapt this script, keep this notice and credit srvScripts.com.
#
# Read-only health check for Asterisk 18+ with chan_pjsip (FreePBX 16/17, plain Asterisk, VitalPBX, Issabel 5).
# It asks Asterisk (asterisk -rx) for: uptime, outbound registrations, contact reachability and round-trip time
# (qualify), endpoint states and the number of active calls, and prints one line per problem plus a summary.
# Nothing on the PBX is changed: no reload, no config edits, no database writes. It is safe to run every minute.
#
#   bash pjsip-health-check.sh                       # human report
#   bash pjsip-health-check.sh --quiet               # only problems (for cron); silent when all is OK
#   bash pjsip-health-check.sh --json                # machine-readable report
#   */5 * * * * root /usr/local/bin/pjsip-health-check.sh --quiet --notify-on-change --mail ops@example.com
#
# What counts as a trunk: an endpoint with an outbound registration, an identify (match=) section, or a name that is
# not all digits. Everything else is treated as a phone. Unreachable trunks are CRITICAL; unreachable phones are
# only listed (offices close at night) unless you add --phones-warn.
# Exit codes (Nagios/Icinga compatible): 0 OK, 1 WARNING, 2 CRITICAL, 3 UNKNOWN (Asterisk not running, a CLI query
# failed or answered in an unexpected format, bad option).
# Version 1.0.1 (2026-10-17): a failed or malformed CLI query is UNKNOWN (1.0.0 could report OK with zero objects);
#   endpoints without a caller ID (typical for trunks) are now counted; new --require-trunk; notification state is saved per channel only after delivery. Found in an independent review.
# Version 1.0.0 (2026-10-17): first release. Tested on FreePBX 17.0.33 / Asterisk 22.11 (Debian 12) with a
#   registered trunk, a trunk taken down, one reachable and two unreachable phones, and calls in progress.
set -uo pipefail
export LC_ALL=C

RTT_WARN=200; RTT_CRIT=800; MAX_CALLS=0; PHONES_WARN=0; IGNORE=""; JSON=0; QUIET=0; MAIL_TO=""; WEBHOOK=""
NOTIFY_CHANGE=0; STATE_DIR=/var/lib/pjsip-health-check; AST=${ASTERISK_BIN:-asterisk}; TIMEOUT=10; REQUIRE=""

usage() {
  cat <<'EOF'
Usage: pjsip-health-check.sh [options]
  --rtt-warn MS        warn when a reachable contact's round-trip time is above MS (default 200)
  --rtt-crit MS        critical above MS (default 800)
  --max-calls N        warn when more than N calls are active (default 0 = no limit). A sudden jump is a
                       common sign of toll fraud.
  --phones-warn        treat unreachable phones as WARNING (default: listed only)
  --ignore REGEX       skip endpoints whose name matches REGEX (e.g. '^(9[0-9]{3}|test)')
  --json               print the report as JSON
  -q, --quiet          print nothing when everything is OK; problems only
  --mail ADDR          e-mail the report (needs a working 'mail' command) when the status is not OK
  --webhook URL        POST the JSON report to URL (Slack/Discord/Teams-compatible "text" field included)
  --notify-on-change   only send mail/webhook when the set of problems changes (state in /var/lib/pjsip-health-check)
  --state-dir DIR      where the change-detection state is kept
  --require-trunk LIST comma-separated trunk names that must exist; a missing one is CRITICAL (catches a trunk
                       that disappeared from the configuration, which would otherwise just lower the counts)
  --timeout SEC        seconds to wait for each Asterisk CLI command (default 10)
  -h, --help           this help
Environment: ASTERISK_BIN path to the asterisk binary (default: asterisk in PATH)
EOF
}
die() { echo "UNKNOWN: $*" >&2; exit 3; }
num() { [[ "$2" =~ ^[0-9]+$ ]] || die "$1 needs a whole number (got '$2')"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --rtt-warn) num "$1" "${2:-}"; RTT_WARN=$2; shift 2 ;;
    --rtt-crit) num "$1" "${2:-}"; RTT_CRIT=$2; shift 2 ;;
    --max-calls) num "$1" "${2:-}"; MAX_CALLS=$2; shift 2 ;;
    --phones-warn) PHONES_WARN=1; shift ;;
    --ignore) IGNORE="${2:-}"; [ -n "$IGNORE" ] || die "--ignore needs a pattern"; shift 2 ;;
    --json) JSON=1; shift ;;
    -q|--quiet) QUIET=1; shift ;;
    --mail) MAIL_TO="${2:-}"; [[ "$MAIL_TO" == *@* ]] || die "--mail needs an e-mail address"; shift 2 ;;
    --webhook) WEBHOOK="${2:-}"; [[ "$WEBHOOK" =~ ^https?:// ]] || die "--webhook needs an http(s) URL"; shift 2 ;;
    --notify-on-change) NOTIFY_CHANGE=1; shift ;;
    --state-dir) STATE_DIR="${2:-}"; [ -n "$STATE_DIR" ] || die "--state-dir needs a folder"; shift 2 ;;
    --require-trunk) REQUIRE="${2:-}"; [ -n "$REQUIRE" ] || die "--require-trunk needs a name list"; shift 2 ;;
    --timeout) num "$1" "${2:-}"; TIMEOUT=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
done
[ "$RTT_CRIT" -ge "$RTT_WARN" ] || die "--rtt-crit must be >= --rtt-warn"
if [ -n "$IGNORE" ]; then echo "" | grep -Eq -- "$IGNORE" 2>/dev/null; [ $? -le 1 ] || die "--ignore is not a valid regular expression"; fi
command -v "$AST" >/dev/null 2>&1 || die "asterisk binary not found (set ASTERISK_BIN)"

ax() { timeout "$TIMEOUT" "$AST" -rx "$1" 2>/dev/null; }
up=$(ax "core show uptime seconds")
[[ "$up" == *"System uptime:"* ]] || die "cannot talk to Asterisk (is it running, and are you root or in the asterisk group?)"
uptime_s=$(awk -F': ' '/System uptime/{print $2+0}' <<<"$up")
reload_s=$(awk -F': ' '/Last reload/{print $2+0}' <<<"$up")
ver=$(ax "core show version" | awk '{print $2; exit}')
ax "module show like res_pjsip.so" | grep -q 'res_pjsip.so' || die "chan_pjsip/res_pjsip is not loaded on this Asterisk"

STATUS=0; PROBLEMS=(); INFO=(); regs=""; idents=""; ctc=""; eps=""; chancount=""
add() { # level text. UNKNOWN (3) wins over CRITICAL: the check itself could not see the PBX.
  local lv=$1; shift
  case "$lv" in UNKNOWN) STATUS=3 ;; CRIT) [ "$STATUS" -lt 2 ] && STATUS=2 ;; WARN) [ "$STATUS" -lt 1 ] && STATUS=1 ;; esac
  PROBLEMS+=("$lv $*")
}
# q WHAT CMD REGEX: run a CLI command and accept its output only if the command succeeded and the output has
# the expected shape ("No objects found." is a real, valid empty answer). Anything else is UNKNOWN, never a
# healthy zero count.
q() { # VAR WHAT CMD REGEX (sets VAR; runs in this shell so UNKNOWN reaches STATUS)
  local var=$1 what=$2 cmd=$3 re=$4 out rc
  printf -v "$var" '%s' ""
  out=$(timeout "$TIMEOUT" "$AST" -rx "$cmd" 2>&1); rc=$?
  if [ "$rc" -ne 0 ] || ! grep -Eq -- "$re" <<<"$out" || grep -Eqi 'No such command|Unable to connect|permission denied' <<<"$out"; then
    add UNKNOWN "could not read $what ('$cmd' exit $rc$([ "$rc" = 124 ] && echo ', timed out'): $(head -1 <<<"$out" | cut -c1-80))"
    return 1
  fi
  printf -v "$var" '%s' "$out"
}
skip() { [ -n "$IGNORE" ] && grep -Eq -- "$IGNORE" <<<"$1"; }

# Trunk names: endpoints with a registration or identify section, or non-numeric names
q regs registrations "pjsip show registrations" 'No objects found|<Registration|/sip'
q idents identifies "pjsip show identifies" 'No objects found|Identify:'
declare -A TRUNK=()
while read -r n; do [ -n "$n" ] && TRUNK[$n]=1; done < <(awk '/^ *[^ <=]+\/sip:/{split($1,a,"/"); print a[1]}' <<<"$regs")
while read -r n; do [ -n "$n" ] && TRUNK[$n]=1; done < <(awk '$1=="Identify:" && $2 !~ /^</ {split($2,a,"/"); print a[2]}' <<<"$idents")

# 1. Outbound registrations
reg_total=0; reg_ok=0
while read -r line; do
  name=${line%%/*}; name=${name// /}
  skip "$name" && continue
  reg_total=$((reg_total + 1))
  st=$(awk '{for(i=3;i<=NF;i++) if($i ~ /^(Registered|Unregistered|Rejected|Stopped|Retrying)$/){print $i; exit}}' <<<"$line")
  [ -n "$st" ] || st=$(awk '{print $3}' <<<"$line")
  if [ "$st" = "Registered" ]; then reg_ok=$((reg_ok + 1)); else add CRIT "registration $name is $st"; fi
done < <(grep -E '^ *[^ <=]+/sip' <<<"$regs")

# 2. Contacts (qualify reachability and round-trip time)
q ctc contacts "pjsip show contacts" 'No objects found|Contact:'
declare -A AORSTATE=()
c_total=0; c_avail=0
while read -r aor uri status rtt; do
  skip "$aor" && continue
  c_total=$((c_total + 1))
  kind=phone; [ -n "${TRUNK[$aor]:-}" ] && kind=trunk
  case "$status" in
    Avail|Reachable)
      c_avail=$((c_avail + 1)); AORSTATE[$aor]=up
      ms=${rtt%.*}; [[ "$ms" =~ ^[0-9]+$ ]] || ms=0
      if [ "$ms" -ge "$RTT_CRIT" ]; then add CRIT "$kind $aor round-trip ${rtt} ms (>= $RTT_CRIT)";
      elif [ "$ms" -ge "$RTT_WARN" ]; then add WARN "$kind $aor round-trip ${rtt} ms (>= $RTT_WARN)"; fi ;;
    NonQual)
      [ "${AORSTATE[$aor]:-}" = up ] || AORSTATE[$aor]=unqualified
      INFO+=("$kind $aor has qualify off (NonQual): its reachability is not being checked") ;;
    Unknown)
      [ "${AORSTATE[$aor]:-}" = up ] || AORSTATE[$aor]=unqualified
      INFO+=("$kind $aor not qualified yet (status Unknown, normal for a minute after it registers)") ;;
    *)
      [ "${AORSTATE[$aor]:-}" = up ] || AORSTATE[$aor]=down
      if [ "$kind" = trunk ]; then add CRIT "trunk $aor contact $uri is $status";
      elif [ "$PHONES_WARN" = 1 ]; then add WARN "phone $aor contact $uri is $status";
      else INFO+=("phone $aor contact $uri is $status"); fi ;;
  esac
done < <(awk '$1=="Contact:" && $2 ~ /\// && $2 !~ /^</ {split($2,a,"/"); u=substr($2,length(a[1])+2); print a[1], u, $(NF-1), $NF}' <<<"$ctc")

# 3. Endpoints: states, and phones/trunks with no contact at all
q eps endpoints "pjsip show endpoints" 'No objects found|Endpoint:'
declare -A SEEN=()
e_total=0; e_unavail=0; e_inuse=0; nocontact=()
while read -r ename estate; do
  SEEN[$ename]=1
  skip "$ename" && continue
  e_total=$((e_total + 1))
  case "$estate" in
    Unavailable) e_unavail=$((e_unavail + 1)) ;;
    "In use"|Busy|Ringing|"On Hold") e_inuse=$((e_inuse + 1)) ;;
  esac
  if [ "$estate" = Unavailable ] && [ -z "${AORSTATE[$ename]:-}" ]; then
    if [ -n "${TRUNK[$ename]:-}" ]; then add CRIT "trunk $ename is Unavailable (no reachable contact)"; else nocontact+=("$ename"); fi
  fi
done < <(awk '$1=="Endpoint:" && $2 !~ /^<Endpoint/ && NF>=6 {split($2,a,"/"); st=$3; for(i=4;i<=NF-3;i++) st=st" "$i; print a[1], st}' <<<"$eps")
[ "${#nocontact[@]}" -gt 0 ] && {
  msg="${#nocontact[@]} phone(s) not registered: $(printf '%s ' "${nocontact[@]:0:15}")"; [ "${#nocontact[@]}" -gt 15 ] && msg+="..."
  if [ "$PHONES_WARN" = 1 ]; then add WARN "$msg"; else INFO+=("$msg"); fi
}

# Required trunks (only judged when the endpoint list itself could be read)
if [ -n "$REQUIRE" ] && [ -n "$eps" ]; then
  IFS=',' read -ra req <<<"$REQUIRE"
  for t in "${req[@]}"; do t=${t// /}; [ -n "$t" ] && [ -z "${SEEN[$t]:-}" ] && add CRIT "required trunk $t is not configured (no such endpoint)"; done
fi

# 4. Calls in progress
q chancount "active calls" "core show channels count" 'active call'
calls=$(awk '/active call/{print $1+0}' <<<"$chancount")
calls=${calls:-0}
if [ "$MAX_CALLS" -gt 0 ] && [ "$calls" -gt "$MAX_CALLS" ]; then add WARN "$calls active calls (limit $MAX_CALLS): check for toll fraud or a call loop"; fi
[ "$uptime_s" -lt 300 ] && add WARN "Asterisk restarted $uptime_s seconds ago"

label=(OK WARNING CRITICAL UNKNOWN)
host=$(hostname -f 2>/dev/null || hostname)
summary="${label[$STATUS]}: registrations $reg_ok/$reg_total up, contacts $c_avail/$c_total reachable, endpoints $e_total ($e_unavail unavailable, $e_inuse busy), $calls active call(s)"

jstr() { local s=${1//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\t'/ }; printf '"%s"' "${s//$'\n'/ }"; }
json() {
  printf '{"host":%s,"asterisk":%s,"status":%s,"uptime_seconds":%s,"last_reload_seconds":%s,' "$(jstr "$host")" "$(jstr "$ver")" "$(jstr "${label[$STATUS]}")" "${uptime_s:-0}" "${reload_s:-0}"
  printf '"registrations":{"total":%s,"registered":%s},"contacts":{"total":%s,"reachable":%s},' "$reg_total" "$reg_ok" "$c_total" "$c_avail"
  printf '"endpoints":{"total":%s,"unavailable":%s,"busy":%s},"active_calls":%s,"problems":[' "$e_total" "$e_unavail" "$e_inuse" "$calls"
  local i; for i in "${!PROBLEMS[@]}"; do [ "$i" -gt 0 ] && printf ','; jstr "${PROBLEMS[$i]}"; done
  printf '],"info":['; for i in "${!INFO[@]}"; do [ "$i" -gt 0 ] && printf ','; jstr "${INFO[$i]}"; done
  printf '],"text":%s}\n' "$(jstr "$host $summary")"
}
report() {
  echo "PJSIP health on $host (Asterisk $ver, up $((uptime_s / 86400))d $(((uptime_s % 86400) / 3600))h)"
  local p; for p in "${PROBLEMS[@]}"; do echo "  $p"; done
  if [ "$QUIET" = 0 ]; then for p in "${INFO[@]}"; do echo "  info $p"; done; fi
  echo "$summary"
}

if [ "$JSON" = 1 ]; then json; elif [ "$QUIET" = 0 ] || [ "$STATUS" -gt 0 ]; then report; fi

# Notifications. With --notify-on-change the state is saved per channel and only after that channel delivered,
# so a failed mail or webhook is retried on the next run.
deliver() { # channel
  case "$1" in
    mail) command -v mail >/dev/null 2>&1 || { echo "pjsip-health-check: 'mail' command not found, cannot e-mail $MAIL_TO" >&2; return 1; }
          report | mail -s "[PJSIP] ${label[$STATUS]} on $host" "$MAIL_TO" ;;
    webhook) json | curl -fsS -m 15 -H 'Content-Type: application/json' --data-binary @- "$WEBHOOK" >/dev/null ;;
  esac
}
if [ -n "$MAIL_TO$WEBHOOK" ]; then
  sig=$(printf '%s\n' "${label[$STATUS]}" "${PROBLEMS[@]}" | sed -E 's/round-trip [0-9.]+ ms/round-trip/' | sha256sum | cut -c1-16)
  [ "$NOTIFY_CHANGE" = 1 ] && { mkdir -p "$STATE_DIR" 2>/dev/null && chmod 700 "$STATE_DIR" 2>/dev/null; }
  for ch in mail webhook; do
    [ "$ch" = mail ] && [ -z "$MAIL_TO" ] && continue
    [ "$ch" = webhook ] && [ -z "$WEBHOOK" ] && continue
    send=1
    if [ "$NOTIFY_CHANGE" = 1 ]; then
      old=$(cat "$STATE_DIR/last.$ch" 2>/dev/null || true)
      [ "$sig" = "$old" ] && send=0
      [ -z "$old" ] && [ "$STATUS" = 0 ] && { send=0; echo "$sig" > "$STATE_DIR/last.$ch" 2>/dev/null; }  # first run and healthy
    elif [ "$STATUS" = 0 ]; then send=0; fi
    [ "$send" = 1 ] || continue
    if deliver "$ch"; then
      [ "$NOTIFY_CHANGE" = 1 ] && { echo "$sig" > "$STATE_DIR/last.$ch" 2>/dev/null || echo "pjsip-health-check: cannot write $STATE_DIR/last.$ch" >&2; }
    else echo "pjsip-health-check: $ch delivery failed; it will be retried on the next run" >&2; fi
  done
fi
exit "$STATUS"
