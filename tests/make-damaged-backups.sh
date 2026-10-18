#!/usr/bin/env bash
# make-damaged-backups.sh - builds a small test tree of cPanel-style backups with known damage, for backup-verify.sh.
# Synthetic data only. Writes nothing outside the directory you give it (default ./bv-demo). Needs GNU tar, gzip, touch.
#   bash make-damaged-backups.sh [DIR]
#   bash backup-verify.sh DIR --accounts-file DIR/accounts.txt           # quick test
#   bash backup-verify.sh DIR --accounts-file DIR/accounts.txt --deep    # deep test
set -euo pipefail
D=${1:-./bv-demo}
[[ -e $D ]] && { echo "$D already exists; give a new directory" >&2; exit 2; }
mkdir -p "$D" && cd "$D" && D=$PWD
day() { date -u -d "-$1 day" +%F; }               # dated run folders: 2 days ago, yesterday, today
R2=$(day 2) R1=$(day 1) R0=$(day 0)
payload() {                                       # deterministic, poorly compressible content (fixed awk seed per account)
  local name=$1 lines=$2; mkdir -p "src/$name/public_html"
  awk -v n="$lines" -v seed="${#name}${lines}" 'BEGIN { srand(seed); for (i = 1; i <= n; i++) { l = ""; for (j = 0; j < 8; j++) l = l sprintf("%08x", int(rand() * 4294967295)); print l } }' > "src/$name/public_html/data.txt"
  printf 'account %s\n' "$name" > "src/$name/README"
}
archive() {                                       # archive NAME LINES RUN HOURS_OLD
  local name=$1 lines=$2 run=$3 age=$4 out="$3/accounts/$1.tar.gz"
  payload "$name" "$lines"; mkdir -p "$run/accounts"
  tar -C src -cf - "$name" | gzip -n -9 > "$out"; rm -rf "src/$name"
  touch -d "-$age hours" "$out"
}
for run in "$R2:50" "$R1:26" "$R0:2"; do
  r=${run%%:*} h=${run##*:}
  archive alice 3000 "$r" "$h"                    # healthy in every run                      -> OK
  [[ $r != "$R0" ]] && archive bob 3000 "$r" $((h + 24))   # missing from today's run, newest 50 h old -> FAIL (age, coverage)
  if [[ $r == "$R0" ]]; then archive carol 900 "$r" "$h"; else archive carol 3000 "$r" "$h"; fi   # shrank 70% -> FAIL
  archive dave 3000 "$r" "$h"; archive erin 3000 "$r" "$h"
done
# dave, today: one byte inverted inside the compressed data -> gzip -t reports a CRC or data error -> FAIL
f=$R0/accounts/dave.tar.gz; o=$(( $(stat -c %s "$f") / 2 )); b=$(od -An -tu1 -j "$o" -N1 "$f" | tr -d ' ')
printf '%b' "\\0$(printf '%03o' $(( b ^ 255 )))" | dd of="$f" bs=1 seek="$o" conv=notrunc status=none; touch -d "-2 hours" "$f"
# erin, today: a valid gzip file around a tar stream cut in half (of a bigger account, so the size looks normal)
# -> gzip -t passes and the size check passes; only --deep (tar listing) fails
payload erin 6000; tar -C src -cf src/erin.tar erin; rm -rf src/erin
f=$R0/accounts/erin.tar.gz; head -c $(( $(stat -c %s src/erin.tar) / 2 )) src/erin.tar | gzip -n -9 > "$f"; rm -f src/erin.tar; touch -d "-2 hours" "$f"
rmdir src
# database dumps: yesterday complete; today has no "-- Dump completed" trailer -> FAIL with --deep
mkdir -p mysql
dump() { printf -- '-- MariaDB dump 10.19  Distrib 10.11.14-MariaDB\n'; awk -v n="$1" 'BEGIN { srand(42); for (i = 1; i <= n; i++) printf "INSERT INTO wp_options VALUES (%d,\x27opt_%d\x27,\x27%08x%08x%08x\x27);\n", i, i, int(rand()*4294967295), int(rand()*4294967295), int(rand()*4294967295) }'; }
{ dump 4000; printf -- '-- Dump completed on %s  3:00:01\n' "$R1"; } | gzip -n -9 > "mysql/wpdb_$R1.sql.gz"; touch -d "-26 hours" "mysql/wpdb_$R1.sql.gz"
# today's dump stopped part-way (a bigger database, cut off before the trailer): same size range, no "Dump completed"
dump 4200 | gzip -n -9 > "mysql/wpdb_$R0.sql.gz"; touch -d "-2 hours" "mysql/wpdb_$R0.sql.gz"
# accounts that must have a fresh backup; grace has never been backed up -> FAIL (coverage)
printf '# expected accounts\nalice\nbob\ncarol\ndave\nerin\ngrace\n' > accounts.txt
echo "Test tree written to $D (runs $R2, $R1, $R0)"
