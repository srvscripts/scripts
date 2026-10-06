#!/usr/bin/env bash
# Server Inventory Report (v1.0.1) - from srvScripts.com
# Source, docs and updates: https://srvscripts.com/scripts/server-inventory-report/
# Copyright (c) 2026 srvScripts.com. MIT licence: if you copy, share or adapt this script, keep this notice and credit srvScripts.com.
# server-inventory-report.sh — one-page inventory of a Linux server: hardware, network, panel, stack, security, backups
# https://srvscripts.com/scripts/server-inventory-report/   License: MIT
#
# Read-only, no network calls. Detects cPanel, DirectAdmin and Plesk, Apache/LiteSpeed/Nginx,
# every installed PHP version, the database and mail servers, firewall, backup tools, listening
# services, pending updates (from the local package cache) and whether a reboot is required.
#   bash server-inventory-report.sh                 # plain text
#   bash server-inventory-report.sh --markdown      # paste into a ticket or wiki
#   bash server-inventory-report.sh --json > inventory-$(hostname).json
# Exit codes: 0 report printed, 2 usage error. Run as root for process names and firewall rules.
set -uo pipefail
export LC_ALL=C

FORMAT=text; COLOR=1; UPDATES=1
usage() {
  cat <<'EOF'
Usage: server-inventory-report.sh [options]
  --markdown     Markdown tables (tickets, wikis, handover notes)
  --json         JSON object: { "section": { "item": "value" } }
  --no-updates   skip the pending-updates count (it reads the dnf/yum/apt cache)
  --no-color     plain text output
  -h, --help     this help
EOF
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --markdown) FORMAT=markdown; shift ;;
    --json) FORMAT=json; shift ;;
    --no-updates) UPDATES=0; shift ;;
    --no-color) COLOR=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1 (try --help)" >&2; exit 2 ;;
  esac
done
[[ -t 1 && "$FORMAT" == text ]] || COLOR=0

# ---- storage: parallel arrays of section / item / value ----------------------------------------
declare -a SEC=() KEY=() VAL=()
CUR=""
section() { CUR=$1; }
add() { [[ -n "${2:-}" ]] || return 0; SEC+=("$CUR"); KEY+=("$1"); VAL+=("$2"); }
have() { command -v "$1" >/dev/null 2>&1; }
first() { head -n 1 | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }
join_lines() { awk 'NR > 1 { printf ", " } { printf "%s", $0 } END { if (NR) print "" }'; }
gib() { awk -v k="$1" 'BEGIN{ printf "%.1fG", k / 1048576 }'; }   # kB -> GiB
meminfo() { awk -v k="$1:" '$1 == k { print $2 }' /proc/meminfo; }

# ---- System ------------------------------------------------------------------------------------------
section "System"
add "Hostname" "$(hostname -f 2>/dev/null || hostname)"
add "OS" "$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-$NAME}")"
add "Kernel" "$(uname -r) ($(uname -m))"
read -r up _ < /proc/uptime; up=${up%.*}
add "Uptime" "$((up / 86400))d $((up % 86400 / 3600))h $((up % 3600 / 60))m"
add "Last boot" "$(uptime -s 2>/dev/null || who -b 2>/dev/null | awk '{ print $3, $4 }')"
if [[ -f /var/run/reboot-required ]]; then
  reboot="yes ($(join_lines < /var/run/reboot-required.pkgs 2>/dev/null || echo 'see /var/run/reboot-required'))"
elif have needs-restarting; then
  if needs-restarting -r >/dev/null 2>&1; then reboot="no"; else reboot="yes (needs-restarting -r)"; fi
else
  newest=$(ls -1 /lib/modules 2>/dev/null | sort -V | tail -n 1)
  if [[ -n "$newest" && "$newest" != "$(uname -r)" ]]; then reboot="likely (newest installed kernel is $newest)"; else reboot="no"; fi
