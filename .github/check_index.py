"""CI check: index.json and the files agree (every script listed, present, checksum matches, version set)."""
import hashlib, json, os, re, sys

d = json.load(open("index.json"))
fail = 0
listed = set()
for s in d["scripts"]:
    listed.add(s["slug"])
    p = os.path.join(s["slug"], s["file"])
    if not os.path.isfile(p):
        print(f"::error::{p} is listed in index.json but missing"); fail = 1; continue
    h = hashlib.sha256(open(p, "rb").read()).hexdigest()
    side = open(p + ".sha256").read().split()[0] if os.path.isfile(p + ".sha256") else ""
    if h != s["sha256"] or h != side:
        print(f"::error file={p}::sha256 {h} does not match index.json / {p}.sha256"); fail = 1
    if not re.fullmatch(r"\d+\.\d+\.\d+", s.get("version", "")):
        print(f"::error file={p}::version '{s.get('version')}' is not X.Y.Z"); fail = 1
folders = {x for x in os.listdir(".") if os.path.isdir(x) and not x.startswith(".")}
for x in sorted(folders - listed):
    print(f"::error::folder {x}/ is not listed in index.json"); fail = 1
print(f"{len(listed)} scripts checked")
sys.exit(fail)
