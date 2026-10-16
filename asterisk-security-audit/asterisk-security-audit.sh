#!/usr/bin/env bash
# Asterisk and FreePBX Security Audit: Toll Fraud, Exposed Ports, Weak Secrets, Fail2ban (v1.0.1) - from srvScripts.com
# Source, docs and updates: https://srvscripts.com/scripts/asterisk-security-audit/
# Copyright (c) 2026 srvScripts.com. MIT licence: if you copy, share or adapt this script, keep this notice and credit srvScripts.com.
#
# Read-only security audit for an Asterisk PBX (FreePBX 15-17, plain Asterisk 18+, VitalPBX, Issabel). It checks the
# things that lead to toll fraud and hijacked PBXs: unsupported Asterisk versions, services listening on public
# addresses (IAX2, H.323, AMI, ARI...), weak or guessable SIP passwords, guest/anonymous SIP, trunks trusted by IP
# into internal contexts, a fail2ban jail that cannot see Asterisk's security log, missing firewall rules,
# international dialling without a PIN, and readable call recordings. Every finding has a one-line fix.
# Nothing is changed and no password is ever printed: weak secrets are reported by object name only.
#
#   bash asterisk-security-audit.sh            # full report
#   bash asterisk-security-audit.sh --json     # JSON for monitoring
#   bash asterisk-security-audit.sh --fails-only
#
# Exit codes: 0 no warnings, 1 warnings only, 2 at least one FAIL, 3 could not run or a check could not run (UNKNOWN,
# e.g. Asterisk or the FreePBX database not readable) and nothing failed.
# Run as root (it reads /etc/asterisk, the FreePBX database and the firewall).
# Version 1.0.1 (2026-10-17): a CLI or database query that fails is reported as UNKNOWN (exit 3) instead of a PASS
#   built on empty data (anonymous endpoint, IP trust, international routes, FreePBX database). Found in an
#   independent review.
# Version 1.0.0 (2026-10-17): first release. Tested on FreePBX 17.0.33 / Asterisk 22.11 on Debian 12 (fresh
#   --opensourceonly install with a trunk, 3 extensions and international routes).
set -uo pipefail
export LC_ALL=C

JSON=0; FAILS_ONLY=0; CONF=/etc/asterisk; AST=${ASTERISK_BIN:-asterisk}; read -ra _MA <<<"${MYSQL_ARGS:-}"; MYSQL=(mysql "${_MA[@]}" -N -B)
MINLEN=12; TODAY=$(date +%F)

usage() {
  cat <<'EOF'
Usage: asterisk-security-audit.sh [options]
  --json            print findings as JSON
  --fails-only      print FAIL lines only (plus the summary)
  --min-secret N    minimum SIP/AMI password length (default 12)
  --conf DIR        Asterisk config folder (default /etc/asterisk)
  -h, --help        this help
Environment: ASTERISK_BIN (default asterisk), MYSQL_ARGS extra mysql client arguments for the FreePBX database
EOF
}
die() { echo "UNKNOWN: $*" >&2; exit 3; }
while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON=1; shift ;;
    --fails-only) FAILS_ONLY=1; shift ;;
    --min-secret) [[ "${2:-}" =~ ^[0-9]+$ ]] || die "--min-secret needs a number"; MINLEN=$2; shift 2 ;;
    --conf) CONF="${2:-}"; [ -d "$CONF" ] || die "--conf: no such folder"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
done
[ "$EUID" -eq 0 ] || die "run as root (reads /etc/asterisk, the firewall and the FreePBX database)"
command -v "$AST" >/dev/null 2>&1 || die "asterisk binary not found"
ax() { timeout 10 "$AST" -rx "$1" 2>/dev/null; }
# axc VAR CMD REGEX: checked CLI query; VAR is set only when the command succeeded and its output has the expected
# shape. Returns 1 otherwise, so the caller reports UNKNOWN instead of a PASS built on empty data.
axc() { local out rc; out=$(timeout 10 "$AST" -rx "$2" 2>&1); rc=$?; printf -v "$1" '%s' "$out"
  [ "$rc" -eq 0 ] && grep -Eq -- "$3" <<<"$out" && ! grep -Eqi 'No such command|Unable to connect' <<<"$out"; }
