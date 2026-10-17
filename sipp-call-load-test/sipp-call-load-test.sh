#!/usr/bin/env bash
# SIPp Call Load Test for Asterisk and FreePBX, Checked Against the CDR (v1.0.1) - from srvScripts.com
# Source, docs and updates: https://srvscripts.com/scripts/sipp-call-load-test/
# Copyright (c) 2026 srvScripts.com. MIT licence: if you copy, share or adapt this script, keep this notice and credit srvScripts.com.
#
# Places a controlled burst of real SIP calls through your PBX as one of its extensions (SIPp registers with the
# extension's password and dials a number you choose), then checks the call records to see how many calls really
# left on a trunk. SIPp alone counts a call as "successful" whenever something answers it with 200 OK, and an
# Asterisk PBX often answers calls itself: a concurrency-limit announcement, an IVR, voicemail or a "number not
# in service" message. This script reports those as false successes.
#
#   SIPP_SECRET='extension password' bash sipp-call-load-test.sh --ext 1002 --number 12125550123 --calls 30 --rate 3 --max 10 --hold 5
#   bash sipp-call-load-test.sh --ext 1002 --secret-file /root/1002.secret --number 12125550123 --calls 200 --rate 10 --max 60 --hold 8 --yes
#
# Run it ON the PBX (default target 127.0.0.1:5060): it then also reads the CDR (FreePBX asteriskcdrdb) and the
# live channel count. A call counts as delivered only when its CDR shows it ANSWERED on one of your trunks: the
# FreePBX trunk list, or the channels you give with --carrier. Call records are matched by extension, number and
# the test's start and end time, so use a test extension that nothing else uses during the test. ANSWERED proves
# signalling and routing, not two-way audio or the final destination.
# Against another PBX use --pbx HOST and --no-cdr; carrier delivery is then NOT verified.
# COST WARNING: every call is a real outbound call. Through a paid SIP trunk it costs money, and bursts to
# international numbers look exactly like toll fraud. Use a test number, a free destination or your own test
# carrier. The script shows the plan and asks for "yes" unless --yes is given.
# The extension password is passed to SIPp in a private injection file (mode 600), never on the command line.
# Exit codes: 0 every requested call was started, answered and (with the CDR) answered on a trunk; 1 failed calls,
# false successes, or an incomplete run (SIPp stopped early, counters missing or not adding up, call records
# missing or mixed with other calls); 2 the test could not run (registration refused, SIPp error, CDR query
# failed); 3 bad option, missing tool or no trunk list.
# Version 1.0.0 (2026-10-17): first release. Tested on FreePBX 17.0.33 / Asterisk 22.11 (Debian 12) with SIPp 3.6
#   and a test carrier: 30 and 200 calls (60 at once), and the false-success case (extension concurrency limit 3).
# Version 1.0.1 (2026-10-17): fixes from an independent review. An incomplete run (SIPp stopped by the time limit,
#   fewer calls started than requested, counters missing) is no longer reported as OK; every count must add up.
#   Carrier delivery is counted only on known trunks (FreePBX trunk list or --carrier), not on any non-Local
#   channel, which also matched extensions. Call records are limited to the test's start and end time and are
#   re-read for up to CDR_WAIT seconds. Fractional rates (--rate 0.5) work; --rate 0 and absurd plans are refused
#   before any call is placed.
set -uo pipefail
export LC_ALL=C
PBX=127.0.0.1:5060; EXT=""; NUM=""; CALLS=20; RATE=2; MAXC=10; HOLD=5; SECRET_FILE=""; CARRIER=""; NOCDR=0; YES=0
LOCAL_IP=""; DB=asteriskcdrdb; AST=${ASTERISK_BIN:-asterisk}
usage() {
  cat <<'EOF'
Usage: sipp-call-load-test.sh --ext EXT --number NUMBER [options]
  --ext EXT            extension SIPp registers as (its password: env SIPP_SECRET or --secret-file)
  --secret-file FILE   file holding only the extension password (keep it mode 600)
  --number NUMBER      number to dial (a test number or test carrier; see the cost warning)
  --calls N            total calls (default 20, max 5000)
  --rate R             new calls per second, 0.01-1000, e.g. 0.5 (default 2)
  --max M              at most M calls at the same time (default 10)
  --hold SEC           seconds each answered call stays up (default 5)
  --pbx HOST[:PORT]    PBX to call through (default 127.0.0.1:5060, i.e. run this on the PBX)
  --local-ip IP        source address for SIPp (default: the address used to reach the PBX)
  --carrier REGEX      count a call as delivered only if its CDR dstchannel matches REGEX (e.g. '^PJSIP/mytrunk-');
                       default: the trunks in the FreePBX trunk list (needed on plain Asterisk)
  --no-cdr             skip the CDR check (remote PBX); delivery to the carrier is then not verified
  --yes                do not ask for confirmation
  -h, --help           this help
Environment: SIPP_SECRET (extension password), MYSQL_ARGS (extra mysql arguments), ASTERISK_BIN,
  CDR_WAIT (seconds to wait for late call records, default 20)
Needs: sipp (Debian/Ubuntu: apt install sip-tester), plus mysql and asterisk on the PBX for the checks.
EOF
}
die() { echo "ERROR: $*" >&2; exit 3; }
num() { [[ "${2:-}" =~ ^[0-9]+$ ]] || die "$1 needs a whole number"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --ext) EXT="${2:-}"; [[ "$EXT" =~ ^[A-Za-z0-9_.+-]+$ ]] || die "--ext: letters, digits, _ . + - only"; shift 2 ;;
    --secret-file) SECRET_FILE="${2:-}"; [ -r "$SECRET_FILE" ] || die "--secret-file: cannot read $SECRET_FILE"; shift 2 ;;
    --number) NUM="${2:-}"; [[ "$NUM" =~ ^[0-9*#+]+$ ]] || die "--number: digits, *, # and + only"; shift 2 ;;
    --calls) num "$1" "${2:-}"; CALLS=$2; shift 2 ;;
    --rate) [[ "${2:-}" =~ ^[0-9]{1,6}(\.[0-9]{1,3})?$ ]] || die "--rate needs a number such as 2 or 0.5"; RATE=$2; shift 2 ;;
    --max) num "$1" "${2:-}"; MAXC=$2; shift 2 ;;
    --hold) num "$1" "${2:-}"; HOLD=$2; shift 2 ;;
    --pbx) PBX="${2:-}"; [[ "$PBX" =~ ^[A-Za-z0-9.:\[\]-]+$ ]] || die "--pbx: invalid host"; shift 2 ;;
    --local-ip) LOCAL_IP="${2:-}"; shift 2 ;;
    --carrier) CARRIER="${2:-}"; [ -n "$CARRIER" ] || die "--carrier needs a pattern"; case "$CARRIER" in *"'"*|*'\'*) die "--carrier: no quotes or backslashes" ;; esac; shift 2 ;;
    --no-cdr) NOCDR=1; shift ;;
    --yes) YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
