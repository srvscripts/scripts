# Changelog: MariaDB Watchdog Script: Restart MariaDB or MySQL Only When It Is Really Hung

File: `mariadb-watchdog.sh`. Page: <https://srvscripts.com/scripts/mariadb-watchdog/>

Newest first. Each version is tagged `mariadb-watchdog/vX.Y.Z` in this repository.

Tested on: 1.0.0 in a test container on 18 Oct 2026: Ubuntu 24.04 with MariaDB 10.11.14; the hang was real (server process frozen with SIGSTOP), systemctl replaced by a stand-in script, so the systemd path on a real server was not part of the test; 42 checks passed (report-only, grace period, backup hold, stop timeout then kill and start, restart limit, down server left alone, too many connections, wrong login, overlapping runs, webhook); 14 more with a fake client run in CI; bash -n and ShellCheck 0.9.0 clean.

## 1.0.0

First release.