VER=$(ax "core show version" | awk '/^Asterisk/{print $2; exit}')
[ -n "$VER" ] || die "cannot talk to Asterisk (is it running?)"

declare -a SEV=() ID=() MSG=() FIX=()
f() { SEV+=("$1"); ID+=("$2"); MSG+=("$3"); FIX+=("${4:-}"); }   # severity id message fix
FREEPBX=0; FPBX_FILE=0; [ -r /etc/freepbx.conf ] && FPBX_FILE=1
if [ "$FPBX_FILE" = 1 ]; then
  if "${MYSQL[@]}" asterisk -e "SELECT 1" >/dev/null 2>&1; then FREEPBX=1
  else f UNKNOWN freepbx_db "FreePBX is installed but its database cannot be queried: the route and admin-user checks were NOT run" "Check that MariaDB runs, or pass credentials in MYSQL_ARGS, then run the audit again."; fi
fi

# 1. Asterisk version support (dates from docs.asterisk.org/About-the-Project/Asterisk-Versions/, checked 2026-10-17)
major=${VER%%.*}; major=${major//[^0-9]/}
eol=""; secfix=""
case "$major" in
  16) eol=2023-10-09 ;; 17) eol=2020-09-30 ;; 18) eol=2025-10-20 ;; 19) eol=2022-11-02 ;;
  20) secfix=2026-10-19; eol=2027-10-19 ;; 21) secfix=2025-10-18; eol=2026-10-18 ;;
  22) secfix=2028-10-16; eol=2029-10-16 ;; 23) secfix=2026-10-15; eol=2027-10-15 ;; 24) secfix=2030-10-15; eol=2031-10-15 ;;
esac
if [ -z "$eol" ]; then
  if [ -n "$major" ] && [ "$major" -lt 16 ]; then f FAIL version "Asterisk $VER is long out of support" "Upgrade to Asterisk 22 LTS (FreePBX 17)."
  else f INFO version "Asterisk $VER: support dates not in this script's table" "Check docs.asterisk.org/About-the-Project/Asterisk-Versions/"; fi
elif [[ "$TODAY" > "$eol" ]]; then f FAIL version "Asterisk $VER reached end of life on $eol: no more security fixes" "Upgrade to Asterisk 22 LTS (FreePBX 17) or newer."
elif [ -n "$secfix" ] && [[ "$TODAY" > "$secfix" ]]; then f WARN version "Asterisk $VER gets security fixes only until $eol" "Plan the move to a current LTS (22) before $eol."
else f PASS version "Asterisk $VER is supported (end of life $eol)"; fi
grep -q 'chan_sip.so' <<<"$(ax "module show like chan_sip.so")" && f WARN chan_sip "chan_sip is loaded (deprecated, removed in Asterisk 21)" "Move extensions and trunks to PJSIP, then noload => chan_sip.so"

# 2. Process user
au=$(ps -o user= -C asterisk 2>/dev/null | head -1)
if [ "$au" = root ]; then f WARN runuser "Asterisk runs as root" "Run it as the asterisk user (AST_USER/AST_GROUP or the FreePBX default)."
elif [ -n "$au" ]; then f PASS runuser "Asterisk runs as user '$au'"; fi

# 3. What Asterisk listens on (public addresses)
pub=()
while read -r proto addr; do
  port=${addr##*:}; ip=${addr%:*}; ip=${ip#[}; ip=${ip%]}
  case "$ip" in 127.*|::1|localhost) continue ;; esac
  pub+=("$proto/$port")
done < <(ss -H -lntup 2>/dev/null | awk '/"asterisk"/{print $1, $5}' | sort -u)
odd=(); for p in "${pub[@]}"; do
  case "$p" in udp/5060|tcp/5060|tcp/5061|udp/5061) ;; *) odd+=("$p") ;; esac
