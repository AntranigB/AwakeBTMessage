#!/usr/bin/env python3
"""Render the delivery record as a standalone SVG for slides.

    python3 tools/chart.py [events.jsonl] [out.svg]

No dependencies. Safe to drop into Keynote / Google Slides / a README.
"""

import json
import os
import sys
from datetime import datetime

W, H = 1000, 430
PAD_L, PAD_R, PAD_T, PAD_B = 74, 26, 74, 58

BG = "#07090a"
PANEL = "#0d1113"
GRID = "#1b2225"
INK = "#e8f1ee"
DIM = "#5d6f6a"
GREEN = "#3ddc84"
CYAN = "#7fd4ff"
AMBER = "#ffb020"


DEFAULT = "dashboard/events.jsonl"


def newest_log():
    """demo.sh archives the live log; a bare run should still find the data."""
    import glob
    folder = os.path.dirname(DEFAULT)
    files = glob.glob(os.path.join(folder, "events*.jsonl"))
    if not files:
        return DEFAULT
    return max(files, key=os.path.getsize)


def load(path):
    out = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                try:
                    out.append(json.loads(line))
                except Exception:
                    pass
    return out


def esc(s):
    return (s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))


def main():
    args = sys.argv[1:]
    since = until = None
    for flag in ("--since", "--until"):
        if flag in args:
            i = args.index(flag)
            if i + 1 < len(args):
                if flag == "--since":
                    since = args[i + 1]
                else:
                    until = args[i + 1]
            del args[i:i + 2]

    src = args[0] if args else newest_log()
    dst = args[1] if len(args) > 1 else "results/soak-latency.svg"
    os.makedirs(os.path.dirname(dst), exist_ok=True)

    ev = load(src)
    clock = lambda e: datetime.fromtimestamp(e["t"]).strftime("%H:%M")
    if since:
        ev = [e for e in ev if clock(e) >= since]
    if until:
        ev = [e for e in ev if clock(e) <= until]
    # Live acks only. A message replayed from the queue reports the age of the
    # queue, not the latency of the link — plotting both invents a cliff.
    acks = sorted([e for e in ev
                   if e.get("kind") == "ack" and "ms" in e and e["ms"] < 5000],
                  key=lambda e: e["t"])
    probes = [e for e in ev if e.get("kind") in ("send", "queued")
              and str(e.get("detail", "")).startswith("probe")]

    if not acks:
        sys.exit("no ack events to plot")

    t0 = min(a["t"] for a in acks)
    t1 = max(a["t"] for a in acks)
    span = max(1.0, t1 - t0)

    ms = sorted(a["ms"] for a in acks)
    p50 = ms[len(ms) // 2]
    p95 = ms[min(len(ms) - 1, int(len(ms) * 0.95))]
    ymax = max(ms) * 1.2

    def X(t):
        return PAD_L + (t - t0) / span * (W - PAD_L - PAD_R)

    def Y(v):
        return H - PAD_B - (v / ymax) * (H - PAD_T - PAD_B)

    layers = []

    # grid + y labels
    step = 25
    v = 0
    while v <= ymax:
        y = Y(v)
        layers.append(f'<line x1="{PAD_L}" y1="{y:.1f}" x2="{W-PAD_R}" y2="{y:.1f}" '
                      f'stroke="{GRID}" stroke-width="1"/>')
        layers.append(f'<text x="{PAD_L-10}" y="{y+4:.1f}" text-anchor="end" '
                      f'font-size="10" fill="{DIM}" font-family="monospace">{v}</text>')
        v += step

    # p50 line
    layers.append(f'<line x1="{PAD_L}" y1="{Y(p50):.1f}" x2="{W-PAD_R}" y2="{Y(p50):.1f}" '
                  f'stroke="{AMBER}" stroke-width="1" stroke-dasharray="5 5" opacity="0.75"/>')
    layers.append(f'<text x="{W-PAD_R}" y="{Y(p50)-7:.1f}" text-anchor="end" font-size="10" '
                  f'fill="{AMBER}" font-family="monospace">p50 {p50:.0f} ms</text>')

    # dots
    for a in acks:
        x, y = X(a["t"]), Y(a["ms"])
        big = (a.get("bytes") or 0) > 300
        colour = CYAN if big else GREEN
        r = 6 if big else 4.5
        layers.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="{r}" fill="{colour}" '
                      f'opacity="0.9"/>')
    # connect
    # Break the line across idle gaps; joining them invents a trend that never
    # happened (an idle hour would look like a latency cliff).
    seg, prev = [], None
    for a in acks:
        fresh = prev is None or (a["t"] - prev) > 300
        seg.append(f'{"M" if fresh else "L"}{X(a["t"]):.1f},{Y(a["ms"]):.1f}')
        prev = a["t"]
    path = " ".join(seg)
    layers.insert(0, f'<path d="{path}" fill="none" stroke="{GREEN}" stroke-width="1.2" '
                     f'opacity="0.35"/>')

    # x labels
    ticks = 5
    for i in range(ticks + 1):
        t = t0 + span * i / ticks
        x = X(t)
        label = datetime.fromtimestamp(t).strftime("%H:%M:%S")
        layers.append(f'<line x1="{x:.1f}" y1="{H-PAD_B}" x2="{x:.1f}" y2="{H-PAD_B+5}" '
                      f'stroke="{GRID}"/>')
        layers.append(f'<text x="{x:.1f}" y="{H-PAD_B+20}" text-anchor="middle" '
                      f'font-size="10" fill="{DIM}" font-family="monospace">{label}</text>')

    svg = f'''<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">
  <rect width="{W}" height="{H}" fill="{BG}"/>
  <text x="{PAD_L}" y="30" font-size="16" fill="{INK}" font-family="monospace"
        letter-spacing="6">AWAKE</text>
  <text x="{PAD_L}" y="50" font-size="11" fill="{DIM}" font-family="monospace">
    delivery to a locked iPhone · Bluetooth only · no Wi-Fi · no cellular</text>

  <text x="{W-PAD_R}" y="30" text-anchor="end" font-size="22" fill="{GREEN}"
        font-family="monospace">{len(acks)}/{max(len(probes), len(acks))}</text>
  <text x="{W-PAD_R}" y="48" text-anchor="end" font-size="9" fill="{DIM}"
        font-family="monospace" letter-spacing="2">DELIVERED · ALL ACKED</text>

  {''.join(layers)}

  <text x="{PAD_L}" y="{H-16}" font-size="9" fill="{DIM}" font-family="monospace">ms →</text>
  <circle cx="{W-250}" cy="{H-20}" r="4.5" fill="{GREEN}"/>
  <text x="{W-238}" y="{H-16}" font-size="9" fill="{DIM}" font-family="monospace">short</text>
  <circle cx="{W-180}" cy="{H-20}" r="6" fill="{CYAN}"/>
  <text x="{W-168}" y="{H-16}" font-size="9" fill="{DIM}" font-family="monospace">688 B / 5 writes</text>
</svg>
'''
    with open(dst, "w", encoding="utf-8") as f:
        f.write(svg)
    print(f"wrote {dst}  ({len(acks)} acks, p50 {p50:.0f} ms, p95 {p95:.0f} ms)")


if __name__ == "__main__":
    main()
