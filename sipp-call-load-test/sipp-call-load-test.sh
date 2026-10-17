#!/usr/bin/env bash
# SIPp Call Load Test for Asterisk and FreePBX, Checked Against the CDR (v1.0.0) - from srvScripts.com
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
# live channel count. Against another PBX use --pbx HOST and --no-cdr; carrier delivery is then NOT verified.
# COST WARNING: every call is a real outbound call. Through a paid SIP trunk it costs money, and bursts to
# international numbers look exactly like toll fraud. Use a test number, a free destination or your own test
# carrier. The script shows the plan and asks for "yes" unless --yes is given.
# The extension password is passed to SIPp in a private injection file (mode 600), never on the command line.
# Exit codes: 0 every call was answered on a trunk, 1 failed calls or false successes, 2 the test could not run
# (registration refused, SIPp error), 3 bad option or missing tool.
# Version 1.0.0 (2026-10-17): first release. Tested on FreePBX 17.0.33 / Asterisk 22.11 (Debian 12) with SIPp 3.6
#   and a test carrier: 30 and 200 calls (60 at once), and the false-success case (extension concurrency limit 3).
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
  --rate R             new calls per second (default 2)
  --max M              at most M calls at the same time (default 10)
  --hold SEC           seconds each answered call stays up (default 5)
  --pbx HOST[:PORT]    PBX to call through (default 127.0.0.1:5060, i.e. run this on the PBX)
  --local-ip IP        source address for SIPp (default: the address used to reach the PBX)
  --carrier REGEX      count a call as delivered only if its CDR dstchannel matches REGEX (e.g. 'PJSIP/mytrunk-');
                       default: any answered call that left on a non-Local channel
  --no-cdr             skip the CDR check (remote PBX); delivery to the carrier is then not verified
  --yes                do not ask for confirmation
  -h, --help           this help
Environment: SIPP_SECRET (extension password), MYSQL_ARGS (extra mysql arguments), ASTERISK_BIN
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
    --rate) [[ "${2:-}" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "--rate needs a number"; RATE=$2; shift 2 ;;
    --max) num "$1" "${2:-}"; MAXC=$2; shift 2 ;;
    --hold) num "$1" "${2:-}"; HOLD=$2; shift 2 ;;
    --pbx) PBX="${2:-}"; [[ "$PBX" =~ ^[A-Za-z0-9.:\[\]-]+$ ]] || die "--pbx: invalid host"; shift 2 ;;
    --local-ip) LOCAL_IP="${2:-}"; shift 2 ;;
    --carrier) CARRIER="${2:-}"; [ -n "$CARRIER" ] || die "--carrier needs a pattern"; shift 2 ;;
    --no-cdr) NOCDR=1; shift ;;
    --yes) YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
done
[ -n "$EXT" ] && [ -n "$NUM" ] || { usage >&2; die "--ext and --number are required"; }
[ "$CALLS" -ge 1 ] && [ "$CALLS" -le 5000 ] || die "--calls must be 1-5000"
[ "$MAXC" -ge 1 ] && [ "$HOLD" -ge 1 ] || die "--max and --hold must be at least 1"
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
fi
HAVE_AST=0; command -v "$AST" >/dev/null 2>&1 && "$AST" -rx "core show version" >/dev/null 2>&1 && HAVE_AST=1

limit=""
[ "$HAVE_AST" = 1 ] && limit=$("$AST" -rx "database get AMPUSER/$EXT concurrency_limit" 2>/dev/null | awk '/^Value:/{print $2}')
echo "Plan: $CALLS call(s) from extension $EXT to $NUM through $host:$port, $RATE new call(s)/s, at most $MAXC at once, ${HOLD}s each."
[ -n "$limit" ] && [ "$limit" != 0 ] && [ "$MAXC" -gt "$limit" ] && \
  echo "Note: FreePBX limits extension $EXT to $limit simultaneous outbound call(s) (Outbound Concurrency Limit). Calls above it are answered by the PBX with an announcement, not sent to the trunk."
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
budget=$(( CALLS * 2 / ${RATE%.*} + HOLD * 3 + 120 )); [ "${RATE%.*}" -ge 1 ] 2>/dev/null || budget=$(( CALLS * 4 + HOLD * 3 + 120 ))
timeout "$budget" sipp "$host:$port" -sf "$W/phone.xml" -inf "$W/auth.csv" -s "$NUM" -i "$LOCAL_IP" -p "$lport" \
  -m "$CALLS" -r "$RATE" -l "$MAXC" -d $((HOLD * 1000)) -nostdin -trace_screen -trace_err -error_file "$W/err.log" >/dev/null 2>&1
