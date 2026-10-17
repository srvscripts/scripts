#!/usr/bin/env bash
# SIP TLS and WSS Certificate Check for Asterisk and FreePBX: Expiry, Hostname, Chain, Reload (v1.0.1) - from srvScripts.com
# Source, docs and updates: https://srvscripts.com/scripts/sip-tls-certificate-check/
# Copyright (c) 2026 srvScripts.com. MIT licence: if you copy, share or adapt this script, keep this notice and credit srvScripts.com.
#
# Read-only check of the certificates an Asterisk/FreePBX server uses for encrypted signalling: PJSIP TLS and WSS
# transports (SIP over TLS, WebRTC) and the Asterisk HTTP TLS server that WebRTC phones connect to. For each one it
# checks the certificate FILE (days left, host name, chain, private key match) and the certificate Asterisk actually
# SERVES on its port. A served certificate that differs from the file means the certificate was renewed on disk but
# Asterisk was never reloaded, the classic cause of "phones stopped registering when the old certificate expired".
# Remote endpoints (your SIP provider's TLS port, a provisioning server) can be added with --check.
#
#   bash sip-tls-cert-check.sh                         # discover and check everything on this PBX
#   bash sip-tls-cert-check.sh --name pbx.example.com --warn-days 30
#   bash sip-tls-cert-check.sh --check sip.provider.example:5061 --json
#   0 7 * * * root /usr/local/bin/sip-tls-cert-check.sh --quiet || mail -s "PBX certificate" ops@example.com < /dev/null
#
# Nothing is changed: it reads config files and certificates and opens TLS connections. Private keys are only used
# to compare public keys; nothing secret is printed.
# Exit codes (Nagios style): 0 OK, 1 WARNING, 2 CRITICAL, 3 UNKNOWN (bad option, openssl missing, nothing to check).
# Version 1.0.1 (2026-10-17): fixes from an independent review: a certificate that is not valid yet, an expired or
#   not-yet-valid CA in the chain, a certificate not allowed for TLS servers, and a server that does not send its
#   intermediate certificate are now reported (1.0.0 said OK); the served chain is always verified, with the transport's
#   ca_list_file and --ca; the "different certificate" message names other possible causes.
# Version 1.0.0 (2026-10-17): first release. Tested on FreePBX 17.0.33 / Asterisk 22.11 (Debian 12, OpenSSL 3.0) with a
#   PJSIP TLS transport and the FreePBX WSS server: private-CA, self-signed default, 9 days left, expired, mismatched
#   key, renewed on disk but not reloaded. Wrong host name and "nothing listening" are tested against openssl s_server.
set -uo pipefail
export LC_ALL=C
WARN_DAYS=21; CRIT_DAYS=7; NAME=""; CAFILE=""; JSON=0; QUIET=0; CHECKS=(); AST=${ASTERISK_BIN:-asterisk}; CONF=/etc/asterisk; TIMEOUT=8
usage() {
  cat <<'EOF'
Usage: sip-tls-cert-check.sh [options]
  --name HOST          host name the certificates must match (default: the transport's external address,
                       then the machine's FQDN)
  --check HOST:PORT    also check a remote TLS endpoint (repeatable), e.g. your provider's SIP TLS port
  --ca FILE            extra CA certificates to trust (a private CA); system CAs are always trusted
  --warn-days N        warn when a certificate expires within N days (default 21)
  --crit-days N        critical within N days (default 7)
  --conf DIR           Asterisk config folder (default /etc/asterisk)
  --json               JSON output
  -q, --quiet          print nothing when everything is OK
  -h, --help           this help
EOF
}
die() { echo "UNKNOWN: $*" >&2; exit 3; }
HPRE='^[][A-Za-z0-9.:-]+:[0-9]{1,5}$'
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="${2:-}"; [[ "$NAME" =~ ^[A-Za-z0-9.*:-]+$ ]] || die "--name: invalid host name"; shift 2 ;;
    --check) [[ "${2:-}" =~ $HPRE ]] || die "--check needs HOST:PORT"; CHECKS+=("$2"); shift 2 ;;
    --ca) CAFILE="${2:-}"; [ -r "$CAFILE" ] || die "--ca: cannot read $CAFILE"; shift 2 ;;
    --warn-days) [[ "${2:-}" =~ ^[0-9]+$ ]] || die "--warn-days needs a number"; WARN_DAYS=$2; shift 2 ;;
    --crit-days) [[ "${2:-}" =~ ^[0-9]+$ ]] || die "--crit-days needs a number"; CRIT_DAYS=$2; shift 2 ;;
    --conf) CONF="${2:-}"; [ -d "$CONF" ] || die "--conf: no such folder"; shift 2 ;;
    --json) JSON=1; shift ;;
    -q|--quiet) QUIET=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
