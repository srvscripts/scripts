#!/usr/bin/env bash
# Server Security Audit Script (v2.3.0) - from srvScripts.com
# Source, docs and updates: https://srvscripts.com/scripts/server-security-audit/
# Copyright (c) 2026 srvScripts.com. MIT licence: if you copy, share or adapt this script, keep this notice and credit srvScripts.com.
# server-security-audit.sh — read-only security baseline check for Linux servers
# https://srvscripts.com/scripts/server-security-audit/   License: MIT
# Version: 2.3.0  (2.3.0: firewall PASS now needs a catch-all deny; shadowed or ban-only DROPs are WARN)
#
# Prints PASS / WARN / SKIP / INFO lines. Changes nothing. Run as root for full coverage:
#   bash server-security-audit.sh                  # full report
#   bash server-security-audit.sh --brief          # only WARN and SKIP lines (cron + mail)
#   bash server-security-audit.sh --allow-skipped  # checks that cannot run do not set exit 1
# A check whose data cannot be read is reported as SKIP, never as PASS. The firewall PASS means
# the INPUT path ends in a catch-all deny (DROP/REJECT policy, or an unconditional DROP/REJECT that
# is reached). An ACCEPT-everything rule before it is a WARN; only specific DROPs (e.g. fail2ban
# bans) with an ACCEPT policy is a WARN; a DROP that only follows a conditional ACCEPT is a WARN
# (unverified), because overlapping matches are not analysed. A PASS does not prove that every
# port or service is covered. Brute-force checks are heuristics.
# Exit: 0 = all checks ran and passed, 1 = warnings or skipped checks, 2 = usage error.
set -uo pipefail
export LC_ALL=C
PATH=$PATH:/usr/sbin:/sbin:/usr/local/sbin      # sshd, sysctl, iptables live here
SCRIPT_VERSION=2.3.0

usage() {
  cat <<'EOF'
Usage: server-security-audit.sh [--brief] [--allow-skipped] [--no-color]
  --brief          print only WARN and SKIP lines plus the summary
  --allow-skipped  exit 0 even if some checks could not run (e.g. not root)
  --no-color       no colours (colour is only used on a terminal anyway)
  -h, --help       this help;  --version  print the version
EOF
}
BRIEF=0; ALLOW_SKIPPED=0; COLOR=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --brief) BRIEF=1 ;;
    --allow-skipped) ALLOW_SKIPPED=1 ;;
    --no-color) COLOR=0 ;;
    -h|--help) usage; exit 0 ;;
    --version) echo "server-security-audit $SCRIPT_VERSION"; exit 0 ;;
    *) echo "Unknown option $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if (( COLOR )) && [[ -t 1 ]]; then GR=$'\e[32m'; YE=$'\e[33m'; CY=$'\e[36m'; NC=$'\e[0m'; else GR=""; YE=""; CY=""; NC=""; fi
WARNS=0; SKIPS=0
pass()  { (( BRIEF )) || printf '  %sPASS%s  %s\n' "$GR" "$NC" "$*"; }
warn()  { WARNS=$((WARNS+1)); printf '  %sWARN%s  %s\n' "$YE" "$NC" "$*"; }
skip()  { SKIPS=$((SKIPS+1)); printf '  %sSKIP%s  %s\n' "$CY" "$NC" "$*"; }
info()  { (( BRIEF )) || printf '  INFO  %s\n' "$*"; }
head_() { (( BRIEF )) || printf '\n== %s ==\n' "$*"; }
have()  { command -v "$1" >/dev/null 2>&1; }
ROOT=0; [[ $EUID -eq 0 ]] && ROOT=1
SYSTEMD=0; have systemctl && [[ -d /run/systemd/system ]] && SYSTEMD=1
TMPD=$(mktemp -d) || { echo "mktemp failed" >&2; exit 2; }
trap 'rm -rf "$TMPD"' EXIT