done
declare -A PNAME=([udp/4569]="IAX2" [udp/4520]="DUNDi" [tcp/1720]="H.323 (chan_ooh323)" [udp/5000]="UNISTIM" [udp/2727]="MGCP" [tcp/2000]="Skinny" [tcp/5038]="AMI" [tcp/8088]="HTTP/ARI" [tcp/8089]="HTTPS/ARI")
if [ "${#odd[@]}" -gt 0 ]; then
  list=""; for p in "${odd[@]}"; do [[ "$p" == udp/[1-9][0-9][0-9][0-9][0-9] && -z "${PNAME[$p]:-}" ]] && continue; list+="$p${PNAME[$p]:+ (${PNAME[$p]})} "; done
  [ -n "$list" ] && f WARN listeners "Asterisk listens on public addresses for: $list" "noload unused channel drivers (chan_iax2, pbx_dundi, chan_ooh323, chan_unistim) in modules.conf, or block those ports in the firewall."
fi
[ "${#pub[@]}" -gt 0 ] && f INFO sip_ports "Asterisk public listeners: ${pub[*]}"

# 4. AMI
ami_bind=$(awk -F= '/^\[general\]/{g=1;next} /^\[/{g=0} g && $1 ~ /^[ \t]*bindaddr/ {gsub(/[ \t]/,"",$2); print $2}' "$CONF/manager.conf" 2>/dev/null | tail -1)
ami_on=$(awk -F= '/^\[general\]/{g=1;next} /^\[/{g=0} g && $1 ~ /^[ \t]*enabled/ {gsub(/[ \t]/,"",$2); print $2}' "$CONF/manager.conf" 2>/dev/null | tail -1)
if [ "${ami_on:-no}" = yes ]; then
  case "${ami_bind:-0.0.0.0}" in 127.*|::1) f PASS ami "AMI listens on $ami_bind only" ;;
    *) f FAIL ami "AMI (port 5038) listens on ${ami_bind:-0.0.0.0}" "Set bindaddr = 127.0.0.1 in manager.conf (FreePBX: Advanced Settings > Asterisk Manager)." ;; esac
  weak=""
  for fcf in "$CONF"/manager.conf "$CONF"/manager_additional.conf "$CONF"/manager_custom.conf; do
    [ -r "$fcf" ] || continue
    weak+=$(awk -v min="$MINLEN" -F= '/^\[/{u=$0; gsub(/[\[\]]/,"",u)} $1 ~ /^[ \t]*secret[ \t]*$/ {s=$2; gsub(/^[ \t]+|[ \t]+$/,"",s); if(length(s)<min || s ~ /^[0-9]+$/ || s==u) printf "%s ", u}' "$fcf")
  done
  [ -n "$weak" ] && f WARN ami_secret "AMI users with short or guessable secrets: $weak" "Use random secrets of $MINLEN+ characters (secrets not shown)."
fi

# 5. HTTP / ARI
hb=$(cat "$CONF"/http.conf "$CONF"/http_additional.conf "$CONF"/http_custom.conf 2>/dev/null | awk -F= '$1 ~ /^[ \t]*bindaddr/ {gsub(/[ \t]/,"",$2); b=$2} $1 ~ /^[ \t]*enabled/ {gsub(/[ \t]/,"",$2); e=$2} END{print e, b}')
read -r h_en h_bind <<<"$hb"
if [ "${h_en:-no}" = yes ]; then
  case "${h_bind:-0.0.0.0}" in 127.*|::1) f PASS http "Asterisk HTTP/ARI listens on $h_bind only" ;;
    *) f WARN http "Asterisk HTTP/ARI server listens on ${h_bind:-0.0.0.0}" "Bind it to 127.0.0.1 unless WebRTC phones need it; then firewall it." ;; esac
fi

# 6. Anonymous / guest SIP
anon=""
if ! axc anon "pjsip show endpoint anonymous" 'Endpoint:|Unable to find object'; then
  f UNKNOWN anonymous "Could not check for an anonymous PJSIP endpoint (CLI query failed)" "Run: asterisk -rx 'pjsip show endpoint anonymous'"
elif grep -q 'Endpoint:' <<<"$anon"; then
  ctx=$(awk '$1=="context"{print $3; exit}' <<<"$anon")
  f WARN anonymous "PJSIP 'anonymous' endpoint exists (context ${ctx:-?}): unauthenticated calls are accepted" "FreePBX: Settings > Asterisk SIP Settings > Allow Anonymous Inbound SIP Calls = No, unless you need it."
