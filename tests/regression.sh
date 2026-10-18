#!/usr/bin/env bash
# srvScripts regression fixtures. Runs each script against small, known inputs and checks the verdict and exit code.
# Used by .github/workflows/checks.yml; a failure here keeps the release tag from being created.
# Run locally from the repository root:  sudo bash tests/regression.sh   (root is needed for the restic test only)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$T"' EXIT
pass=0; fail=0; skip=0
ok(){ pass=$((pass+1)); echo "PASS  $1"; }
bad(){ fail=$((fail+1)); echo "FAIL  $1"; [[ -n "${2:-}" ]] && sed 's/^/      | /' "$2" | head -25; [[ -n "${GITHUB_ACTIONS:-}" ]] && echo "::error::$1"; }
skp(){ skip=$((skip+1)); echo "SKIP  $1"; }
# run NAME EXPECTED_EXIT GREP_PATTERN -- command...   (pattern may be empty; "!pattern" means must NOT appear)
run(){ local name=$1 want=$2 pat=$3; shift 4; local out=$T/out.$RANDOM; "$@" >"$out" 2>&1; local rc=$?
  if [[ "$want" != "*" && "$rc" != "$want" ]]; then bad "$name (exit $rc, expected $want)" "$out"; return; fi
  if [[ -n "$pat" ]]; then if [[ "$pat" == !* ]]; then grep -Eq -- "${pat#!}" "$out" && { bad "$name (output contains '${pat#!}')" "$out"; return; }
    else grep -Eq -- "$pat" "$out" || { bad "$name (output lacks '$pat')" "$out"; return; }; fi; fi
  grep -Eq "(command not found|syntax error|unbound variable|integer expression expected)" "$out" && { bad "$name (shell error in output)" "$out"; return; }
  ok "$name"; }
S(){ echo "$ROOT/$1/$1.sh"; }

# ---- every Bash script: --help works, and the version in the file matches index.json ----
for f in "$ROOT"/*/*.sh; do s=$(basename "$(dirname "$f")"); [[ "$s" == tests || ! -f "$ROOT/$s/$s.sh" ]] && continue
  case $s in cpanel-disk-usage-report|exim-mail-queue-report|mysql-health-snapshot) ;; # check the environment before parsing options
    *) run "$s --help" 0 "" -- timeout 20 bash "$f" --help ;; esac
  v=$(python3 -c "import json,sys;print(next(x['version'] for x in json.load(open('$ROOT/index.json'))['scripts'] if x['slug']=='$s'))")
  grep -q -- "$v" "$f" && ok "$s version $v present in file" || bad "$s version $v from index.json not found in the file"
done

# ---- backup-verify ----
B=$T/backups; mkdir -p "$B/alice" "$B/bob"
head -c 300000 /dev/urandom > "$T/payload"
tar -czf "$B/alice/backup-10.7.2026_alice.tar.gz" -C "$T" payload; tar -czf "$B/alice/backup-10.8.2026_alice.tar.gz" -C "$T" payload
touch -d '-30 hours' "$B/alice/backup-10.7.2026_alice.tar.gz"
tar -czf "$B/bob/backup-10.8.2026_bob.tar.gz" -C "$T" payload
run "backup-verify: fresh, complete backups pass" 0 "" -- bash "$(S backup-verify)" "$B" --expect "alice bob" --no-color
run "backup-verify: --deep lists the archives" 0 "" -- bash "$(S backup-verify)" "$B" --expect "alice bob" --deep --no-color
run "backup-verify: missing account fails" 1 "carol" -- bash "$(S backup-verify)" "$B" --expect "alice bob carol" --no-color
cp -r "$B" "$T/old"; touch -d '-3 days' "$T"/old/*/*
run "backup-verify: stale backups fail" 1 "FAIL" -- bash "$(S backup-verify)" "$T/old" --expect "alice bob" --no-color
cp -r "$B" "$T/shrunk"; head -c 2000 /dev/urandom > "$T/small"; tar -czf "$T/shrunk/alice/backup-10.8.2026_alice.tar.gz" -C "$T" small
run "backup-verify: a backup that shrank fails" 1 "FAIL" -- bash "$(S backup-verify)" "$T/shrunk" --expect "alice bob" --no-color
cp -r "$B" "$T/broken"; head -c 150000 "$B/bob/backup-10.8.2026_bob.tar.gz" > "$T/broken/bob/backup-10.8.2026_bob.tar.gz"
run "backup-verify: --deep catches a truncated archive" 1 "FAIL" -- bash "$(S backup-verify)" "$T/broken" --expect "alice bob" --deep --no-color

# ---- web-log-top-ips ----
L=$T/access.log; now(){ date -u -d "-$1 minutes" '+%d/%b/%Y:%H:%M:%S +0000'; }
for i in $(seq 1 30); do echo "198.51.100.$i - - [$(now 5)] \"GET /page-$i HTTP/1.1\" 200 512 \"-\" \"Mozilla/5.0\""; done > "$L"
run "web-log-top-ips: quiet log is clean" 0 "198.51.100" -- bash "$(S web-log-top-ips)" --log "$L" --since=1h --no-color
for i in $(seq 1 80); do echo "203.0.113.66 - - [$(now 3)] \"POST /wp-login.php HTTP/1.1\" 200 1200 \"-\" \"python-requests/2.31\""; done >> "$L"
run "web-log-top-ips: wp-login flood is flagged" 1 "203\.0\.113\.66" -- bash "$(S web-log-top-ips)" --log "$L" --since=1h --no-color
run "web-log-top-ips: old entries are outside the window" 0 "!203\.0\.113\.66" -- bash "$(S web-log-top-ips)" --log "$L" --since=1m --no-color

# ---- php-fpm-slowlog-analyzer ----
P=$T/www-slow.log; : > "$P"
for i in 1 2 3; do printf '\n[%s]  [pool www] pid 41%02d\nscript_filename = /home/shop/public_html/index.php\n[0x00007f0001] curl_exec() /home/shop/public_html/wp-includes/class-wp-http-curl.php:298\n[0x00007f0002] request() /home/shop/public_html/wp-content/plugins/slowpay/api.php:41\n' "$(date '+%d-%b-%Y %H:%M:%S')" "$i" >> "$P"; done
run "php-fpm-slowlog-analyzer: slow requests are reported" 1 "slowpay|curl_exec" -- bash "$(S php-fpm-slowlog-analyzer)" --log "$P" --no-color
: > "$T/empty-slow.log"
run "php-fpm-slowlog-analyzer: empty slow log is clean" 0 "" -- bash "$(S php-fpm-slowlog-analyzer)" --log "$T/empty-slow.log" --no-color

# ---- mariadb-slow-query-summary ----
M=$T/slow.log
for q in "SELECT * FROM wp_options WHERE autoload = 'yes'" "SELECT * FROM wp_options WHERE autoload = 'no'" "SELECT * FROM wp_postmeta WHERE meta_key = '_price' AND meta_value > 10"; do
  printf '# Time: 261008 10:00:00\n# User@Host: shop[shop] @ localhost []\n# Query_time: 4.500000  Lock_time: 0.000100 Rows_sent: 900  Rows_examined: 250000\nSET timestamp=1791453600;\n%s;\n' "$q" >> "$M"; done
run "mariadb-slow-query-summary: queries are fingerprinted and grouped" 0 "wp_options" -- bash "$(S mariadb-slow-query-summary)" --log "$M" --no-db
run "mariadb-slow-query-summary: literal values are replaced" 0 "!_price' AND meta_value > 10" -- bash "$(S mariadb-slow-query-summary)" --log "$M" --no-db

# ---- wordpress-version-audit ----
W=$T/sites; for v in 6.4.2 7.0.5; do mkdir -p "$W/site-$v/public_html/wp-includes"; printf "<?php\n\$wp_version = '%s';\n" "$v" > "$W/site-$v/public_html/wp-includes/version.php"; echo "<?php" > "$W/site-$v/public_html/wp-load.php"; done
mkdir -p "$W/site-broken/public_html/wp-includes"; echo "<?php" > "$W/site-broken/public_html/wp-includes/version.php"; echo "<?php" > "$W/site-broken/public_html/wp-load.php"
run "wordpress-version-audit: old core is BELOW-MINIMUM" "*" "6\.4\.2.*BELOW-MINIMUM" -- bash "$(S wordpress-version-audit)" --path "$W" --min-version 7.0.3
run "wordpress-version-audit: current core meets the minimum" "*" "7\.0\.5.*MINIMUM-MET" -- bash "$(S wordpress-version-audit)" --path "$W" --min-version 7.0.3
run "wordpress-version-audit: missing version is UNKNOWN" "*" "UNKNOWN" -- bash "$(S wordpress-version-audit)" --path "$W" --min-version 7.0.3
run "wordpress-version-audit: branch fix is recognised" "*" "6\.4\.2.*BRANCH-FIXED" -- bash "$(S wordpress-version-audit)" --path "$W" --min-version 7.0.3 --branch-fix 6.4.1

# ---- ssl-expiry-check: a local TLS server with a certificate that expires in 3 days ----
if command -v openssl >/dev/null; then
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$T/k.pem" -out "$T/c.pem" -days 3 -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost" >/dev/null 2>&1
  openssl s_server -quiet -accept 127.0.0.1:18443 -cert "$T/c.pem" -key "$T/k.pem" -www >/dev/null 2>&1 & sleep 1
  run "ssl-expiry-check: certificate expiring in 3 days is flagged" 1 "" -- bash "$(S ssl-expiry-check)" -w 14 --allow-untrusted localhost:18443
  run "ssl-expiry-check: self-signed certificate is a problem without --allow-untrusted" 1 "" -- bash "$(S ssl-expiry-check)" -w 1 localhost:18443
  run "ssl-expiry-check: under the warning threshold passes with --allow-untrusted" 0 "" -- bash "$(S ssl-expiry-check)" -w 1 --allow-untrusted localhost:18443
else skp "ssl-expiry-check (openssl missing)"; fi

# ---- disk-inode-alert ----
run "disk-inode-alert: 99%/100% thresholds are clean on a runner disk" 0 "" -- bash "$(S disk-inode-alert)" --warn 99 --crit 100 --days 0 --no-state --no-scan --no-color
run "disk-inode-alert: a 1% threshold raises an alert" "*" "WARN|CRIT" -- bash "$(S disk-inode-alert)" --warn 1 --crit 99 --days 0 --no-state --no-scan --no-color

