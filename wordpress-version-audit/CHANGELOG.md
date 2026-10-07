# Changelog: WordPress Version Audit: Find Every WordPress Site and Its Version

File: `wordpress-version-audit.sh`. Page: <https://srvscripts.com/scripts/wordpress-version-audit/>

Newest first. Each version is tagged `wordpress-version-audit/vX.Y.Z` in this repository.

Tested on: 1.1.0 on AlmaLinux 9.8 with cPanel & WHM 11.138 (lab test, 7 Oct 2026: three WordPress 7.1.2 sites MINIMUM-MET and BEHIND-LATEST with --current 7.1.3); 17 fixtures; Run on 6 Oct 2026 on AlmaLinux 9.8 with cPanel & WHM 11.138 (3 WordPress sites) and AlmaLinux 9.8 with DirectAdmin 1.712 (3 WordPress sites), plus a test folder with 7.0.2 and 6.9.6 copies; bash -n and ShellCheck 0.9.0 clean.

## 1.1.0

Status words now say what is checked: MINIMUM-MET / BELOW-MINIMUM (against 7.0.3 for CVE-2026-64638 by default) instead of OK / OUTDATED; the threshold and advisory are printed. New --current (latest release per branch, e.g. 7.1.3,7.0.7) adds an UP-TO-DATE / BEHIND-LATEST column. A missing or unreadable version.php is UNKNOWN (exit 3). Scripts that grep for OK or OUTDATED need updating. Found in an external review (PROD7-07).

## 1.0.0

First release.
