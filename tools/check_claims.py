#!/usr/bin/env python3
"""Check that the numbers written in RESULTS.md still match the archived logs.

The failure this exists to catch has happened four times in this project: a
figure gets computed once, quoted in five documents, and quietly stops being
true. If a claim can't be regenerated from a stored artifact, it isn't evidence.

    python3 tools/check_claims.py
"""

import datetime
import glob
import json
import os
import re
import sys

RESULTS = "RESULTS.md"
WINDOW = ("05:11:00", "05:25:00")
# Redacted copy of the run, shipped so a public clone can still reproduce the
# numbers. No coordinates in it.
FIXTURE = "results/fixture-soak.jsonl"


def clock(e):
    return datetime.datetime.fromtimestamp(e.get("t", 0)).strftime("%H:%M:%S")


def sources():
    if len(sys.argv) > 1:
        return sys.argv[1:]
    live = sorted(glob.glob("dashboard/events*.jsonl"))
    if live:
        return live
    if os.path.exists(FIXTURE):
        return [FIXTURE]
    return []


def load(paths):
    events = []
    for p in paths:
        for line in open(p, encoding="utf-8"):
            line = line.strip()
            if not line:
                continue
            try:
                e = json.loads(line)
            except Exception:
                continue
            events.append(e)
    return events


def documented():
    text = open(RESULTS, encoding="utf-8").read()
    m = re.search(
        r"probes sent\s+(\d+)\s*\n"
        r"acks received\s+(\d+)\s*\n"
        r"delivery rate\s+(\d+)%\s*\n"
        r"p50 / p95 / max\s+(\d+) / (\d+) / (\d+) ms", text)
    if not m:
        return None
    return dict(probes=int(m[1]), acks=int(m[2]), rate=int(m[3]),
                p50=int(m[4]), p95=int(m[5]), mx=int(m[6]))


def measured(events):
    lo, hi = WINDOW
    w = [e for e in events if lo <= clock(e) <= hi]
    probes = [e for e in w if e.get("kind") in ("send", "queued")
              and str(e.get("detail", "")).startswith("probe")]
    acks = [e for e in w if e.get("kind") == "ack" and "ms" in e and e["ms"] < 5000]
    ms = sorted(a["ms"] for a in acks)
    if not ms:
        return None
    return dict(probes=len(probes), acks=len(acks),
                rate=round(len(acks) / max(1, len(probes)) * 100),
                p50=round(ms[len(ms) // 2]),
                p95=round(ms[min(len(ms) - 1, int(len(ms) * 0.95))]),
                mx=round(ms[-1]))


def main():
    paths = sources()
    if not paths:
        print("skip: no archived logs and no fixture in this checkout")
        return 0
    doc = documented()
    if not doc:
        # Deliberately not a skip. If logs exist but the table can't be parsed,
        # the check has stopped checking — which must look like failure, not
        # like success.
        print("FAIL: RESULTS.md has no parseable soak table — cannot verify the numbers")
        return 1

    events = load(paths)
    got = measured(events)
    if not got and os.path.exists(FIXTURE) and FIXTURE not in paths:
        # The live log may not reach back to the documented window (a demo.sh
        # reset, or archives deleted). The shipped fixture always does.
        print("note: no acks in the supplied logs, checking the fixture instead")
        events = load([FIXTURE])
        got = measured(events)
    if not got:
        print("FAIL: no acks in the documented window")
        return 1

    failed = 0
    for k in ("probes", "acks", "rate", "p50", "p95", "mx"):
        ok = doc[k] == got[k]
        failed += 0 if ok else 1
        print(f"  {'ok      ' if ok else 'MISMATCH'}  {k:<7} docs={doc[k]:<6} measured={got[k]}")

    for label, ok in {
        "56 ms ack present": any(e.get("kind") == "ack" and round(e.get("ms", -1)) == 56
                                 for e in events),
        "83906 ms ack present": any(e.get("kind") == "ack" and round(e.get("ms", -1)) == 83906
                                    for e in events),
    }.items():
        failed += 0 if ok else 1
        print(f"  {'ok      ' if ok else 'MISSING '}  {label}")

    print()
    if failed:
        print(f"FAIL: {failed} documented claim(s) disagree with the archive")
        return 1
    print("PASS: every documented number regenerates from the archive")
    return 0


if __name__ == "__main__":
    sys.exit(main())