# find wrapper: prints matches; returns 1 only for real errors (a file vanishing mid-scan is not one)
safe_find() {
  find "$@" 2>"$TMPD/find.err"; local rc=$?
  (( rc == 0 )) && return 0
  grep -qv 'No such file or directory' "$TMPD/find.err" && return 1
  return 0
}
# systemd unit state: 0 active, 1 not active (inactive/failed/missing), 2 no systemd,
# 3 the query itself failed (no state printed, e.g. no D-Bus access). UNIT_STATE holds the word.
unit_active() {
  UNIT_STATE=""
  (( SYSTEMD )) || return 2
  UNIT_STATE=$(systemctl is-active "$1" 2>/dev/null | head -n 1)
  case $UNIT_STATE in
    active|reloading) return 0 ;;
    inactive|failed|activating|deactivating|maintenance|unknown) return 1 ;;
    *) UNIT_STATE="query failed"; return 3 ;;
  esac
}

(( ROOT )) || info "Not running as root: checks that need root are reported as SKIP and make the exit code 1 (use --allow-skipped to accept that)."

head_ "System"
info "Host: $(hostname -f 2>/dev/null || hostname)  Kernel: $(uname -r)"
# shellcheck source=/dev/null
[[ -r /etc/os-release ]] && info "OS: $(. /etc/os-release && echo "${PRETTY_NAME:-unknown}")"
info "Uptime:$(uptime -p 2>/dev/null | sed 's/^up//')  Load:$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)"

head_ "Accounts"
if uid0=$(awk -F: '$3==0 && $1!="root"{printf "%s ", $1}' /etc/passwd 2>/dev/null); then
  if [[ -z $uid0 ]]; then pass "Only root has UID 0"; else warn "Extra UID 0 accounts: $uid0"; fi
else skip "UID 0 check: /etc/passwd not readable"; fi
if [[ -r /etc/shadow ]] && nopass=$(awk -F: '$2==""{printf "%s ", $1}' /etc/shadow 2>/dev/null); then
  if [[ -z $nopass ]]; then pass "No accounts with an empty password"; else warn "Accounts with empty password: $nopass"; fi
else skip "Empty-password check: /etc/shadow not readable (needs root)"; fi
shells=$(awk -F: '$7 ~ /(bash|sh|zsh)$/ && $3>=1000 {printf "%s ", $1}' /etc/passwd 2>/dev/null)
info "Login-capable users (UID>=1000): ${shells:-none}"
if [[ -e /etc/sudoers ]]; then
  # grep: 0 = match, 1 = no match, 2 = a file could not be read
  nopw=$(grep -rhs 'NOPASSWD' /etc/sudoers /etc/sudoers.d 2>/dev/null); rc=$?
  nopw=$(printf '%s\n' "$nopw" | grep -v '^[[:space:]]*#' | grep -v '^$' | head -5)
  if (( rc > 1 )); then
    [[ -n $nopw ]] && warn "NOPASSWD sudo rules present: $(echo "$nopw" | tr '\n' ';')"
    skip "NOPASSWD sudo check: sudoers files not readable (needs root)"
  elif [[ -z $nopw ]]; then pass "No NOPASSWD sudo rules"
  else warn "NOPASSWD sudo rules present: $(echo "$nopw" | tr '\n' ';')"; fi
else info "sudo is not installed (/etc/sudoers absent)"; fi