# ---- server-inventory-report: JSON output parses ----
bash "$(S server-inventory-report)" --json > "$T/inv.json" 2>"$T/inv.err"
python3 -m json.tool "$T/inv.json" >/dev/null 2>&1 && ok "server-inventory-report: --json is valid JSON" || bad "server-inventory-report: --json is not valid JSON" "$T/inv.json"

# ---- restic-offsite-backup: init, back up, restore-test, check against a local repository ----
if command -v restic >/dev/null && [[ $EUID -eq 0 ]]; then
  R=$T/restic; mkdir -p "$R/data/etc" "$R/repo"; head -c 200000 /dev/urandom > "$R/data/etc/app.bin"; echo hello > "$R/data/etc/app.conf"
  echo "test-only-password-$RANDOM" > "$R/pw"; chmod 600 "$R/pw"
  printf 'RESTIC_REPOSITORY=%s\nRESTIC_PASSWORD_FILE=%s\nRESTIC_CACHE_DIR=%s\nBACKUP_PATHS="%s"\nMYSQL_DUMP=0\nLOG_FILE=%s\n' "$R/repo" "$R/pw" "$R/cache" "$R/data" "$R/log" > "$R/conf"; chmod 600 "$R/conf"
  run "restic-offsite-backup: --init creates the repository" 0 "" -- bash "$(S restic-offsite-backup)" --init --yes --config "$R/conf"
  run "restic-offsite-backup: backup succeeds" 0 "" -- bash "$(S restic-offsite-backup)" --config "$R/conf"
  run "restic-offsite-backup: --list shows the snapshot" 0 "" -- bash "$(S restic-offsite-backup)" --list --config "$R/conf"
  run "restic-offsite-backup: --restore-test verifies a file" 0 "" -- bash "$(S restic-offsite-backup)" --restore-test --config "$R/conf"
  run "restic-offsite-backup: --check passes" 0 "" -- bash "$(S restic-offsite-backup)" --check --config "$R/conf"
  echo wrong > "$R/pw"
  run "restic-offsite-backup: wrong password fails" "*" "FAIL|wrong password" -- bash "$(S restic-offsite-backup)" --list --config "$R/conf"
else skp "restic-offsite-backup (needs restic and root)"; fi

# ---- server-security-audit: firewall rule order (fake iptables/nft; the real firewall is never read or changed) ----
FW=$T/fw; mkdir -p "$FW/bin"
printf '%s\n' '#!/bin/bash' '[ "${FAKE_IPT_FAIL:-}" = 1 ] && { echo "Permission denied (you must be root)" >&2; exit 4; }' '[ "$1" = -S ] && cat "$FAKE_IPT"; exit 0' > "$FW/bin/iptables"
printf '%s\n' '#!/bin/bash' 'exit 0' > "$FW/bin/ip6tables"
printf '%s\n' '#!/bin/bash' '[ "$1 $2" = "list ruleset" ] && exit 0; exit 0' > "$FW/bin/nft"
for x in firewall-cmd ufw csf; do printf '%s\n' '#!/bin/bash' 'exit 1' > "$FW/bin/$x"; done
chmod 755 "$FW"/bin/*
fw(){ local name=$1 want=$2; shift 2; printf '%s\n' "$@" > "$FW/rules.$RANDOM" ; local f; f=$(ls -t "$FW"/rules.* | head -1)
  run "server-security-audit firewall: $name" "*" "$want" -- env PATH="$FW/bin:$PATH" FAKE_IPT="$f" bash "$(S server-security-audit)" --no-color; }
fw "catch-all DROP policy with specific ACCEPTs passes" "PASS.*INPUT filtering verified" \
  "-P INPUT DROP" "-A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT" "-A INPUT -p tcp --dport 22 -j ACCEPT"
fw "conditional ACCEPT then catch-all DROP passes" "PASS.*INPUT filtering verified" \
  "-P INPUT ACCEPT" "-A INPUT -p tcp --dport 443 -j ACCEPT" "-A INPUT -j DROP"
fw "ACCEPT-all before DROP is a warning" "WARN.*accepts all traffic before any DROP" \
  "-P INPUT ACCEPT" "-A INPUT -j ACCEPT" "-A INPUT -j DROP"
fw "ACCEPT-all before DROP never passes" "!PASS.*INPUT filtering verified" \
  "-P INPUT ACCEPT" "-A INPUT -j ACCEPT" "-A INPUT -j DROP"
fw "DROP after a conditional ACCEPT only is unverified" "WARN.*UNVERIFIED" \
  "-P INPUT ACCEPT" "-A INPUT -s 10.0.0.0/8 -j ACCEPT" "-A INPUT -s 10.1.2.3/32 -j DROP"
fw "ban-only rules with ACCEPT policy are a warning" "WARN.*No catch-all DROP" \
  "-P INPUT ACCEPT" "-N f2b-sshd" "-A INPUT -p tcp --dport 22 -j f2b-sshd" "-A f2b-sshd -s 203.0.113.5/32 -j REJECT" "-A f2b-sshd -j RETURN"
fw "jump to a chain ending in DROP passes" "PASS.*INPUT filtering verified" \
  "-P INPUT ACCEPT" "-N LOCALINPUT" "-A INPUT -j LOCALINPUT" "-A LOCALINPUT -p tcp --dport 22 -j ACCEPT" "-A LOCALINPUT -j DROP"
run "server-security-audit firewall: unreadable rules are never a PASS" "*" "!PASS.*INPUT filtering verified" -- env PATH="$FW/bin:$PATH" FAKE_IPT=/dev/null FAKE_IPT_FAIL=1 bash "$(S server-security-audit)" --no-color

# ---- restic-offsite-backup: database-name collisions, foreign files and links, cleanup ownership (fake client/dumper) ----
if command -v restic >/dev/null && [[ $EUID -eq 0 ]]; then
  Q=$T/rq; FK2=$Q/bin; mkdir -p "$FK2" "$Q/data" "$Q/dump"; echo data > "$Q/data/f.txt"; printf SENTINEL > "$Q/sentinel"; chmod 600 "$Q/sentinel"
  printf '%s\n' '#!/bin/bash' 'printf "%s\n" shop "a b" "a?b" a_b broken' > "$FK2/mariadb"
  printf '%s\n' '#!/bin/bash' 'db="${*: -1}"; echo "-- dump of $db"; echo "CREATE TABLE t (i INT);"; [ "$db" != broken ]' > "$FK2/mariadb-dump"
  chmod 755 "$FK2"/*
  echo "test-only-password-$RANDOM" > "$Q/pw"; chmod 600 "$Q/pw"
  printf 'RESTIC_REPOSITORY=%s\nRESTIC_PASSWORD_FILE=%s\nRESTIC_CACHE_DIR=%s\nBACKUP_PATHS="%s"\nMYSQL_DUMP=yes\nDUMP_DIR=%s\nLOG_FILE=%s\n' \
    "$Q/repo" "$Q/pw" "$Q/cache" "$Q/data" "$Q/dump" "$Q/log" > "$Q/conf"; chmod 600 "$Q/conf"
  RQ=(env PATH="$FK2:$PATH" bash "$(S restic-offsite-backup)" --config "$Q/conf")
  run "restic fixtures: --init" 0 "" -- "${RQ[@]}" --init --yes
  # an earlier run's workspace: marker lists a dump that is now a link to the sentinel; a foreign dir has no marker
  chk(){ if eval "$2"; then ok "$1"; else bad "$1" "$Q/log"; fi; }
  run "restic fixtures: a failed dump makes the run fail" 1 "" -- "${RQ[@]}"
  ls_snap(){ env RESTIC_REPOSITORY="$Q/repo" RESTIC_PASSWORD_FILE="$Q/pw" RESTIC_CACHE_DIR="$Q/cache" restic ls latest 2>/dev/null | grep '\.sql$' | sed 's#.*/##' | sort; }
  chk "restic fixtures: 'a b' and 'a?b' get separate hashed dump files" '[[ $(ls_snap | grep -c "^a_b-[0-9a-f]\{8\}\.sql$") == 2 ]] && ls_snap | grep -qx a_b.sql && ls_snap | grep -qx shop.sql'
  chk "restic fixtures: failed dump is reported and not saved" '! ls_snap | grep -q broken && grep -q "dump of database .broken. failed" "$Q/log"'
  chk "restic fixtures: retention skipped after a failed dump" 'grep -q "retention skipped" "$Q/log"'
  # now plant foreign files, a link, an interrupted run whose listed dump became a link, and a workspace with no marker
  old=$Q/dump/run.QwErTy; mkdir -p "$old"; printf 'header\nlinked.sql\n' > "$old/.srvscripts-restic-run"; ln -s "$Q/sentinel" "$old/linked.sql"
  mkdir -p "$Q/dump/run.ABCDEF"; printf FOREIGN > "$Q/dump/run.ABCDEF/keep.sql"
  printf OTHER > "$Q/dump/foreign.sql"; ln -s "$Q/sentinel" "$Q/dump/evil.sql"; : > "$Q/log"
  run "restic fixtures: second run with planted files" 1 "" -- "${RQ[@]}"
  chk "restic fixtures: foreign files and links in DUMP_DIR unchanged" '[[ $(cat "$Q/dump/foreign.sql") == OTHER && -L $Q/dump/evil.sql && $(cat "$Q/sentinel") == SENTINEL ]]'
  chk "restic fixtures: workspace without a run marker left alone" '[[ $(cat "$Q/dump/run.ABCDEF/keep.sql") == FOREIGN ]] && grep -q "run.ABCDEF has no run marker" "$Q/log"'
  chk "restic fixtures: listed dump that became a link is neither followed nor deleted" '[[ $(cat "$Q/sentinel") == SENTINEL && -L $old/linked.sql ]]'
  chk "restic fixtures: second run still dumps the good databases" 'grep -q "dumped 4 of 5 database" "$Q/log"'
else skp "restic-offsite-backup fixtures (need restic and root)"; fi

