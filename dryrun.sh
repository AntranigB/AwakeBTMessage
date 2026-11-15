#!/usr/bin/env bash
# Prove the demo will land, right now, in about 15 seconds.
#
#   ./dryrun.sh
#
# Non-disruptive: it asks the running anchor for a round trip through a trigger
# file. Nothing is restarted, so the phone's link is left exactly as it was.
set -uo pipefail
cd "$(dirname "$0")"

PORT="${PORT:-8787}"
ALOG="$HOME/Library/Application Support/AwakeAnchor/anchor.log"
TRIGGER="/tmp/awake-ping-request"

fail() { printf "  \033[31m✗\033[0m %s\n" "$1"; exit 1; }
ok()   { printf "  \033[32m✓\033[0m %s\n" "$1"; }

echo
echo "  AWAKE · dry run"
echo "  ───────────────────────────────────────────"

curl -sf --max-time 2 "http://localhost:$PORT/health" >/dev/null \
  && ok "dashboard up" || fail "dashboard down — run ./demo.sh first"

pgrep -x AwakeNode >/dev/null && ok "anchor running" \
  || fail "anchor not running — ./demo.sh"

pgrep -x caffeinate >/dev/null && ok "Mac kept awake" \
  || fail "caffeinate not running — ./demo.sh re-arms it"

BEFORE=$(wc -l < "$ALOG" 2>/dev/null | tr -d ' ' || echo 0)

# Ask for one round trip.
: > "$TRIGGER"

PINGED=0
for _ in $(seq 1 20); do
  if tail -n +$((BEFORE + 1)) "$ALOG" 2>/dev/null | grep -q "ping probe"; then
    PINGED=1; break
  fi
  sleep 0.4
done

if [ "$PINGED" = "0" ]; then
  echo "  ! the anchor did not answer the trigger within 8s"
  echo "    (it may be an older build — rebuild it, or open the app)"
  exit 1
fi
ok "anchor sent a probe"

# Give the phone time to receive and ack.
sleep 6

STATS=$(curl -s "http://localhost:$PORT/events" | python3 -c "
import json,sys,time
e=json.load(sys.stdin); now=time.time()
w=[x for x in e if now-x.get('t',0)<14]
acks=[x for x in w if x.get('kind')=='ack']
ms=sorted(a.get('ms',0) for a in acks if a.get('ms',0)<5000)
print(len(acks), int(ms[len(ms)//2]) if ms else -1)
")
read -r ACKS P50 <<<"$STATS"

echo
if [ "${ACKS:-0}" -gt 0 ]; then
  ok "round trip: $ACKS ack(s), p50 ${P50} ms"
  echo
  printf "  \033[32mREADY.\033[0m Lock the phone, type in the anchor, press SEND.\n"
  echo
  exit 0
fi

printf "  \033[31mProbe went out, no ack came back.\033[0m\n"
echo
echo "  Check, in order:"
echo "    1. Awake open on the phone and showing LINKED"
echo "    2. Not force-quit (swipe-away defeats wake until reopened)"
echo "    3. Bluetooth on, and not toggled in Settings since launch"
echo "    4. Within ~10 m of the Mac"
echo "  Full list: TROUBLESHOOTING.md"
echo
echo "  Anchor log tail:"
tail -4 "$ALOG" 2>/dev/null | cut -c1-110 | sed 's/^/    /'
echo
exit 1