else f PASS anonymous "No anonymous (guest) PJSIP endpoint"; fi

# 7. PJSIP passwords (names only)
weak=(); total=0
while IFS='|' read -r sec user pass; do
  total=$((total + 1))
  if [ "${#pass}" -lt "$MINLEN" ] || [[ "$pass" =~ ^[0-9]+$ ]] || [ "$pass" = "$user" ] || [ "$pass" = "$sec" ]; then weak+=("$sec"); fi
done < <(cat "$CONF"/pjsip*.conf 2>/dev/null | awk '
  /^\[/{ if(t=="auth") print n "|" u "|" p; n=$0; gsub(/[\[\]]|\(.*$/,"",n); t=""; u=""; p=""; next }
  { line=$0; sub(/;.*/,"",line); split(line,kv,"="); k=kv[1]; gsub(/[ \t]/,"",k); v=substr(line,index(line,"=")+1); gsub(/^[ \t]+|[ \t]+$/,"",v) }
  k=="type"{t=v} k=="username"{u=v} k=="password"{p=v}
  END{ if(t=="auth") print n "|" u "|" p }')
if [ "$total" -eq 0 ]; then f INFO pjsip_secret "No PJSIP auth sections found in $CONF/pjsip*.conf"
elif [ "${#weak[@]}" -gt 0 ]; then f FAIL pjsip_secret "${#weak[@]} of $total PJSIP passwords are short, numeric or equal to the user name: $(printf '%s ' "${weak[@]:0:20}")" "Set random $MINLEN+ character secrets and re-provision the phones (FreePBX: each extension's Secret field)."
else f PASS pjsip_secret "All $total PJSIP passwords are $MINLEN+ characters and not guessable from the name"; fi

# 8. Endpoints trusted by IP that land in an internal context
bad=(); unk=(); idents=""
if axc idents "pjsip show identifies" 'No objects found|Identify:'; then
  while read -r ep; do
    [ -n "$ep" ] || continue
    epout=""; c=""
    if axc epout "pjsip show endpoint $ep" 'Endpoint:'; then c=$(awk '$1=="context"{print $3; exit}' <<<"$epout"); fi
    [ -n "$c" ] || { unk+=("$ep"); continue; }
    case "$c" in from-internal*|default|internal|from-users) bad+=("$ep(context $c)") ;; esac
  done < <(awk '$1=="Identify:" && $2 !~ /^</ {split($2,a,"/"); print a[2]}' <<<"$idents" | sort -u)
else unk+=("(identify list)"); fi
[ "${#unk[@]}" -gt 0 ] && f UNKNOWN ip_trust "Could not read the context of: ${unk[*]}" "Run: asterisk -rx 'pjsip show identifies' and 'pjsip show endpoint NAME'"
if [ "${#bad[@]}" -gt 0 ]; then f FAIL ip_trust "IP-authenticated endpoints dial from an internal context: ${bad[*]}" "Trunks must use from-pstn/from-trunk; anyone who can spoof or share that IP can make outbound calls."
elif [ "${#unk[@]}" -eq 0 ]; then f PASS ip_trust "No IP-authenticated endpoint uses an internal context"; fi

# 9. fail2ban sees Asterisk security events?
if command -v fail2ban-client >/dev/null 2>&1 && fail2ban-client ping >/dev/null 2>&1; then
  jails=$(fail2ban-client status 2>/dev/null | sed -n 's/.*Jail list:[[:space:]]*//p' | tr ',' ' ')
  ajail=""; for j in $jails; do case "$j" in *asterisk*|*sip*) ajail=$j ;; esac; done
  if [ -z "$ajail" ]; then f FAIL fail2ban "fail2ban runs but has no Asterisk/SIP jail" "Enable the asterisk jail (filter asterisk, logpath = the file your logger writes security events to)."
  else
    lp=$(fail2ban-client get "$ajail" logpath 2>/dev/null | awk '/\//{print $NF}' | head -1)
    # fail2ban drops a logpath that does not exist, so read the configured one from the jail files
    [ -n "$lp" ] || lp=$(cat /etc/fail2ban/jail.conf /etc/fail2ban/jail.local /etc/fail2ban/jail.d/*.conf /etc/fail2ban/jail.d/*.local 2>/dev/null | awk -v j="[$ajail]" '$0==j{f=1;next} /^\[/{f=0} f && $1=="logpath" {sub(/^[^=]*=[ \t]*/,""); print; exit}')
    lpb=$(basename "${lp:-none}")
    chan=$(cat "$CONF"/logger*.conf 2>/dev/null | grep -vE '^[[:space:]]*;' | awk -F'=>' -v b="$lpb" '{k=$1; gsub(/[ \t]/,"",k)} k==b {print $2}')
    if [ -z "$lp" ] || [ ! -e "$lp" ]; then f FAIL fail2ban "jail $ajail watches ${lp:-nothing}, which does not exist: SIP attacks are never banned" "Add '$lpb => notice,security' to logger_logfiles_custom.conf and run: asterisk -rx 'logger reload'"
    elif ! grep -qiE 'security|notice' <<<"$chan"; then f FAIL fail2ban "jail $ajail watches $lp but no Asterisk logger channel writes security events there" "Add '$lpb => notice,security' to logger_logfiles_custom.conf and run: asterisk -rx 'logger reload'"
    else f PASS fail2ban "fail2ban jail $ajail reads $lp (logger:$chan)"; fi
  fi