head_ "SSH"
SSHD_CFG=/etc/ssh/sshd_config; SSH_SRC=""; SSH_T=""
# Fallback when sshd -T fails: emit "key value" from sshd_config and its Include files in
# the order sshd reads them, stopping at Match blocks. Returns 1 if any file is unreadable.
ssh_cfg_dump() {
  local f=$1 k v g inc rc=0
  [[ -r $f ]] || return 1
  while read -r k v || [[ -n $k ]]; do
    [[ -z $k || $k == \#* ]] && continue
    k=${k,,}
    [[ $k == match ]] && break
    if [[ $k == include ]]; then
      for g in $v; do                       # unquoted on purpose: Include takes globs
        [[ $g == /* ]] || g=/etc/ssh/$g
        for inc in $g; do [[ -e $inc ]] || continue; ssh_cfg_dump "$inc" || rc=1; done
      done
      continue
    fi
    echo "$k ${v%%#*}"
  done <"$f"
  return $rc
}
if ! have sshd && [[ ! -e $SSHD_CFG ]]; then
  info "OpenSSH server is not installed"
else
  if have sshd && SSH_T=$(sshd -T 2>/dev/null) && [[ -n $SSH_T ]]; then SSH_SRC="sshd -T"
  elif SSH_T=$(ssh_cfg_dump "$SSHD_CFG"); then SSH_SRC="config files (sshd -T failed)"
  else SSH_T=""; fi
  eff() { awk -v k="$1" '$1==k{print $2; exit}' <<<"$SSH_T"; }
  if [[ -z $SSH_SRC ]]; then
    skip "SSH settings: sshd -T failed and $SSHD_CFG or an Include file is not readable (needs root)"
  else
    info "Settings from: $SSH_SRC"
    port=$(eff port); info "SSH port: ${port:-22}"
    prl=$(eff permitrootlogin); prl=${prl:-prohibit-password}
    case "$prl" in
      no|prohibit-password|without-password) pass "PermitRootLogin = $prl" ;;
      *) warn "PermitRootLogin = $prl — allow keys only or disable" ;;
    esac
    pwa=$(eff passwordauthentication)
    if [[ ${pwa:-yes} == no ]]; then pass "PasswordAuthentication = no"; else warn "PasswordAuthentication = ${pwa:-yes (default)} — use keys"; fi
    x11=$(eff x11forwarding)
    if [[ ${x11:-no} == no ]]; then pass "X11Forwarding off"; else info "X11Forwarding enabled"; fi
  fi
  if (( ROOT )); then
    if files=$(safe_find /root/.ssh /home/*/.ssh -maxdepth 1 -name authorized_keys -type f); then
      keys=0; while IFS= read -r f; do [[ -n $f ]] && keys=$(( keys + $(grep -cEv '^[[:space:]]*(#|$)' "$f") )); done <<<"$files"
      info "authorized_keys entries found: $keys"
    else skip "authorized_keys count: find reported errors"; fi
  else skip "authorized_keys count: needs root"; fi
fi

# Does the INPUT path end in a catch-all deny? Reads `iptables -S` (or ip6tables -S) and evaluates
# rules in order: an unconditional ACCEPT ends the chain, so anything after it is unreachable; jumps
# into user chains (CSF, ufw, firewalld, fail2ban, Docker) are followed; RETURN ends a user chain.
# Only a catch-all deny counts as filtering: the DROP/REJECT policy (if traffic reaches the end of
# INPUT) or an unconditional DROP/REJECT reached without a conditional jump. Conditional DROPs
# (fail2ban bans, single ports) only block what they match. Matches are NOT compared, so a DROP
# after a conditional ACCEPT (or after a conditional jump into a chain that ACCEPTs) may never be
# reached: that is unverified, never yes.
# Prints: yes (catch-all deny), acceptall:<rule> (unconditional ACCEPT before any drop),
# unverified:<rule> (<reason>) (a drop exists, but only after an ACCEPT),
# partial:<detail> (only specific DROP/REJECT rules, then ACCEPT), no.
ipt_input_filters() {
  awk '
    function uncond(s) { gsub(/-m comment --comment ("[^"]*"|[^ ]+)/, "", s); gsub(/-c [0-9]+ [0-9]+/, "", s); sub(/(^| )-[jg] .*$/, "", s); gsub(/[[:space:]]+/, "", s); return (s == "") }
    # walk(chain, depth, pc): 1 = catch-all DROP/REJECT reached; 2 = traffic stopped by an unconditional
    # ACCEPT; 0 = fell through. pc = 1 if this chain was entered by a conditional jump.
    # ca = first conditional ACCEPT on the path, sh = first DROP/REJECT after it (may be unreachable),
    # np/pt = number and first of the specific (conditional) DROP/REJECT rules reached before any ACCEPT.
    function walk(c, depth, pc,   i, t, r, u) {
      if (depth > 30 || (c in busy)) return 0
      busy[c]=1
      for (i=1; i<=n[c]; i++) {
        t=tgt[c,i]; u=unc[c,i]
        if (t=="DROP" || t=="REJECT") { if (u && !pc) { delete busy[c]; return 1 }
                                        if (ca != "") { if (sh=="") sh=c " rule " i } else { np++; if (pt=="") pt=c " rule " i }
                                        continue }
        if (t=="ACCEPT") { if (u) { if (c=="INPUT") firstacc=i; delete busy[c]; return 2 } if (ca=="") ca=c " rule " i; continue }
        if (t=="RETURN") { if (u) { delete busy[c]; return 0 } continue }
        if (t in known) { r=walk(t, depth+1, (pc || !u)); if (r==1) { delete busy[c]; return 1 }
                          if (r==2 && u) { if (c=="INPUT" && !firstacc) firstacc=i; delete busy[c]; return 2 }
                          if (r==2 && ca=="") ca=c " rule " i " (jump to " t ")" }
      }
      delete busy[c]; return 0
    }
    $1=="-P" { pol[$2]=$3; known[$2]=1; next }
    $1=="-N" { known[$2]=1; next }
    $1=="-A" { c=$2; known[c]=1; k=++n[c]; t=""; for (i=3;i<NF;i++) if ($i=="-j" || $i=="-g") t=$(i+1)
               tgt[c,k]=t; line=$0; sub(/^-A [^ ]+ ?/, "", line); unc[c,k]=uncond(line) }
    END {
      np=0; r=walk("INPUT", 0, 0)
      if (r==1) { print "yes"; exit }
      if (r==0 && (pol["INPUT"]=="DROP" || pol["INPUT"]=="REJECT")) { print "yes"; exit }
      if (sh != "") { print "unverified:" sh " (DROP/REJECT after a conditional ACCEPT at " ca ")"; exit }
      if (np) { print "partial:" np " specific DROP/REJECT rule(s), first " pt "; then " (r==2 ? "ACCEPT-all at INPUT rule " firstacc : "INPUT policy " (pol["INPUT"]=="" ? "ACCEPT" : pol["INPUT"])); exit }
      if (r==2) { print "acceptall:INPUT rule " firstacc; exit }
      print "no"
    }'
}
# Same question for `nft list ruleset`: every base chain with hook input is evaluated in order
# (a drop in any of them is final, an accept only ends that chain). jump/goto targets in the same
# table are followed. Same rules as above: only a catch-all drop or policy drop is yes, a drop after a
# conditional accept is unverified, and specific drops (e.g. fail2ban/sshguard set bans) are partial.
# Prints yes / acceptall:<table/chain> / unverified:<table/chain rule N> (<reason>) / partial:<detail> / no.
nft_input_filters() {
  awk '
    function opens(s) { return gsub(/\{/, "{", s) }
    function closes(s) { return gsub(/\}/, "}", s) }
    # the rule without counter/log statements, so "counter drop" counts as an unconditional drop
    function bare(s) { gsub(/(^| )counter( packets [0-9]+ bytes [0-9]+)?( |$)/, " ", s); gsub(/(^| )log( prefix "[^"]*"| level [a-z]+)*( |$)/, " ", s)
                       gsub(/ +/, " ", s); sub(/^ /, "", s); sub(/ $/, "", s); return s }
    function walk(c, depth, pc,   i, l, b, r, t, u) {
      if (depth > 30 || (c in busy)) return 0
      busy[c]=1
      for (i=1; i<=n[c]; i++) {
        l=rl[c,i]; b=bare(l)
        if (l ~ /(^|[[:space:]])(drop|reject)([[:space:]]|$)/ || l ~ /reject with /) {
          if (!pc && b ~ /^(drop|reject( with .*)?)$/) { delete busy[c]; return 1 }
          if (ca != "") { if (sh=="") sh=c " rule " i } else { np++; if (pt=="") pt=c " rule " i }
          continue }
        if (b=="accept") { delete busy[c]; return 2 }
        if (l ~ /(^|[[:space:]])accept([[:space:],}]|$)/) { if (ca=="") ca=c " rule " i; continue }
        if (b=="return") { delete busy[c]; return 0 }
        if (match(l, /(jump|goto) [^ ;}]+/)) { t=substr(l, RSTART, RLENGTH); sub(/^(jump|goto) /, "", t); t=tb[c] "/" t
          u=(b ~ /^(jump|goto) [^ ]+$/)
          r=walk(t, depth+1, (pc || !u)); if (r==1) { delete busy[c]; return 1 }
          if (r==2 && u) { delete busy[c]; return 2 }
          if (r==2 && ca=="") ca=c " rule " i " (jump to " t ")" }
      }
      delete busy[c]; return 0
    }
    {
      line=$0; sub(/[[:space:]]*#.*/, "", line); gsub(/comment "[^"]*"/, "", line)
      if (depth==0 && match(line, /^[[:space:]]*table[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]{]+/)) {
        s1=substr(line, RSTART, RLENGTH); sub(/^[[:space:]]+/, "", s1); split(s1, w, /[[:space:]]+/); tbl=w[2] " " w[3] }
      if (depth==1 && match(line, /^[[:space:]]*chain[[:space:]]+[^[:space:]{]+/)) {
        s2=substr(line, RSTART, RLENGTH); sub(/^[[:space:]]*chain[[:space:]]+/, "", s2); ch=tbl "/" s2; inch=1; tb[ch]=tbl; n[ch]+=0 }
      else if (inch && depth==2) {
        l=line; gsub(/[[:space:]]+/, " ", l); sub(/^ /, "", l); sub(/ ?;? ?$/, "", l)
        if (l ~ /hook input/) { hook[ch]=1; if (l ~ /policy drop/) pd[ch]=1 }
        else if (l != "" && l != "}" && l !~ /^(type|policy|comment|devices?) /) rl[ch, ++n[ch]]=l
      }
      depth += opens(line) - closes(line)
      if (depth<=1) inch=0
    }
    END {
      acc=""; unv=""; part=""; tot=0
      for (c in hook) { ca=""; sh=""; pt=""; np=0; r=walk(c, 0, 0)
        if (r==1 || (r==0 && pd[c])) { print "yes"; exit }
        if (sh != "") { if (unv=="") unv=sh " (DROP/REJECT after a conditional ACCEPT at " ca ")" }
        else if (np) { tot+=np; if (part=="") part=pt "; then " (r==2 ? "accept-all" : "policy accept") " in " c }
        else if (r==2 && acc=="") acc=c }
      if (unv != "") { print "unverified:" unv; exit }
      if (tot) { print "partial:" tot " specific drop/reject rule(s), first " part; exit }
      if (acc != "") { print "acceptall:" acc; exit }
      print "no"
    }'
}

head_ "Firewall"
# Which manager is in charge is reported for context only: an active service does not prove that
# its rules filter anything, so the PASS below depends on the ordered rule check alone.
mgr=(); notes=()
if have csf && [[ -f /etc/csf/csf.conf ]]; then
  if [[ -e /etc/csf/csf.disable ]]; then warn "CSF is installed but disabled (/etc/csf/csf.disable exists; csf -e enables it)"
  elif grep -q '^TESTING = "0"' /etc/csf/csf.conf 2>/dev/null; then mgr+=("CSF")
  elif [[ -r /etc/csf/csf.conf ]]; then warn "CSF is installed but TESTING mode is on (rules are flushed every 5 minutes)"
  else notes+=("csf.conf not readable"); fi
fi
if have firewall-cmd; then unit_active firewalld; case $? in 0) mgr+=("firewalld") ;; 3) notes+=("firewalld state query failed") ;; esac; fi
if have ufw; then if out=$(ufw status 2>/dev/null); then [[ $out == *"Status: active"* ]] && mgr+=("ufw"); else notes+=("ufw status needs root"); fi; fi
(( ${#mgr[@]} )) && info "Firewall manager active: ${mgr[*]} (its rules are checked below)"

fwres=(); fwread=0
if have nft; then
  if out=$(nft list ruleset 2>/dev/null) && [[ -n $out || $ROOT -eq 1 ]]; then fwread=1; fwres+=("nftables:$(nft_input_filters <<<"$out")")
  else notes+=("nft list ruleset needs root"); fi
fi
if have iptables; then
  if out=$(iptables -S 2>/dev/null); then fwread=1; fwres+=("iptables:$(ipt_input_filters <<<"$out")")
  else notes+=("iptables -S needs root"); fi
fi
fwyes=""; fwacc=""; fwunv=""; fwpart=""
for r in "${fwres[@]}"; do
  case ${r#*:} in
    yes) fwyes+="${fwyes:+ and }${r%%:*}" ;;
    acceptall:*) fwacc+="${fwacc:+; }${r%%:*} ${r#*:acceptall:}" ;;
    unverified:*) fwunv+="${fwunv:+; }${r%%:*} ${r#*:unverified:}" ;;
    partial:*) fwpart+="${fwpart:+; }${r%%:*}: ${r#*:partial:}" ;;
  esac
done
if [[ -n $fwyes ]]; then
  pass "INPUT filtering verified in ${fwyes}: the INPUT path ends in a catch-all DROP/REJECT rule or policy (ports are not analysed one by one)"
  [[ -n $fwacc ]] && info "Not filtering on its own: ${fwacc} (accepts everything first)"
  [[ -n $fwunv ]] && info "Not verified on its own: ${fwunv}"
  [[ -n $fwpart ]] && info "No catch-all DROP on its own: ${fwpart}"
elif [[ -n $fwacc || -n $fwunv || -n $fwpart ]]; then
  [[ -n $fwacc ]] && warn "Firewall does not filter: ${fwacc} accepts all traffic before any DROP/REJECT is reached${mgr:+ (manager active: ${mgr[*]})}"
  [[ -n $fwunv ]] && warn "INPUT filtering UNVERIFIED in ${fwunv}: a DROP rule exists, but an earlier ACCEPT rule may let the same traffic through first; check the rule order manually"
  [[ -n $fwpart ]] && warn "No catch-all DROP on the INPUT path (${fwpart}): only specific DROP/REJECT rules such as fail2ban bans or single ports; traffic not explicitly blocked is allowed"
elif (( fwread )); then
  warn "No reachable DROP/REJECT rule or DROP policy on the INPUT path${mgr:+, although ${mgr[*]} is active}"
elif (( ${#mgr[@]} )); then
  skip "Firewall: ${mgr[*]} active, but its rules could not be read ($(printf '%s; ' "${notes[@]}" | sed 's/; $//')), so filtering is unverified"
elif (( ${#notes[@]} )); then
  skip "Firewall state unknown: $(printf '%s; ' "${notes[@]}" | sed 's/; $//')"
else warn "No firewall found (no nft, iptables, CSF, firewalld or ufw)"; fi

head_ "Listening services"
if ! have ss; then skip "Listening services: ss not installed (iproute2)"
elif ! lst=$(ss -Hltn 2>/dev/null); then skip "Listening services: ss -ltn failed"
else
  info "TCP ports: $(awk '{print $4}' <<<"$lst" | sed 's/.*://' | sort -un | tr '\n' ' ')"
  exposed=0
  for p in 3306 6379 27017 11211 5432; do
    if awk '{print $4}' <<<"$lst" | grep -Eq "^(0\.0\.0\.0|\*|\[::\]):$p\$"; then
      warn "Port $p is bound to all interfaces — bind to localhost or firewall it"; exposed=1
    fi
  done
  (( exposed )) || pass "No database/cache port (3306, 5432, 6379, 11211, 27017) bound to all interfaces"
fi

head_ "Brute-force protection"
prot=""; unknown=()
if have fail2ban-client || have fail2ban-server; then
  unit_active fail2ban
  case $? in
    0) if have fail2ban-client && st=$(fail2ban-client status 2>/dev/null); then
         jails=$(sed -n 's/.*Number of jail:[[:space:]]*\([0-9]*\).*/\1/p' <<<"$st")
         if [[ ${jails:-0} -gt 0 ]]; then prot="fail2ban ($jails jail(s))"
         else warn "fail2ban is running but has no jails enabled"; fi
       else unknown+=("fail2ban is running but fail2ban-client status failed (needs root)"); fi ;;
    1) info "fail2ban is installed but not running (${UNIT_STATE})" ;;
    2) unknown+=("fail2ban installed but systemd not available") ;;
    3) unknown+=("fail2ban state query failed") ;;
  esac
fi
if [[ -f /usr/local/cpanel/cpanel ]]; then
  if ! have whmapi1; then unknown+=("whmapi1 not found")
  elif out=$(whmapi1 cphulk_status 2>/dev/null); then [[ $out == *"is_enabled: 1"* ]] && prot="${prot:+$prot, }cPHulk"
  else unknown+=("whmapi1 cphulk_status failed"); fi
fi
if [[ " ${mgr[*]} " == *" CSF "* ]]; then
  unit_active lfd
  case $? in 0) prot="${prot:+$prot, }LFD" ;; 1) warn "CSF is active but LFD is not running (${UNIT_STATE})" ;; 2) unknown+=("systemd not available to check lfd") ;; 3) unknown+=("lfd state query failed") ;; esac
fi
# Imunify360: an installed agent is not enough; its service must be running.
# The free ImunifyAV (default on cPanel) ships the same imunify360-agent command but is only a malware
# scanner with no imunify360 service, so Imunify360 is recognised by its service unit or firewall package.
im360=0
if have imunify360-agent; then
  if (( SYSTEMD )) && systemctl list-unit-files imunify360.service 2>/dev/null | grep -q '^imunify360\.service'; then im360=1
  elif { have rpm && rpm -q imunify360-firewall >/dev/null 2>&1; } || { have dpkg-query && dpkg-query -W imunify360-firewall >/dev/null 2>&1; }; then im360=1; fi
fi
if (( ! im360 )) && { have imunify-antivirus || { have rpm && rpm -q imunify-antivirus >/dev/null 2>&1; }; }; then
  info "ImunifyAV found: a malware scanner only; it does not block brute-force logins"
fi
if (( im360 )); then
  unit_active imunify360
  case $? in
    0) prot="${prot:+$prot, }Imunify360 (service running; protection settings not inspected)" ;;
    1) warn "Imunify360 is installed but its service is not running (${UNIT_STATE})" ;;
    2) unknown+=("Imunify360 installed but systemd not available") ;;
    3) unknown+=("Imunify360 service state query failed") ;;
  esac
