# Changelog: SIP TLS Certificate Check for Asterisk and FreePBX (TLS and WSS)

File: `sip-tls-cert-check.sh`. Page: <https://srvscripts.com/scripts/sip-tls-certificate-check/>

Newest first. Each version is tagged `sip-tls-certificate-check/vX.Y.Z` in this repository.

Tested on: 1.0.2, 1.0.1 and 1.0.0 on Debian 12 with FreePBX 17.0.33 and Asterisk 22.11 (lab test, 16-17 Oct 2026): PJSIP TLS transport with a private-CA certificate, the FreePBX self-signed WSS default, 9 days left, renewed but not reloaded, wrong host name, mismatched key, expired, remote endpoint; 1.0.1 also with 16 automated fixtures (not yet valid, expired intermediate, missing intermediate, client-only certificate); 1.0.2 with 23 fixtures (combined PEM, encrypted key, client certificate required over TLS 1.3 and 1.2)

## 1.0.2

The private key is also compared when it is in the same PEM file as the certificate; an encrypted or missing key is reported; an unfinished TLS handshake (for example a server that requires a client certificate) is a WARNING, and the JSON has certificate_valid and handshake_complete. Found in a second independent review.

## 1.0.1

Checks a certificate that is not valid yet, an expired CA certificate in the chain, a certificate not allowed for TLS server use and a served chain without its intermediate; the served chain is always verified; the different-certificate message names the other possible causes (proxy, SNI, another file). Found in an independent review.

## 1.0.0

Initial release
