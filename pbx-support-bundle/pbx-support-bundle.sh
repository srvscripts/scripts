#!/usr/bin/env bash
# PBX Support Bundle for Asterisk and FreePBX: Redacted Diagnostics, Preview, No Upload (v1.0.4) - from srvScripts.com
# Source, docs and updates: https://srvscripts.com/scripts/pbx-support-bundle/
# Copyright (c) 2026 srvScripts.com. MIT licence: if you copy, share or adapt this script, keep this notice and credit srvScripts.com.
#
# Collects what a VoIP consultant, your provider or a forum usually asks for (versions, PJSIP transports, endpoints,
# registrations and contacts, selected config files, the last lines of the Asterisk log) into one archive, with
# passwords, digest values, SRTP/ICE keys from SIP traces, private keys, e-mail addresses, public IP addresses and
# phone numbers masked.
# Only files on a fixed list are copied: never pjsip.auth.conf, manager.conf, voicemail.conf or the FreePBX database
# config. Those are only read to check that none of their passwords ended up in the bundle (any match is masked).
# Nothing is uploaded or sent anywhere. The result is a private folder (700) and archive (600) for you to review.
#
#   bash pbx-support-bundle.sh                    # bundle in /root, last 2000 log lines
#   bash pbx-support-bundle.sh --dry-run          # show what would be collected, collect nothing
#   bash pbx-support-bundle.sh --lines 5000 --out /root/support --keep-private-ips
#
# Changes nothing on the PBX: it runs read-only Asterisk CLI commands and writes only the bundle.
# Exit codes: 0 archive created and the final scan found nothing, 1 the scan found something that may be sensitive
# (no archive; fix the listed lines and run --pack), 2 nothing collected or the archive could not be written,
# 3 bad option or missing tool.
# Version 1.0.4 (2026-10-18): comment correction only, no change in behaviour: the 1.0.3 note below now also names
#   passwords shorter than 4 characters, which the 1.0.2 "known" file left readable as well.
# Version 1.0.3 (2026-10-17): fixes from a third review: 1.0.2 copied its internal list of this PBX's passwords
#   into the bundle as a file named "known" (masked, except passwords shorter than 4 characters, of any kind, and
#   passwords of up to 5 digits); the list now lives outside
#   the bundle, and folder and archive are checked against the fixed layout. With two or more known passwords the
#   first masking pass read the list as one value, so a password with a space could keep its second word; fixed.
#   Known passwords too short or too numeric to search for safely are counted in a warning.
# Version 1.0.2 (2026-10-17): fixes from a second independent review: SDP keying material in SIP traces (SDES
#   inline: keys incl. FEC keys, a=key-mgmt, k= lines, ICE passwords) is masked and checked by the final scan; this
#   PBX's known passwords are masked before any pattern rule, and quoted FreePBX variable values are masked whole
#   (1.0.1 masked only the first word of a password with a space); a scan that fails (unreadable file, report not
#   writable) stops with exit 2 instead of counting as clean; the scan now covers every file, README.txt included;
#   the archive name must not be an existing folder or link.
# Version 1.0.1 (2026-10-17): fixes from an independent review: Digest values written with spaces around "=", other
#   Authorization/Authentication-Info parameters and Bearer tokens are masked; known passwords with spaces are no
#   longer cut short; scan.txt lists file, line and rule only (it printed the value in 1.0.0); no archive is created
#   while the scan finds something (new --pack); a failed archive is an error instead of OK.
# Version 1.0.0 (2026-10-17): first release. Tested on FreePBX 17.0.33 / Asterisk 22.11 (Debian 12).
set -uo pipefail
export LC_ALL=C
umask 077
OUT=/root; LINES=2000; DRY=0; KEEP_PRIV=1; MASK_HOST=1; MASK_NUM=1; AST=${ASTERISK_BIN:-asterisk}; CONF=/etc/asterisk
LOGDIR=/var/log/asterisk
usage() {
  cat <<'EOF'
Usage: pbx-support-bundle.sh [options]
  --out DIR            where to write the bundle (default /root)
  --lines N            last N lines of the Asterisk "full" log (default 2000, 0 = none)
  --conf DIR           Asterisk config folder (default /etc/asterisk)
  --logdir DIR         Asterisk log folder (default /var/log/asterisk)
  --mask-private-ips   also mask private (RFC 1918) addresses; by default they are kept, they help with NAT problems
  --keep-ips           do not mask any IP address (public addresses are masked by default)
  --keep-host          keep this server's host and domain name (masked as pbx.example.com by default)
  --keep-numbers       keep phone numbers (7 to 15 digits are masked by default, last 2 digits kept)
  --dry-run            list what would be collected and exit
  --pack DIR           after you edited a bundle folder: scan it again and create the archive if it is clean
  -h, --help           this help
EOF
}
die() { echo "ERROR: $*" >&2; exit 3; }
KEEP_IPS=0; PACK=""
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="${2:-}"; [ -d "$OUT" ] || die "--out: no such folder"; shift 2 ;;
    --lines) [[ "${2:-}" =~ ^[0-9]+$ ]] || die "--lines needs a number"; LINES=$2; shift 2 ;;
    --conf) CONF="${2:-}"; [ -d "$CONF" ] || die "--conf: no such folder"; shift 2 ;;
    --logdir) LOGDIR="${2:-}"; shift 2 ;;
    --mask-private-ips) KEEP_PRIV=0; shift ;;
    --keep-ips) KEEP_IPS=1; shift ;;
    --keep-host) MASK_HOST=0; shift ;;
    --keep-numbers) MASK_NUM=0; shift ;;
    --dry-run) DRY=1; shift ;;
    --pack) PACK="${2:-}"; [ -d "$PACK" ] || die "--pack needs an existing bundle folder"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