done
[ -n "$EXT" ] && [ -n "$NUM" ] || { usage >&2; die "--ext and --number are required"; }
[ "$CALLS" -ge 1 ] && [ "$CALLS" -le 5000 ] || die "--calls must be 1-5000"
[ "$MAXC" -ge 1 ] && [ "$HOLD" -ge 1 ] || die "--max and --hold must be at least 1"
[ "$HOLD" -le 3600 ] || die "--hold must be at most 3600"
awk -v r="$RATE" 'BEGIN{exit !(r >= 0.01 && r <= 1000)}' || die "--rate must be between 0.01 and 1000 calls per second"
# time limit for SIPp: the slower of the call rate and the --max/--hold rhythm, plus 50%, plus fixed slack
budget=$(awk -v c="$CALLS" -v r="$RATE" -v m="$MAXC" -v h="$HOLD" 'BEGIN{t=c/r; w=(c/m)*(h+5); if(w>t)t=w; b=t*1.5+h*3+120; printf "%d", (b==int(b))?b:int(b)+1}')
[[ "$budget" =~ ^[0-9]+$ ]] || die "cannot work out the time limit"
[ "$budget" -le 86400 ] || die "this plan would run for more than 24 hours (time limit ${budget}s); raise --rate or --max, or lower --calls"
CDR_WAIT=${CDR_WAIT:-20}; [[ "$CDR_WAIT" =~ ^[0-9]{1,3}$ ]] || die "CDR_WAIT must be 0-999 seconds"
command -v sipp >/dev/null 2>&1 || die "sipp not found (Debian/Ubuntu: apt install sip-tester; RHEL: build from github.com/SIPp/sipp)"
SECRET=${SIPP_SECRET:-}; [ -n "$SECRET_FILE" ] && SECRET=$(head -1 "$SECRET_FILE" | tr -d '\r\n')
[ -n "$SECRET" ] || die "no extension password: set SIPP_SECRET or use --secret-file"
case "$SECRET" in *';'*|*'['*|*']'*|*[[:space:]]*) die "the password contains ';', '[', ']' or a space, which SIPp cannot pass safely; set a simpler test password" ;; esac
host=${PBX%:*}; port=${PBX##*:}; [ "$host" = "$PBX" ] && port=5060
if [ -z "$LOCAL_IP" ]; then
  case "$host" in 127.*|localhost) LOCAL_IP=127.0.0.1 ;;
    *) LOCAL_IP=$(ip route get "$(getent ahostsv4 "$host" | awk 'NR==1{print $1}')" 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="src"){print $(i+1); exit}}') ;; esac
