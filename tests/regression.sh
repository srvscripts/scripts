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
    '[ -n "${RACE_MP3:-}" ] && [ ! -e "$RACE_MP3" ] && printf OTHER >"$RACE_MP3"' \
    '[ -n "${RACE_DIR:-}" ] && mkdir -p "$RACE_DIR" && chown 65534:65534 "$RACE_DIR"' \
    '[ -n "${RACE_DIRLINK:-}" ] && ln -s "$RACE_DIRLINK_TO" "$RACE_DIRLINK" && chown -h 65534:65534 "$RACE_DIRLINK"; exit 0' > "$FK/ffmpeg"
  printf '%s\n' '#!/bin/bash' 'printf "sample_rate=8000\nnb_samples=8000\n"' > "$FK/ffprobe"
  printf '%s\n' '#!/bin/bash' 'q="${*: -1}"' 'case "$q" in *"SELECT 1 FROM"*) echo 1 ;; *UPDATE*) [ -n "${CDR_LOG:-}" ] && echo "$q" >>"$CDR_LOG"; [ "${FAKE_CDR:-}" = fail ] && exit 1; echo "${FAKE_ROWS:-1}" ;; *"COUNT(*)"*) echo 0 ;; esac' > "$FK/mysql"
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
  # EVE-10: a publish killed half-way must not leave a partial final MP3 that later runs would skip.
  printf '%s\n' '#!/bin/bash' 'o=$(readlink /proc/$$/fd/1 2>/dev/null)' \
    'if [ -n "${KILL_PUBLISH:-}" ] && [[ $o == */.*.mp3.*.part ]]; then head -c 3; kill -9 $PPID; exit 1; fi' 'exec /bin/cat "$@"' > "$FK/cat"; chmod 755 "$FK/cat"
  R5=$A/r5; mkrec "$R5" kill.wav; chown -R 65534:65534 "$R5"; touch -d '-10 minutes' "$R5"/kill.wav
  run "asterisk: a publish killed half-way is reported as interrupted" 1 "was interrupted" -- env KILL_PUBLISH=1 "${AST[@]}" --dir "$R5" --delete-original
  chk "asterisk: after the kill there is no final MP3 and the original is kept" '[[ ! -e $R5/kill.mp3 && -f $R5/kill.wav ]] && ls -A "$R5" | grep -q "^\.kill\.mp3\..*\.part$"'
  for p in "$R5"/.kill.mp3.*.part; do touch -d '-40 minutes' "$p"; done
  run "asterisk: the next run converts the recording again" 0 "ok  kill\.wav" -- "${AST[@]}" --dir "$R5" --delete-original
  chk "asterisk: retried MP3 is complete, owned by the owner, original deleted" 'same "$R5/kill.mp3" FAKE-MP3 && [[ $(stat -c %u $R5/kill.mp3) == 65534 && ! -e $R5/kill.wav ]]'
  chk "asterisk: the stale hidden temporary file of the killed run is removed" '! ls -A "$R5" | grep -q "\.part$" && same "$R5/kill.mp3" FAKE-MP3'
  rm -f "$FK/cat"
  # NEW-AST-DIR: a folder, or a link to a folder, created at the MP3 name after the existence check must be refused:
  # no MP3 written inside it, no call log update, original kept, run reported as failed.
  R6=$A/r6; mkrec "$R6" d.wav; chown -R 65534:65534 "$R6"; touch -d '-10 minutes' "$R6"/d.wav
  run "asterisk: a folder created at the MP3 name during conversion is refused" 1 "appeared while converting" -- env RACE_DIR="$R6/d.mp3" CDR_LOG="$A/cdr6" "${AST[@]}" --dir "$R6" --update-cdr --delete-original
  chk "asterisk: nothing written inside that folder, original kept, call log untouched" '[[ -d $R6/d.mp3 && -z $(ls -A "$R6/d.mp3") && -f $R6/d.wav && ! -s $A/cdr6 ]] && ! ls -A "$R6" | grep -q "\.part$"'
  R7=$A/r7; TD=$A/tdir; mkdir -p "$TD"; chown 65534:65534 "$TD"; mkrec "$R7" l.wav; chown -R 65534:65534 "$R7"; touch -d '-10 minutes' "$R7"/l.wav
  run "asterisk: a link to a folder created at the MP3 name during conversion is refused" 1 "appeared while converting" -- env RACE_DIRLINK="$R7/l.mp3" RACE_DIRLINK_TO="$TD" CDR_LOG="$A/cdr7" "${AST[@]}" --dir "$R7" --update-cdr --delete-original
  chk "asterisk: nothing written through that link, original kept, call log untouched" '[[ -L $R7/l.mp3 && -z $(ls -A "$TD") && -f $R7/l.wav && ! -s $A/cdr7 ]] && ! ls -A "$R7" | grep -q "\.part$"'
  R4=$A/r4; mkrec "$R4" rootrec.wav; chown 65534:65534 "$R4"; touch -d '-10 minutes' "$R4"/rootrec.wav
  run "asterisk: root-owned recording in a tenant folder is refused" 1 "owned by root in a folder other users can change" -- "${AST[@]}" --dir "$R4"
  chk "asterisk: refused recording kept, nothing written" '[[ -f $R4/rootrec.wav && ! -e $R4/rootrec.mp3 ]]'
else skp "asterisk-recordings-to-mp3 fixtures (need root and setpriv)"; fi

echo; echo "$pass passed, $fail failed, $skip skipped"
(( fail == 0 ))