# ---- asterisk-recordings-to-mp3: links, collisions and call-log failures never change other files or lose originals ----
# Fake ffmpeg/ffprobe/mysql in PATH; recordings belong to uid 65534 like a tenant-owned spool. Runs as root (CI does).
if [[ $EUID -eq 0 ]] && command -v setpriv >/dev/null; then
  A=$T/ast; FK=$A/bin; chmod 711 "$T"; mkdir -p "$FK"; chmod 711 "$A"
  printf '%s\n' '#!/bin/bash' 'out="${*: -1}"; printf FAKE-MP3 >"$out"' \
    '[ -n "${RACE_MP3:-}" ] && [ ! -e "$RACE_MP3" ] && printf OTHER >"$RACE_MP3"; exit 0' > "$FK/ffmpeg"
  printf '%s\n' '#!/bin/bash' 'printf "sample_rate=8000\nnb_samples=8000\n"' > "$FK/ffprobe"
  printf '%s\n' '#!/bin/bash' 'q="${*: -1}"' 'case "$q" in *"SELECT 1 FROM"*) echo 1 ;; *UPDATE*) [ "${FAKE_CDR:-}" = fail ] && exit 1; echo "${FAKE_ROWS:-1}" ;; *"COUNT(*)"*) echo 0 ;; esac' > "$FK/mysql"
  chmod 755 "$FK"/*
  AST=(env PATH="$FK:$PATH" RECORDINGS_MP3_LOCK="$A/lock" bash "$(S asterisk-recordings-to-mp3)")
  mkrec(){ mkdir -p "$1"; for n in "${@:2}"; do head -c 4000 /dev/urandom > "$1/$n"; done; }
  same(){ [[ "$(cat "$1" 2>/dev/null)" == "$2" ]]; }
  chk(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }
  printf SENTINEL > "$A/sentinel"; chmod 600 "$A/sentinel"
  R1=$A/r1/2026/10/09; mkrec "$R1" clean.wav part.wav link.wav exist.wav dangle.wav
  printf OLDPART > "$R1/part.mp3.part"; ln -s "$A/sentinel" "$R1/link.mp3.part"; printf EXISTING > "$R1/exist.mp3"
  ln -s "$A/created-by-link" "$R1/dangle.mp3"; ln -s "$A/sentinel" "$R1/evil.wav"
  chown -R 65534:65534 "$A/r1"; chown -h 65534:65534 "$R1"/*; touch -h -d '-10 minutes' "$R1"/*
  run "asterisk: ordinary run converts and reports the dangling final link" 0 "dangle\.mp3 is a link" -- "${AST[@]}" --dir "$A/r1"
  chk "asterisk: clean recording converted, owned by the recording owner" '[[ -f $R1/clean.mp3 && $(stat -c %u $R1/clean.mp3) == 65534 && -f $R1/clean.wav ]]'
  chk "asterisk: preexisting .mp3.part left untouched" 'same "$R1/part.mp3.part" OLDPART && [[ -f $R1/part.mp3 ]]'
  chk "asterisk: .mp3.part link to a sentinel: sentinel unchanged" 'same "$A/sentinel" SENTINEL && [[ -L $R1/link.mp3.part ]]'
  chk "asterisk: existing final MP3 unchanged" 'same "$R1/exist.mp3" EXISTING'
  chk "asterisk: dangling final link unchanged, no target created" '[[ -L $R1/dangle.mp3 && ! -e $A/created-by-link ]]'
  chk "asterisk: input link to a sentinel is not converted" '[[ ! -e $R1/evil.mp3 ]] && same "$A/sentinel" SENTINEL'
  chk "asterisk: all originals kept" '[[ -f $R1/clean.wav && -f $R1/part.wav && -f $R1/link.wav && -f $R1/exist.wav && -f $R1/dangle.wav ]]'
  R2=$A/r2; mkrec "$R2" race.wav; chown -R 65534:65534 "$R2"; touch -d '-10 minutes' "$R2"/race.wav
  run "asterisk: an MP3 that appears during conversion is reported" 1 "appeared while converting" -- env RACE_MP3="$R2/race.mp3" "${AST[@]}" --dir "$R2" --delete-original
  chk "asterisk: the MP3 that appeared is unchanged and the original kept" 'same "$R2/race.mp3" OTHER && [[ -f $R2/race.wav ]]'
  R3=$A/r3; mkrec "$R3" c1.wav; chown -R 65534:65534 "$R3"; touch -d '-10 minutes' "$R3"/c1.wav
  run "asterisk: call log update matching no row fails" 1 "matched 0 rows" -- env FAKE_ROWS=0 "${AST[@]}" --dir "$R3" --update-cdr --delete-original
  chk "asterisk: no-row update keeps the original and removes the MP3" '[[ -f $R3/c1.wav && ! -e $R3/c1.mp3 ]]'
  run "asterisk: failed call log update fails" 1 "call log update failed" -- env FAKE_CDR=fail "${AST[@]}" --dir "$R3" --update-cdr --delete-original
  chk "asterisk: failed update keeps the original" '[[ -f $R3/c1.wav && ! -e $R3/c1.mp3 ]]'
  run "asterisk: successful update deletes the original" 0 "ok  c1\.wav" -- "${AST[@]}" --dir "$R3" --update-cdr --delete-original
  chk "asterisk: after a good update only the MP3 remains" '[[ ! -e $R3/c1.wav && -f $R3/c1.mp3 ]]'
  R4=$A/r4; mkrec "$R4" rootrec.wav; chown 65534:65534 "$R4"; touch -d '-10 minutes' "$R4"/rootrec.wav
  run "asterisk: root-owned recording in a tenant folder is refused" 1 "owned by root in a folder other users can change" -- "${AST[@]}" --dir "$R4"
  chk "asterisk: refused recording kept, nothing written" '[[ -f $R4/rootrec.wav && ! -e $R4/rootrec.mp3 ]]'
else skp "asterisk-recordings-to-mp3 fixtures (need root and setpriv)"; fi

# ---- VoIP scripts (v1.0.1): failure paths found in the 17 Oct 2026 independent review must never pass as success ----
VD=$T/voip; mkdir -p "$VD/bin"
# Fake asterisk CLI: "asterisk -rx CMD". FAIL_LIST (comma-separated commands) fail like a broken CLI; EMPTY=1 answers
# "No objects found." for the PJSIP lists.
cat > "$VD/ast" <<'FAKE'
#!/bin/bash
cmd="$2"
case ",${FAIL_LIST:-}," in *",$cmd,"*) echo "Unable to connect to remote asterisk"; exit 1;; esac
case "$cmd" in
  "core show uptime seconds") printf 'System uptime: 99999\nLast reload: 999\n';;
  "core show version") echo "Asterisk 22.11.0 built by ci on a x86_64";;
  "module show like res_pjsip.so") echo "res_pjsip.so  Basic SIP resource  Running";;
  "module show like chan_sip.so") echo "0 modules loaded";;
  "pjsip show registrations") if [ "${EMPTY:-0}" = 1 ]; then echo "No objects found."; else printf ' <Registration/ServerURI....>  <Auth....>  <Status.......>\n==========\n carrier/sip:192.0.2.10:5060   carrier     Registered\n'; fi;;
  "pjsip show identifies") echo "No objects found.";;
  "pjsip show contacts") if [ "${EMPTY:-0}" = 1 ]; then echo "No objects found."; else printf '  Contact:  <Aor/ContactUri.....> <Hash> <Status> <RTT(ms)>\n  Contact:  carrier/sip:192.0.2.10:5060  ab12  Avail  12.5\n'; fi;;
  "pjsip show endpoints") if [ "${EMPTY:-0}" = 1 ]; then echo "No objects found."; else printf ' Endpoint:  <Endpoint/CID.....>  <State.....>  <Channels.>\n Endpoint:  carrier   Not in use    0 of inf\n'; fi;;
  "pjsip show endpoint anonymous") echo "Unable to find object anonymous.";;
  "core show channels count") echo "0 active calls";;
  *) echo "No such command '$cmd'"; exit 1;;
esac
FAKE
chmod +x "$VD/ast"
DET="pjsip show registrations,pjsip show identifies,pjsip show contacts,pjsip show endpoints,core show channels count"
HC=$(S pjsip-health-check)
run "pjsip-health-check: healthy fake PBX is OK and counts a trunk endpoint without caller ID" 0 "endpoints 1 " -- env ASTERISK_BIN="$VD/ast" bash "$HC"
run "pjsip-health-check: failed detail queries are UNKNOWN, never OK" 3 "UNKNOWN could not read endpoints" -- env ASTERISK_BIN="$VD/ast" FAIL_LIST="$DET" bash "$HC"
run "pjsip-health-check: genuinely empty configuration is a valid OK" 0 "^OK:" -- env ASTERISK_BIN="$VD/ast" EMPTY=1 bash "$HC"
run "pjsip-health-check: a missing required trunk is CRITICAL" 2 "required trunk backup1" -- env ASTERISK_BIN="$VD/ast" bash "$HC" --require-trunk carrier,backup1
mkdir -p "$VD/hcstate"
env ASTERISK_BIN="$VD/ast" FAIL_LIST="pjsip show contacts" bash "$HC" --quiet --notify-on-change --state-dir "$VD/hcstate" --webhook http://127.0.0.1:9/ >/dev/null 2>&1
[[ ! -e $VD/hcstate/last.webhook ]] && ok "pjsip-health-check: failed webhook delivery leaves no state (retried next run)" || bad "pjsip-health-check: failed webhook delivery leaves no state (retried next run)"

AU=$(S asterisk-security-audit); mkdir -p "$VD/conf"
run "asterisk-security-audit: unreadable identify list is UNKNOWN, not PASS" 3 "UNKNOWN Could not read the context" -- env ASTERISK_BIN="$VD/ast" FAIL_LIST="pjsip show identifies" bash "$AU" --conf "$VD/conf"
run "asterisk-security-audit: no PASS line for the check that could not run" "*" "!PASS No IP-authenticated" -- env ASTERISK_BIN="$VD/ast" FAIL_LIST="pjsip show identifies" bash "$AU" --conf "$VD/conf"
run "asterisk-security-audit: readable empty identify list passes" "*" "PASS No IP-authenticated" -- env ASTERISK_BIN="$VD/ast" bash "$AU" --conf "$VD/conf"

# Fake mysql that always fails like a wrong password
printf '#!/bin/bash\necho "ERROR 1045 (28000): Access denied for user root@localhost" >&2\nexit 1\n' > "$VD/bin/mysql"; chmod +x "$VD/bin/mysql"
run "voip-toll-fraud-watch: CDR database that cannot be queried is UNKNOWN (exit 3)" 3 "cannot query the CDR database" -- env PATH="$VD/bin:$PATH" bash "$(S voip-toll-fraud-watch)" --source db

FB=$(S freepbx-offsite-backup)
if [[ $(id -u) -eq 0 && ! -e /etc/freepbx.conf ]]; then
  MADE_AST=0; [[ -e /etc/asterisk ]] || { mkdir -p /etc/asterisk && echo "[general]" > /etc/asterisk/ci-fixture.conf && MADE_AST=1; }
  run "freepbx-offsite-backup: a database server that cannot be queried fails the backup" 2 "cannot query the database server" -- env PATH="$VD/bin:$PATH" bash "$FB" --dest "$VD/dest" --work "$VD/work1"
  # Plain-Asterisk box (no databases), "remote" copy works but the verification run fails: must NOT be reported verified
  mkdir -p "$VD/bin2"
  printf '#!/bin/bash\necho information_schema\n' > "$VD/bin2/mysql"; printf '#!/bin/bash\nexit 0\n' > "$VD/bin2/mysqldump"; chmod +x "$VD/bin2/mysql" "$VD/bin2/mysqldump"
  cat > "$VD/bin2/rsync" <<'FAKE'
#!/bin/bash
args=(); for a in "$@"; do [[ $a == --dry-run ]] && { echo "ssh: connect to host backup port 22: Connection refused" >&2; exit 12; }; done
src=${@: -2:1}; dst=${@: -1}; dst=${dst#*:}; mkdir -p "$dst" && cp -a "$src." "$dst"
FAKE
  chmod +x "$VD/bin2/rsync"
  cat > "$VD/bin2/sqlite3" <<'FAKE'
#!/bin/bash
case "$2" in .backup*) d=${2#.backup }; d=${d//\'/}; cp "$1" "$d";; PRAGMA*) echo ok;; *) echo 1;; esac
FAKE
  chmod +x "$VD/bin2/sqlite3"
  run "freepbx-offsite-backup: failed verification run is not success" 1 "NOT verified" -- env PATH="$VD/bin2:$PATH" bash "$FB" --dest "ci@backup:$VD/remote" --work "$VD/work2" --keep 1
  run "freepbx-offsite-backup: no local pruning after a failed copy" 1 "local pruning skipped" -- env PATH="$VD/bin2:$PATH" bash "$FB" --dest "ci@backup:$VD/remote" --work "$VD/work2" --keep 1
  [[ $MADE_AST -eq 1 ]] && rm -rf /etc/asterisk
else skp "freepbx-offsite-backup fixtures (need root on a machine without FreePBX)"; fi

RC=$(S recording-retention-cleaner); RD=$VD/monitor
mkold(){ local n; for n in "$@"; do mkdir -p "$RD/2026/01/01"; head -c 2000 /dev/urandom > "$RD/2026/01/01/$n"; touch -d '-200 days' "$RD/2026/01/01/$n"; done; }
mkold a.wav b.wav
tail -f -- "$RD/2026/01/01/a.wav" >/dev/null 2>&1 & H1=$!; tail -f -- "$RD/2026/01/01/b.wav" >/dev/null 2>&1 & H2=$!; sleep 0.5
run "recording-retention-cleaner: every old file open, nothing is removed" 0 "removed 0" -- bash "$RC" --dir "$RD" --days 90 --apply --quiet
[[ -f $RD/2026/01/01/a.wav && -f $RD/2026/01/01/b.wav ]] && ok "recording-retention-cleaner: both open files still exist" || bad "recording-retention-cleaner: both open files still exist"
kill "$H2" 2>/dev/null; wait "$H2" 2>/dev/null
run "recording-retention-cleaner: mixed, only the closed file is removed" 0 "removed 1" -- bash "$RC" --dir "$RD" --days 90 --apply --quiet
[[ -f $RD/2026/01/01/a.wav && ! -e $RD/2026/01/01/b.wav ]] && ok "recording-retention-cleaner: the open file survived" || bad "recording-retention-cleaner: the open file survived"
kill "$H1" 2>/dev/null; wait "$H1" 2>/dev/null
mkold $'new\nline.wav' $'tab\tname.wav' "quote'name.wav"
run "recording-retention-cleaner: unusual file names are archived and removed" 0 "removed 4" -- bash "$RC" --dir "$RD" --days 90 --apply --archive "$VD/arch" --quiet
[[ $(tar -tzf "$VD"/arch/*.tar.gz | wc -l) -eq 4 ]] && ok "recording-retention-cleaner: archive holds all 4 files" || bad "recording-retention-cleaner: archive holds all 4 files"
mkold c.wav
run "recording-retention-cleaner: dry run changes nothing" 0 "dry run" -- bash "$RC" --dir "$RD" --days 90
[[ -f $RD/2026/01/01/c.wav ]] && ok "recording-retention-cleaner: dry run kept the file" || bad "recording-retention-cleaner: dry run kept the file"




# ---- sip-tls-cert-check: local TLS servers stand in for Asterisk (no Asterisk needed; nothing is changed) ----
TC="$ROOT/sip-tls-certificate-check/sip-tls-cert-check.sh"
if command -v openssl >/dev/null && [[ -f $TC ]]; then
  K=$T/tls; mkdir -p "$K/conf"
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$K/ca.key" -out "$K/ca.pem" -days 3650 -subj "/CN=srvScripts Test CA" >/dev/null 2>&1
  leaf(){ # name days cn
    openssl req -newkey rsa:2048 -nodes -keyout "$K/$1.key" -out "$K/$1.csr" -subj "/CN=$3" >/dev/null 2>&1
    printf 'subjectAltName=DNS:%s\nextendedKeyUsage=serverAuth\n' "$3" > "$K/$1.ext"
    openssl x509 -req -in "$K/$1.csr" -CA "$K/ca.pem" -CAkey "$K/ca.key" -CAcreateserial -days "$2" -extfile "$K/$1.ext" -out "$K/$1.pem" >/dev/null 2>&1; }
  leaf good 400 pbx.test; leaf renewed 400 pbx.test; leaf soon 2 pbx.test
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$K/self.key" -out "$K/self.pem" -days 400 -subj "/CN=pbx.test" -addext "subjectAltName=DNS:pbx.test" >/dev/null 2>&1
  tls(){ # served-cert served-key file-cert file-key [port]
    printf 'tlsenable=yes\ntlsbindaddr=127.0.0.1:%s\ntlscertfile=%s\ntlsprivatekey=%s\n' "${5:-18089}" "$K/$3.pem" "$K/$4.key" > "$K/conf/http_custom.conf"
    [[ -n "${TLSPID:-}" ]] && { kill "$TLSPID" 2>/dev/null; wait "$TLSPID" 2>/dev/null; }
    openssl s_server -quiet -accept 127.0.0.1:18089 -cert "$K/$1.pem" -key "$K/$2.key" -www >/dev/null 2>&1 & TLSPID=$!; sleep 1; }
  TCR=(env ASTERISK_BIN=/bin/false bash "$TC" --conf "$K/conf" --name pbx.test)
  tls good good good good
  run "sip-tls-cert-check: trusted private-CA certificate is OK" 0 "^OK: 1 TLS" -- "${TCR[@]}" --ca "$K/ca.pem"
  run "sip-tls-cert-check: unknown CA is a warning" 1 "chain is not trusted" -- "${TCR[@]}"
  run "sip-tls-cert-check: wrong host name is a warning" 1 "does not match host name" -- env ASTERISK_BIN=/bin/false bash "$TC" --conf "$K/conf" --name sip.other.test --ca "$K/ca.pem"
  run "sip-tls-cert-check: JSON output" 0 '"status":"OK"' -- "${TCR[@]}" --ca "$K/ca.pem" --json
  tls self self self self
  run "sip-tls-cert-check: self-signed certificate is a warning" 1 "self-signed" -- "${TCR[@]}"
  tls soon soon soon soon
  run "sip-tls-cert-check: certificate expiring within --crit-days is critical" 2 "CRIT .*expires in [01] day" -- "${TCR[@]}" --ca "$K/ca.pem"
  tls good good good renewed
  run "sip-tls-cert-check: private key that does not match is critical" 2 "does not belong" -- "${TCR[@]}" --ca "$K/ca.pem"
  tls good good renewed renewed
  run "sip-tls-cert-check: renewed on disk but not reloaded is detected" 1 "renewed but not reloaded" -- "${TCR[@]}" --ca "$K/ca.pem"
  # review 17 Oct 2026 (VOIP-03): not-yet-valid leaf, missing served intermediate, expired intermediate, wrong purpose
  C2=$K/ca2; mkdir -p "$C2/new"; : > "$C2/index.txt"; echo 1000 > "$C2/serial"
  printf '[ca]\ndefault_ca=d\n[d]\ndir=%s\ndatabase=$dir/index.txt\nserial=$dir/serial\nnew_certs_dir=$dir/new\ndefault_md=sha256\npolicy=p\nunique_subject=no\ncopy_extensions=copy\n[p]\ncommonName=supplied\n[leaf]\nbasicConstraints=CA:false\nsubjectAltName=DNS:pbx.test\nextendedKeyUsage=serverAuth\n[client]\nbasicConstraints=CA:false\nsubjectAltName=DNS:pbx.test\nextendedKeyUsage=clientAuth\n[inter]\nbasicConstraints=critical,CA:true\nkeyUsage=critical,keyCertSign,cRLSign\n' "$C2" > "$C2/ca.cnf"
  sign(){ # name subject-cn signer-cert signer-key ext start end
    openssl req -newkey rsa:2048 -nodes -keyout "$K/$1.key" -out "$K/$1.csr" -subj "/CN=$2" >/dev/null 2>&1
    openssl ca -batch -config "$C2/ca.cnf" -cert "$3" -keyfile "$4" -extensions "$5" -startdate "$6" -enddate "$7" -in "$K/$1.csr" -out "$K/$1.crt" >/dev/null 2>&1
    openssl x509 -in "$K/$1.crt" -out "$K/$1.pem" >/dev/null 2>&1; }
  D(){ date -u -d "$1" +%Y%m%d%H%M%SZ; }
  sign inter "srvScripts Test Intermediate" "$K/ca.pem" "$K/ca.key" inter "$(D '-1 day')" "$(D '+1000 days')"
  sign oldint "srvScripts Expired Intermediate" "$K/ca.pem" "$K/ca.key" inter "$(D '-400 days')" "$(D '-2 days')"
  sign ileaf pbx.test "$K/inter.pem" "$K/inter.key" leaf "$(D '-1 day')" "$(D '+300 days')"
  sign oleaf pbx.test "$K/oldint.pem" "$K/oldint.key" leaf "$(D '-10 days')" "$(D '+300 days')"
  sign future pbx.test "$K/ca.pem" "$K/ca.key" leaf "$(D '+2 days')" "$(D '+300 days')"
  sign client pbx.test "$K/ca.pem" "$K/ca.key" client "$(D '-1 day')" "$(D '+300 days')"
  cat "$K/ileaf.pem" "$K/inter.pem" > "$K/ifull.pem"; cp "$K/ileaf.key" "$K/ifull.key"
  cat "$K/oleaf.pem" "$K/oldint.pem" > "$K/ofull.pem"; cp "$K/oleaf.key" "$K/ofull.key"
  if [[ -s $K/ifull.pem && -s $K/future.pem && -s $K/client.pem && -s $K/ofull.pem ]]; then
    tls future future future future
    run "sip-tls-cert-check: certificate not valid yet is critical" 2 "not valid yet" -- "${TCR[@]}" --ca "$K/ca.pem"
    tls ileaf ileaf ifull ifull
    run "sip-tls-cert-check: server without its intermediate is a warning" 1 "served chain is incomplete" -- "${TCR[@]}" --ca "$K/ca.pem"
    printf 'tlsenable=yes\ntlsbindaddr=127.0.0.1:18089\ntlscertfile=%s\ntlsprivatekey=%s\n' "$K/ifull.pem" "$K/ifull.key" > "$K/conf/http_custom.conf"
    kill "$TLSPID" 2>/dev/null; wait "$TLSPID" 2>/dev/null
    openssl s_server -quiet -accept 127.0.0.1:18089 -cert "$K/ileaf.pem" -key "$K/ileaf.key" -cert_chain "$K/inter.pem" -www >/dev/null 2>&1 & TLSPID=$!; sleep 1
    run "sip-tls-cert-check: server with the full chain is OK" 0 "^OK: 1 TLS" -- "${TCR[@]}" --ca "$K/ca.pem"
    tls oleaf oleaf ofull ofull
    run "sip-tls-cert-check: expired intermediate is critical" 2 "CA certificate .*expired" -- "${TCR[@]}" --ca "$K/ca.pem"
    tls client client client client
    run "sip-tls-cert-check: certificate not allowed for TLS servers is a warning" 1 "not allowed for TLS server use" -- "${TCR[@]}" --ca "$K/ca.pem"
  else bad "sip-tls-cert-check: could not build the chain fixtures (openssl ca)"; fi
  # 1.0.2: certificate and key in one PEM file (FreePBX tlscertfile without tlsprivatekey), encrypted key, client certificate required
  cmb(){ # served-cert served-key combined-file
    printf 'tlsenable=yes\ntlsbindaddr=127.0.0.1:18089\ntlscertfile=%s\n' "$3" > "$K/conf/http_custom.conf"
    [[ -n "${TLSPID:-}" ]] && { kill "$TLSPID" 2>/dev/null; wait "$TLSPID" 2>/dev/null; }
    openssl s_server -quiet -accept 127.0.0.1:18089 -cert "$K/$1.pem" -key "$K/$2.key" -www >/dev/null 2>&1 & TLSPID=$!; sleep 1; }
  cat "$K/good.pem" "$K/good.key" > "$K/both-ok.pem"; cat "$K/good.pem" "$K/renewed.key" > "$K/both-bad.pem"
  cmb good good "$K/both-ok.pem"
  run "sip-tls-cert-check: certificate and matching key in one PEM is OK" 0 "^OK: 1 TLS" -- "${TCR[@]}" --ca "$K/ca.pem"
  cmb good good "$K/both-bad.pem"
  run "sip-tls-cert-check: certificate and a different key in one PEM is critical" 2 "private key in .*does not belong" -- "${TCR[@]}" --ca "$K/ca.pem"
  cp "$K/good.pem" "$K/both-none.pem"; cmb good good "$K/both-none.pem"
  run "sip-tls-cert-check: one PEM without a private key is critical" 2 "no private key found" -- "${TCR[@]}" --ca "$K/ca.pem"
  openssl pkey -in "$K/good.key" -aes256 -passout pass:fixture -out "$K/enc.key" 2>/dev/null
  printf 'tlsenable=yes\ntlsbindaddr=127.0.0.1:18089\ntlscertfile=%s\ntlsprivatekey=%s\n' "$K/good.pem" "$K/enc.key" > "$K/conf/http_custom.conf"
  run "sip-tls-cert-check: encrypted key is reported, not waited on" 1 "is encrypted" -- timeout 60 "${TCR[@]}" --ca "$K/ca.pem"
  kill "$TLSPID" 2>/dev/null; wait "$TLSPID" 2>/dev/null
  openssl s_server -quiet -accept 127.0.0.1:18090 -cert "$K/good.pem" -key "$K/good.key" -CAfile "$K/ca.pem" -Verify 1 -www >/dev/null 2>&1 & TLSPID=$!; sleep 1
  run "sip-tls-cert-check: server that requires a client certificate is not OK" 1 "asks for a client certificate" -- env ASTERISK_BIN=/bin/false bash "$TC" --conf "$T" --check 127.0.0.1:18090 --name pbx.test --ca "$K/ca.pem"
  run "sip-tls-cert-check: JSON separates certificate validity from the handshake" 1 '"certificate_valid":true,"handshake_complete":false' -- env ASTERISK_BIN=/bin/false bash "$TC" --conf "$T" --check 127.0.0.1:18090 --name pbx.test --ca "$K/ca.pem" --json
  kill "$TLSPID" 2>/dev/null; wait "$TLSPID" 2>/dev/null
  openssl s_server -quiet -accept 127.0.0.1:18090 -cert "$K/good.pem" -key "$K/good.key" -CAfile "$K/ca.pem" -Verify 1 -no_tls1_3 -www >/dev/null 2>&1 & TLSPID=$!; sleep 1
  run "sip-tls-cert-check: client certificate required over TLS 1.2 is not OK either" 1 "asks for a client certificate|did not complete" -- env ASTERISK_BIN=/bin/false bash "$TC" --conf "$T" --check 127.0.0.1:18090 --name pbx.test --ca "$K/ca.pem"
  kill "$TLSPID" 2>/dev/null; wait "$TLSPID" 2>/dev/null; TLSPID=""
  tls good good good good 18099
  run "sip-tls-cert-check: nothing listening is critical" 2 "no TLS handshake" -- "${TCR[@]}" --ca "$K/ca.pem"
  kill "$TLSPID" 2>/dev/null; wait "$TLSPID" 2>/dev/null
  run "sip-tls-cert-check: nothing to check is UNKNOWN" 3 "nothing to check" -- env ASTERISK_BIN=/bin/false bash "$TC" --conf "$T"
  run "sip-tls-cert-check: bad --check value is UNKNOWN" 3 "HOST:PORT" -- env ASTERISK_BIN=/bin/false bash "$TC" --conf "$T" --check 'a;b:1'
else skp "sip-tls-cert-check (openssl or script missing)"; fi


# ---- pbx-support-bundle: secrets, digest values, public IPs and numbers never reach the bundle (fake Asterisk) ----
PB=$(S pbx-support-bundle)
if [[ -f $PB ]] && command -v perl >/dev/null; then
  B=$T/bundle; mkdir -p "$B/conf" "$B/log" "$B/bin" "$B/out" "$B/out2" "$B/out3" "$B/out4" "$B/out5"
  printf '#!/bin/bash\ncase "$2" in\n "core show version") echo "Asterisk 22.11.0";;\n "pjsip show contacts") echo " Contact: 1001/sip:1001@84.12.33.7:5062 Avail"; echo " Contact: 1004/sip:1004@[2a01:4f8:1:2::5]:5060 Avail";;\n *) echo "output of $2";;\nesac\n' > "$B/bin/asterisk"; chmod +x "$B/bin/asterisk"
  printf '[trunk-auth]\ntype=auth\nusername=trunkuser\npassword=SuperSecret123\n; secret = OldSecret99\n' > "$B/conf/pjsip_custom.conf"
  echo "secret=PjsipAuthSecret" > "$B/conf/pjsip.auth.conf"; printf '[admin]\nsecret = AmiSecret77\n' > "$B/conf/manager.conf"
  cat > "$B/log/full" <<'LOG'
[2026-10-16 20:19:45] VERBOSE[1] pbx.c: Executing [12125550123@from-internal:1] Dial("PJSIP/1002-00000007", "PJSIP/+442071838750@trunk") in new stack
Authorization: Digest username="1002",realm="asterisk",nonce="1792199985/7fea92",response="8d5bc810081ae870537f3dec158ca74c",cnonce="327b23c6"
From: "Alice" <sip:alice@company.co.uk>;tag=1
Contact: <sip:1001@84.12.33.7:5062> lan 10.0.0.5 linkedid 1792200256.818317 time 20:19:45 v6 2001:4860:4860::8888
[2026-10-16 20:02:14] VERBOSE[2] pbx_variables.c: Setting global variable 'AMPMGRPASS' to 'aB3dE5fG7hJ9'
[2026-10-16 20:02:14] VERBOSE[2] pbx_variables.c: Setting global variable 'AMPDBPASS' to 'Zx9Qw8Lk'
[2026-10-16 20:05:00] VERBOSE[1] app_custom.c: debug dump: login ok with AmiSecret77 for remote user
-----BEGIN RSA PRIVATE KEY-----
MIIEpAIBAAKCAQEAtest
-----END RSA PRIVATE KEY-----
LOG
  PBR=(env ASTERISK_BIN="$B/bin/asterisk" bash "$PB" --conf "$B/conf" --logdir "$B/log")
  run "pbx-support-bundle: dry run lists sources and collects nothing" 0 "Never copied" -- "${PBR[@]}" --dry-run --out "$B/out"
  [[ -z $(ls -A "$B/out") ]] && ok "pbx-support-bundle: dry run wrote nothing" || bad "pbx-support-bundle: dry run wrote nothing"
  run "pbx-support-bundle: bundle created, final scan clean" 0 "known secrets: 1 occurrence" -- "${PBR[@]}" --out "$B/out"
  BD=$(ls -d "$B"/out/pbx-support-*/ 2>/dev/null | head -1)
  if [[ -n $BD ]]; then
    grep -rqE 'SuperSecret123|OldSecret99|PjsipAuthSecret|AmiSecret77|aB3dE5fG7hJ9|Zx9Qw8Lk|8d5bc810|7fea92|MIIEpAIBAAKCAQEAtest|alice@company|84\.12\.33\.7|2001:4860|12125550123|442071838750' "$BD" \
      && bad "pbx-support-bundle: no secret, digest, key, e-mail, public IP or phone number in the bundle" || ok "pbx-support-bundle: no secret, digest, key, e-mail, public IP or phone number in the bundle"
    [[ ! -e $BD/config/pjsip.auth.conf && ! -e $BD/config/manager.conf ]] && ok "pbx-support-bundle: password files are never copied" || bad "pbx-support-bundle: password files are never copied"
    grep -q '10\.0\.0\.5' "$BD/logs/asterisk-full-tail.log" && grep -q '20:19:45' "$BD/logs/asterisk-full-tail.log" && grep -q 'PJSIP/1002-00000007' "$BD/logs/asterisk-full-tail.log" \
      && ok "pbx-support-bundle: private IPs, times and channel names are kept" || bad "pbx-support-bundle: private IPs, times and channel names are kept" "$BD/logs/asterisk-full-tail.log"
    [[ $(stat -c %a "$BD") == 700 && $(stat -c %a "${BD%/}.tar.gz") == 600 ]] && ok "pbx-support-bundle: folder 700, archive 600" || bad "pbx-support-bundle: folder 700, archive 600"
  else bad "pbx-support-bundle: no bundle folder"; fi
  run "pbx-support-bundle: --keep-ips keeps public addresses" 0 "" -- "${PBR[@]}" --out "$B/out2" --keep-ips
  grep -rq '84\.12\.33\.7' "$B"/out2/pbx-support-*/ && ok "pbx-support-bundle: --keep-ips output has the address" || bad "pbx-support-bundle: --keep-ips output has the address"
  printf '%s\n' "token-like blob: QWxhZGRpbjpvcGVuIHNlc2FtZVFXeGhaR1JwYmpwdmNHVnVJSE5sYzJGdFpRPT1RV3hoWkdScGJqcHZjR1Z1SUhObGMyRnRaUT09" >> "$B/log/full"
  run "pbx-support-bundle: something the masks miss is reported (exit 1), no archive" 1 "No archive was created" -- "${PBR[@]}" --out "$B/out3"
  BD3=$(ls -d "$B"/out3/pbx-support-*/ 2>/dev/null | head -1); BD3=${BD3%/}
  if [[ -n $BD3 ]]; then
    [[ ! -e $BD3.tar.gz ]] && ok "pbx-support-bundle: no archive while the scan finds something" || bad "pbx-support-bundle: no archive while the scan finds something"
    grep -q 'long-token' "$BD3/scan.txt" && ! grep -q 'QWxhZGRpbjpvcGVu' "$BD3/scan.txt" && ok "pbx-support-bundle: scan.txt names the rule, never the value" || bad "pbx-support-bundle: scan.txt names the rule, never the value" "$BD3/scan.txt"
    sed -i '/token-like blob/d' "$BD3/logs/asterisk-full-tail.log"
    run "pbx-support-bundle: --pack after the fix creates the archive" 0 "Archive: " -- bash "$PB" --pack "$BD3"
    [[ -s $BD3.tar.gz && $(stat -c %a "$BD3.tar.gz") == 600 ]] && ok "pbx-support-bundle: packed archive exists, mode 600" || bad "pbx-support-bundle: packed archive exists, mode 600"
  else bad "pbx-support-bundle: no bundle folder for the scan test"; fi
  sed -i '/token-like blob/d' "$B/log/full"
  # review 17 Oct 2026 (VOIP-01, VOIP-06, VOIP-15): spaced Digest values, other auth headers, spaced known password, Bearer, failed archive
  printf 'password=aa FixtureSpacedCredential ; old note\n' >> "$B/conf/pjsip.auth.conf"
  cat >> "$B/log/full" <<'LOG'
