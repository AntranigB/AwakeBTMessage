#!/usr/bin/env bash
# Bring the whole demo up in a known-good state.
#   ./demo.sh          keep tonight's log, start clean
#   ./demo.sh --probe  also start the 5-minute probe
set -uo pipefail
cd "$(dirname "$0")"

PROBE=""
[ "${1:-}" = "--probe" ] && PROBE="--probe"

echo "→ stopping any running anchor and dashboard"
pkill -f "AwakeNode.app/Contents/MacOS/AwakeNode" 2>/dev/null || true
pkill -f "dashboard/server.py" 2>/dev/null || true
sleep 1

if [ -f dashboard/events.jsonl ]; then
  ARCHIVE="dashboard/events-$(date +%H%M).jsonl"
  mv dashboard/events.jsonl "$ARCHIVE"
  echo "→ archived previous log to $ARCHIVE"
fi

echo "→ keeping the Mac awake"
pgrep -x caffeinate >/dev/null || (nohup caffeinate -dimsu >/dev/null 2>&1 &)

echo "→ dashboard"
nohup python3 dashboard/server.py >/tmp/awake_dash.log 2>&1 &
sleep 1.2
curl -sf http://localhost:8787/health >/dev/null \
  && echo "  ok  http://localhost:8787" \
  || echo "  ✗ dashboard failed — see /tmp/awake_dash.log"

APP=$(ls -d ~/Library/Developer/Xcode/DerivedData/Awake-*/Build/Products/Debug/AwakeNode.app 2>/dev/null | head -1)
if [ -z "${APP:-}" ]; then
  echo "  ✗ AwakeNode.app not built. Run: ./install.sh? no — build the macOS target:"
  echo "     xcodebuild -project Awake.xcodeproj -scheme AwakeNode -destination 'platform=macOS' build"
  exit 1
fi

echo "→ anchor${PROBE:+ (probe mode)}"
open "$APP" --args $PROBE

sleep 3
echo "→ dashboard in browser"
open "http://localhost:8787"

cat <<'EOF'

  ─────────────────────────────────────────────
  Demo ready.

  1. Anchor window should read  PHONE LINKED
  2. iPhone: Awake open, header  LINKED · AWAKE-ANCHOR
  3. Lock the phone, put it face down
  4. Type in the anchor, press SEND
  5. Phone buzzes. That's the demo.

  If it reads NO PHONE · QUEUEING for more than
  ~30s, unlock the phone and open Awake once.
  ─────────────────────────────────────────────
EOF
