# Changelog: Server Security Audit Script

File: `server-security-audit.sh`. Page: <https://srvscripts.com/scripts/server-security-audit/>

Newest first. Each version is tagged `server-security-audit/vX.Y.Z` in this repository.

Tested on: 2.3.0 on Debian 12 with FreePBX 17 (fail2ban only, ACCEPT policy: WARN; with a TCP ACCEPT inserted before a TCP DROP: WARN UNVERIFIED, where 2.2.1 said PASS), AlmaLinux 9.8 with DirectAdmin 1.712 and CSF (PASS) and AlmaLinux 9.8 with cPanel & WHM 11.138 nftables (WARN UNVERIFIED) (lab test, 7 Oct 2026); 61 iptables/nft parser fixtures under gawk and mawk; AlmaLinux 9.8 with DirectAdmin 1.712 (lab test, 6 Oct 2026); AlmaLinux 9.8 with cPanel & WHM 11.138 (lab test, 5 Oct 2026); Ubuntu 24.04 as root and as an unprivileged user; dnf, apt-get, needs-restarting, whmapi1 and csf failure paths tested with stub commands; 2.2.0 firewall evaluation tested with 15 iptables and nft rule fixtures (accept-all before drop, accept-only, policy drop, CSF, ufw and firewalld-style user chains, RETURN, unrelated chains, unreadable rules) under gawk and mawk, and with real iptables-nft and nftables rules in a network namespace; systemctl, Imunify360 and fail2ban states with stub commands (container tests, not yet run on a production server)

## 2.3.0

Firewall check is stricter: PASS only when the INPUT path ends in a catch-all DROP/REJECT (policy or final rule). A DROP that comes after a conditional ACCEPT is now WARN "UNVERIFIED" instead of "filtering verified", and a host with only specific DROPs (fail2ban bans, single ports) on an ACCEPT policy is a WARN. Found in an external review (PROD7-01).

## 2.2.1

The free ImunifyAV (installed by default on cPanel) is no longer mistaken for Imunify360, which gave a false "Imunify360 is installed but not running" warning. Found in our lab test, 5 Oct 2026.

## 2.2.0

Firewall: rules are evaluated in order, so an ACCEPT-everything rule before the DROP is a WARN, not a PASS. An active CSF, firewalld or ufw is reported for context and no longer passes without a reachable DROP/REJECT in the rules; unreadable rules with an active manager are SKIP.

## 2.1.0

Imunify360 counts as brute-force protection only when its service is running; an installed but stopped agent is a WARN.

## 2.1.0

iptables/nftables checks follow the INPUT path and the chains it jumps to and need a drop or reject there; accept-only rules or a drop in an unrelated chain no longer count. A disabled CSF is reported.

## 2.1.0

A failed systemctl query is SKIP instead of "not active"; fail2ban without jails and CSF without a running LFD are reported.

## 2.0.0

Checks whose data cannot be read (shadow, sudoers, firewall rules, sshd config, auth log) report SKIP instead of PASS; skipped checks are counted and set exit 1 unless --allow-skipped.

## 2.0.0

dnf/yum check-update exit codes handled (0 none, 100 updates, other = unknown); failed apt-get -s upgrade or empty apt lists are unknown; needs-restarting -r exit 1 means reboot, other codes mean unknown.

## 2.0.0

Disk usage warnings now count towards the total and the exit code.

## 2.0.0

Every command that can fail for reasons other than a negative finding (sshd -T, whmapi1, systemctl, ss, find, ufw, nft, iptables, sysctl, df) is handled explicitly.

## 2.0.0

sshd -T fallback reads Include files and uses the correct OpenSSH default for PermitRootLogin; --no-color, -h/--help, --version; colour only on a terminal; SKIP lines in --brief.

## 1.0.0

Initial release: accounts, SSH, firewall, ports, brute-force, updates, sysctl, filesystem.
