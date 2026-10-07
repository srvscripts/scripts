#!/usr/bin/env bash
# Inode Usage Report: Top Directories by File Count per Account (v1.1.0) - from srvScripts.com
# Source, docs and updates: https://srvscripts.com/scripts/inode-usage-report/
# Copyright (c) 2026 srvScripts.com. MIT licence: if you copy, share or adapt this script, keep this notice and credit srvScripts.com.
#
# inode-usage-report.sh
# Report inode (file count) usage per hosting account and list the top N
# directories by inode count inside each account, with warning and critical
# thresholds. Works on cPanel, DirectAdmin and plain Linux servers.
#
# https://srvscripts.com/scripts/inode-usage-report/
# Version: 1.1.0
# License: MIT
#
# Read-only: uses `du --inodes` (GNU coreutils 8.22+) and never changes files.
# Runs at low CPU and I/O priority (nice/ionice) unless --no-nice is given.
#
# If du fails or prints an error for an account (unreadable or vanished
# directory, I/O error), that account is reported as INCOMPLETE with a lower
# bound ("12345+") or as UNKNOWN when no total was produced - never as OK.
#
# Exit codes: 0 = all accounts below --warn, 1 = at least one WARN,
#             2 = at least one CRIT, 3 = usage or environment error, or at
#             least one account INCOMPLETE/UNKNOWN (3 takes precedence,
#             because the report is not complete).

set -euo pipefail

VERSION="1.1.0"
TOP=10
DEPTH=2
WARN=200000
CRIT=400000
CSV=0
NICE=1
SUMMARY_ONLY=0
declare -a USERS=()
declare -a PATHS=()

usage() {
    cat <<'EOF'
Usage: inode-usage-report.sh [options]

Counts inodes per account home and shows the directories holding the most files.
If du reports an error for an account, its status is INCOMPLETE (count shown as
a lower bound, e.g. 12345+) or UNKNOWN (no total), and the script exits 3.

Options:
  --top N          Directories to list per account (default: 10)
  --depth N        Directory depth below the home to rank (default: 2)
  --warn N         Account total that triggers WARN (default: 200000)
  --crit N         Account total that triggers CRIT (default: 400000)
  --user NAME      Only this account (repeatable)
  --path DIR       Treat DIR as one account home (repeatable; skips panel detection)
  --summary        Only print the per-account totals table
  --csv            CSV output: account,home,total,status,directory,inodes,percent
  --no-nice        Do not lower CPU/I/O priority
  -h, --help       Show this help
  -V, --version    Show script version

Examples:
  inode-usage-report.sh --summary
  inode-usage-report.sh --user bob --top 20 --depth 3
  inode-usage-report.sh --warn 150000 --crit 250000 --csv > inodes.csv
EOF
}

die() { echo "Error: $*" >&2; exit 3; }
# need_num OPTION VALUE MIN [MAX]
need_num() {
    if ! [[ "$2" =~ ^[0-9]+$ ]] || [[ "$2" -lt "$3" ]] || { [[ -n "${4:-}" ]] && [[ "$2" -gt "$4" ]]; }; then
        die "$1 needs a whole number >= $3${4:+ and <= $4}"
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --top)    need_num "$1" "${2:-}" 1;  TOP="$2";   shift 2 ;;
        --depth)  need_num "$1" "${2:-}" 1 10; DEPTH="$2"; shift 2 ;;
        --warn)   need_num "$1" "${2:-}" 1;  WARN="$2";  shift 2 ;;
        --crit)   need_num "$1" "${2:-}" 1;  CRIT="$2";  shift 2 ;;
        --user)   [[ $# -ge 2 && "$2" =~ ^[a-z_][a-z0-9_.-]*$ ]] || die "--user needs a valid account name"; USERS+=("$2"); shift 2 ;;
        --path)   [[ $# -ge 2 && -d "$2" ]] || die "--path needs an existing directory"; PATHS+=("${2%/}"); shift 2 ;;
        --summary) SUMMARY_ONLY=1; shift ;;
        --csv)    CSV=1; shift ;;
        --no-nice) NICE=0; shift ;;
        -h|--help) usage; exit 0 ;;
        -V|--version) echo "inode-usage-report.sh $VERSION"; exit 0 ;;
        *) usage >&2; die "unknown option: $1" ;;
    esac