fi
[ -n "$LOCAL_IP" ] || die "cannot work out the local address; use --local-ip"
read -ra MA <<<"${MYSQL_ARGS:-}"
CDR=0
if [ "$NOCDR" = 0 ]; then
  command -v mysql >/dev/null 2>&1 && mysql "${MA[@]}" -N -B "$DB" -e "SELECT 1 FROM cdr LIMIT 1" >/dev/null 2>&1 && CDR=1
  [ "$CDR" = 1 ] || die "cannot read the CDR ($DB.cdr) on this machine; run on the PBX, set MYSQL_ARGS, or use --no-cdr"
  if [ -n "$CARRIER" ]; then
    oncarrier="dstchannel REGEXP '$CARRIER'"; trunks="channels matching --carrier '$CARRIER'"
  else
    # FreePBX trunk list -> dstchannel prefixes (PJSIP/name-, SIP/name-, IAX2/name-, DAHDI/; custom: PJSIP/x@name)
    likes=(); names=()
    while IFS=$'\t' read -r tech chan; do
      pre=""
      case "$tech" in
        pjsip) pre="PJSIP/$chan-" ;; sip) pre="SIP/$chan-" ;; iax|iax2) pre="IAX2/$chan-" ;; dahdi) pre="DAHDI/" ;;
        custom) if [[ "$chan" =~ ^(PJSIP|SIP|IAX2)/[^@]*@([A-Za-z0-9_.-]+) ]]; then pre="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}-"
                elif [[ "$chan" =~ ^(PJSIP|SIP|IAX2)/([A-Za-z0-9_.-]+)(/|$) ]]; then pre="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}-"; fi ;;
      esac
      [[ "$pre" =~ ^[A-Za-z0-9]+/[A-Za-z0-9_.-]*$ ]] || continue
      names+=("$pre"); e=${pre//_/\\_}; likes+=("dstchannel LIKE '$e%'")
    done < <(mysql "${MA[@]}" -N -B asterisk -e "SELECT tech, channelid FROM trunks WHERE disabled <> 'on'" 2>/dev/null)
    [ "${#likes[@]}" -gt 0 ] || die "cannot read the FreePBX trunk list (asterisk.trunks); give your trunk with --carrier '^PJSIP/mytrunk-', or use --no-cdr"
    oncarrier="($(IFS='|'; printf '%s' "${likes[*]}" | sed 's/|/ OR /g'))"; trunks="trunks ${names[*]}"
  fi
fi
HAVE_AST=0; command -v "$AST" >/dev/null 2>&1 && "$AST" -rx "core show version" >/dev/null 2>&1 && HAVE_AST=1

limit=""
[ "$HAVE_AST" = 1 ] && limit=$("$AST" -rx "database get AMPUSER/$EXT concurrency_limit" 2>/dev/null | awk '/^Value:/{print $2}')
echo "Plan: $CALLS call(s) from extension $EXT to $NUM through $host:$port, $RATE new call(s)/s, at most $MAXC at once, ${HOLD}s each."
[ -n "$limit" ] && [ "$limit" != 0 ] && [ "$MAXC" -gt "$limit" ] && \
  echo "Note: FreePBX limits extension $EXT to $limit simultaneous outbound call(s) (Outbound Concurrency Limit). Calls above it are answered by the PBX with an announcement, not sent to the trunk."
[ "$CDR" = 1 ] && echo "Carrier delivery is counted on: $trunks (CDR ANSWERED)."
echo "SIPp is stopped after ${budget}s if it has not finished."
echo "Every call is a real outbound call: through a paid trunk it is billed."
if [ "$YES" = 0 ]; then
  [ -t 0 ] || die "not a terminal: add --yes to confirm"
  read -r -p "Type yes to start: " a; [ "$a" = yes ] || { echo "Cancelled."; exit 0; }
fi

W=$(mktemp -d) || die "mktemp failed"; trap 'kill "${SMP:-}" 2>/dev/null; rm -rf "$W"' EXIT
chmod 700 "$W"; cd "$W" || exit 3
# SIPp 3.6 does not expand [fieldN] inside [authentication ...], but it does expand an authentication keyword
# that comes from the injection file, so the whole keyword (with the password) lives in this private file.
( umask 077; printf 'SEQUENTIAL\n%s;[authentication username=%s password=%s];\n' "$EXT" "$EXT" "$SECRET" > "$W/auth.csv" )
cat > "$W/phone.xml" <<'XML'
<?xml version="1.0" encoding="ISO-8859-1" ?>
<!DOCTYPE scenario SYSTEM "sipp.dtd">
<!-- srvScripts sipp-call-load-test: register with digest auth, call [service], hold for -d ms, hang up. -->
<scenario name="srvscripts call load test">
  <send retrans="500"><![CDATA[
REGISTER sip:[remote_ip] SIP/2.0
Via: SIP/2.0/[transport] [local_ip]:[local_port];branch=[branch]
From: <sip:[field0]@[remote_ip]>;tag=[pid]reg[call_number]
To: <sip:[field0]@[remote_ip]>
Call-ID: [call_id]
CSeq: 1 REGISTER
Contact: <sip:[field0]@[local_ip]:[local_port]>
Max-Forwards: 70
Expires: 120
User-Agent: srvScripts-sipp-load-test
Content-Length: 0

]]></send>
  <recv response="401" auth="true"/>
  <send retrans="500"><![CDATA[
REGISTER sip:[remote_ip] SIP/2.0
Via: SIP/2.0/[transport] [local_ip]:[local_port];branch=[branch]
From: <sip:[field0]@[remote_ip]>;tag=[pid]reg[call_number]
To: <sip:[field0]@[remote_ip]>
Call-ID: [call_id]
CSeq: 2 REGISTER
Contact: <sip:[field0]@[local_ip]:[local_port]>
[field1]
Max-Forwards: 70
Expires: 120
User-Agent: srvScripts-sipp-load-test
Content-Length: 0

]]></send>
  <recv response="200"/>
  <pause milliseconds="300"/>
  <send retrans="500"><![CDATA[
INVITE sip:[service]@[remote_ip] SIP/2.0
Via: SIP/2.0/[transport] [local_ip]:[local_port];branch=[branch]
From: <sip:[field0]@[remote_ip]>;tag=[pid]inv[call_number]
To: <sip:[service]@[remote_ip]>
Call-ID: [call_id]
CSeq: 1 INVITE
Contact: <sip:[field0]@[local_ip]:[local_port]>
Max-Forwards: 70
User-Agent: srvScripts-sipp-load-test
Content-Type: application/sdp
Content-Length: [len]

v=0
o=sipp 53655765 2353687637 IN IP[local_ip_type] [local_ip]
s=-
c=IN IP[media_ip_type] [media_ip]
t=0 0
m=audio [media_port] RTP/AVP 0 8
a=rtpmap:0 PCMU/8000
a=rtpmap:8 PCMA/8000
]]></send>
  <recv response="401" auth="true" optional="true" next="authinv"/>
  <recv response="407" auth="true"/>
  <label id="authinv"/>
  <send><![CDATA[
ACK sip:[service]@[remote_ip] SIP/2.0
Via: SIP/2.0/[transport] [local_ip]:[local_port];branch=[branch]
From: <sip:[field0]@[remote_ip]>;tag=[pid]inv[call_number]
To: <sip:[service]@[remote_ip]>[peer_tag_param]
Call-ID: [call_id]
CSeq: 1 ACK
Max-Forwards: 70
Content-Length: 0

]]></send>
  <send retrans="500"><![CDATA[
INVITE sip:[service]@[remote_ip] SIP/2.0
Via: SIP/2.0/[transport] [local_ip]:[local_port];branch=[branch]
From: <sip:[field0]@[remote_ip]>;tag=[pid]inv[call_number]
To: <sip:[service]@[remote_ip]>
Call-ID: [call_id]
CSeq: 2 INVITE
Contact: <sip:[field0]@[local_ip]:[local_port]>
[field1]
Max-Forwards: 70
User-Agent: srvScripts-sipp-load-test
Content-Type: application/sdp
Content-Length: [len]

v=0
o=sipp 53655765 2353687637 IN IP[local_ip_type] [local_ip]
s=-
c=IN IP[media_ip_type] [media_ip]
t=0 0
m=audio [media_port] RTP/AVP 0 8
a=rtpmap:0 PCMU/8000
a=rtpmap:8 PCMA/8000
]]></send>
  <recv response="100" optional="true"/>
  <recv response="180" optional="true"/>
  <recv response="183" optional="true"/>
  <recv response="200" rtd="true"/>
  <send><![CDATA[
ACK sip:[service]@[remote_ip] SIP/2.0
Via: SIP/2.0/[transport] [local_ip]:[local_port];branch=[branch]
From: <sip:[field0]@[remote_ip]>;tag=[pid]inv[call_number]
To: <sip:[service]@[remote_ip]>[peer_tag_param]
Call-ID: [call_id]
CSeq: 2 ACK
Max-Forwards: 70
Content-Length: 0

]]></send>
  <pause/>
  <send retrans="500"><![CDATA[
BYE sip:[service]@[remote_ip] SIP/2.0
Via: SIP/2.0/[transport] [local_ip]:[local_port];branch=[branch]
From: <sip:[field0]@[remote_ip]>;tag=[pid]inv[call_number]
To: <sip:[service]@[remote_ip]>[peer_tag_param]
Call-ID: [call_id]
CSeq: 3 BYE
Max-Forwards: 70
Content-Length: 0

]]></send>
  <recv response="200" crlf="true"/>
  <ResponseTimeRepartition value="50, 100, 200, 500"/>
</scenario>
XML

# sample the live channel count once a second (PBX only)
echo 0 > "$W/peak"
if [ "$HAVE_AST" = 1 ]; then
  ( p=0; while sleep 1; do c=$("$AST" -rx "core show channels count" 2>/dev/null | awk '/active call/{print $1+0}'); [ "${c:-0}" -gt "$p" ] && { p=$c; echo "$p" > "$W/peak"; }; done ) & SMP=$!
fi
t0=$(date +%s); since=$(date -d "@$((t0 - 2))" '+%F %T'); load0=$(cut -d' ' -f1 /proc/loadavg)
lport=$((20000 + RANDOM % 20000))
timeout "$budget" sipp "$host:$port" -sf "$W/phone.xml" -inf "$W/auth.csv" -s "$NUM" -i "$LOCAL_IP" -p "$lport" \
  -m "$CALLS" -r "$RATE" -l "$MAXC" -d $((HOLD * 1000)) -nostdin -trace_screen -trace_err -error_file "$W/err.log" >/dev/null 2>&1
src=$?
t1=$(date +%s); secs=$(( t1 - t0 )); until=$(date -d "@$((t1 + 2))" '+%F %T'); [ -n "${SMP:-}" ] && kill "$SMP" 2>/dev/null; sleep 1
scr=$(ls "$W"/phone_*_screen.log 2>/dev/null | head -1)
[ -n "$scr" ] || { echo "ERROR: SIPp produced no results (exit $src). First error lines:"; head -5 "$W/err.log" 2>/dev/null; exit 2; }
# cumulative counters from the final statistics screen; empty when the line is missing or not a number
cnt() { awk -F'|' -v k="$1" -v f="$2" '$1 ~ "^ *"k" *$" {v=$f; gsub(/[ \t]/,"",v); if (v ~ /^[0-9]+$/) r=v} END{print r}' "$scr"; }
created=$(cnt "Total Calls? created" 3); okc=$(cnt "Successful call" 3); failc=$(cnt "Failed call" 3); cur=$(cnt "Current Calls?" 2)
reg401=$(awk '$1=="REGISTER"{n++} n==2 && $1=="200"{print $3; exit}' "$scr")

echo
echo "SIPp: ${created:-?} of $CALLS call(s) started, ${okc:-?} answered (200 OK), ${failc:-?} failed, in ${secs}s (exit $src)"
grep -E "^ *(REGISTER|INVITE|ACK|BYE|[1-6][0-9][0-9]) +(-+>|<-+)" "$scr" | sed "s/E-RTD1//" | \
  awk 'BEGIN{printf "  %-9s %-5s %9s %8s %8s %11s\n","message","dir","count","retrans","timeout","unexpected"} {d=($2 ~ /^-/)?"send":"recv"; printf "  %-9s %-5s %9s %8s %8s %11s\n",$1,d,$3,$4,$5,$6}'
[ "$HAVE_AST" = 1 ] && echo "Peak simultaneous calls in Asterisk: $(cat "$W/peak")"
echo "Load average before/after: $load0 / $(cut -d' ' -f1 /proc/loadavg)"
if [ "${created:-}" = 0 ]; then
  echo "ERROR: SIPp started no calls (exit $src). First error lines:"; head -5 "$W/err.log" 2>/dev/null; exit 2
fi
if [ "${okc:-0}" = 0 ] && grep -qE "40[13] |Forbidden" "$scr" 2>/dev/null && [ "${reg401:-0}" = 0 ]; then
  echo "Registration was refused: check the extension number and password."; exit 2
fi

rc=0; inc=0
incomplete() { echo "INCOMPLETE: $*"; inc=1; rc=1; }
case "$src" in
  0|1) ;;
  124) incomplete "SIPp did not finish within ${budget}s and was stopped; the counts below are not the full test" ;;
  *) incomplete "SIPp exited with code $src (an error or an aborted run)" ;;
