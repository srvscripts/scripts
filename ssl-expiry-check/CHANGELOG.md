# Changelog: SSL Expiry Check Script: Free Network Test for Web and Mail

File: `ssl-expiry-check.sh`. Page: <https://srvscripts.com/scripts/ssl-expiry-check/>

Newest first. Each version is tagged `ssl-expiry-check/vX.Y.Z` in this repository.

Tested on: AlmaLinux 9.8 with cPanel & WHM 11.138 (lab test, 5 Oct 2026); AlmaLinux 9, Ubuntu 24.04, macOS 14 (BSD date supported)

## 1.1.0

Also verifies the certificate chain and host name: self-signed, untrusted, incomplete-chain and wrong-host certificates are now reported as BAD (previously only the expiry date was checked, so a self-signed certificate showed OK). New --allow-untrusted option. Found in our lab test on cPanel, 5 Oct 2026.

## 1.0.0

Initial release
