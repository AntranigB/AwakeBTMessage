#!/usr/bin/env bash
# Rebuild and reinstall on the phone. Unlock the phone first.
set -euo pipefail
cd "$(dirname "$0")"

# Auto-detect the first connected iPhone; override with DEVICE=<udid>.
DEVICE="${DEVICE:-$(xcrun devicectl list devices 2>/dev/null \
  | grep -oE '[0-9A-F]{8}-[0-9A-F]{16}' | head -1)}"

if [ -z "$DEVICE" ]; then
  echo "No iPhone found. Unlock it, keep it near the Mac, and retry."
  echo "  xcrun devicectl list devices   # should say 'available (paired)'"
  echo "  DEVICE=<udid> ./install.sh     # or name it explicitly"
  exit 1
fi
echo "→ device $DEVICE"
BUNDLE="com.antranigbaghdassarian.awake"

echo "→ generating project"
xcodegen generate >/dev/null

echo "→ building for device"
xcodebuild -project Awake.xcodeproj \
  -scheme Awake \
  -destination "id=$DEVICE" \
  -configuration Debug \
  -allowProvisioningUpdates \
  build | grep -E "BUILD (SUCCEEDED|FAILED)"

APP=$(find ~/Library/Developer/Xcode/DerivedData -name "Awake.app" -path "*Debug-iphoneos*" | head -1)
if [ -z "${APP:-}" ]; then
  echo "✗ no Awake.app produced"; exit 1
fi

echo "→ installing $APP"
xcrun devicectl device install app --device "$DEVICE" "$APP" | grep -E "bundleID|installationURL" || true

echo "→ launching"
xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE" >/dev/null 2>&1 || \
  echo "  (launch failed — open Awake from the home screen)"

echo "✓ done. On the phone: allow Notifications, Bluetooth, Location (Always), Microphone."