fi
if [[ -n $prot ]]; then pass "Active: $prot"
elif (( ${#unknown[@]} )); then skip "Brute-force protection unknown: $(printf "%s; " "${unknown[@]}" | sed "s/; $//")"
else warn "No brute-force protection detected (fail2ban / CSF+LFD / cPHulk / Imunify)"; fi
log=""; for l in /var/log/secure /var/log/auth.log; do [[ -e $l ]] && { log=$l; break; }; done
if [[ -z $log ]]; then info "No /var/log/secure or /var/log/auth.log (journald only): failed logins not counted"
elif f=$(grep -c 'Failed password' "$log" 2>/dev/null) || [[ $? -eq 1 ]]; then info "Failed SSH logins in $log: ${f:-0}"
else skip "Failed SSH logins: $log not readable (needs root)"; fi

head_ "Updates"
PM=""; have dnf && PM=dnf; [[ -z $PM ]] && have yum && PM=yum
if [[ -n $PM ]]; then
  # check-update exit codes: 0 = no updates, 100 = updates available, anything else = error
  out=$("$PM" -q check-update 2>/dev/null); rc=$?
  case $rc in
    0) pass "No pending $PM updates" ;;
    100) n=$(grep -cE '^[[:alnum:]][^[:space:]]*\.[[:alnum:]_]+[[:space:]]' <<<"$out")
         warn "${n} package(s) have updates pending ($PM check-update)" ;;
    *) skip "Pending updates unknown: $PM check-update failed (exit $rc; repo or network problem?)" ;;
  esac
