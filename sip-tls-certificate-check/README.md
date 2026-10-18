# SIP TLS Certificate Check for Asterisk and FreePBX (TLS and WSS)

A read-only Bash script that checks every SIP TLS certificate an Asterisk or FreePBX server uses (PJSIP TLS transports and the WSS server WebRTC phones connect to): days left, host name, chain, private key, and whether Asterisk still serves an old certificate after a renewal.

**Full documentation, example output and troubleshooting:** <https://srvscripts.com/scripts/sip-tls-certificate-check/>

Version 1.0.2 · updated 2026-10-17 · Lab-tested

## Download, verify and run

```bash
curl -fsSLO https://scr.srvscripts.com/sip-tls-certificate-check/sip-tls-cert-check.sh
curl -fsSLO https://scr.srvscripts.com/sip-tls-certificate-check/sip-tls-cert-check.sh.sha256
sha256sum -c sip-tls-cert-check.sh.sha256
bash sip-tls-cert-check.sh --help
```

Read the script before you run it, and try it on a test server first.

## Requirements

Bash 4+, OpenSSL 1.1.1 or newer (openssl command), GNU date and coreutils
Run as root (or the asterisk user) on the PBX, so it can read the private keys and ask Asterisk for its transports
Remote checks only need outbound access to the HOST:PORT you give with --check

## Usage

```text
Usage: sip-tls-cert-check.sh [options]
  --name HOST          host name the certificates must match (default: the transport's external address,
                       then the machine's FQDN)
  --check HOST:PORT    also check a remote TLS endpoint (repeatable), e.g. your provider's SIP TLS port
  --ca FILE            extra CA certificates to trust (a private CA); system CAs are always trusted
  --warn-days N        warn when a certificate expires within N days (default 21)
  --crit-days N        critical within N days (default 7)
  --conf DIR           Asterisk config folder (default /etc/asterisk)
  --json               JSON output
  -q, --quiet          print nothing when everything is OK
  -h, --help           this help
```

## How we tested it

1.0.2, 1.0.1 and 1.0.0 on Debian 12 with FreePBX 17.0.33 and Asterisk 22.11 (lab test, 16-17 Oct 2026): PJSIP TLS transport with a private-CA certificate, the FreePBX self-signed WSS default, 9 days left, renewed but not reloaded, wrong host name, mismatched key, expired, remote endpoint; 1.0.1 also with 16 automated fixtures (not yet valid, expired intermediate, missing intermediate, client-only certificate); 1.0.2 with 23 fixtures (combined PEM, encrypted key, client certificate required over TLS 1.3 and 1.2)

## Changes and licence

What changed in each version: [CHANGELOG.md](CHANGELOG.md). Releases are tagged `sip-tls-certificate-check/vX.Y.Z`.

MIT licence. If you copy, share or adapt the script, keep its header and credit [srvScripts.com](https://srvscripts.com/scripts/sip-tls-certificate-check/).