Authorization: Digest username="fixture", realm="asterisk", response = "abcdefabcdefabcdefabcdefabcdefab", nonce = "nonceFixtureAlpha", cnonce= cnonceFixtureBeta
Proxy-Authorization: Digest username="fx2", response="fedcbafedcbafedcbafedcbafedcba99",
	opaque="opaqueFixtureGamma"
Authentication-Info: rspauth="rspauthFixtureDelta", nextnonce="nextnonceFixtureEps"
Authorization: Bearer fixtureBearerCredentialABC
NOTICE arbitrary debug text aa FixtureSpacedCredential end
LOG
  run "pbx-support-bundle: spaced Digest values, Bearer and spaced passwords are masked (exit 0)" 0 "Archive: " -- "${PBR[@]}" --out "$B/out4"
  BD4=$(ls -d "$B"/out4/pbx-support-*/ 2>/dev/null | head -1)
  if [[ -n $BD4 ]]; then
    grep -rqE 'abcdefabcdef|nonceFixtureAlpha|cnonceFixtureBeta|fedcbafedcba|opaqueFixtureGamma|rspauthFixtureDelta|nextnonceFixtureEps|fixtureBearerCredentialABC|FixtureSpacedCredential' "$BD4" \
      && bad "pbx-support-bundle: no auth value or spaced password survives" "$BD4/logs/asterisk-full-tail.log" || ok "pbx-support-bundle: no auth value or spaced password survives"
    grep -q 'username="fixture"' "$BD4/logs/asterisk-full-tail.log" && ok "pbx-support-bundle: Digest username and realm are kept" || bad "pbx-support-bundle: Digest username and realm are kept" "$BD4/logs/asterisk-full-tail.log"
  else bad "pbx-support-bundle: no bundle folder for the auth test"; fi
  mkdir -p "$B/badtar"; printf '#!/bin/sh\necho "synthetic archive failure" >&2\nexit 2\n' > "$B/badtar/tar"; chmod +x "$B/badtar/tar"
  run "pbx-support-bundle: a failed archive is an error (exit 2), not OK" 2 "archive could not be created" -- env PATH="$B/badtar:$PATH" ASTERISK_BIN="$B/bin/asterisk" bash "$PB" --conf "$B/conf" --logdir "$B/log" --out "$B/out5"
  ls "$B"/out5/*.tar.gz >/dev/null 2>&1 && bad "pbx-support-bundle: no archive left after a failed tar" || ok "pbx-support-bundle: no archive left after a failed tar"
  # ---- 1.0.2: SDP keys, spaced FreePBX variable, scan failures, README, archive name collisions ----
  C=$T/bundle2; mkdir -p "$C/conf" "$C/log" "$C/o1" "$C/o2"
  printf '[admin]\nsecret=aa FixtureSpacedCredential\n' > "$C/conf/manager_custom.conf"
  cat > "$C/log/full" <<'LOG'
<--- Received SIP request (1146 bytes) from PJSIP/1001 --->
INVITE sip:1002@pbx.test SIP/2.0
Content-Type: application/sdp

v=0
o=- 1 1 IN IP4 10.0.0.5
s=-
c=IN IP4 10.0.0.5
t=0 0
m=audio 12000 RTP/SAVP 0
a=crypto:1 AES_CM_128_HMAC_SHA1_80 inline:QUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFB|2^20|1:1;inline:QkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJC|2^20|2:1
a=crypto:2 AES_CM_128_HMAC_SHA1_32 inline:Q0NDQ0NDQ0NDQ0NDQ0ND FEC_KEY=inline:RkVDS0VZRkVDS0VZRkVD
a=key-mgmt:mikey AQAFgM0XflABAAAAAAAAAAAAAAsAyOuzAAAA
k=base64:c2VjcmV0a2V5Zml4dHVyZQ==
a=ice-ufrag:abcd
a=ice-pwd:SyntheticICEPasswordAbc
[2026-10-16 20:02:14] VERBOSE[2] pbx_variables.c: Setting global variable 'AMPMGRPASS' to 'aa FixtureSpacedCredential'
LOG
  PBC=(env ASTERISK_BIN="$B/bin/asterisk" bash "$PB" --conf "$C/conf" --logdir "$C/log")
  run "pbx-support-bundle: SDES, FEC, MIKEY, k= and ICE keys in a SIP trace are masked (exit 0)" 0 "SRTP/ICE key" -- "${PBC[@]}" --out "$C/o1"
  CD1=$(ls -d "$C"/o1/pbx-support-*/ 2>/dev/null | head -1); CD1=${CD1%/}
  if [[ -n $CD1 && -f $CD1.tar.gz ]]; then
    X=$C/x1; mkdir -p "$X"; tar -xzf "$CD1.tar.gz" -C "$X"
    grep -rqE 'QUFBQUFB|QkJCQkJC|Q0NDQ0ND|RkVDS0VZ|AQAFgM0X|c2VjcmV0a2V5|SyntheticICEPassword|FixtureSpacedCredential' "$CD1" "$X" \
      && bad "pbx-support-bundle: no SRTP/ICE key or password suffix in the folder or the archive" "$CD1/logs/asterisk-full-tail.log" || ok "pbx-support-bundle: no SRTP/ICE key or password suffix in the folder or the archive"
    grep -q "to '\*\*\*\*\*\*\*\*'" "$CD1/logs/asterisk-full-tail.log" && ok "pbx-support-bundle: spaced FreePBX variable value masked whole" || bad "pbx-support-bundle: spaced FreePBX variable value masked whole" "$CD1/logs/asterisk-full-tail.log"
    grep -q 'ice-ufrag:abcd' "$CD1/logs/asterisk-full-tail.log" && ok "pbx-support-bundle: non-secret SDP lines are kept" || bad "pbx-support-bundle: non-secret SDP lines are kept"
  else bad "pbx-support-bundle: no archive for the SDP key test"; fi
  # --pack must fail closed: scanner error, README.txt content, a folder or link where the archive should go
  P1=$C/p1; mkdir -p "$P1/logs" "$P1/scan.txt"; echo 'password=FixtureMustNotBePacked' > "$P1/logs/data.txt"
  run "pbx-support-bundle: --pack with scan.txt as a folder stops (exit 2), no archive" 2 "not a plain file" -- bash "$PB" --pack "$P1"
  [[ ! -e $P1.tar.gz ]] && ok "pbx-support-bundle: no archive after a failed scan" || bad "pbx-support-bundle: no archive after a failed scan"
  P2=$C/p2; mkdir -p "$P2/logs"; echo 'note'> "$P2/logs/a.txt"; echo 'secret=FixtureMustNotBePacked' > "$P2/README.txt"
  run "pbx-support-bundle: --pack scans README.txt too (exit 1)" 1 "still look sensitive" -- bash "$PB" --pack "$P2"
  [[ ! -e $P2.tar.gz ]] && grep -q 'README.txt:1: assignment' "$P2/scan.txt" && ! grep -q FixtureMustNotBePacked "$P2/scan.txt" \
    && ok "pbx-support-bundle: README.txt finding listed without its value, no archive" || bad "pbx-support-bundle: README.txt finding listed without its value, no archive" "$P2/scan.txt"
  P3=$C/p3; mkdir -p "$P3/logs"; echo 'clean' > "$P3/logs/a.txt"; echo 'secret=FixtureMustNotBePacked' > "$P3/logs/b.txt"; chmod 000 "$P3/logs/b.txt"
  if [[ $(id -u) != 0 ]]; then
    run "pbx-support-bundle: --pack with an unreadable file stops (exit 2)" 2 "scan failed" -- bash "$PB" --pack "$P3"
    [[ ! -e $P3.tar.gz ]] && ok "pbx-support-bundle: no archive when a file cannot be scanned" || bad "pbx-support-bundle: no archive when a file cannot be scanned"
  else skp "pbx-support-bundle: unreadable-file scan (running as root)"; fi
  chmod 600 "$P3/logs/b.txt"
  P4=$C/p4; mkdir -p "$P4/logs" "$P4.tar.gz"; echo 'clean' > "$P4/logs/a.txt"
  run "pbx-support-bundle: archive name that is a folder is refused (exit 2)" 2 "not a plain file" -- bash "$PB" --pack "$P4"
  [[ -z $(ls -A "$P4.tar.gz") ]] && ok "pbx-support-bundle: nothing moved into that folder" || bad "pbx-support-bundle: nothing moved into that folder"
  P5=$C/p5; mkdir -p "$P5/logs" "$C/elsewhere"; echo 'clean' > "$P5/logs/a.txt"; ln -s "$C/elsewhere" "$P5.tar.gz"
  run "pbx-support-bundle: archive name that is a link is refused (exit 2)" 2 "not a plain file" -- bash "$PB" --pack "$P5"
  P6=$C/p6; mkdir -p "$P6/logs"; echo 'clean' > "$P6/logs/a.txt"
  run "pbx-support-bundle: --pack of a clean folder creates the archive (exit 0)" 0 "Archive: " -- bash "$PB" --pack "$P6"
  [[ -f $P6.tar.gz && ! -L $P6.tar.gz && $(stat -c %a "$P6.tar.gz") == 600 ]] && ok "pbx-support-bundle: packed archive is a plain file, mode 600" || bad "pbx-support-bundle: packed archive is a plain file, mode 600"
  # ---- 1.0.3: the password list never enters the bundle; several known passwords are masked whole ----
  E=$T/bundle3; mkdir -p "$E/c1" "$E/c2" "$E/log" "$E/o1" "$E/o2"
  echo 'NOTICE harmless line' > "$E/log/full"; printf '[auth]\npassword=1234\n' > "$E/c1/pjsip.auth.conf"; touch "$E/c1/pjsip.conf"
  run "pbx-support-bundle: a short numeric known password gives a warning, not a file" 0 "too short or only digits" -- env ASTERISK_BIN="$B/bin/asterisk" bash "$PB" --conf "$E/c1" --logdir "$E/log" --out "$E/o1"
  ED1=$(ls -d "$E"/o1/pbx-support-*/ 2>/dev/null | head -1); ED1=${ED1%/}
  if [[ -n $ED1 && -f $ED1.tar.gz ]]; then
    members=$(tar -tzf "$ED1.tar.gz"); X=$E/x1; mkdir -p "$X"; tar -xzf "$ED1.tar.gz" -C "$X"
    { [[ -z $(find "$ED1" "$X" -name known) ]] && ! grep -qvE "^[^/]+/((README|scan)\.txt|(commands|config|logs)/([^/]+)?)?$" <<<"$members" && ! grep -rqw 1234 "$ED1" "$X"; } \
      && ok "pbx-support-bundle: no password list and no other unexpected file in folder or archive" || bad "pbx-support-bundle: no password list and no other unexpected file in folder or archive"
  else bad "pbx-support-bundle: no archive for the password-list test"; fi
  printf '[auth]\npassword=aa FixtureSpacedCredential\n' > "$E/c2/pjsip.auth.conf"; printf '[ami]\nsecret=SecondFixtureCredential\n' > "$E/c2/manager_custom.conf"; touch "$E/c2/pjsip.conf"
  printf 'NOTICE custom password=aa FixtureSpacedCredential\nNOTICE other SecondFixtureCredential end\n' > "$E/log/full"
  run "pbx-support-bundle: two known passwords, one with a space, are masked whole (exit 0)" 0 "Archive: " -- env ASTERISK_BIN="$B/bin/asterisk" bash "$PB" --conf "$E/c2" --logdir "$E/log" --out "$E/o2"
  ED2=$(ls -d "$E"/o2/pbx-support-*/ 2>/dev/null | head -1); ED2=${ED2%/}
  if [[ -n $ED2 && -f $ED2.tar.gz ]]; then X=$E/x2; mkdir -p "$X"; tar -xzf "$ED2.tar.gz" -C "$X"
    grep -rqE 'FixtureSpacedCredential|SecondFixtureCredential' "$ED2" "$X" && bad "pbx-support-bundle: no part of either known password survives" "$ED2/logs/asterisk-full-tail.log" || ok "pbx-support-bundle: no part of either known password survives"
  else bad "pbx-support-bundle: no archive for the two-password test"; fi
  P7=$C/p7; mkdir -p "$P7/logs"; echo 'clean' > "$P7/logs/a.txt"; echo 'clean' > "$P7/extra.txt"
  run "pbx-support-bundle: --pack refuses files the bundle does not write (exit 2)" 2 "does not write" -- bash "$PB" --pack "$P7"
  run "pbx-support-bundle: bad option is UNKNOWN" 3 "unknown option" -- bash "$PB" --nope