fi
add "Reboot required" "$reboot"
virt=$(systemd-detect-virt 2>/dev/null); [[ -n "$virt" ]] || virt="unknown"
[[ "$virt" == none ]] && virt="none (bare metal)"
add "Virtualization" "$virt"
add "Hardware" "$(cat /sys/class/dmi/id/sys_vendor /sys/class/dmi/id/product_name 2>/dev/null | paste -sd' ' -)"

# ---- CPU and memory ------------------------------------------------------------------------------
section "CPU and memory"
add "CPU model" "$(grep -m1 -E '^(model name|Model|cpu model)' /proc/cpuinfo | cut -d: -f2 | first)"
sockets=$(lscpu 2>/dev/null | awk -F: '/^Socket\(s\)/ { gsub(/ /, "", $2); print $2 }')
add "CPU threads" "$(nproc)${sockets:+ ($sockets socket(s))}"
add "Load average" "$(cut -d' ' -f1-3 /proc/loadavg)"
add "RAM" "$(gib "$(meminfo MemTotal)") total, $(gib "$(meminfo MemAvailable)") available"
st=$(meminfo SwapTotal)
if (( ${st:-0} > 0 )); then add "Swap" "$(gib "$st") total, $(gib $(( st - $(meminfo SwapFree) ))) used"; else add "Swap" "none"; fi

# ---- Storage ---------------------------------------------------------------------------------------
section "Storage"
if have lsblk; then
  while read -r name size type rota model; do
    [[ "$type" == disk && "$name" != zram* && "$size" != 0B ]] || continue
    add "/dev/$name" "$size $([[ "$rota" == 1 ]] && echo rotational || echo ssd)${model:+ $model}"
  done < <(lsblk -dn -o NAME,SIZE,TYPE,ROTA,MODEL 2>/dev/null)
fi
[[ -r /proc/mdstat ]] && while read -r md _ state level rest; do
  add "$md" "software RAID $state $level: $rest"
