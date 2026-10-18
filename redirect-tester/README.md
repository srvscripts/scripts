# Redirect Chain Checker

A redirect chain checker for the command line: follows each URL hop by hop with curl and flags loops, chains longer than two, 302s, HTTPS downgrades, non-200 endings and inconsistent www/https variants.

**Full documentation, example output and troubleshooting:** <https://srvscripts.com/scripts/redirect-tester/>

Version 1.0.0 · updated 2026-10-06 · Lab-tested

## Download, verify and run

```bash
curl -fsSLO https://scr.srvscripts.com/redirect-tester/redirect-tester.sh
curl -fsSLO https://scr.srvscripts.com/redirect-tester/redirect-tester.sh.sha256
sha256sum -c redirect-tester.sh.sha256
bash redirect-tester.sh --help
```

Read the script before you run it, and try it on a test server first.

## Requirements

Bash 4+, curl
No root needed; outbound HTTP/HTTPS to the sites you test

## Usage

```text
Usage: redirect-tester.sh [options] URL|DOMAIN ...

Options:
  --file FILE         read URLs from FILE (one per line, # comments allowed)
  --variants          for each domain, test http/https x www/non-www and check
                      that all four end on the same URL
  --max-hops=N        give up after N redirects (default 10)
  --timeout=SEC       per-request timeout (default 10)
  --user-agent=STR    User-Agent header to send
  -q, --quiet         print only URLs that have a problem
  --no-color          plain output even on a terminal
  -h, --help          show this help

A bare domain (example.com) is tested as http://example.com/.
Exit codes: 0 all OK, 1 at least one WARN/FAIL, 2 usage or dependency error
```

## How we tested it

AlmaLinux 9.8 with DirectAdmin 1.712 (lab test, 6 Oct 2026); AlmaLinux 9.8 with cPanel & WHM 11.138 (lab test, 5 Oct 2026); Ubuntu 24.04 (bash 5.2, curl 8.5) against a local test server with 301/302/308, loops, missing Location and 404/500 endings, and live public sites

## Changes and licence

What changed in each version: [CHANGELOG.md](CHANGELOG.md). Releases are tagged `redirect-tester/vX.Y.Z`.

MIT licence. If you copy, share or adapt the script, keep its header and credit [srvScripts.com](https://srvscripts.com/scripts/redirect-tester/).