else skp "pbx-support-bundle (script or perl missing)"; fi

# ---- sipp-call-load-test: success only when every count adds up (stub SIPp and CDR; no SIP traffic, no calls) ----
SP=$(S sipp-call-load-test)
if [[ -f $SP ]] && command -v python3 >/dev/null; then
  L=$T/sipp; mkdir -p "$L/bin"
  # screen file in the format SIPp 3.6.1 writes with -trace_screen (taken from a lab run, counters set per test)
  mkscr(){ # created ok failed [cut]  -> $L/screen
    python3 - "$@" > "$L/screen" <<'PY'
import sys
c,o,f=sys.argv[1:4]; cut=len(sys.argv)>4
print("""------------------------------ Scenario Screen -------- [1-9]: Change Screen --
  Call rate (length)   Port   Total-time  Total-calls  Remote-host
  5.0(2000 ms)/1.000s   25070      4.15 s            %s  127.0.0.1:5060(UDP)

                                 Messages  Retrans   Timeout   Unexpected-Msg
    REGISTER ---------->         %s         0         0
         401 <----------         %s         0         0         0
    REGISTER ---------->         %s         0         0
         200 <----------         %s         0         0         0
      INVITE ---------->         %s         0         0
         200 <----------  E-RTD1 %s         0         0         0
         BYE ---------->         %s         0         0
         200 <----------         %s         0         0         0""" % (c,c,c,c,c,c,o,o,o))
if not cut:
  print("""----------------------------- Statistics Screen ------- [1-9]: Change Screen --
-------------------------+---------------------------+--------------------------
  Counter Name           | Periodic value            | Cumulative value
-------------------------+---------------------------+--------------------------
  Incoming calls created |        0                  |        0
  Outgoing calls created |        0                  |        %s
  Total Calls created    |                           |        %s
  Current Calls          |        0                  |
-------------------------+---------------------------+--------------------------
  Successful call        |        0                  |        %s
  Failed call            |        0                  |        %s
-------------------------+---------------------------+--------------------------""" % (c,c,o,f))
PY
  }
  # SIPp stub: writes the prepared screen file where SIPp would, records its arguments, exits with $FX_RC
  printf '#!/bin/sh\necho "$@" > "%s/sipp.args"\ncp "%s/screen" "./phone_$$_screen.log"\n: > err.log\nexit ${FX_RC:-0}\n' "$L" "$L" > "$L/bin/sipp"
  # mysql stub: CDR rows from $L/cdr.tsv are queried with SQLite (same predicate text), or counts from $L/seq
  cat > "$L/bin/mysql" <<'PY'
