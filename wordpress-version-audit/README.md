# WordPress Version Audit: Find Every WordPress Site and Its Version

This WordPress version audit script, wordpress-version-audit.sh, finds every WordPress install on a cPanel, DirectAdmin or plain Linux server by reading wp-includes/version.php, and prints domain, path, core version, owner and a status. Installs below --min-version (default 7.0.3, the CVE-2026-64638 fix) are marked BELOW-MINIMUM, installs at or above it MINIMUM-MET, and patched older branches can be marked BRANCH-FIXED. MINIMUM-MET is not a full security assessment: add --current with the latest security release of each branch to see which sites are behind. --csv gives you a list to feed into an update loop. It is read-only.

**Full documentation, example output and troubleshooting:** <https://srvscripts.com/scripts/wordpress-version-audit/>

Version 1.1.0 · updated 2026-10-07 · Lab-tested

## Download, verify and run

```bash
curl -fsSLO https://scr.srvscripts.com/wordpress-version-audit/wordpress-version-audit.sh
curl -fsSLO https://scr.srvscripts.com/wordpress-version-audit/wordpress-version-audit.sh.sha256
sha256sum -c wordpress-version-audit.sh.sha256
bash wordpress-version-audit.sh --help
```

Read the script before you run it, and try it on a test server first.

## Requirements

Bash 4+, GNU find/grep/sort/awk; run as root to scan all accounts. cPanel, DirectAdmin or plain Linux.

## Usage

```text
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
```

## How we tested it

1.1.0 on AlmaLinux 9.8 with cPanel & WHM 11.138 (lab test, 7 Oct 2026: three WordPress 7.1.2 sites MINIMUM-MET and BEHIND-LATEST with --current 7.1.3); 17 fixtures; Run on 6 Oct 2026 on AlmaLinux 9.8 with cPanel & WHM 11.138 (3 WordPress sites) and AlmaLinux 9.8 with DirectAdmin 1.712 (3 WordPress sites), plus a test folder with 7.0.2 and 6.9.6 copies; bash -n and ShellCheck 0.9.0 clean.

## Changes and licence

What changed in each version: [CHANGELOG.md](CHANGELOG.md). Releases are tagged `wordpress-version-audit/vX.Y.Z`.

MIT licence. If you copy, share or adapt the script, keep its header and credit [srvScripts.com](https://srvscripts.com/scripts/wordpress-version-audit/).
