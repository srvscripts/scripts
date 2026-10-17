# Changelog: SIP TLS Certificate Check for Asterisk and FreePBX (TLS and WSS)

File: `sip-tls-cert-check.sh`. Page: <https://srvscripts.com/scripts/sip-tls-certificate-check/>

Newest first. Each version is tagged `sip-tls-certificate-check/vX.Y.Z` in this repository.

Tested on: 1.0.1 and 1.0.0 on Debian 12 with FreePBX 17.0.33 and Asterisk 22.11 (lab test, 16-17 Oct 2026): PJSIP TLS transport with a private-CA certificate, the FreePBX self-signed WSS default, 9 days left, renewed but not reloaded, wrong host name, mismatched key, expired, remote endpoint; 1.0.1 also with 16 automated fixtures (not yet valid, expired intermediate, missing intermediate, client-only certificate)

## 1.0.1

Checks a certificate that is not valid yet, an expired CA certificate in the chain, a certificate not allowed for TLS server use and a served chain without its intermediate; the served chain is always verified; the different-certificate message names the other possible causes (proxy, SNI, another file). Found in an independent review.

## 1.0.0

Initial release