#!/usr/bin/env python3
import sys, os, re, sqlite3, datetime
L=os.environ["FX_DIR"]; q=sys.argv[sys.argv.index("-e")+1]
open(L+"/sql.log","a").write(q+"\n")
if "SELECT 1 FROM cdr" in q: print(1); sys.exit(0)
if "FROM trunks" in q:
    if os.path.exists(L+"/trunks"): sys.stdout.write(open(L+"/trunks").read()); sys.exit(0)
    sys.exit(1)
if os.path.exists(L+"/seq") and "COUNT(DISTINCT uniqueid)" in q:
    lines=open(L+"/seq").read().split("\n"); lines=[x for x in lines if x]; n=int(open(L+"/seqn").read()) if os.path.exists(L+"/seqn") else 0
    print(lines[min(n,len(lines)-1)]); open(L+"/seqn","w").write(str(n+1)); sys.exit(0)
db=sqlite3.connect(":memory:"); db.create_function("REGEXP",2,lambda p,v: 1 if v is not None and re.search(p,v) else 0)
db.execute("CREATE TABLE cdr(calldate TEXT, src TEXT, dst TEXT, dstchannel TEXT, disposition TEXT, lastapp TEXT, uniqueid TEXT)")
now=datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
for i,l in enumerate(open(L+"/cdr.tsv").read().split("\n")):
    if l: f=l.split("\t"); db.execute("INSERT INTO cdr VALUES(?,?,?,?,?,?,?)",(now,f[0],f[1],f[2],f[3],f[4],"u%d"%i))
