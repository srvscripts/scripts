#!/usr/bin/env bash
# WordPress Version Audit: Find Every WordPress Site and Its Version (v1.1.0) - from srvScripts.com
# Source, docs and updates: https://srvscripts.com/scripts/wordpress-version-audit/
# Copyright (c) 2026 srvScripts.com. MIT licence: if you copy, share or adapt this script, keep this notice and credit srvScripts.com.
#
# wordpress-version-audit.sh
# Find every WordPress install on a cPanel, DirectAdmin or plain Linux server,
# print domain, path, core version and owner, and check each install against a
# minimum version for one advisory (default 7.0.3, the CVE-2026-64638 fix).
# Optionally (--current) also check against the latest security release of
# each branch. MINIMUM-MET is not a full security assessment.
#
# https://srvscripts.com/scripts/wordpress-version-audit/
# Version: 1.1.0
# License: MIT
#
# Read-only: the script only reads wp-includes/version.php and panel domain
# maps. It never runs PHP, never loads WordPress and never changes files.
#
# Exit codes: 0 = every install MINIMUM-MET/BRANCH-FIXED (and UP-TO-DATE when
#                 --current is given),
#             1 = at least one BELOW-MINIMUM (or BEHIND-LATEST with --current),
#             2 = usage or environment error,
#             3 = no install below, but at least one version is UNKNOWN.

set -euo pipefail

VERSION="1.1.0"
DEFAULT_MIN="7.0.3"
DEFAULT_ADVISORY="CVE-2026-64638"
MIN_VERSION="$DEFAULT_MIN"
ADVISORY=""
BRANCH_FIX=""
CURRENT=""
CSV=0
MAXDEPTH=7
ONLY_OUTDATED=0
declare -a ROOTS=()
declare -a EXCLUDES=()

usage() {
    cat <<'EOF'
Usage: wordpress-version-audit.sh [options]

Finds WordPress installs (wp-includes/version.php) and reports their core version.

Status (one advisory only):
  MINIMUM-MET     core is at or above --min-version (default 7.0.3, CVE-2026-64638).
                  This is NOT a full security assessment: it does not mean the site
                  is on the latest security release, and plugins, themes and
                  configuration are not checked.
  BRANCH-FIXED    below the minimum, but at or above a --branch-fix release for the
                  same advisory on its branch
  BELOW-MINIMUM   older than --min-version
  UNKNOWN         version.php missing, unreadable or without a version
Latest column (only with --current): UP-TO-DATE or BEHIND-LATEST; otherwise
"not-checked".

Options:
  --min-version X     Minimum version for the advisory (default: 7.0.3)
  --advisory TEXT     Advisory the minimum relates to, shown in the report
                      (default: CVE-2026-64638 when --min-version is the default)
  --branch-fix LIST   Comma list of releases on older branches that fix the SAME
                      advisory, e.g. 6.9.6,6.8.7. A site on that major.minor branch at
                      or above the release is BRANCH-FIXED instead of BELOW-MINIMUM.
                      It says nothing about other advisories.
  --current LIST      Comma list of the latest security release per branch, e.g.
                      7.1.3,7.0.7. Installs below the release for their branch (or
                      below the highest listed when their branch is not listed) are
                      BEHIND-LATEST. Take the numbers from the official WordPress
                      release/security announcements.
  --path DIR          Scan DIR instead of auto-detected account homes (repeatable)
  --exclude PATTERN   Skip paths matching this find -path pattern (repeatable),
                      e.g. '*/backups/*'
  --maxdepth N        How deep to search below each root (default: 7)
  --only-outdated     Print only rows needing attention (BELOW-MINIMUM, UNKNOWN,
                      BEHIND-LATEST)
  --csv               CSV output (domain,path,version,owner,status,latest)
  -h, --help          Show this help
  -V, --version       Show script version

Examples:
  wordpress-version-audit.sh
  wordpress-version-audit.sh --current 7.1.3,7.0.7
  wordpress-version-audit.sh --min-version 7.1.2 --advisory "CVE-XXXX-YYYY" --only-outdated
  wordpress-version-audit.sh --branch-fix 6.9.6,6.8.7 --csv > wp-audit.csv
EOF
}