esac
if [ -z "$created" ] || [ -z "$okc" ] || [ -z "$failc" ]; then
  incomplete "SIPp's call counters are missing from its results, so the outcome is unknown"
else
  [ "$created" = "$CALLS" ] || incomplete "$created of $CALLS requested call(s) were started"
  [ $((okc + failc)) = "$created" ] || incomplete "$created call(s) started but only $((okc + failc)) finished (answered or failed)"
  [ "$src" = 1 ] && [ "$failc" = 0 ] && incomplete "SIPp reported failure (exit 1) but counted no failed call"
fi
[ -n "$cur" ] && [ "$cur" != 0 ] && incomplete "$cur call(s) were still up when SIPp ended"
if [ "$CDR" = 1 ]; then
  where="calldate BETWEEN '$since' AND '$until' AND src = '$EXT' AND dst LIKE '%$NUM'"
  cond="$oncarrier AND disposition = 'ANSWERED'"
  q="SELECT COUNT(DISTINCT uniqueid), COUNT(DISTINCT CASE WHEN $cond THEN uniqueid END) FROM cdr WHERE $where"
  # call records are written when a call ends: re-read until the count stops changing (at most CDR_WAIT seconds)
  waited=0; prev=""
  while :; do
    res=$(mysql "${MA[@]}" -N -B "$DB" -e "$q" 2>"$W/sql.err") || { echo "ERROR: CDR query failed: $(head -1 "$W/sql.err")"; exit 2; }
    read -r cdr_total delivered <<<"$res"
    [[ "${cdr_total:-}" =~ ^[0-9]+$ ]] && [[ "${delivered:-}" =~ ^[0-9]+$ ]] || { echo "ERROR: unexpected CDR query result"; exit 2; }
    [ "$cdr_total" -ge "${created:-$CALLS}" ] && [ "$res" = "$prev" ] && break
    [ "$waited" -ge "$CDR_WAIT" ] && break
    prev=$res; sleep 2; waited=$((waited + 2))
  done
  echo "Call records from $since to $until: $cdr_total call(s) from $EXT to $NUM; answered on a listed trunk: $delivered of $CALLS"
  if [ "$cdr_total" -gt "$CALLS" ]; then
    echo "WARNING: there are more call records ($cdr_total) than calls placed ($CALLS): another call from $EXT to $NUM happened"
    echo "  during the test, so the counts cannot be trusted. Use a test extension that nothing else uses."; rc=1
  elif [ -n "$okc" ] && [ "$cdr_total" -lt "$okc" ]; then
    echo "WARNING: only $cdr_total call record(s) for $okc answered call(s) after waiting ${waited}s: the CDR is late or not"
    echo "  writing these calls (check CDR_WAIT and that CDR logging is on)."; rc=1
  fi
  self=$(( ${okc:-0} - delivered )); [ "$self" -lt 0 ] && self=0
  if [ "$self" -gt 0 ]; then
    echo "WARNING: $self call(s) counted as successful by SIPp were not answered on a listed trunk: the PBX itself or an"
    echo "  internal phone answered them (typical causes: the outbound concurrency limit, an announcement, IVR or voicemail)."
    mysql "${MA[@]}" -N -B "$DB" -e "SELECT lastapp, COUNT(*) FROM cdr WHERE $where AND NOT ($cond) GROUP BY lastapp ORDER BY 2 DESC LIMIT 5" 2>/dev/null | \
      awk -F'\t' '{printf "  answered by %s: %s call(s)\n", ($1==""?"(unknown)":$1), $2}'
    rc=1
  fi
  [ "$delivered" = "$CALLS" ] || rc=1
else
  echo "Carrier delivery NOT verified (--no-cdr): a 200 OK only proves that something answered."
fi
[ "${failc:-0}" -gt 0 ] && { echo "WARNING: ${failc} call(s) failed; first SIPp errors:"; grep -m3 -E "Aborting|unexpected|failed" "$W/err.log" | cut -c1-160; rc=1; }
[ "$rc" = 0 ] && { [ "$okc" = "$CALLS" ] && [ "$failc" = 0 ] && [ "$src" = 0 ] && [ "$inc" = 0 ] || rc=1; }
if [ "$rc" = 0 ]; then
  if [ "$CDR" = 1 ]; then echo "OK: all $CALLS call(s) were started, answered and answered on a listed trunk (CDR). This shows signalling and"
    echo "  routing work at this load; it does not prove two-way audio or the final destination."
  else echo "OK: all $CALLS call(s) were started and answered (200 OK); delivery to the carrier was NOT verified."; fi
else
  echo "NOT OK: see the lines above."
fi
exit "$rc"