q=re.sub(r"(\w+) REGEXP '([^']*)'", r"REGEXP('\2',\1)", q).replace("\\_","_")
for r in db.execute(q): print("\t".join(str(x) for x in r))
PY
  chmod +x "$L/bin/sipp" "$L/bin/mysql"
  printf 'custom\tPJSIP/$OUTNUM$@labcarrier\npjsip\tother_trunk\n' > "$L/trunks"
  cdr(){ : > "$L/cdr.tsv"; rm -f "$L/seq" "$L/seqn" "$L/sql.log"; local x; for x in "$@"; do printf '1002\t12125550123\t%s\tANSWERED\tDial\n' "$x" >> "$L/cdr.tsv"; done; }
  spr(){ env PATH="$L/bin:$PATH" FX_DIR="$L" ASTERISK_BIN=/nonexistent CDR_WAIT="${CW:-0}" SIPP_SECRET=fixturepass bash "$SP" --ext 1002 --number 12125550123 --hold 1 --yes "$@"; }
  T5=(PJSIP/labcarrier-00000001 PJSIP/labcarrier-00000002 PJSIP/labcarrier-00000003 PJSIP/labcarrier-00000004 PJSIP/labcarrier-00000005)
  mkscr 5 5 0; cdr "${T5[@]}"
  run "sipp-call-load-test: all calls answered on the trunk is OK" 0 "OK: all 5 call\(s\) were started, answered and answered on a listed trunk" -- spr --calls 5
  grep -q "dstchannel LIKE 'PJSIP/labcarrier-%'" "$L/sql.log" && grep -q "PJSIP/other\\\\_trunk-%" "$L/sql.log" && ! grep -q "NOT LIKE 'Local" "$L/sql.log" && grep -q "calldate BETWEEN" "$L/sql.log" \
    && ok "sipp-call-load-test: trunk list from FreePBX, start and end time in the CDR query" || bad "sipp-call-load-test: trunk list from FreePBX, start and end time in the CDR query" "$L/sql.log"
  mkscr 1 1 0; cdr PJSIP/labcarrier-00000001
  FX_RC=124 run "sipp-call-load-test: stopped by the time limit after one call is INCOMPLETE (exit 1)" 1 "INCOMPLETE: SIPp did not finish" -- spr --calls 30
  FX_RC=124 run "sipp-call-load-test: one of 30 started never prints all OK" 1 "!OK: all" -- spr --calls 30
  mkscr 0 0 0; cdr
  FX_RC=99 run "sipp-call-load-test: no call started is an error (exit 2)" 2 "started no calls" -- spr --calls 30
  mkscr 5 5 0 cut; cdr "${T5[@]}"
  run "sipp-call-load-test: screen without the counters is INCOMPLETE" 1 "counters are missing" -- spr --calls 5
  mkscr 5 3 2; cdr "${T5[@]:0:3}"
  FX_RC=1 run "sipp-call-load-test: failed calls are reported (exit 1)" 1 "WARNING: 2 call\(s\) failed" -- spr --calls 5
  mkscr 5 5 0; cdr "${T5[@]:0:3}" PJSIP/1003-00000006 PJSIP/1004-00000007
  run "sipp-call-load-test: calls answered by an extension are not carrier delivery" 1 "answered on a listed trunk: 3 of 5" -- spr --calls 5
  cdr "${T5[@]}" PJSIP/labcarrier-00000009
  run "sipp-call-load-test: another call in the same window makes the result untrusted" 1 "more call records \(6\) than calls placed" -- spr --calls 5
  cdr; printf '3\t3\n5\t5\n5\t5\n' > "$L/seq"
  CW=6 run "sipp-call-load-test: late call records are waited for" 0 "answered on a listed trunk: 5 of 5" -- spr --calls 5
  cdr; printf '3\t3\n' > "$L/seq"
  CW=2 run "sipp-call-load-test: call records that never arrive are reported" 1 "only 3 call record" -- spr --calls 5
  cdr "${T5[@]}"; mv "$L/trunks" "$L/trunks.off"; rm -f "$L/sipp.args"
  run "sipp-call-load-test: no trunk list and no --carrier is refused before calling" 3 "trunk list" -- spr --calls 5
  [[ ! -e $L/sipp.args ]] && ok "sipp-call-load-test: SIPp not started without a trunk list" || bad "sipp-call-load-test: SIPp not started without a trunk list"
  run "sipp-call-load-test: --carrier regex counts the trunk" 0 "OK: all 5" -- spr --calls 5 --carrier '^PJSIP/labcarrier-'
  mv "$L/trunks.off" "$L/trunks"
  run "sipp-call-load-test: --no-cdr says delivery is not verified" 0 "delivery to the carrier was NOT verified" -- spr --calls 5 --no-cdr
  for r in 0 0.0 abc -1; do rm -f "$L/sipp.args"
    run "sipp-call-load-test: --rate $r is refused" 3 "rate" -- spr --calls 5 --rate "$r"
    [[ ! -e $L/sipp.args ]] || bad "sipp-call-load-test: SIPp started with --rate $r"; done
  run "sipp-call-load-test: --rate 100000 is refused" 3 "between 0.01 and 1000" -- spr --calls 5 --rate 100000
  run "sipp-call-load-test: a plan longer than 24 hours is refused" 3 "more than 24 hours" -- spr --calls 5000 --rate 0.01
  for r in 0.5 0.01 00.5 2 250; do
    run "sipp-call-load-test: --rate $r runs" 0 "OK: all 5" -- spr --calls 5 --rate "$r"
    grep -q -- "-r $r " "$L/sipp.args" || bad "sipp-call-load-test: SIPp got -r $r" "$L/sipp.args"; done
  run "sipp-call-load-test: bad option is refused" 3 "unknown option" -- spr --nope