src=$?
secs=$(( $(date +%s) - t0 )); [ -n "${SMP:-}" ] && kill "$SMP" 2>/dev/null; sleep 1
scr=$(ls "$W"/phone_*_screen.log 2>/dev/null | head -1)
[ -n "$scr" ] || { echo "ERROR: SIPp produced no results (exit $src). First error lines:"; head -5 "$W/err.log" 2>/dev/null; exit 2; }
okc=$(awk -F'|' '/Successful call/{gsub(/ /,"",$3); print $3+0; exit}' "$scr"); failc=$(awk -F'|' '/Failed call/{gsub(/ /,"",$3); print $3+0; exit}' "$scr")
reg401=$(awk '$1=="REGISTER"{n++} n==2 && $1=="200"{print $3; exit}' "$scr")

echo
echo "SIPp: ${okc:-0} call(s) answered (200 OK), ${failc:-0} failed, in ${secs}s"
grep -E "^ *(REGISTER|INVITE|ACK|BYE|[1-6][0-9][0-9]) +(-+>|<-+)" "$scr" | sed "s/E-RTD1//" | \
  awk 'BEGIN{printf "  %-9s %-5s %9s %8s %8s %11s\n","message","dir","count","retrans","timeout","unexpected"} {d=($2 ~ /^-/)?"send":"recv"; printf "  %-9s %-5s %9s %8s %8s %11s\n",$1,d,$3,$4,$5,$6}'
[ "$HAVE_AST" = 1 ] && echo "Peak simultaneous calls in Asterisk: $(cat "$W/peak")"
echo "Load average before/after: $load0 / $(cut -d' ' -f1 /proc/loadavg)"
if [ "${okc:-0}" = 0 ] && grep -qE "40[13] |Forbidden" "$scr" 2>/dev/null && [ "${reg401:-0}" = 0 ]; then
  echo "Registration was refused: check the extension number and password."; exit 2
fi

rc=0
if [ "$CDR" = 1 ]; then
  sleep 2
  where="calldate >= '$since' AND src = '$EXT' AND dst LIKE '%$NUM'"
  cond="dstchannel <> '' AND dstchannel NOT LIKE 'Local/%' AND disposition = 'ANSWERED'"
  [ -n "$CARRIER" ] && cond="dstchannel REGEXP '${CARRIER//\'/}' AND disposition = 'ANSWERED'"
  res=$(mysql "${MA[@]}" -N -B "$DB" -e "SELECT COUNT(DISTINCT uniqueid), COUNT(DISTINCT CASE WHEN $cond THEN uniqueid END) FROM cdr WHERE $where" 2>"$W/sql.err") \
    || { echo "ERROR: CDR query failed: $(head -1 "$W/sql.err")"; exit 2; }
  read -r cdr_total delivered <<<"$res"
  self=$(( ${okc:-0} - ${delivered:-0} )); [ "$self" -lt 0 ] && self=0
  echo "Call records: $cdr_total call(s) from $EXT to $NUM; answered on a trunk: $delivered of $CALLS"
  if [ "$self" -gt 0 ]; then
    echo "WARNING: $self call(s) counted as successful by SIPp were answered by the PBX itself, not by the carrier"
    echo "  (typical causes: the extension's outbound concurrency limit, an announcement, an IVR or voicemail)."
    mysql "${MA[@]}" -N -B "$DB" -e "SELECT lastapp, COUNT(*) FROM cdr WHERE $where AND NOT ($cond) GROUP BY lastapp ORDER BY 2 DESC LIMIT 5" 2>/dev/null | \
      awk -F'\t' '{printf "  answered by %s: %s call(s)\n", ($1==""?"(unknown)":$1), $2}'
    rc=1
  fi
else
  echo "Carrier delivery NOT verified (--no-cdr): a 200 OK only proves that something answered."
fi
[ "${failc:-0}" -gt 0 ] && { echo "WARNING: ${failc} call(s) failed; first SIPp errors:"; grep -m3 -E "Aborting|unexpected|failed" "$W/err.log" | cut -c1-160; rc=1; }
if [ "$rc" = 0 ]; then
  if [ "$CDR" = 1 ]; then echo "OK: all $CALLS call(s) were answered on a trunk."; else echo "OK: all $CALLS call(s) answered (delivery not verified)."; fi
fi
exit "$rc"