done < <(grep '^md' /proc/mdstat)
while read -r target fstype size used pcent; do
  [[ "$target" == /home/virtfs/* ]] && continue
  add "$target" "$fstype $size, $pcent used ($used)"
done < <(df -h --output=target,fstype,size,used,pcent -x tmpfs -x devtmpfs -x overlay -x squashfs -x efivarfs 2>/dev/null | tail -n +2)

# ---- Network -----------------------------------------------------------------------------------------
section "Network"
if have ip; then
  add "IPv4" "$(ip -o -4 addr show scope global 2>/dev/null | awk '{ print $4 " (" $2 ")" }' | join_lines)"
  add "IPv6" "$(ip -o -6 addr show scope global 2>/dev/null | awk '{ print $4 " (" $2 ")" }' | join_lines)"
  add "Default gateway" "$(ip route show default 2>/dev/null | awk '{ print $3 " (" $5 ")" }' | join_lines)"
  add "IPv6 gateway" "$(ip -6 route show default 2>/dev/null | awk '{ print $3 " (" $5 ")" }' | join_lines)"
else
  add "IP addresses" "$(hostname -I 2>/dev/null)"
fi
dns=$(awk '$1 == "nameserver" { print $2 }' /etc/resolv.conf 2>/dev/null | join_lines)
if [[ "$dns" == 127.0.0.53 && -r /run/systemd/resolve/resolv.conf ]]; then
  dns="$(awk '$1 == "nameserver" { print $2 }' /run/systemd/resolve/resolv.conf | join_lines) (via systemd-resolved)"
fi
add "DNS resolvers" "${dns:-none}"

# ---- Control panel and web stack -----------------------------------------------------------------------
section "Hosting stack"
panel=""
[[ -r /usr/local/cpanel/version ]] && panel="cPanel & WHM $(cat /usr/local/cpanel/version)"
if [[ -x /usr/local/directadmin/directadmin ]]; then
  da=$( { timeout 5 /usr/local/directadmin/directadmin version || timeout 5 /usr/local/directadmin/directadmin v; } 2>/dev/null | grep -m1 -Eo 'v?\.?[0-9]+\.[0-9.]+')
  panel="DirectAdmin ${da:-(version unknown)}"
fi
[[ -r /usr/local/psa/version ]] && panel="Plesk $(awk '{ print $1 }' /usr/local/psa/version)"
[[ -z "$panel" && -d /usr/local/CyberCP ]] && panel="CyberPanel"
[[ -z "$panel" && -d /usr/local/cwpsrv ]] && panel="CentOS Web Panel"
[[ -z "$panel" && -d /usr/local/hestia ]] && panel="HestiaCP"
[[ -z "$panel" && -r /etc/webmin/version ]] && panel="Webmin $(cat /etc/webmin/version)"
add "Control panel" "${panel:-none detected}"

web=()
for b in httpd apache2 /usr/sbin/httpd /usr/local/apache/bin/httpd; do
  have "$b" || continue
  v=$("$b" -v 2>/dev/null | sed -n 's/^Server version: //p'); [[ -n "$v" ]] && { web+=("$v"); break; }
done
[[ -x /usr/local/lsws/bin/lshttpd ]] && web+=("$( (timeout 5 /usr/local/lsws/bin/lshttpd -v 2>&1 | first) || cat /usr/local/lsws/VERSION)")
have nginx && web+=("$(nginx -v 2>&1 | sed 's/^nginx version: //' | first)")
have caddy && web+=("Caddy $(caddy version 2>/dev/null | awk '{ print $1 }')")
add "Web server" "$( ((${#web[@]})) && printf '%s\n' "${web[@]}" | join_lines || echo 'none detected')"

declare -A PHPSEEN=()
php=()
for b in /opt/cpanel/ea-php*/root/usr/bin/php /opt/alt/php*/usr/bin/php /opt/remi/php*/root/usr/bin/php \
         /usr/local/php*/bin/php /usr/local/lsws/lsphp*/bin/php /usr/bin/php[0-9]* /usr/bin/php /usr/local/bin/php; do
  [[ -x "$b" ]] || continue
  real=$(readlink -f "$b"); [[ -n "${PHPSEEN[$real]:-}" ]] && continue; PHPSEEN[$real]=1
  v=$(timeout 5 "$b" -n -r 'echo PHP_VERSION;' 2>/dev/null) || continue
  label=$(sed -E 's#^/opt/cpanel/(ea-php[0-9]+)/.*#\1#; s#^/opt/alt/(php[0-9]+)/.*#alt-\1#; s#^/opt/remi/(php[0-9]+)/.*#remi-\1#;
                s#^/usr/local/lsws/(lsphp[0-9]+)/.*#\1#; s#^/usr/local/(php[0-9]+)/.*#\1#; s#^/usr/(local/)?bin/##' <<< "$b")
  php+=("$v ($label)")
done
add "PHP versions" "$( ((${#php[@]})) && printf '%s\n' "${php[@]}" | join_lines || echo 'none found')"
have php && add "PHP default CLI" "$(php -n -r 'echo PHP_VERSION;' 2>/dev/null)"

db=()
for b in /usr/sbin/mariadbd /usr/libexec/mariadbd /usr/sbin/mysqld /usr/libexec/mysqld; do
  [[ -x "$b" ]] || continue
  v=$("$b" --version 2>/dev/null | sed -n 's/.*Ver \([^ ]*\).*/\1/p')
  [[ -n "$v" ]] && { [[ "$v" == *MariaDB* ]] && db+=("MariaDB ${v%%-MariaDB*}") || db+=("MySQL $v"); break; }
done
for b in /usr/pgsql-*/bin/postgres /usr/lib/postgresql/*/bin/postgres; do
  [[ -x "$b" ]] && db+=("PostgreSQL $("$b" --version 2>/dev/null | sed -n 's/.*(PostgreSQL) \([^ ]*\).*/\1/p')")
done
have redis-server && db+=("Redis $(redis-server --version 2>/dev/null | sed -n 's/.* v=\([^ ]*\).*/\1/p')")
add "Databases" "$( ((${#db[@]})) && printf '%s\n' "${db[@]}" | join_lines || echo 'none detected')"

mail=()
have exim && mail+=("Exim $(exim -bV 2>/dev/null | sed -n 's/^Exim version \([^ ]*\).*/\1/p' | first)")
have postconf && mail+=("Postfix $(postconf -h mail_version 2>/dev/null)")
have dovecot && mail+=("Dovecot $(dovecot --version 2>/dev/null | awk '{ print $1 }')")
add "Mail" "$( ((${#mail[@]})) && printf '%s\n' "${mail[@]}" | join_lines || echo 'none detected')"

# ---- Security and backups ----------------------------------------------------------------------------
section "Security and backups"
fw=()
if have csf; then
  c=$(csf -v 2>/dev/null | first)
  grep -qE '^TESTING *= *"1"' /etc/csf/csf.conf 2>/dev/null && c="$c, TESTING mode"
  fw+=("$c")
fi
have firewall-cmd && fw+=("firewalld $(firewall-cmd --state 2>&1 | first)")
have ufw && fw+=("ufw $(ufw status 2>/dev/null | sed -n 's/^Status: //p')")
have nft && n=$(nft list ruleset 2>/dev/null | grep -cE '^\s+(ip|tcp|udp|ct|iif|oif|meta|counter|accept|drop|reject)') && (( n > 0 )) && fw+=("nftables ($n rules)")
have iptables && n=$(iptables -S 2>/dev/null | grep -c '^-A') && (( n > 0 )) && fw+=("iptables ($n rules)")
add "Firewall" "$( ((${#fw[@]})) && printf '%s\n' "${fw[@]}" | join_lines || echo 'none detected (or not root)')"
ips=()
have fail2ban-client && ips+=("fail2ban$(pgrep -f fail2ban-server >/dev/null && echo ' (running)')")
if have imunify360-agent; then   # the free ImunifyAV ships the same command; Imunify360 has its own service unit
  imv=$(imunify360-agent version 2>/dev/null | first)
  if systemctl list-unit-files imunify360.service 2>/dev/null | grep -q '^imunify360\.service' || { have rpm && rpm -q imunify360-firewall >/dev/null 2>&1; }; then ips+=("Imunify360 $imv")
  else ips+=("ImunifyAV $imv (malware scanner only)"); fi
fi
pgrep -x lfd >/dev/null && ips+=("LFD (running)")
[[ -d /usr/local/cpanel ]] && [[ -e /var/cpanel/hulkd/enabled ]] && ips+=("cPHulk")
add "Intrusion prevention" "$( ((${#ips[@]})) && printf '%s\n' "${ips[@]}" | join_lines || echo 'none detected')"

bk=()
if [[ -r /var/cpanel/backups/config ]]; then
  grep -qE "^BACKUPENABLE: '?yes" /var/cpanel/backups/config && bk+=("cPanel backups (enabled)") || bk+=("cPanel backups (disabled)")
fi
{ have jetbackup5api || [[ -d /usr/local/jetapps/usr/bin ]]; } && bk+=("JetBackup")
[[ -s /usr/local/directadmin/data/admin/backup_crons.list ]] && bk+=("DirectAdmin admin backups")
[[ -d /usr/lib/Acronis ]] && bk+=("Acronis agent")
for t in restic borg rsnapshot duplicity rclone veeamconfig bacula-fd; do have "$t" && bk+=("$t"); done
[[ -r /etc/srvscripts/restic.conf ]] && bk+=("restic-offsite-backup config")
add "Backup tools" "$( ((${#bk[@]})) && printf '%s\n' "${bk[@]}" | join_lines || echo 'none detected')"

# ---- Listening services ----------------------------------------------------------------------------
section "Listening services"
if have ss; then
  while IFS=$'\t' read -r port procs addrs; do
    add "$port" "$procs on $addrs"
  done < <(ss -ltnup 2>/dev/null | awk 'NR > 1 {
      local = $5; p = local; sub(/.*:/, "", p); a = local; sub(/:[^:]*$/, "", a); sub(/%.*/, "", a)
      name = "?"; if (match($0, /users:\(\("[^"]+"/)) name = substr($0, RSTART + 9, RLENGTH - 10)
      sub(/ \(.*$/, "", name); sub(/ - .*$/, "", name)   # process titles like "cpsrvd (SSL) - ..." -> cpsrvd
      k = p "/" $1
      if (!(k in n)) n[k] = name; else if (index(n[k], name) == 0) n[k] = n[k] "," name
      if (!(k in ad)) ad[k] = a; else if (index(ad[k], a) == 0) ad[k] = ad[k] " " a
    } END { for (k in n) print k "\t" n[k] "\t" ad[k] }' | sort -t/ -k1,1n)
else
  add "ss" "skipped: ss not installed"
fi

# ---- Updates -----------------------------------------------------------------------------------------
section "Updates"
if (( UPDATES )); then
  if have dnf || have yum; then
    pm=$(command -v dnf || command -v yum)
    out=$(timeout 120 "$pm" -q -C check-update 2>/dev/null); rc=$?
    case $rc in
      0) add "Pending updates" "0 (from the local ${pm##*/} cache)" ;;
      100) add "Pending updates" "$(awk '/^Obsoleting/ { exit } NF == 3 && $1 ~ /\./ { n++ } END { print n + 0 }' <<< "$out") (from the local ${pm##*/} cache)" ;;
      *) add "Pending updates" "unknown (no ${pm##*/} cache yet: run ${pm##*/} makecache)" ;;
    esac
  elif have apt-get; then
    out=$(apt-get -s -o Debug::NoLocking=1 upgrade 2>/dev/null | grep '^Inst')
    add "Pending updates" "$(grep -c . <<< "$out") ($(grep -ci security <<< "$out") security; as of the last apt update)"
  else
    add "Pending updates" "skipped: no dnf, yum or apt"
  fi
fi

# ---- output ------------------------------------------------------------------------------------------
jstr() { local s=$1; s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\t'/ }; s=${s//$'\n'/ }; printf '"%s"' "$s"; }
jkey() { if [[ "$1" =~ ^[A-Za-z] ]]; then tr 'A-Z' 'a-z' <<< "$1" | sed -E 's/[^a-z0-9]+/_/g; s/_$//'; else printf '%s' "$1"; fi; }
if (( COLOR )); then H=$'\e[1m'; N=$'\e[0m'; else H=""; N=""; fi
last=""; n=${#KEY[@]}
case $FORMAT in
  text)
    printf 'Server inventory: %s   (%s)\n' "$(hostname)" "$(date '+%Y-%m-%d %H:%M %Z')"
    for ((i = 0; i < n; i++)); do
      [[ "${SEC[i]}" != "$last" ]] && { printf '\n%s== %s ==%s\n' "$H" "${SEC[i]}" "$N"; last=${SEC[i]}; }
      printf '  %-22s %s\n' "${KEY[i]}" "${VAL[i]}"
    done ;;
  markdown)
    printf '# Server inventory: %s\n\nGenerated %s by server-inventory-report.sh\n' "$(hostname)" "$(date '+%Y-%m-%d %H:%M %Z')"
    for ((i = 0; i < n; i++)); do
      [[ "${SEC[i]}" != "$last" ]] && { printf '\n## %s\n\n| Item | Value |\n|---|---|\n' "${SEC[i]}"; last=${SEC[i]}; }
      printf '| %s | %s |\n' "${KEY[i]//|/\\|}" "${VAL[i]//|/\\|}"
    done ;;
  json)
    printf '{\n  "generated": %s' "$(jstr "$(date -u '+%Y-%m-%dT%H:%M:%SZ')")"
    for ((i = 0; i < n; i++)); do
      if [[ "${SEC[i]}" != "$last" ]]; then
        [[ -n "$last" ]] && printf '\n  }'
        printf ',\n  %s: {\n' "$(jstr "$(jkey "${SEC[i]}")")"; last=${SEC[i]}
      else printf ',\n'; fi
      printf '    %s: %s' "$(jstr "$(jkey "${KEY[i]}")")" "$(jstr "${VAL[i]}")"
    done
    [[ -n "$last" ]] && printf '\n  }'
    printf '\n}\n' ;;
esac
exit 0