else f WARN fail2ban "fail2ban is not running" "Install fail2ban and enable an asterisk jail; SIP scanners try thousands of passwords a day."; fi

# 10. Firewall present?
fw=""
nftr=$(nft list ruleset 2>/dev/null); iptr=$(iptables -S INPUT 2>/dev/null)
if grep -qE 'hook input.*policy drop' <<<"$nftr"; then fw="nftables (input policy drop)"; fi
if [ -z "$fw" ] && grep -qE '^-P INPUT (DROP|REJECT)' <<<"$iptr"; then fw="iptables (INPUT policy DROP)"; fi
if [ -z "$fw" ] && command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then fw="firewalld"; fi
if [ -z "$fw" ] && command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then fw="ufw"; fi
if [ -n "$fw" ]; then f PASS firewall "Default-deny firewall found: $fw" "Allow SIP/RTP only from your phones and provider."
else f WARN firewall "No default-deny host firewall found (nftables/iptables/firewalld/ufw)" "Allow 5060/5061 and RTP only from your provider and office IPs; drop the rest."; fi

# 11. International dialling (FreePBX routes)
if [ "$FREEPBX" = 1 ]; then
  intl_ok=1
  intl=$("${MYSQL[@]}" asterisk -e "SELECT DISTINCT CONCAT_WS('|', r.name, IFNULL(r.password,''), IFNULL(r.time_group_id,0)) FROM outbound_routes r JOIN outbound_route_patterns p USING(route_id) WHERE CONCAT(p.match_pattern_prefix,p.match_pattern_pass) REGEXP '^(9?011|9?00|\\\\+|_?011|_?00)'" 2>/dev/null) || intl_ok=0
  if [ "$intl_ok" = 0 ]; then f UNKNOWN intl_route "Could not read the FreePBX outbound routes (query failed)" "Check the asterisk database; the international-route check was NOT run."
  elif [ -n "$intl" ]; then
    while IFS='|' read -r rn pw tg; do
      if [ -z "$pw" ] && [ "${tg:-0}" = 0 ]; then f WARN intl_route "Outbound route '$rn' allows international calls with no PIN and no time condition" "Add a route password (PIN) or a time group, and set a per-call/day spend limit at your SIP provider."
      else f PASS intl_route "International route '$rn' is protected (PIN or time condition)"; fi
    done <<<"$intl"
  else f PASS intl_route "No outbound route matches international prefixes (011/00/+)"; fi
  adm=$("${MYSQL[@]}" asterisk -e "SELECT COUNT(*) FROM ampusers WHERE username='admin'" 2>/dev/null)
  [ "${adm:-0}" -gt 0 ] && f INFO gui_admin "FreePBX GUI user 'admin' exists (the first name attackers try)" "Use a non-default admin name and 2FA (or restrict the GUI to your IPs)."