done
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"
[ "$CRIT_DAYS" -le "$WARN_DAYS" ] || die "--crit-days must not be larger than --warn-days"
TMP=$(mktemp -d) || die "mktemp failed"; trap 'rm -rf "$TMP"' EXIT
STATUS=0; LINES=(); JS=(); NOW=$(date +%s)
bump() { case "$1" in CRIT) [ "$STATUS" -lt 2 ] && STATUS=2 ;; WARN) [ "$STATUS" -lt 1 ] && STATUS=1 ;; UNKNOWN) [ "$STATUS" -lt 2 ] && STATUS=3 ;; esac; }
say() { bump "$1"; LINES+=("  $1 $2"); }
jstr() { local s=${1//\\/\\\\}; s=${s//\"/\\\"}; printf '"%s"' "${s//$'\n'/ }"; }

# ---- discovery: list of "label|host:port|certfile|keyfile|cafile|name" ----
ITEMS=()
default_name() { [ -n "$NAME" ] && { echo "$NAME"; return; }; [ -n "${1:-}" ] && { echo "$1"; return; }; hostname -f 2>/dev/null || hostname; }
connect_host() { case "$1" in 0.0.0.0|::|'['::']'|'') echo 127.0.0.1 ;; *) echo "$1" ;; esac; }
if command -v "$AST" >/dev/null 2>&1 && "$AST" -rx "core show version" >/dev/null 2>&1; then
  while read -r tid; do
    det=$("$AST" -rx "pjsip show transport $tid" 2>/dev/null)
    proto=$(awk '$1=="protocol"{print $3}' <<<"$det"); [[ "$proto" =~ ^(tls|wss)$ ]] || continue
    bind=$(awk '$1=="bind"{print $3}' <<<"$det"); cert=$(awk '$1=="cert_file"{print $3}' <<<"$det"); key=$(awk '$1=="priv_key_file"{print $3}' <<<"$det")
    ca=$(awk '$1=="ca_list_file"{print $3}' <<<"$det"); ext=$(awk '$1=="external_signaling_address"{print $3}' <<<"$det")
    h=${bind%:*}; p=${bind##*:}; [ "$proto" = wss ] && p=""   # WSS rides on the HTTP TLS server, checked below
    if [ -z "$cert" ]; then [ "$proto" = tls ] && say WARN "PJSIP transport $tid (tls) has no cert_file"; continue; fi
    ITEMS+=("PJSIP $proto transport $tid|$( [ -n "$p" ] && echo "$(connect_host "$h"):$p")|$cert|$key|$ca|$(default_name "$ext")")
  done < <("$AST" -rx "pjsip show transports" 2>/dev/null | awk '$1=="Transport:" && $2 !~ /^</ {print $2}')
fi
# Asterisk HTTP TLS (WSS for WebRTC phones). The last value wins, as in Asterisk's own include order.
hcert=""; hkey=""; hbind=""; hen=""
for f in "$CONF/http.conf" "$CONF/http_additional.conf" "$CONF/http_custom.conf"; do
  [ -r "$f" ] || continue
  while IFS='=' read -r k v; do
    k=${k//[[:space:]]/}; v=${v%%;*}; v=${v//[[:space:]]/}
    case "$k" in tlsenable) hen=$v ;; tlsbindaddr) hbind=$v ;; tlscertfile) hcert=$v ;; tlsprivatekey) hkey=$v ;; esac
  done < <(grep -E '^[[:space:]]*(tlsenable|tlsbindaddr|tlscertfile|tlsprivatekey)[[:space:]]*=' "$f")
