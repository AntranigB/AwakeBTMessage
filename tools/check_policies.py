#!/usr/bin/env python3
"""Assert the safety invariants that were each fixed once, by hand.

These are static policy checks, not behavioural tests. They exist because every
one of these properties was established by an edit and could silently return.

    python3 tools/check_policies.py
"""

import json
import re
import subprocess
import sys

COORD = re.compile(r"42\.4[0-9]{3,}|-76\.4[0-9]{3,}")
UDID = re.compile(r"[0-9A-F]{8}-[0-9A-F]{16}")

res = []


def check(label, ok):
    res.append((label, ok))


# 1 — the dashboard must default to localhost: it renders coordinates.
server = open("dashboard/server.py", encoding="utf-8").read()
check("dashboard defaults to 127.0.0.1",
      'AWAKE_BIND", "127.0.0.1"' in server)

# 2 — event logs must stay ignored; they carry live positions.
ign = open(".gitignore", encoding="utf-8").read()
check("event logs are gitignored", "dashboard/events*.jsonl" in ign)

# 3 — the shipped fixture must be position-free.
try:
    rows = [json.loads(l) for l in open("results/fixture-soak.jsonl") if l.strip()]
    text = json.dumps(rows)
    check(f"fixture has no coordinates ({len(rows)} events)",
          not COORD.search(text) and '"lat"' not in text and '"lon"' not in text)
except FileNotFoundError:
    check("fixture present", False)

# 4 — the push guard must still carry both patterns.
try:
    hook = open("tools/pre-push", encoding="utf-8").read()
    check("pre-push blocks coordinates", r"42\.4[0-9]{3,}" in hook)
    check("pre-push blocks device UDIDs", "[0-9A-F]{8}-[0-9A-F]{16}" in hook)
except FileNotFoundError:
    check("pre-push present", False)

# 5 — nothing tracked may contain a real UDID or the coordinates.
tracked = subprocess.run(["git", "ls-files"], capture_output=True,
                         text=True).stdout.split()
bad = []
for f in tracked:
    if f == "tools/pre-push":
        continue
    try:
        body = open(f, encoding="utf-8", errors="ignore").read()
    except OSError:
        continue
    if UDID.search(body) or COORD.search(body):
        bad.append(f)
check("no tracked file contains an identifier" + (f" -> {', '.join(bad)}" if bad else ""),
      not bad)

# 6 — every script the docs tell you to run must exist.
import glob
import os
refs = set()
for p in glob.glob("*.md"):
    s = open(p, encoding="utf-8").read()
    refs |= set(re.findall(r"\./([A-Za-z0-9_.-]+\.sh)", s))
    refs |= {"tools/" + m for m in re.findall(r"tools/([A-Za-z0-9_.-]+\.py)", s)}
missing = sorted(r for r in refs if not os.path.exists(r))
check(f"all {len(refs)} scripts named in the docs exist" +
      (f" -> missing {', '.join(missing)}" if missing else ""), not missing)

fail = 0
for label, ok in res:
    fail += 0 if ok else 1
    print(f"  {'ok      ' if ok else 'FAILED  '}  {label}")
print()
print("PASS: safety invariants hold" if not fail else f"FAIL: {fail} invariant(s) broken")
sys.exit(1 if fail else 0)