done

[[ "$WARN" -lt "$CRIT" ]] || die "--warn ($WARN) must be lower than --crit ($CRIT)"
du --inodes --version >/dev/null 2>&1 || die "this du does not support --inodes (need GNU coreutils 8.22 or newer)"
[[ $EUID -eq 0 || ${#PATHS[@]} -gt 0 ]] || echo "Warning: not running as root; counts for other users will be incomplete." >&2

RUN=()
if [[ $NICE -eq 1 ]]; then
    command -v nice >/dev/null && RUN+=(nice -n 19)
    command -v ionice >/dev/null && RUN+=(ionice -c3)
fi

# ---- build the account list: "name<TAB>home" -------------------------------
PANEL="plain"
declare -a ACCOUNTS=()

home_of() { getent passwd "$1" | cut -d: -f6 || true; }

if [[ ${#PATHS[@]} -gt 0 ]]; then
    PANEL="paths"
    for p in "${PATHS[@]}"; do ACCOUNTS+=("$(basename "$p")"$'\t'"$p"); done
else
    if [[ -d /var/cpanel/users && -f /usr/local/cpanel/version ]]; then
        PANEL="cpanel"; src=(/var/cpanel/users/*)
    elif [[ -d /usr/local/directadmin/data/users ]]; then
        PANEL="directadmin"; src=(/usr/local/directadmin/data/users/*)
    else
        src=()
        for d in /home/*; do
            [[ -d "$d" ]] || continue
            case "$(basename "$d")" in virtfs|lost+found|tmp|cpanelsolr) continue ;; esac
            src+=("$d")
        done
    fi
    for s in "${src[@]+"${src[@]}"}"; do
        u="$(basename "$s")"
        [[ "$u" == "system" || "$u" == "nobody" ]] && continue
        if [[ ${#USERS[@]} -gt 0 ]]; then
            match=0; for w in "${USERS[@]}"; do [[ "$w" == "$u" ]] && match=1; done
            [[ $match -eq 1 ]] || continue
        fi
        if [[ "$PANEL" == "plain" ]]; then h="$s"; else h="$(home_of "$u")"; fi
        [[ -n "$h" && -d "$h" ]] && ACCOUNTS+=("$u"$'\t'"$h")
    done
fi
[[ ${#ACCOUNTS[@]} -gt 0 ]] || die "no accounts found (check --user, or use --path DIR)"

status_of() {
    if   [[ "$1" -ge "$CRIT" ]]; then echo "CRIT"
    elif [[ "$1" -ge "$WARN" ]]; then echo "WARN"
    else echo "OK"; fi
}

# ---- measure ----------------------------------------------------------------
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
declare -a SUMMARY=()
worst=0
incomplete=0

for a in "${ACCOUNTS[@]}"; do
    IFS=$'\t' read -r name home <<< "$a"
    out="$TMP/$name.du"
    # -x: stay on one filesystem; any du error (unreadable or vanished
    # directory, I/O error) means the count is not complete
    rc=0
    "${RUN[@]+"${RUN[@]}"}" du --inodes -x --max-depth="$DEPTH" "$home" 2> "$TMP/$name.err" > "$out" || rc=$?
    total="$(awk -v h="$home" -F'\t' '$2==h && $1 ~ /^[0-9]+$/ {print $1}' "$out" | tail -n1)"
    if [[ -z "$total" ]]; then
        total="?"; st="UNKNOWN"
    elif [[ $rc -ne 0 || -s "$TMP/$name.err" ]]; then
        total="$total+"; st="INCOMPLETE"
    else
        st="$(status_of "$total")"
    fi
    case "$st" in
        CRIT) worst=2 ;; WARN) [[ $worst -lt 1 ]] && worst=1 ;;
        UNKNOWN|INCOMPLETE)
            incomplete=$((incomplete + 1))
            msg="$(head -n1 "$TMP/$name.err" 2>/dev/null || true)"
            echo "Warning: $name: $st (du exit $rc): ${msg:-no total line in du output}" >&2 ;;
    esac
    SUMMARY+=("$total"$'\t'"$name"$'\t'"$home"$'\t'"$st")
done

pct() { awk -v a="$1" -v b="$2" 'BEGIN{ b += 0; if (b>0) printf "%.1f", a*100/b; else print "?" }'; }

# align: tab-separated input -> padded columns (no dependency on column(1))
align() {
    awk -F'\t' '{ for (i = 1; i <= NF; i++) { c[NR, i] = $i; if (length($i) > w[i]) w[i] = length($i) } if (NF > n) n = NF }
        END { for (r = 1; r <= NR; r++) { line = ""; for (i = 1; i <= n; i++) line = line sprintf(i < n ? "%-" w[i] "s  " : "%s", c[r, i]); print line } }'
}

# ---- output -----------------------------------------------------------------
sorted="$(printf '%s\n' "${SUMMARY[@]}" | sort -t$'\t' -k1,1nr)"

if [[ $CSV -eq 1 ]]; then
    echo "account,home,total,status,directory,inodes,percent"
    while IFS=$'\t' read -r total name home st; do
        if [[ $SUMMARY_ONLY -eq 1 ]]; then
            printf '%s,%s,%s,%s,,,\n' "$name" "$home" "$total" "$st"; continue
        fi
        # an account with no directory rows (empty, or UNKNOWN) still gets one row
        awk -v h="$home" -F'\t' '$2!=h {f=1} END {exit !f}' "$TMP/$name.du" ||
            printf '%s,%s,%s,%s,,,\n' "$name" "$home" "$total" "$st"
        awk -v h="$home" -F'\t' '$2!=h' "$TMP/$name.du" | sort -t$'\t' -k1,1nr | head -n "$TOP" |
        while IFS=$'\t' read -r n d; do
            printf '%s,%s,%s,%s,"%s",%s,%s\n' "$name" "$home" "$total" "$st" "${d//\"/\"\"}" "$n" "$(pct "$n" "$total")"
        done || true   # head closing the pipe early is expected
    done <<< "$sorted"
    [[ $incomplete -eq 0 ]] || exit 3
    exit "$worst"
fi

echo "Inode usage report - panel: $PANEL - warn: $WARN - crit: $CRIT - depth: $DEPTH"
echo
{
    printf 'ACCOUNT\tINODES\tSTATUS\tHOME\n'
    while IFS=$'\t' read -r total name home st; do printf '%s\t%s\t%s\t%s\n' "$name" "$total" "$st" "$home"; done <<< "$sorted"
} | align

if [[ $SUMMARY_ONLY -eq 0 ]]; then
    while IFS=$'\t' read -r total name home st; do
        echo
        echo "== $name ($home) - $total inodes - $st - top $TOP directories"
        awk -v h="$home" -F'\t' '$2!=h' "$TMP/$name.du" | sort -t$'\t' -k1,1nr | head -n "$TOP" |
        while IFS=$'\t' read -r n d; do printf '%10s  %5s%%  %s\n' "$n" "$(pct "$n" "$total")" "$d"; done || true
    done <<< "$sorted"
fi

if [[ $incomplete -gt 0 ]]; then
    echo
    echo "WARNING: $incomplete account(s) could not be fully measured (du reported errors)."
    echo "INCOMPLETE counts (shown as N+) are lower bounds; UNKNOWN means no total. Exit code 3."
    exit 3
fi
exit "$worst"
