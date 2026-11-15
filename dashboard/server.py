#!/usr/bin/env python3
"""Zero-dependency dashboard server for Awake.

    python3 dashboard/server.py

Serves http://localhost:8080 and accepts POST /event from the anchor app.
"""

import json
import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

EVENTS = []
HERE = os.path.dirname(os.path.abspath(__file__))
LOG_PATH = os.environ.get("AWAKE_LOG", os.path.join(HERE, "events.jsonl"))


MAX_EVENTS = 2000
MAX_BYTES = 5 * 1024 * 1024


def rotate_if_large():
    """An always-on anchor should not grow one log file without bound."""
    try:
        if os.path.getsize(LOG_PATH) > MAX_BYTES:
            stamp = time.strftime("%H%M%S")
            os.rename(LOG_PATH, LOG_PATH.replace(".jsonl", f"-{stamp}.jsonl"))
    except OSError:
        pass


def load_events():
    """Replay the on-disk log so a restart never loses an overnight run."""
    if not os.path.exists(LOG_PATH):
        return
    with open(LOG_PATH, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                EVENTS.append(json.loads(line))
            except Exception:
                pass
    # Only the tail is useful to the dashboard; do not hold the whole file.
    del EVENTS[:-MAX_EVENTS]


def append_event(ev):
    with open(LOG_PATH, "a", encoding="utf-8") as f:
        f.write(json.dumps(ev, separators=(",", ":")) + "\n")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _send(self, code, body, ctype="application/json"):
        if isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.startswith("/events"):
            self._send(200, json.dumps(EVENTS[-800:]))
        elif self.path.startswith("/health"):
            self._send(200, json.dumps({"ok": True, "events": len(EVENTS)}))
        else:
            try:
                with open(os.path.join(HERE, "index.html"), "rb") as f:
                    self._send(200, f.read(), "text/html; charset=utf-8")
            except FileNotFoundError:
                self._send(404, "index.html missing", "text/plain")

    def do_POST(self):
        if not self.path.startswith("/event"):
            self._send(404, "{}")
            return
        n = int(self.headers.get("Content-Length", 0) or 0)
        raw = self.rfile.read(n) if n else b"{}"
        try:
            ev = json.loads(raw)
        except Exception:
            ev = {"kind": "raw", "detail": raw.decode("utf-8", "replace")}
        if not isinstance(ev, dict):
            ev = {"kind": "raw", "detail": str(ev)}
        ev.setdefault("t", time.time())
        EVENTS.append(ev)
        append_event(ev)
        del EVENTS[:-MAX_EVENTS]
        self._send(204, b"")

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8787"))
    rotate_if_large()
    load_events()
    print(f"\n  AWAKE dashboard  ->  http://localhost:{port}")
    print(f"  log              ->  {LOG_PATH}  ({len(EVENTS)} replayed)\n")
    # Localhost by default. This panel shows live GPS coordinates and accepts
    # unauthenticated POSTs, so it must not be reachable from venue Wi-Fi.
    # Set AWAKE_BIND=0.0.0.0 deliberately for a LAN demo.
    bind = os.environ.get("AWAKE_BIND", "127.0.0.1")
    print(f"  bind             ->  {bind}:{port}\n")
    ThreadingHTTPServer((bind, port), Handler).serve_forever()
