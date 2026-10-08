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

echo; echo "$pass passed, $fail failed, $skip skipped"
(( fail == 0 ))
