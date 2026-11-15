#!/usr/bin/env bash
# One screen of truth: is the demo still standing?
set -uo pipefail
cd "$(dirname "$0")"

green() { printf "\033[32m%s\033[0m" "$1"; }
amber() { printf "\033[33m%s\033[0m" "$1"; }
red()   { printf "\033[31m%s\033[0m" "$1"; }

echo
echo "  AWAKE · status"
echo "  ───────────────────────────────────────────"

# anchor (exact process name, so this script can't match itself)
if pgrep -x AwakeNode >/dev/null 2>&1; then
  printf "  anchor        %s\n" "$(green running)"
else
  printf "  anchor        %s\n" "$(red "NOT RUNNING — ./demo.sh")"
fi

PROBE_ON=0
ps -Ao command | awk '/AwakeNode\.app\/Contents\/MacOS/ && /--probe/ && !/awk/ {f=1} END {exit !f}' && PROBE_ON=1
if pgrep -x AwakeNode >/dev/null 2>&1 && [ "$PROBE_ON" = "1" ]; then
  printf "  probe mode    %s\n" "$(amber "ON — stop before judging")"
else
  printf "  probe mode    %s\n" "$(green off)"
fi

if pgrep -x caffeinate >/dev/null 2>&1; then
  printf "  mac awake     %s\n" "$(green yes)"
else
  printf "  mac awake     %s\n" "$(red "NO — will sleep")"
fi

if lsof -nP -iTCP:8787 -sTCP:LISTEN >/dev/null 2>&1; then
  EVENTS=$(curl -s --max-time 2 http://localhost:8787/health \
           | python3 -c "import json,sys; print(json.load(sys.stdin)['events'])" 2>/dev/null)
  printf "  dashboard     %s (%s events)\n" "$(green up)" "${EVENTS:-?}"
else
  printf "  dashboard     %s\n" "$(red "DOWN — python3 dashboard/server.py")"
fi

DEV=$(xcrun devicectl list devices 2>/dev/null | grep -i "iphone" | grep -Ei "available|connected" | head -1 | awk '{print $1, $2, $3}')
if [ -n "${DEV:-}" ]; then
  printf "  iphone        %s\n" "$(green reachable)"
else
  printf "  iphone        %s\n" "$(amber "not reachable — unlock + plug in / same Wi-Fi")"
fi

if [ -f dashboard/events.jsonl ]; then
  LAST=$(tail -1 dashboard/events.jsonl 2>/dev/null \
         | python3 -c "import json,sys,datetime; e=json.load(sys.stdin); print(datetime.datetime.fromtimestamp(e['t']).strftime('%H:%M:%S'), e.get('kind'), str(e.get('detail',''))[:40])" 2>/dev/null)
  printf "  last event    %s\n" "${LAST:-none}"
fi

echo "  ───────────────────────────────────────────"
echo "  phone:   open Awake, header should read LINKED · AWAKE-ANCHOR"
echo "  anchor:  header should read PHONE LINKED"
echo
