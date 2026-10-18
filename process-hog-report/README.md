# Process Hog Report: Which Account Is Using the CPU, RAM and Disk

A read-only Bash script that samples /proc twice and shows which accounts and processes are using the CPU, memory and disk, with each account's domain on cPanel and DirectAdmin, the I/O wait, stuck processes, and a cron mode that only reports when the load is high.

**Full documentation, example output and troubleshooting:** <https://srvscripts.com/scripts/process-hog-report/>

Version 1.0.0 · updated 2026-10-11 · Lab-tested

## Download, verify and run

```bash
curl -fsSLO https://scr.srvscripts.com/process-hog-report/process-hog-report.sh
curl -fsSLO https://scr.srvscripts.com/process-hog-report/process-hog-report.sh.sha256
sha256sum -c process-hog-report.sh.sha256
bash process-hog-report.sh --help
```

Read the script before you run it, and try it on a test server first.

## Requirements

Bash 4+, awk (gawk or mawk), GNU coreutils, getent
Linux /proc (any modern kernel)
Root for disk I/O figures and other users' command lines

## Usage

```text
Usage: process-hog-report.sh [options]

Options:
  --interval=SEC   seconds between the two samples (default 5, 1-300)
  --top=N          lines in each process list (default 10)
  --user=NAME      only this Linux user / hosting account
  --if-load=N      print nothing and exit 0 unless the 1-minute load is >= N
                   (for cron: you only get mail when the server is busy)
  --no-color       plain output even on a terminal
  -V, --version    print the version
  -h, --help       show this help

CPU % is a share of ONE core (a busy 4-core server can show up to 400 %).
Memory is RSS; shared pages are counted once per process, so per-user totals
can be higher than the real use. Disk figures need root. A process that ends
during the sample is not listed; Linux adds its disk I/O to the parent that
collected it (often PID 1, crond or the web server).
```

## How we tested it

AlmaLinux 9.8 with cPanel & WHM 138 (lab test with a CPU burner and a disk writer under two accounts, 11 Oct 2026); AlmaLinux 9.8 with DirectAdmin 1.712; Debian 12 (bash 5.2, gawk 5.2); mawk 1.3.4

## Changes and licence

What changed in each version: [CHANGELOG.md](CHANGELOG.md). Releases are tagged `process-hog-report/vX.Y.Z`.

MIT licence. If you copy, share or adapt the script, keep its header and credit [srvScripts.com](https://srvscripts.com/scripts/process-hog-report/).