elif have apt-get; then
  lists=$(find /var/lib/apt/lists -maxdepth 1 -name '*_Packages*' -printf '%T@\n' 2>/dev/null | sort -n | tail -1)
  if [[ -z $lists ]]; then skip "Pending updates unknown: apt package lists are empty (run apt-get update)"
  elif out=$(apt-get -s upgrade 2>/dev/null); then
    n=$(grep -c '^Inst' <<<"$out"); days=$(( ($(date +%s) - ${lists%.*}) / 86400 ))
    if (( n == 0 )); then pass "No pending apt updates (package lists ${days}d old)"
    else warn "$n packages have updates pending (apt-get -s upgrade, lists ${days}d old)"; fi
  else skip "Pending updates unknown: apt-get -s upgrade failed (exit $?; dpkg lock or broken packages?)"; fi
else skip "Pending updates: no dnf, yum or apt-get found"; fi
[[ -f /var/run/reboot-required ]] && warn "Reboot required (/var/run/reboot-required)"
if [[ -n $PM ]]; then
  # needs-restarting -r: 0 = no reboot needed, 1 = reboot needed, anything else = error
  if have needs-restarting; then nr=(needs-restarting -r); else nr=("$PM" needs-restarting -r); fi
  out=$("${nr[@]}" 2>&1); rc=$?
  if (( rc == 0 )); then pass "No reboot required (${nr[*]})"
  elif (( rc == 1 )) && [[ $out == *"Reboot is required"* ]]; then warn "Reboot required (${nr[*]})"
  else skip "Reboot status unknown: ${nr[*]} failed (exit $rc)$(have needs-restarting || echo '; is dnf-utils/yum-utils installed?')"; fi
