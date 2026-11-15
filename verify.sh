#!/usr/bin/env bash
# One command to prove the whole thing still works.
#   ./verify.sh
# Fault-injected: a failing test or a stopped dashboard exits non-zero.
set -uo pipefail
cd "$(dirname "$0")"

fail=0
say() { printf "\n\033[1m%s\033[0m\n" "$1"; }
ok()  { printf "  \033[32m✓\033[0m %s\n" "$1"; }
bad() { printf "  \033[31m✗\033[0m %s\n" "$1"; fail=1; }

say "1/6  core unit tests (protocol, store-and-forward, crypto)"
if ( cd core && swift test 2>&1 | tee /tmp/awake-tests.log | grep -q "Executed .* tests, with 0 failures" ); then
  ok "$(grep -o 'Executed [0-9]* tests, with 0 failures' /tmp/awake-tests.log | tail -1)"
else
  bad "unit tests failed — see /tmp/awake-tests.log"
fi

say "2/6  generate Xcode project"
if xcodegen generate >/tmp/awake-xcodegen.log 2>&1; then ok "Awake.xcodeproj"; else bad "xcodegen failed"; fi

say "3/6  iOS app builds"
if xcodebuild -project Awake.xcodeproj -scheme Awake -sdk iphonesimulator \
     -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
     -derivedDataPath /tmp/awake-verify \
     -configuration Debug build CODE_SIGNING_ALLOWED=NO >/tmp/awake-ios.log 2>&1; then
  ok "BUILD SUCCEEDED"
else
  bad "iOS build failed — see /tmp/awake-ios.log"
fi

say "4/6  macOS anchor builds"
if xcodebuild -project Awake.xcodeproj -scheme AwakeNode -destination 'platform=macOS' \
     -derivedDataPath /tmp/awake-verify \
     -configuration Debug build CODE_SIGNING_ALLOWED=NO >/tmp/awake-mac.log 2>&1; then
  ok "BUILD SUCCEEDED (isolated from the app you run)"
  # This gate once rebuilt the anchor unsigned into the same DerivedData that
  # demo.sh launches, which presented as 'Bluetooth unsupported'. Assert the
  # shipped app is still properly signed.
  SHIPPED=$(ls -d ~/Library/Developer/Xcode/DerivedData/Awake-*/Build/Products/Debug/AwakeNode.app 2>/dev/null | head -1)
  if [ -n "${SHIPPED:-}" ]; then
    if codesign -v --deep "$SHIPPED" >/dev/null 2>&1; then
      ok "the anchor you run is still signed"
    else
      bad "an unsigned build overwrote the anchor — run a clean build of AwakeNode"
    fi
  fi
else
  bad "macOS build failed — see /tmp/awake-mac.log"
fi

say "5/6  dashboard responds"
if curl -sf --max-time 2 http://localhost:8787/health >/dev/null; then
  ok "$(curl -s http://localhost:8787/health)"
else
  # A fresh clone has nothing running. Start it rather than failing the only
  # command the README tells a newcomer to run.
  ( nohup python3 dashboard/server.py >/tmp/awake_dash.log 2>&1 & )
  sleep 2
  if curl -sf --max-time 2 http://localhost:8787/health >/dev/null; then
    ok "was not running — started it: $(curl -s http://localhost:8787/health)"
  else
    bad "dashboard will not start — see /tmp/awake_dash.log"
  fi
fi

say "6/6  documented numbers and safety invariants"
if python3 tools/check_claims.py >/tmp/awake-claims.log 2>&1; then
  ok "$(tail -1 /tmp/awake-claims.log)"
else
  bad "docs disagree with the logs — see /tmp/awake-claims.log"
fi
if python3 tools/check_policies.py >/tmp/awake-policies.log 2>&1; then
  ok "$(tail -1 /tmp/awake-policies.log)"
else
  bad "a safety invariant is broken — see /tmp/awake-policies.log"
fi

say "RESULTS"
if [ "$fail" -eq 0 ]; then
  printf "  \033[32mall checks passed\033[0m\n\n"
else
  printf "  \033[31msomething failed\033[0m\n\n"
fi
exit "$fail"