die() { echo "Error: $*" >&2; exit 2; }

valid_version() { [[ "$1" =~ ^[0-9]+(\.[0-9]+){1,3}$ ]]; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --min-version) [[ $# -ge 2 ]] || die "--min-version needs a value"
                       valid_version "$2" || die "invalid version '$2' (expected e.g. 7.0.3)"
                       MIN_VERSION="$2"; shift 2 ;;
        --advisory)    [[ $# -ge 2 && -n "$2" ]] || die "--advisory needs a value"
                       ADVISORY="$2"; shift 2 ;;
        --branch-fix)  [[ $# -ge 2 ]] || die "--branch-fix needs a value"
                       BRANCH_FIX="$2"; shift 2 ;;
        --current)     [[ $# -ge 2 ]] || die "--current needs a value"
                       CURRENT="$2"; shift 2 ;;
        --path)        [[ $# -ge 2 ]] || die "--path needs a directory"
                       [[ -d "$2" ]] || die "not a directory: $2"
                       ROOTS+=("$2"); shift 2 ;;
        --exclude)     [[ $# -ge 2 ]] || die "--exclude needs a pattern"
                       EXCLUDES+=("$2"); shift 2 ;;
        --maxdepth)    [[ $# -ge 2 && "$2" =~ ^[0-9]+$ && "$2" -ge 3 ]] || die "--maxdepth needs a number >= 3"
                       MAXDEPTH="$2"; shift 2 ;;
        --only-outdated) ONLY_OUTDATED=1; shift ;;
        --csv)         CSV=1; shift ;;
        -h|--help)     usage; exit 0 ;;
        -V|--version)  echo "wordpress-version-audit.sh $VERSION"; exit 0 ;;
        *)             usage >&2; die "unknown option: $1" ;;
    esac
done

if [[ -n "$BRANCH_FIX" ]]; then
    IFS=',' read -r -a _bf <<< "$BRANCH_FIX"
    for v in "${_bf[@]}"; do valid_version "$v" || die "invalid --branch-fix version '$v'"; done
fi
if [[ -n "$CURRENT" ]]; then
    IFS=',' read -r -a _cur <<< "$CURRENT"
    for v in "${_cur[@]}"; do valid_version "$v" || die "invalid --current version '$v'"; done
fi
if [[ -z "$ADVISORY" ]]; then
    if [[ "$MIN_VERSION" == "$DEFAULT_MIN" ]]; then ADVISORY="$DEFAULT_ADVISORY"; else ADVISORY="no advisory named"; fi
fi

if [[ $EUID -ne 0 && ${#ROOTS[@]} -eq 0 ]]; then
    echo "Warning: not running as root; other users' homes may be unreadable." >&2
fi

# ---- version helpers ---------------------------------------------------------
# ver_lt A B  -> true if A < B (natural version sort)
ver_lt() {
    [[ "$1" != "$2" ]] && [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" == "$1" ]]
}
branch_of() { echo "$1" | cut -d. -f1,2; }

status_for() {
    local v="$1" fix
    [[ -z "$v" ]] && { echo "UNKNOWN"; return; }
    if ! ver_lt "$v" "$MIN_VERSION"; then echo "MINIMUM-MET"; return; fi
    if [[ -n "$BRANCH_FIX" ]]; then
        for fix in "${_bf[@]}"; do
            if [[ "$(branch_of "$v")" == "$(branch_of "$fix")" ]] && ! ver_lt "$v" "$fix"; then
                echo "BRANCH-FIXED"; return
            fi
        done
    fi
    echo "BELOW-MINIMUM"
}

# latest_for VERSION -> not-checked | UNKNOWN | UP-TO-DATE | BEHIND-LATEST
latest_for() {
    local v="$1" c target=""
    [[ -z "$CURRENT" ]] && { echo "not-checked"; return; }
    [[ -z "$v" ]] && { echo "UNKNOWN"; return; }
    for c in "${_cur[@]}"; do
        [[ "$(branch_of "$v")" == "$(branch_of "$c")" ]] && target="$c"
    done
    [[ -n "$target" ]] || target="$(printf '%s\n' "${_cur[@]}" | sort -V | tail -n1)"
    if ver_lt "$v" "$target"; then echo "BEHIND-LATEST"; else echo "UP-TO-DATE"; fi
}

# ---- panel detection and roots ----------------------------------------------
PANEL="plain"
declare -A DOCROOT_DOMAIN=()

if [[ -f /usr/local/cpanel/version && -r /etc/userdatadomains ]]; then
    PANEL="cpanel"
    # /etc/userdatadomains: domain: user==owner==type==main==docroot==ip:port==...
    while IFS= read -r line; do
        dom="${line%%:*}"
        rest="${line#*: }"
        IFS='|' read -r -a f <<< "${rest//==/|}"
        type="${f[2]:-}"; docroot="${f[4]:-}"
        [[ -z "$docroot" || "$type" == "parked" ]] && continue
        # keep the first non-parked domain per docroot (main/addon beat sub)
        if [[ -z "${DOCROOT_DOMAIN[$docroot]:-}" || "$type" == "main" || "$type" == "addon" ]]; then
            DOCROOT_DOMAIN[$docroot]="$dom"
        fi
    done < /etc/userdatadomains
    if [[ ${#ROOTS[@]} -eq 0 ]]; then
        for u in /var/cpanel/users/*; do
            [[ -f "$u" ]] || continue
            h="$(getent passwd "$(basename "$u")" | cut -d: -f6 || true)"
            [[ -n "$h" && -d "$h" ]] && ROOTS+=("$h")
        done
    fi
elif [[ -x /usr/local/directadmin/directadmin && -d /usr/local/directadmin/data/users ]]; then
    PANEL="directadmin"
    if [[ ${#ROOTS[@]} -eq 0 ]]; then
        for u in /usr/local/directadmin/data/users/*; do
            [[ -d "$u" ]] || continue
            h="$(getent passwd "$(basename "$u")" | cut -d: -f6 || true)"
            [[ -n "$h" && -d "$h/domains" ]] && ROOTS+=("$h/domains")
        done
    fi
fi

if [[ ${#ROOTS[@]} -eq 0 ]]; then
    for d in /var/www /home /srv; do [[ -d "$d" ]] && ROOTS+=("$d"); done
fi
[[ ${#ROOTS[@]} -gt 0 ]] || die "nothing to scan (no account homes found; use --path)"

domain_for() {
    local dir="$1" p
    case "$PANEL" in
        cpanel)
            p="$dir"
            while [[ -n "$p" && "$p" != "/" ]]; do
                if [[ -n "${DOCROOT_DOMAIN[$p]:-}" ]]; then
                    if [[ "$p" == "$dir" ]]; then echo "${DOCROOT_DOMAIN[$p]}"
                    else echo "${DOCROOT_DOMAIN[$p]}${dir#"$p"}"; fi
                    return
                fi
                p="$(dirname "$p")"
            done
            echo "-" ;;
        directadmin)
            # /home/USER/domains/DOMAIN/public_html[/sub]
            if [[ "$dir" =~ /domains/([^/]+)/(public_html|private_html)(/.*)?$ ]]; then
                echo "${BASH_REMATCH[1]}${BASH_REMATCH[3]:-}"
            else
                echo "-"
            fi ;;
        *) echo "-" ;;
    esac
}

# ---- scan --------------------------------------------------------------------
find_args=(-maxdepth "$MAXDEPTH")
for pat in '*/virtfs/*' '*/.trash/*' '*/.cagefs/*' '*/.snapshot/*' '*/node_modules/*' ${EXCLUDES[@]+"${EXCLUDES[@]}"}; do
    find_args+=(-path "$pat" -prune -o)
done
# match version.php and wp-load.php, so an install whose version.php is missing
# is still found (and reported as UNKNOWN)
find_args+=(-type f '(' -path '*/wp-includes/version.php' -o -name wp-load.php ')' -print0)

declare -a ROWS=()
declare -A SEEN=()
total=0; outdated=0; unknown=0; behind=0

for root in "${ROOTS[@]}"; do
    while IFS= read -r -d '' hit; do
        if [[ "$hit" == */wp-includes/version.php ]]; then wpdir="$(dirname "$(dirname "$hit")")"
        else wpdir="$(dirname "$hit")"; fi
        [[ -n "${SEEN[$wpdir]:-}" ]] && continue
        SEEN[$wpdir]=1
        # skip stray copies that are not a full core tree
        [[ -f "$wpdir/wp-load.php" && -d "$wpdir/wp-includes" ]] || continue
        vf="$wpdir/wp-includes/version.php"
        # missing or unreadable version.php -> empty version -> UNKNOWN
        ver="$(grep -m1 "\$wp_version[[:space:]]*=" "$vf" 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)+(-[A-Za-z0-9]+)?' | head -n1 || true)"
        owner="$(stat -c '%U' "$vf" 2>/dev/null || stat -c '%U' "$wpdir/wp-load.php" 2>/dev/null || echo '?')"
        st="$(status_for "$ver")"
        lt="$(latest_for "$ver")"
        total=$((total + 1))
        [[ "$st" == "BELOW-MINIMUM" ]] && outdated=$((outdated + 1))
        [[ "$st" == "UNKNOWN" ]] && unknown=$((unknown + 1))
        [[ "$lt" == "BEHIND-LATEST" ]] && behind=$((behind + 1))
        [[ $ONLY_OUTDATED -eq 1 && "$st" != "BELOW-MINIMUM" && "$st" != "UNKNOWN" && "$lt" != "BEHIND-LATEST" ]] && continue
        ROWS+=("$(domain_for "$wpdir")"$'\t'"$wpdir"$'\t'"${ver:-?}"$'\t'"$owner"$'\t'"$st"$'\t'"$lt")
    done < <(find "$root" "${find_args[@]}" 2>/dev/null || true)
done

# align: tab-separated input -> padded columns (no dependency on column(1))
align() {
    awk -F'\t' '{ for (i = 1; i <= NF; i++) { c[NR, i] = $i; if (length($i) > w[i]) w[i] = length($i) } if (NF > n) n = NF }
        END { for (r = 1; r <= NR; r++) { line = ""; for (i = 1; i <= n; i++) line = line sprintf(i < n ? "%-" w[i] "s  " : "%s", c[r, i]); print line } }'
}

# ---- output ------------------------------------------------------------------
csv_field() { local s="${1//\"/\"\"}"; if [[ "$s" == *[,\"]* ]]; then printf '"%s"' "$s"; else printf '%s' "$s"; fi; }

NOTE="MINIMUM-MET only means core >= $MIN_VERSION ($ADVISORY). It is not a full security assessment."
if [[ $CSV -eq 1 ]]; then
    echo "domain,path,version,owner,status,latest"
    for r in "${ROWS[@]+"${ROWS[@]}"}"; do
        IFS=$'\t' read -r d p v o s l <<< "$r"
        printf '%s,%s,%s,%s,%s,%s\n' "$(csv_field "$d")" "$(csv_field "$p")" "$v" "$(csv_field "$o")" "$s" "$l"
    done
    echo "Note: $NOTE" >&2
else
    echo "WordPress version audit - panel: $PANEL - minimum: $MIN_VERSION ($ADVISORY)${BRANCH_FIX:+ - branch fixes for $ADVISORY only: $BRANCH_FIX} - latest: ${CURRENT:-not checked}"
    echo "Note: $NOTE"
    [[ -n "$CURRENT" ]] || echo "      Newer security releases are not checked; add --current with the latest release of each branch."
    echo
    {
        printf 'DOMAIN\tPATH\tVERSION\tOWNER\tSTATUS\tLATEST\n'
        for r in "${ROWS[@]+"${ROWS[@]}"}"; do printf '%s\n' "$r"; done | sort -t$'\t' -k5,5 -k6,6 -k1,1
    } | align
    echo
    echo "Installs found: $total - below minimum (< $MIN_VERSION, $ADVISORY): $outdated - unknown version: $unknown${CURRENT:+ - behind latest ($CURRENT): $behind}"
fi

[[ $outdated -eq 0 && $behind -eq 0 ]] || exit 1
[[ $unknown -eq 0 ]] || exit 3
exit 0