fi

head_ "Kernel / MAC"
if have getenforce; then
  m=$(getenforce 2>/dev/null)
  if [[ $m == Enforcing ]]; then pass "SELinux enforcing"; else info "SELinux: ${m:-unknown}"; fi
fi
if have aa-status; then
  if aa-status --enabled 2>/dev/null; then pass "AppArmor enabled"; else info "AppArmor not enabled (or not readable)"; fi
fi
v=$(sysctl -n net.ipv4.tcp_syncookies 2>/dev/null)
case $v in 1|2) pass "tcp_syncookies = $v" ;; 0) warn "tcp_syncookies is off" ;; *) skip "tcp_syncookies: sysctl could not read it" ;; esac
v=$(sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null)
case $v in 1) pass "rp_filter = 1" ;; 0|2) info "rp_filter = $v (not strict)" ;; *) skip "rp_filter: sysctl could not read it" ;; esac

head_ "Filesystem"
if (( ROOT )); then
  dirs=(); for d in /home /var/www; do [[ -d $d ]] && dirs+=("$d"); done
  if (( ${#dirs[@]} == 0 )); then info "No /home or /var/www to scan"
  else
    # report what was found even if the scan hit errors; an error means SKIP, never PASS
    ww=$(safe_find "${dirs[@]}" -xdev -type f -perm -0002); rc=$?
    [[ -n $ww ]] && warn "World-writable files ($(grep -c . <<<"$ww")), first 5: $(head -5 <<<"$ww" | tr '\n' ' ')"
    if (( rc )); then skip "World-writable scan incomplete: $(head -1 "$TMPD/find.err")"
    elif [[ -z $ww ]]; then pass "No world-writable files in ${dirs[*]}"; fi
  fi
  suid=$(safe_find / -xdev -type f -perm -4000 -newer /etc/passwd); rc=$?
  [[ -n $suid ]] && warn "SUID binaries newer than /etc/passwd: $(head -5 <<<"$suid" | tr '\n' ' ')"
  if (( rc )); then skip "SUID scan incomplete: $(head -1 "$TMPD/find.err")"
  elif [[ -z $suid ]]; then pass "No SUID binaries newer than /etc/passwd"; fi
else
  skip "World-writable file scan: needs root"
  skip "SUID binary scan: needs root"
fi
if have findmnt; then
  tmp=$(findmnt -no OPTIONS /tmp 2>/dev/null)
  if [[ $tmp == *noexec* ]]; then pass "/tmp is noexec"
  elif [[ -n $tmp ]]; then info "/tmp is not mounted noexec"
  else info "/tmp is not a separate mount (so not noexec)"; fi
fi
dfo=$(df -hP -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null); rc=$?
full=0
while read -r fs _ _ _ pct mnt; do
  [[ $pct =~ ^([0-9]+)%$ ]] || continue
  (( BASH_REMATCH[1] >= 90 )) && { warn "$mnt is $pct full ($fs)"; full=1; }
done < <(tail -n +2 <<<"$dfo")
if (( rc != 0 )); then skip "Disk usage: df could not read every filesystem (exit $rc)"
elif (( ! full )); then pass "All filesystems below 90% used"; fi

head_ "Summary"
printf '%d warning(s), %d check(s) could not run.\n' "$WARNS" "$SKIPS"
if (( SKIPS )); then
  (( ROOT )) || echo "Not running as root: re-run as root for a complete audit."
  (( ALLOW_SKIPPED )) && echo "Skipped checks do not affect the exit code (--allow-skipped)."
fi
(( WARNS > 0 )) && exit 1
(( SKIPS > 0 && ! ALLOW_SKIPPED )) && exit 1
exit 0