else skp "sipp-call-load-test (script or python3 missing)"; fi

# ---- mariadb-watchdog: hang detection and every safety guard (fake client, fake mariadbd process, stub systemctl) ----
if [[ -f "$(S mariadb-watchdog)" ]]; then
  WB=$T/wdbin; mkdir -p "$WB"; WS=$T/wdstate; WL=$T/wdlogs
  cp "$(command -v sleep)" "$WB/mariadbd"                       # a process whose name is mariadbd
  cat > "$WB/mariadb" <<'EOF'
#!/bin/bash
case "$(cat "$WD_MODE_FILE" 2>/dev/null)" in
  hang) sleep 30 ;; denied) echo "ERROR 1045 (28000): Access denied for user 'x'@'localhost'" >&2; exit 1 ;;
  busy) echo "ERROR 1040 (HY000): Too many connections" >&2; exit 1 ;; *) echo 1 ;;
esac
EOF
  cat > "$WB/systemctl" <<'EOF'
#!/bin/bash
echo "$*" >> "$WD_SYSTEMCTL_LOG"
case "$1" in
  is-active) pgrep -x mariadbd >/dev/null && echo active || echo inactive ;;
  stop) pkill -x mariadbd; sleep 1 ;;
  kill) pkill -9 -x mariadbd ;;
  start) (exec -a mariadbd "$WD_BIN/mariadbd" 600 & ) ; echo ok > "$WD_MODE_FILE" ;;
esac
exit 0
EOF
  chmod +x "$WB/mariadb" "$WB/systemctl"
  export WD_MODE_FILE=$T/wdmode WD_SYSTEMCTL_LOG=$T/wdsysctl.log WD_BIN=$WB
  ( exec -a mariadbd "$WB/mariadbd" 600 & ); sleep 1
  WD(){ PATH="$WB:$PATH" bash "$(S mariadb-watchdog)" --state-dir "$WS" --log-dir "$WL" --service mariadb --grace 0 --timeout 2 "$@"; }
  echo ok > "$WD_MODE_FILE"
  run "mariadb-watchdog: healthy server" 0 "OK: answered SELECT 1" -- WD
  echo denied > "$WD_MODE_FILE"
  run "mariadb-watchdog: wrong login is a config error, never a restart" 3 "never a reason to restart" -- WD --restart
  echo busy > "$WD_MODE_FILE"
  run "mariadb-watchdog: too many connections is not a hang" 1 "BUSY" -- WD --restart --fails 1
  echo hang > "$WD_MODE_FILE"; rm -rf "$WS"
  run "mariadb-watchdog: hang 1 of 3 only counts" 1 "HUNG \(1/3\)" -- WD --restart
  run "mariadb-watchdog: hang 2 of 3 only counts" 1 "HUNG \(2/3\)" -- WD --restart
  run "mariadb-watchdog: grace period holds the restart" 1 "grace 3600s" -- WD --restart --grace 3600
  ( exec -a mariadb-dump "$WB/mariadbd" 30 & ); sleep 1
  run "mariadb-watchdog: a running backup holds the restart" 1 "a backup is running" -- WD --restart
  pkill -f "^mariadb-dump" 2>/dev/null
  run "mariadb-watchdog: report-only never restarts" 2 "would restart" -- WD
  if grep -Eq "^(stop|start|kill)" "$WD_SYSTEMCTL_LOG" 2>/dev/null; then bad "mariadb-watchdog: systemctl stop/start called before --restart"; else ok "mariadb-watchdog: no stop/start before --restart"; fi
  run "mariadb-watchdog: --restart restarts and waits for an answer" 2 "answers again" -- WD --restart --stop-timeout 10 --wait-up 30
  run "mariadb-watchdog: healthy again, and the lock was not inherited" 0 "OK: answered" -- WD
  echo hang > "$WD_MODE_FILE"
  WD --restart --max-restarts 1 >/dev/null 2>&1; WD --restart --max-restarts 1 >/dev/null 2>&1
  run "mariadb-watchdog: restart limit stops a restart loop" 2 "restart limit reached" -- WD --restart --max-restarts 1
  pkill -x mariadbd 2>/dev/null; for _ in 1 2 3 4 5; do pgrep -x mariadbd >/dev/null || break; sleep 1; done; rm -f "$WS/failures"
  run "mariadb-watchdog: a stopped server is not started without --start-if-down" 2 "was not started" -- WD --restart --fails 1
  if pgrep -x mariadbd >/dev/null; then bad "mariadb-watchdog: down server was started"; else ok "mariadb-watchdog: down server left alone"; fi
  pkill -x mariadbd 2>/dev/null
else
  skp "mariadb-watchdog not in this tree"
fi

echo; echo "$pass passed, $fail failed, $skip skipped"
(( fail == 0 ))