else
  grep -hqE '^[[:space:]]*exten[[:space:]]*=>[[:space:]]*_(9?011|9?00|\+)' "$CONF"/extensions*.conf 2>/dev/null && \
    f INFO intl_route "Dialplan has international patterns (_011/_00/_+)" "Protect them with a PIN (Authenticate/VMAuthenticate) and provider spend limits."
fi

# 12. Recordings / voicemail readable by everyone
for d in /var/spool/asterisk/monitor /var/spool/asterisk/voicemail; do
  [ -d "$d" ] || continue
  n=$(find "$d" -maxdepth 4 -type f -perm -o+r 2>/dev/null | head -1000 | wc -l)
  if [ "$n" -gt 0 ]; then f WARN files "$n file(s) under $d are readable by every local user" "chmod -R o-rwx $d (calls and voicemail are personal data)."
  elif [ "$(stat -c %a "$d" 2>/dev/null | cut -c3)" != 0 ] && [ -n "$(stat -c %a "$d" 2>/dev/null)" ]; then f INFO files "$d itself is world-listable (mode $(stat -c %a "$d"))" "chmod o-rwx $d"; fi
done

# 13. Web GUI exposure
if ss -H -lnt 2>/dev/null | awk '{print $4}' | grep -qE '(^0\.0\.0\.0|^\*|^\[::\]):(80|443)$'; then
  f INFO gui "The web server (FreePBX GUI/UCP) listens on all addresses (80/443)" "Restrict /admin to your office/VPN IPs in the firewall; the GUI is a frequent target."
fi

# ---------- report ----------
nf=0; nw=0; np=0; nu=0
for s in "${SEV[@]}"; do case "$s" in FAIL) nf=$((nf+1)) ;; WARN) nw=$((nw+1)) ;; PASS) np=$((np+1)) ;; UNKNOWN) nu=$((nu+1)) ;; esac; done
host=$(hostname -f 2>/dev/null || hostname)
rc=0; [ "$nw" -gt 0 ] && rc=1; [ "$nu" -gt 0 ] && rc=3; [ "$nf" -gt 0 ] && rc=2
if [ "$JSON" = 1 ]; then
  js() { local s=${1//\\/\\\\}; s=${s//\"/\\\"}; printf '"%s"' "${s//$'\t'/ }"; }
  printf '{"host":%s,"asterisk":%s,"freepbx":%s,"date":%s,"fail":%s,"warn":%s,"unknown":%s,"pass":%s,"findings":[' "$(js "$host")" "$(js "$VER")" "$([ $FREEPBX = 1 ] && echo true || echo false)" "$(js "$TODAY")" "$nf" "$nw" "$nu" "$np"
  for i in "${!SEV[@]}"; do [ "$i" -gt 0 ] && printf ','; printf '{"severity":%s,"id":%s,"message":%s,"fix":%s}' "$(js "${SEV[$i]}")" "$(js "${ID[$i]}")" "$(js "${MSG[$i]}")" "$(js "${FIX[$i]}")"; done
  printf ']}\n'
else
  echo "Asterisk security audit: $host, Asterisk $VER$([ $FREEPBX = 1 ] && echo ', FreePBX'), $TODAY"
  for sev in FAIL UNKNOWN WARN INFO PASS; do
    [ "$FAILS_ONLY" = 1 ] && [ "$sev" != FAIL ] && continue
    for i in "${!SEV[@]}"; do
      [ "${SEV[$i]}" = "$sev" ] || continue
      printf '%-4s %s\n' "$sev" "${MSG[$i]}"
      [ -n "${FIX[$i]}" ] && [ "$sev" != PASS ] && printf '     fix: %s\n' "${FIX[$i]}"
    done
  done
  echo "Summary: $nf fail, $nw warning$([ "$nu" -gt 0 ] && echo ", $nu check(s) could not run"), $np pass. Nothing was changed."
fi
exit "$rc"
