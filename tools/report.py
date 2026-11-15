#!/usr/bin/env python3
"""Morning read-out for an overnight Awake run.

    python3 tools/report.py [path/to/events.jsonl] [--since HH:MM]

Answers the question nobody in this space publishes: when the phone is locked
and asleep, how often does a message actually arrive, and how fast?
"""

import json
import os
import sys
import time
from datetime import datetime

DEFAULT = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       "..", "dashboard", "events.jsonl")


def newest_log():
    """Prefer the archived run if demo.sh has reset the live log."""
    import glob
    folder = os.path.dirname(os.path.abspath(DEFAULT))
    files = glob.glob(os.path.join(folder, "events*.jsonl"))
    if not files:
        return DEFAULT
    return max(files, key=os.path.getsize)


def load(path):
    if not os.path.exists(path):
        sys.exit(f"no log at {path} — was the dashboard running?")
    out = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                out.append(json.loads(line))
            except Exception:
                pass
    return out


def bar(n, width=40):
    return "█" * min(width, n)


def main():
    args = [a for a in sys.argv[1:]]
    since = None
    if "--since" in args:
        i = args.index("--since")
        since = args[i + 1] if i + 1 < len(args) else None
        del args[i:i + 2]
    path = args[0] if args else newest_log()
    ev = load(path)

    if since:
        ev = [e for e in ev
              if datetime.fromtimestamp(e["t"]).strftime("%H:%M") >= since]
        print(f"\n  filtering events since {since}")

    # A probe is "sent" if it went out live *or* was queued for later.
    probes = [e for e in ev
              if e.get("kind") in ("send", "queued")
              and str(e.get("detail", "")).startswith("probe")]
    acks = [e for e in ev if e.get("kind") == "ack" and "ms" in e]

    # Under 5 s is a live delivery; beyond that it was replayed from the queue
    # after the phone came back, which is a different (also good) result.
    live = [a for a in acks if a["ms"] < 5000]
    replayed = [a for a in acks if a["ms"] >= 5000]
    locked = [e for e in ev if e.get("kind") == "recv" and e.get("locked")]
    queued = [e for e in ev if e.get("kind") == "queued"]
    flushes = [e for e in ev if e.get("kind") == "flush"]

    print()
    print("  AWAKE · overnight delivery report")
    print("  " + "─" * 52)

    if not probes:
        print("  no probe messages in this log.")
        print("  start one with:  open AwakeNode.app --args --probe")
        print()
        return

    span_h = max(0.0, (probes[-1]["t"] - probes[0]["t"]) / 3600.0)
    print(f"  window            {span_h:.1f} h")
    print(f"  probes sent       {len(probes)}")
    print(f"  acks received     {len(acks)}")
    rate = min(100.0, (len(acks) / len(probes) * 100)) if probes else 0
    print(f"  delivered         {len(acks)} / {len(probes)}  ({rate:.0f}%)")

    if live:
        ms = sorted(a["ms"] for a in live)
        p50 = ms[len(ms) // 2]
        p95 = ms[min(len(ms) - 1, int(len(ms) * 0.95))]
        print(f"  live ack          p50 {p50:.0f} ms · p95 {p95:.0f} ms · max {ms[-1]:.0f} ms")

    if replayed:
        worst = max(a["ms"] for a in replayed) / 1000
        print(f"  replayed from queue {len(replayed)} (slowest {worst:.0f} s) — "
              "held while the phone was away")

    if acks:
        first = datetime.fromtimestamp(acks[0]["t"]).strftime("%H:%M:%S")
        last = datetime.fromtimestamp(acks[-1]["t"]).strftime("%H:%M:%S")
        print(f"  first / last ack  {first} / {last}")

    if queued:
        print(f"  queued offline    {len(queued)} messages held")
    if flushes:
        print(f"  queue flushes     {len(flushes)}")
    if locked:
        print(f"  delivered locked  {len(locked)}")

    # hourly histogram of acks
    if acks:
        buckets = {}
        for a in acks:
            h = datetime.fromtimestamp(a["t"]).strftime("%H")
            buckets[h] = buckets.get(h, 0) + 1
        print()
        print("  deliveries per hour")
        for h in sorted(buckets):
            print(f"    {h}:00  {bar(buckets[h])} {buckets[h]}")

    # gaps between acks
    if len(acks) > 1:
        gaps = []
        for a, b in zip(acks, acks[1:]):
            gaps.append((b["t"] - a["t"], a, b))
        gaps.sort(reverse=True, key=lambda g: g[0])
        worst = gaps[0]
        if worst[0] > 360:
            t0 = datetime.fromtimestamp(worst[1]["t"]).strftime("%H:%M:%S")
            t1 = datetime.fromtimestamp(worst[2]["t"]).strftime("%H:%M:%S")
            print()
            print(f"  longest silent gap  {worst[0]/60:.0f} min  ({t0} → {t1})")
            print("  ^ that is where the link dropped or the app was purged.")

    print()


if __name__ == "__main__":
    main()