done
command -v perl >/dev/null 2>&1 || die "perl is required (it is part of every Debian/RHEL base system)"
command -v tar >/dev/null 2>&1 || die "tar is required"
scan_bundle() { # dir report-file -> writes the report (file:line:rule, never values), prints the number of hits;
  # returns non-zero if any file cannot be read or the report cannot be written (a failed scan is never "clean")
  ( cd "$1" && find . \( -type f -o -type l \) -print0 ) | perl -0 -e '
    use strict; use warnings; my ($dir, $rep) = @ARGV; my $n = 0; open my $o, ">", $rep or die "scan report: $!\n";
    my $K = qr/(?:password|secret|passwd|md5_cred|apikey|api_key|token|auth_?pass)/i;
    sub masked { my $v = shift; return 1 if $v =~ /^(["\x27])\*{4,}\1/; return 1 if $v =~ /^\*{4,}(?:$|[\s,;&)}\]])/; 0 }
    my @R = (
      [ "assignment", sub { $_[0] =~ /\b$K\s*(?:=>|=|:)\s*([^\n]*)/ && length($1) && !masked($1) } ],
      [ "freepbx-variable", sub { $_[0] =~ /(?:PASS|SECRET|TOKEN)[A-Z_]*["\x27]?\s+to\s+(["\x27][^\n]*)/ && !masked($1) } ],
      [ "private-key", sub { $_[0] =~ /BEGIN [A-Z ]*PRIVATE KEY/ } ],
      [ "auth-header", sub { $_[0] =~ /\b(?:Proxy-)?Authorization\s*:\s*(?:Basic|Bearer)\s+(?!\*{4})\S/i } ],
      [ "digest-value", sub { $_[0] =~ /\b(?:response|nonce|cnonce|opaque|nextnonce|rspauth|auts)\s*=\s*"?(?!\*{4})[^\s",;*]/i } ],
      [ "sdp-key", sub { $_[0] =~ /inline:(?!\*{4})[A-Za-z0-9+\/]{8,}|ice-pwd:(?!\*{4})\S{4,}|a=key-mgmt:\s*\S+\s+(?!\*{4})\S|(?:^|\s)k=(?:clear|base64|uri|prompt):(?!\*{4})\S/i } ],
      [ "long-token", sub { $_[0] =~ m{[A-Za-z0-9+/]{60,}={0,2}} } ] );
    my $err = 0; local $/ = "\0";
    while (my $f = <STDIN>) { chomp $f; $f =~ s{^\./}{}; (my $safe = $f) =~ s/[^\w.\/-]/?/g;
      if (-l "$dir/$f") { print $o "$safe:0: symbolic-link\n"; $n++; next }
      my $i; unless (open $i, "<", "$dir/$f") { warn "cannot read $safe: $!\n"; $err++; next }
      local $/ = "\n"; my $ln = 0;
      while (my $l = <$i>) { $ln++; for my $r (@R) { if ($r->[1]->($l)) { print $o "$safe:$ln: $r->[0]\n"; $n++; last } } }
      close $i or $err++; }
    close $o or die "scan report: $!\n"; die "$err file(s) could not be scanned\n" if $err; print $n;' "$1" "$2"
}
scan_or_stop() { # dir -> sets HITS and leaves dir/scan.txt only when something was found; exits 2 if the scan fails
  local dir=$1 rep rc
  if [ -e "$dir/scan.txt" ] || [ -L "$dir/scan.txt" ]; then
    if [ -f "$dir/scan.txt" ] && [ ! -L "$dir/scan.txt" ]; then rm -f "$dir/scan.txt"
    else echo "ERROR: $dir/scan.txt is not a plain file (folder or link); remove it and try again. No archive was created." >&2; exit 2; fi
  fi
  rep=$(mktemp) || { echo "ERROR: cannot create a temporary scan report. No archive was created." >&2; exit 2; }
  HITS=$(scan_bundle "$dir" "$rep"); rc=$?
  if [ "$rc" -ne 0 ] || ! [[ "$HITS" =~ ^[0-9]+$ ]]; then rm -f "$rep"; echo "ERROR: the final scan failed (see above), so the bundle cannot be called clean. No archive was created." >&2; exit 2; fi
  if [ "$HITS" -gt 0 ]; then cp "$rep" "$dir/scan.txt" && chmod 600 "$dir/scan.txt" || { rm -f "$rep"; echo "ERROR: cannot write $dir/scan.txt. No archive was created." >&2; exit 2; }; fi
  rm -f "$rep"
}
pack_bundle() { # dir -> creates dir.tar.gz atomically, mode 600, verified; returns 0 or 2
  local dir=${1%/} base parent tmp members; base=$(basename "$dir"); parent=$(dirname "$dir")
  if [ -L "$dir.tar.gz" ] || { [ -e "$dir.tar.gz" ] && [ ! -f "$dir.tar.gz" ]; }; then
    echo "ERROR: $dir.tar.gz already exists and is not a plain file (folder or link); move it away first. No archive was created." >&2; return 2; fi
  tmp=$(mktemp "$parent/.${base}.XXXXXX") || { echo "ERROR: cannot create a temporary archive in $parent" >&2; return 2; }
  if tar -C "$parent" -czf "$tmp" "$base" && gzip -t "$tmp" && chmod 600 "$tmp" && [ -s "$tmp" ] \
     && members=$(tar -tzf "$tmp") && ! grep -qvE "^$(printf '%s' "$base" | sed 's/[.[\*^$]/\\&/g')/((README|scan)\.txt|(commands|config|logs)/([^/]+)?)?\$" <<<"$members" \
     && mv -fT "$tmp" "$dir.tar.gz" && [ -f "$dir.tar.gz" ] && [ ! -L "$dir.tar.gz" ]; then return 0; fi
  rm -f "$tmp"; echo "ERROR: the archive could not be created (disk full or not writable?) or did not hold exactly the bundle files; the reviewed folder $dir is kept" >&2; return 2
}

layout_ok() { # dir -> 0 if the folder holds only what the bundle writes: README.txt, scan.txt, commands/ config/ logs/ files
  local dir=$1 bad
  bad=$(cd "$dir" && find . -mindepth 1 ! -path ./README.txt ! -path ./scan.txt ! -path ./commands ! -path ./config ! -path ./logs \
        ! -regex '\./\(commands\|config\|logs\)/[^/]*' -print | head -3)
  [ -z "$bad" ] && return 0
  echo "ERROR: $dir contains something the bundle does not write ($(echo $bad | tr '\n' ' ')); move it out and run --pack again. No archive was created." >&2; return 1
}
# ---- --pack: re-scan a bundle folder you edited and create the archive if nothing sensitive is left ----
if [ -n "$PACK" ]; then
  PACK=${PACK%/}; layout_ok "$PACK" || exit 2; scan_or_stop "$PACK"
  if [ "$HITS" -gt 0 ]; then echo "WARNING: $HITS line(s) still look sensitive; see $PACK/scan.txt (file, line, rule; no values). No archive was created."; exit 1; fi
  pack_bundle "$PACK" || exit 2
  echo "OK: nothing that looks like a password, key or token is left. Archive: $PACK.tar.gz (mode 600, $(du -h "$PACK.tar.gz" | cut -f1))"; exit 0
fi

# ---- what is collected: fixed lists, nothing else is read ----
CONFS=(asterisk.conf modules.conf pjsip.conf pjsip.transports.conf pjsip.transports_custom.conf pjsip_custom.conf
  pjsip.endpoint.conf pjsip.endpoint_custom.conf pjsip.endpoint_custom_post.conf pjsip.aor.conf pjsip.aor_custom_post.conf
  pjsip.registration.conf pjsip.registration_custom_post.conf pjsip.identify.conf pjsip.identify_custom_post.conf
  rtp.conf rtp_additional.conf rtp_custom.conf logger.conf logger_general_custom.conf logger_logfiles_custom.conf
  http.conf http_additional.conf http_custom.conf extensions_custom.conf features_general_custom.conf)
NEVER="pjsip.auth.conf manager.conf manager_custom.conf manager_additional.conf voicemail.conf res_odbc.conf cdr_mysql.conf freepbx.conf amportal.conf"
CMDS=(
  "system|cat /etc/os-release; echo; uname -a; echo; uptime; echo; df -h -x tmpfs -x devtmpfs; echo; free -m; echo; date; timedatectl 2>/dev/null | head -8"
  "network|ip -br addr 2>/dev/null; echo; ip route 2>/dev/null; echo; ss -lntup 2>/dev/null | grep -Ei 'asterisk|httpd|apache|nginx|5060|5061|8089' "
  "asterisk-version|$AST -rx 'core show version'; $AST -rx 'core show uptime'"
  "asterisk-settings|$AST -rx 'core show settings'"
  "pjsip-transports|$AST -rx 'pjsip show transports'"
  "pjsip-endpoints|$AST -rx 'pjsip show endpoints'"
  "pjsip-registrations|$AST -rx 'pjsip show registrations'"
  "pjsip-contacts|$AST -rx 'pjsip show contacts'"
  "pjsip-identifies|$AST -rx 'pjsip show identifies'"
  "channels|$AST -rx 'core show channels count'; $AST -rx 'core show channels concise' | wc -l"
  "rtp|$AST -rx 'rtp show settings' 2>/dev/null"
  "modules|$AST -rx 'module show like res_pjsip' ; $AST -rx 'module show like chan_'"
  "freepbx|command -v fwconsole >/dev/null && { fwconsole -V; fwconsole ma list 2>/dev/null | head -150; }"
  "fail2ban|command -v fail2ban-client >/dev/null && { fail2ban-client status; for j in \$(fail2ban-client status 2>/dev/null | sed -n 's/.*Jail list:[[:space:]]*//p' | tr ',' ' '); do fail2ban-client status \$j; done; }"
  "services|systemctl --no-pager --plain list-units --type=service --state=failed 2>/dev/null; systemctl --no-pager status asterisk freepbx 2>/dev/null | head -30"
)
if [ "$DRY" = 1 ]; then
  echo "Would run (read-only):"; for c in "${CMDS[@]}"; do echo "  ${c%%|*}: ${c#*|}" | cut -c1-150; done
  echo "Would copy from $CONF (only if present):"; for f in "${CONFS[@]}"; do [ -f "$CONF/$f" ] && echo "  $f"; done
  echo "Never copied (only read to check that their passwords do not appear in the bundle): $NEVER"
  echo "Logs: last $LINES lines of $LOGDIR/full; last 300 lines of $LOGDIR/freepbx.log and /var/log/fail2ban.log"
  echo "Masking: passwords and secrets, digest values, private keys, e-mail addresses, $( [ $KEEP_IPS = 1 ] && echo "no IPs" || { [ $KEEP_PRIV = 1 ] && echo "public IPs" || echo "all IPs"; }), $( [ $MASK_NUM = 1 ] && echo "phone numbers" || echo "numbers kept"), $( [ $MASK_HOST = 1 ] && echo "host name" || echo "host name kept")"
  exit 0
fi

host=$(hostname -f 2>/dev/null || hostname); dom=$(hostname -d 2>/dev/null || true)
stamp=$(date +%Y%m%d-%H%M%S); name="pbx-support-$( [ $MASK_HOST = 1 ] && echo pbx || echo "${host%%.*}")-$stamp"
# RAW holds only the collected payload; WORK holds this script's own files (the password list, counters) and is
# never read into the bundle
RAW=$(mktemp -d) && WORK=$(mktemp -d) || die "mktemp failed"; trap 'rm -rf "$RAW" "$WORK"' EXIT
mkdir -p "$RAW/commands" "$RAW/config" "$RAW/logs"
n=0; got=0
"$AST" -rx "core show version" >/dev/null 2>&1 || echo "WARNING: the Asterisk CLI did not answer (not running, or not root?): only system information and files are collected" >&2
for c in "${CMDS[@]}"; do
  n=$((n+1)); lab=${c%%|*}; f=$(printf '%s/commands/%02d-%s.txt' "$RAW" "$n" "$lab")
  { echo "# ${c#*|}"; timeout 60 bash -c "${c#*|}" 2>&1; } > "$f"; [ "$(wc -l < "$f")" -gt 1 ] && got=$((got+1))
done
for f in "${CONFS[@]}"; do [ -f "$CONF/$f" ] && cp "$CONF/$f" "$RAW/config/" && got=$((got+1)); done
if [ "$LINES" -gt 0 ] && [ -r "$LOGDIR/full" ]; then tail -n "$LINES" "$LOGDIR/full" > "$RAW/logs/asterisk-full-tail.log"; got=$((got+1)); fi
[ -r "$LOGDIR/freepbx.log" ] && tail -n 300 "$LOGDIR/freepbx.log" > "$RAW/logs/freepbx-tail.log"
[ -r /var/log/fail2ban.log ] && tail -n 300 /var/log/fail2ban.log > "$RAW/logs/fail2ban-tail.log"
[ "$got" -gt 0 ] || { echo "ERROR: nothing could be collected (is this an Asterisk server? run as root)" >&2; exit 2; }

# Real passwords of this PBX, read (never copied) from the files the bundle leaves out; masked before any other rule.
perl -ne '
  if (/^\s*(?:password|secret|md5_cred)\s*=>?\s*(.*?)\s*$/i) { my $v = $1; $v =~ s/(?<!\\);.*$//; $v =~ s/\;/;/g; $v =~ s/^\s+|\s+$//g; $v =~ s/^"(.*)"$/$1/; print "$v\n" if length $v; }
  if (/\b(?:AMPDBPASS|AMPMGRPASS)["\x27]?\]?\s*=>?\s*["\x27]?([^"\x27;]+?)["\x27]?\s*;?\s*$/) { print "$1\n"; }
' "$CONF/pjsip.auth.conf" "$CONF"/manager*.conf "$CONF/voicemail.conf" "$CONF/res_odbc.conf" /etc/freepbx.conf /etc/amportal.conf > "$WORK/known" 2>/dev/null
# ---- redaction: one pass over every file, the same address always gets the same replacement ----
DEST="$OUT/$name"; mkdir -m 700 "$DEST" || die "cannot create $DEST"; mkdir "$DEST/commands" "$DEST/config" "$DEST/logs"
KNOWN="$WORK/known"; export KEEP_IPS KEEP_PRIV MASK_HOST MASK_NUM host dom KNOWN
( cd "$RAW" && find . -type f -print0 ) | perl -0 -e '
  use strict; use warnings;
  my ($raw, $dest) = @ARGV; my (%map, %cnt); my ($n4, $n6) = (0, 0);
  my ($host, $dom) = ($ENV{host} // "", $ENV{dom} // "");
  my $kre; if (open my $k, "<", $ENV{KNOWN}) { local $/ = "\n"; my %s; my @v = grep { length >= 4 && !/^\d{1,5}$/ && !$s{$_}++ } map { chomp; $_ } <$k>; close $k;
    $kre = join "|", map { quotemeta } sort { length $b <=> length $a } @v if @v; }
  sub priv4 { my @o = split /\./, $_[0]; return 1 if $o[0]==10 || $o[0]==127 || ($o[0]==172 && $o[1]>=16 && $o[1]<=31) || ($o[0]==192 && $o[1]==168) || ($o[0]==100 && $o[1]>=64 && $o[1]<=127) || $o[0]==0 || $o[0]>=224 || ($o[0]==169 && $o[1]==254); 0 }
  sub doc4 { $_[0] =~ /^(192\.0\.2|198\.51\.100|203\.0\.113)\./ }
  sub ip4 { my $ip = shift; my @o = split /\./, $ip; return $ip if grep { $_ > 255 } @o; return $ip if $ENV{KEEP_IPS};
    return $ip if doc4($ip) || $ip eq "0.0.0.0" || $ip =~ /^127\./ || $ip eq "255.255.255.255" || $ip =~ /^255\./;
    return $ip if priv4($ip) && $ENV{KEEP_PRIV};
    $map{$ip} //= do { $n4++; $n4 <= 250 ? "203.0.113." . ($n4 + 4) : "198.51.100." . ($n4 - 246) }; $cnt{ip}++; $map{$ip} }
  sub ip6 { my $a = shift; my $c = ($a =~ tr/://); return $a unless $a =~ /::/ || $c == 7; return $a if $a =~ /:::/ || $a !~ /[0-9a-f]{2}/i; return $a if $a =~ m{^(fe80|fc|fd|2001:db8)}i || $a !~ m{^[23]}; $map{lc $a} //= "2001:db8::" . (++$n6); $cnt{ip}++; $map{lc $a} }
  my %KEEP = map { $_ => 1 } qw(username realm uri algorithm qop nc stale domain);
  sub authparams { my $p = shift; $p =~ s{([A-Za-z][\w-]*)(\s*=\s*)("(?:[^"\\]|\\.)*"|[^\s,]+)}{my ($k, $e, $v) = ($1, $2, $3); $KEEP{lc $k} ? "$k$e$v" : do { $cnt{digest}++; $v =~ /^"/ ? "$k$e\"****\"" : "$k$e****" }}ge; return $p; }
  sub authval { my ($h, $v) = @_;
    return authparams($v) if $h =~ /^Authentication-Info$/i;
    if ($v =~ /^(\s*)(Digest)(\s+)(.*)$/is) { return $1 . $2 . $3 . authparams($4); }
    if ($v =~ /^(\s*)([A-Za-z][\w-]*)(\s+)\S/) { $cnt{digest}++; return "$1$2$3****"; }
    return $v; }
  local $/ = "\0";
  while (my $f = <STDIN>) { chomp $f; $f =~ s{^\./}{};
    open my $in, "<", "$raw/$f" or next; local $/; my $t = <$in>; close $in;
    if (defined $kre) { $cnt{known} += ($t =~ s/$kre/********/g); }
    $cnt{key} += ($t =~ s/-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----/[private key removed]/gs);
    $cnt{secret} += ($t =~ s/^(\s*[;#]?\s*(?:password|secret|md5_cred|passwd|pass|apikey|api_key|token|auth_?pass|pin|community|key_?pass(?:word)?)\s*(?:=>|=|:)\s*)\S.*$/$1********/gmi);
    $cnt{secret} += ($t =~ s/\b(password|secret|passwd|token|apikey|api_key)(\s*[=:]\s*"?|":\s*")(?!\*{8})[^\s"&;,]+/$1$2********/gi);
    # FreePBX logs its manager and database credentials on every reload ("Setting global variable AMPDBPASS to ...")
    my $VAR = qr/\b[A-Za-z0-9_-]*(?:PASS|SECRET|TOKEN|APIKEY|API_KEY|PIN|CRED|DBUSER|MGRUSER)[A-Za-z0-9_-]*[\x27"]?\s*(?:to|=|=>)\s*/i;
    $cnt{secret} += ($t =~ s/($VAR)([\x27"])(?!\*{8}\2)[^\n]*?\2/$1$2********$2/g);
    $cnt{secret} += ($t =~ s/($VAR)(?![\x27"*])[^\s)]+/$1********/g);
    # SDP keying material in SIP traces: SDES keys (all of them, FEC keys too), MIKEY, k= lines, ICE passwords
    $cnt{sdp} += ($t =~ s{(\binline:)(?!\*{8})[A-Za-z0-9+/]+=*}{$1********}gi);
    $cnt{sdp} += ($t =~ s{(a=key-mgmt:\s*\S+\s+)(?!\*{8})\S+}{$1********}gi);
    $cnt{sdp} += ($t =~ s{((?:^|\s)k=(?:clear|base64|uri|prompt):)(?!\*{8})\S+}{$1********}gim);
    $cnt{sdp} += ($t =~ s{(\bice-pwd[:=]\s*"?)(?!\*{8})[^\s",;]+}{$1********}gi);
    # SIP / HTTP authentication headers: keep username, realm, uri, algorithm, qop, nc; mask everything else
    # (RFC 3261 allows spaces around "=" and folded continuation lines)
    $t =~ s{\b((?:Proxy-)?Authorization|(?:WWW|Proxy)-Authenticate|Authentication-Info)(\s*:)([^\n]*(?:\n[ \t]+[^\n]*)*)}{$1 . $2 . authval($1, $3)}gie;
    $cnt{digest} += ($t =~ s{\b(response|nonce|cnonce|opaque|nextnonce|rspauth|auts)(\s*=\s*)("[^"]*"|[^\s,;"]+)}{my ($k, $e, $v) = ($1, $2, $3); $v =~ /^"?\*+"?$/ ? "$k$e$v" : ($v =~ /^"/ ? "$k$e\"****\"" : "$k$e****")}gie);
    $cnt{email} += ($t =~ s/[\w.+-]+@(?!example\.)[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}/user\@example.com/g);
    if ($ENV{MASK_HOST} && length $host > 3) { $cnt{host} += ($t =~ s/\Q$host\E/pbx.example.com/gi); }
    if ($ENV{MASK_HOST} && length $dom > 3) { $cnt{host} += ($t =~ s/\b[\w-]+\.\Q$dom\E\b/pbx.example.com/gi); $cnt{host} += ($t =~ s/\b\Q$dom\E\b/example.com/gi); }
    $t =~ s/(?<![\w.])((?:\d{1,3}\.){3}\d{1,3})(?![\w.])/ip4($1)/ge;
    unless ($ENV{KEEP_IPS}) { $t =~ s{(?<![\w:.])([0-9a-f]{0,4}(?::[0-9a-f]{0,4}){2,7})(?![\w:.])}{ip6($1)}gie; }
    if ($ENV{MASK_NUM}) { $cnt{number} += ($t =~ s/(?<![\w.\/\-\$])(\+?)(\d{5,13})(\d{2})(?![\w.:])/$1 . ("*" x length $2) . $3/ge); }
    open my $out, ">", "$dest/$f" or die "cannot write $dest/$f: $!\n"; print $out $t; close $out;
  }
  printf "masked: %d secret value(s), %d digest value(s), %d SRTP/ICE key(s), %d private key(s), %d e-mail(s), %d IP address occurrence(s) (%d distinct), %d phone number(s), %d host name(s)\n",
    map({ $cnt{$_} // 0 } qw(secret digest sdp key email ip)), scalar(keys %map), map({ $cnt{$_} // 0 } qw(number host));
  printf "KNOWN1=%d\n", $cnt{known} // 0;
' "$RAW" "$DEST" > "$WORK/redaction.txt" 2>&1; prc=$?
if [ "$prc" -ne 0 ]; then echo "ERROR: redaction failed, the bundle was removed: $(tail -1 "$WORK/redaction.txt")" >&2; rm -rf "$DEST"; exit 2; fi
KNOWN1=$(sed -n 's/^KNOWN1=//p' "$WORK/redaction.txt"); sed -i '/^KNOWN1=/d' "$WORK/redaction.txt"
# ---- safety net: the real secrets of this PBX must not appear anywhere in the bundle ----
# The values were read (never copied) before redaction and masked first; this second pass catches any occurrence
# the pattern rules may have changed around them. Short or purely numeric values under 6 digits are skipped.
known=$(find "$DEST" -type f -print0 | perl -0 -e '
  open my $k, "<", shift or exit 0; my @v; { local $/ = "\n"; @v = grep { length >= 4 && !/^\d{1,5}$/ && !/^\*+$/ } map { chomp; $_ } <$k>; } my %s; @v = grep { !$s{$_}++ } @v;
  exit 0 unless @v; my $re = join "|", map { quotemeta } sort { length $b <=> length $a } @v; my $n = 0;
  local $/ = "\0"; while (my $f = <STDIN>) { chomp $f; local $/; open my $i, "<", $f or next; my $t = <$i>; close $i;
    my $c = ($t =~ s/$re/********/g); if ($c) { $n += $c; open my $o, ">", $f or die; print $o $t; close $o } }
  print $n;' "$WORK/known")
echo "known secrets: ${KNOWN1:-0} occurrence(s) of this PBX's real passwords found and masked first, ${known:-0} more after the other rules" >> "$WORK/redaction.txt"
{
  echo "PBX support bundle created by https://srvscripts.com/scripts/pbx-support-bundle/ (v1.0.4) on $(date -u '+%F %T UTC')"
  echo "Options: lines=$LINES keep_ips=$KEEP_IPS keep_private_ips=$KEEP_PRIV mask_host=$MASK_HOST mask_numbers=$MASK_NUM"
  cat "$WORK/redaction.txt"
  echo "Not collected on purpose: $NEVER, CDR and call recordings, the FreePBX database."
  echo "Masked IP addresses use documentation ranges (203.0.113.x, 198.51.100.x, 2001:db8::); the same address always gets the same replacement."
} > "$DEST/README.txt"

# ---- final scan: anything that still looks secret? The list shows file, line number and rule, never the text ----
layout_ok "$DEST" || { rm -rf "$DEST"; exit 2; }
weak=$(perl -ne 'chomp; $n++ if length($_) && (length($_) < 4 || /^\d{1,5}$/); END { print $n // 0 }' "$WORK/known")
[ "${weak:-0}" -gt 0 ] && echo "WARNING: $weak of this PBX's passwords are too short or only digits (up to 5) to be searched for safely; they are masked only where they appear as password=... Change them: they are weak."
scan_or_stop "$DEST"; hits=$HITS
echo "Bundle folder: $DEST (mode 700)"
sed -n 3,4p "$DEST/README.txt"
echo "Files: $(find "$DEST" -type f | wc -l). Nothing was uploaded."
if [ "$hits" -gt 0 ]; then
  echo "WARNING: the final scan found $hits line(s) that may still be sensitive. No archive was created."
  echo "  The list (file, line, rule; no values) is in $DEST/scan.txt. Edit or remove those lines, then run:"
  echo "  bash $0 --pack $DEST"
  exit 1
fi
pack_bundle "$DEST" || exit 2
echo "Archive:       $DEST.tar.gz (mode 600, $(du -h "$DEST.tar.gz" | cut -f1))"
echo "Review before you send it: less -R $DEST/logs/asterisk-full-tail.log"
echo "OK: the final scan found nothing that looks like a password, key or token."
exit 0
