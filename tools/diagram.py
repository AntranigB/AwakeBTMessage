#!/usr/bin/env python3
"""Render the system architecture as a standalone SVG.

    python3 tools/diagram.py [out.svg]
"""

import os
import sys

W, H = 1000, 560
BG = "#07090a"
PANEL = "#0d1113"
LINE = "#1b2225"
INK = "#e8f1ee"
DIM = "#5d6f6a"
GREEN = "#3ddc84"
CYAN = "#7fd4ff"
AMBER = "#ffb020"


def box(x, y, w, h, title, subtitle, bullets, accent):
    out = [f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="12" fill="{PANEL}" '
           f'stroke="{LINE}" stroke-width="1"/>']
    out.append(f'<rect x="{x}" y="{y}" width="{w}" height="3" rx="1.5" fill="{accent}"/>')
    out.append(f'<text x="{x+18}" y="{y+34}" font-size="13" fill="{INK}" '
               f'font-family="monospace" letter-spacing="2">{title}</text>')
    out.append(f'<text x="{x+18}" y="{y+52}" font-size="9.5" fill="{DIM}" '
               f'font-family="monospace">{subtitle}</text>')
    yy = y + 80
    for b in bullets:
        out.append(f'<text x="{x+18}" y="{yy}" font-size="10" fill="#9ab0aa" '
                   f'font-family="monospace">· {b}</text>')
        yy += 20
    return "".join(out)


def arrow(x1, y1, x2, y2, colour, label="", above=True):
    out = [f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="{colour}" '
           f'stroke-width="1.6" marker-end="url(#head)"/>']
    if label:
        mx = (x1 + x2) / 2
        my = (y1 + y2) / 2 + (-12 if above else 20)
        out.append(f'<text x="{mx}" y="{my}" text-anchor="middle" font-size="9.5" '
                   f'fill="{DIM}" font-family="monospace">{label}</text>')
    return "".join(out)


def main():
    dst = sys.argv[1] if len(sys.argv) > 1 else "results/architecture.svg"
    os.makedirs(os.path.dirname(dst), exist_ok=True)

    svg = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" '
           f'viewBox="0 0 {W} {H}">',
           f'<defs><marker id="head" viewBox="0 0 10 10" refX="9" refY="5" '
           f'markerWidth="7" markerHeight="7" orient="auto-start-reverse">'
           f'<path d="M 0 0 L 10 5 L 0 10 z" fill="{DIM}"/></marker></defs>',
           f'<rect width="{W}" height="{H}" fill="{BG}"/>',
           f'<text x="60" y="44" font-size="17" fill="{INK}" font-family="monospace" '
           f'letter-spacing="7">AWAKE</text>',
           f'<text x="60" y="66" font-size="10.5" fill="{DIM}" font-family="monospace">'
           f'the delivery layer for the ninety seconds after the network dies</text>']

    # phone
    svg.append(box(60, 120, 300, 250, "IPHONE", "locked · airplane mode · no Wi-Fi",
                   ["CoreBluetooth central",
                    "WhisperKit speech→text (on device)",
                    "outbox + retry + local notification",
                    "notifies with the screen off",
                    "app suspended by iOS, still reachable"], GREEN))

    # anchor
    svg.append(box(400, 120, 250, 250, "ANCHOR", "always on · $8 board in production",
                   ["BLE peripheral (GATT)",
                    "store-and-forward queue",
                    "ChaChaPoly seal / open",
                    "replays on reconnect",
                    "never sleeps"], GREEN))

    # dashboard
    svg.append(box(690, 120, 250, 250, "DASHBOARD", "venue operations · localhost",
                   ["live mesh graph",
                    "p50 / p95 delivery latency",
                    "queue depth",
                    "GPS position",
                    "event log persisted to disk"], CYAN))

    # arrows
    svg.append(arrow(360, 245, 398, 245, DIM))
    svg.append(arrow(398, 275, 360, 275, DIM, above=False))
    svg.append(f'<text x="379" y="212" text-anchor="middle" font-size="9" fill="{GREEN}" '
               f'font-family="monospace">BLE</text>')
    svg.append(arrow(650, 245, 688, 245, DIM))
    svg.append(f'<text x="669" y="232" text-anchor="middle" font-size="9" fill="{DIM}" '
               f'font-family="monospace">HTTP</text>')

    # the key mechanism
    svg.append(f'<rect x="60" y="400" width="580" height="86" rx="10" fill="{PANEL}" '
               f'stroke="{LINE}"/>')
    svg.append(f'<text x="80" y="426" font-size="10" fill="{AMBER}" '
               f'font-family="monospace" letter-spacing="1.5">THE MECHANISM</text>')
    svg.append(f'<text x="80" y="448" font-size="10.5" fill="#9ab0aa" '
               f'font-family="monospace">iOS will not let a suspended app scan or advertise.</text>')
    svg.append(f'<text x="80" y="466" font-size="10.5" fill="#c7d7d2" '
               f'font-family="monospace">But it WILL wake one for a notification from a connected</text>')
    svg.append(f'<text x="80" y="482" font-size="10.5" fill="#c7d7d2" '
               f'font-family="monospace">peripheral. So the anchor holds the link, not the phone.</text>')

    # measured box
    svg.append(f'<rect x="664" y="400" width="276" height="86" rx="10" fill="{PANEL}" '
               f'stroke="{LINE}"/>')
    svg.append(f'<text x="684" y="426" font-size="10" fill="{GREEN}" '
               f'font-family="monospace" letter-spacing="1.5">11-MIN SOAK · APP OPEN</text>')
    svg.append(f'<text x="684" y="452" font-size="20" fill="{GREEN}" '
               f'font-family="monospace">23 / 23</text>')
    svg.append(f'<text x="684" y="470" font-size="9.5" fill="{DIM}" '
               f'font-family="monospace">delivered · p50 40 ms · p95 102 ms</text>')

    svg.append(f'<text x="60" y="530" font-size="9" fill="{DIM}" '
               f'font-family="monospace">no Wi-Fi · no cellular · 688-byte frames '
               f'across 5 BLE writes · 56 ms with the app backgrounded</text>')
    svg.append("</svg>")

    with open(dst, "w", encoding="utf-8") as f:
        f.write("\n".join(svg))
    print(f"wrote {dst}")


if __name__ == "__main__":
    main()