done
if [[ "$hen" =~ ^(yes|true|1)$ ]] && [ -n "$hcert" ]; then
  hb=${hbind:-0.0.0.0:8089}; hh=${hb%:*}; hp=${hb##*:}; [ "$hh" = "$hb" ] && hp=8089
  ITEMS+=("Asterisk HTTP TLS (WSS/WebRTC)|$(connect_host "$hh"):$hp|$hcert|${hkey:-$hcert}||$(default_name "")")
fi
for c in "${CHECKS[@]}"; do rn=${c%:*}; rn=${rn#[}; rn=${rn%]}; ITEMS+=("Remote $c|$c||||${NAME:-$rn}"); done
[ "${#ITEMS[@]}" -gt 0 ] || die "nothing to check: no TLS transport or HTTP TLS found in Asterisk and no --check given"

days_left() { local e; e=$(openssl x509 -enddate -noout -in "$1" 2>/dev/null | cut -d= -f2); [ -n "$e" ] || return 1; echo $(( ($(date -d "$e" +%s) - NOW) / 86400 )); }
cn_of() { openssl x509 -noout -subject -nameopt multiline -in "$1" 2>/dev/null | awk -F'= ' '/commonName/{print $2; exit}'; }
fp_of() { openssl x509 -noout -fingerprint -sha256 -in "$1" 2>/dev/null | cut -d= -f2; }
host_ok() { if [[ "$2" =~ ^[0-9.]+$|: ]]; then openssl x509 -noout -checkip "$2" -in "$1" 2>/dev/null | grep -q 'does match'; else openssl x509 -noout -checkhost "$2" -in "$1" 2>/dev/null | grep -q 'does match'; fi; }
cabundle() { # transport ca_list_file + --ca -> path of a combined CA file, or nothing (system CAs only)
  [ -z "$1" ] && [ -z "$CAFILE" ] && return 0
  cat ${1:+"$1"} ${CAFILE:+"$CAFILE"} > "$TMP/ca.pem" 2>/dev/null; echo "$TMP/ca.pem"
}
verify_chain() { # cert cafile -> one "code depth message" line per problem; dates checked on every certificate in the chain
  local ca=() out; [ -n "$2" ] && ca=(-CAfile "$2")
  out=$(openssl verify "${ca[@]}" -purpose sslserver -untrusted "$1" "$1" 2>&1) && return 0
  sed -nE 's/^error ([0-9]+) at ([0-9]+) depth lookup: (.*)$/\1 \2 \3/p' <<<"$out" | sort -u; return 1
}
not_before() { local b; b=$(openssl x509 -startdate -noout -in "$1" 2>/dev/null | cut -d= -f2); [ -n "$b" ] && [ "$(date -d "$b" +%s)" -gt "$NOW" ] && echo "$b"; }
left() { if [ "$1" -lt 0 ]; then echo "expired $(( -$1 )) day(s) ago"; else echo "$1 day(s) left"; fi; }
check_days() { # label days
  if [ "$2" -lt 0 ]; then say CRIT "$1 EXPIRED $(( -$2 )) day(s) ago"
  elif [ "$2" -le "$CRIT_DAYS" ]; then say CRIT "$1 expires in $2 day(s)"
  elif [ "$2" -le "$WARN_DAYS" ]; then say WARN "$1 expires in $2 day(s)"; fi
}

for it in "${ITEMS[@]}"; do
  IFS='|' read -r label hp cert key ca name <<<"$it"
  LINES+=("$label${hp:+ ($hp)}"); fdays=""; ffp=""; sdays=""; sfp=""; proto=""; selfsigned=0; vcode=""; vtext=""
  if [ -n "$cert" ]; then
    if [ ! -r "$cert" ] || ! openssl x509 -noout -in "$cert" 2>/dev/null; then say CRIT "certificate file $cert is missing or unreadable"
    else
      fdays=$(days_left "$cert"); ffp=$(fp_of "$cert")
      LINES+=("    file $cert: CN=$(cn_of "$cert"), $(left "$fdays")")
      check_days "file $cert" "$fdays"
      nb=$(not_before "$cert") && say CRIT "file certificate is not valid yet (valid from $nb): clients reject it until then"
      host_ok "$cert" "$name" || say WARN "file certificate does not match host name $name"
      selfsigned=0
      [ "$(openssl x509 -noout -subject -nameopt RFC2253 -in "$cert" | cut -d= -f2-)" = "$(openssl x509 -noout -issuer -nameopt RFC2253 -in "$cert" | cut -d= -f2-)" ] && selfsigned=1
      cab=$(cabundle "$ca")
      if ! why=$(verify_chain "$cert" "$cab"); then
        while read -r code depth msg; do
          case "$code" in
            10) [ "$depth" -gt 0 ] && say CRIT "a CA certificate in the file's chain (depth $depth) has expired" ;;   # the leaf itself is reported above
            9) [ "$depth" -gt 0 ] && say CRIT "a CA certificate in the file's chain (depth $depth) is not valid yet" ;;
            18|19) [ "$selfsigned" = 1 ] && say WARN "file certificate is self-signed: only clients told to trust this exact certificate accept it; browsers (WebRTC) and most SIP providers reject it" \
                     || say WARN "file certificate chain ends in a CA that is not trusted here: $msg (add the CA with --ca)" ;;
            26) say WARN "file certificate (depth $depth) is not allowed for TLS server use (extended key usage): $msg" ;;
            "") ;;
            *) say WARN "file certificate chain is not trusted: $msg (add the CA with --ca, or install the full chain)" ;;
          esac
        done <<<"${why:-0 0 unknown error}"
      fi
      if [ -n "$key" ] && [ "$key" != "$cert" ]; then
        if [ ! -r "$key" ]; then say WARN "private key $key is not readable by this user"
        elif ! cmp -s <(openssl x509 -noout -pubkey -in "$cert" 2>/dev/null) <(openssl pkey -pubout -in "$key" 2>/dev/null); then
          say CRIT "private key $key does not belong to the certificate: after the next reload TLS handshakes fail (Asterisk logs 'key values mismatch')"; fi
      fi
    fi
  fi
  if [ -n "$hp" ]; then
    if [[ "$name" =~ ^[0-9.]+$|: ]]; then vopt=(-verify_ip "$name"); else vopt=(-servername "$name" -verify_hostname "$name"); fi
    cab=$(cabundle "$ca")
    out=$(timeout "$TIMEOUT" openssl s_client -connect "$hp" "${vopt[@]}" ${cab:+-CAfile "$cab"} -showcerts </dev/null 2>&1); rc=$?
    awk '/-----BEGIN CERTIFICATE-----/{f=1} f{print} /-----END CERTIFICATE-----/{exit}' <<<"$out" > "$TMP/served.pem"
    if ! openssl x509 -noout -in "$TMP/served.pem" 2>/dev/null; then
      say CRIT "no TLS handshake on $hp: nothing listening, port blocked, or the server cannot load its certificate ($(grep -m1 -iE 'connect|errno|refused|timeout|alert' <<<"$out" | cut -c1-80 || echo "openssl exit $rc"))"
    else
      sdays=$(days_left "$TMP/served.pem"); sfp=$(fp_of "$TMP/served.pem"); proto=$(grep -m1 -oE 'TLSv1(\.[0-3])?' <<<"$out")
      LINES+=("    served on $hp: CN=$(cn_of "$TMP/served.pem"), $(left "$sdays"), ${proto:-TLS}")
      [ "$ffp" = "$sfp" ] || { check_days "served certificate" "$sdays"; nb=$(not_before "$TMP/served.pem") && say CRIT "served certificate is not valid yet (valid from $nb)"; }   # same certificate: already reported above
      if [ -n "$ffp" ] && [ "$ffp" != "$sfp" ]; then
        if [[ "$label" == PJSIP* ]]; then fix="Reload PJSIP: fwconsole reload, or asterisk -rx 'module reload res_pjsip.so' (older Asterisk versions may need allow_reload=yes on the transport or a restart)"
        else fix="Reload the HTTP server: asterisk -rx 'module reload http'"; fi
        say WARN "Asterisk serves a different certificate than $cert. Usually the file was renewed but not reloaded ($fix); a proxy in front, SNI or another configuration can also cause this."
      fi
      vr=$(grep -m1 -oE 'Verify return code: [0-9]+ \([^)]*\)' <<<"$out"); vcode=$(grep -oE '[0-9]+' <<<"$vr" | head -1); vtext=${vr#*(}; vtext=${vtext%)}
      [ -z "$cert" ] && { host_ok "$TMP/served.pem" "$name" || say WARN "served certificate does not match host name $name"; }
      # what a client sees: always judge the served chain, even when the leaf equals the file (the server may omit the intermediate)
      case "${vcode:-x}" in
        0) ;;
        62) { [ -z "$cert" ] || [ "$ffp" = "$sfp" ]; } || say WARN "served certificate does not match host name $name" ;;   # otherwise reported above
        9) not_before "$TMP/served.pem" >/dev/null || say CRIT "served chain: a CA certificate is not valid yet" ;;   # leaf: reported above
        10) [ "${sdays:-1}" -lt 0 ] || say CRIT "served chain: a CA certificate has expired" ;;
        18|19) { [ "$ffp" = "$sfp" ] && [ "${selfsigned:-0}" = 1 ]; } || say WARN "served certificate is self-signed or its CA is not trusted: $vtext" ;;
        20|21) say WARN "served chain is incomplete or its CA is unknown ($vtext): the server probably does not send the intermediate certificate. Point the transport at the full chain file (certificate + intermediates), or add a private CA with --ca" ;;
        x) say WARN "TLS handshake did not complete, so the served chain could not be verified (client certificate required, or the connection was closed)" ;;
        *) say WARN "served certificate fails verification: $vtext" ;;
      esac
      [[ "$proto" =~ ^TLSv1(\.[01])?$ ]] && say WARN "server negotiated $proto: TLS 1.0 and 1.1 are obsolete; set method=tlsv1_2 (or newer)"
    fi
  fi
  JS+=("{\"item\":$(jstr "$label"),\"endpoint\":$(jstr "$hp"),\"file\":$(jstr "$cert"),\"name\":$(jstr "$name"),\"file_days_left\":${fdays:-null},\"served_days_left\":${sdays:-null},\"served_matches_file\":$( [ -n "$ffp" ] && [ -n "$sfp" ] && { [ "$ffp" = "$sfp" ] && echo true || echo false; } || echo null),\"tls\":$(jstr "$proto"),\"served_verify\":$(jstr "${vtext:-}")}")
done

LVL=(OK WARNING CRITICAL UNKNOWN); host=$(hostname -f 2>/dev/null || hostname)
probs=(); for l in "${LINES[@]}"; do [[ "$l" =~ ^\ \ (WARN|CRIT|UNKNOWN)\  ]] && probs+=("${l#  }"); done
summary="${LVL[$STATUS]}: ${#ITEMS[@]} TLS endpoint(s) checked, ${#probs[@]} problem(s)"
if [ "$JSON" = 1 ]; then
  printf '{"host":%s,"status":%s,"warn_days":%s,"crit_days":%s,"items":[%s],"problems":[' "$(jstr "$host")" "$(jstr "${LVL[$STATUS]}")" "$WARN_DAYS" "$CRIT_DAYS" "$(IFS=,; echo "${JS[*]}")"
  for i in "${!probs[@]}"; do [ "$i" -gt 0 ] && printf ','; jstr "${probs[$i]}"; done; printf '],"text":%s}\n' "$(jstr "$host $summary")"
elif [ "$QUIET" = 0 ] || [ "$STATUS" -gt 0 ]; then
  echo "SIP TLS certificate check on $host"; printf '%s\n' "${LINES[@]}"; echo "$summary"
fi
exit "$STATUS"
