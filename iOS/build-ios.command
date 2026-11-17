#!/bin/bash
# Builds plickass for iPhone/iPad and installs it on a connected device.
# Double-click in Finder, or run ./iOS/build-ios.command [device name or UDID].
set -euo pipefail
cd "$(dirname "$0")/.."
LOG="$PWD/iOS/build-ios.log"
exec > >(tee "$LOG") 2>&1
echo "== started $(date)"
xcodebuild -version 2>/dev/null | head -1 || true
# Signing team: PLICKASS_APPLE_TEAM, else the one in the project, else the first in Xcode.
if [ -z "${PLICKASS_APPLE_TEAM:-}" ]; then
  PLICKASS_APPLE_TEAM=$(grep -o 'DEVELOPMENT_TEAM = "[A-Z0-9]\{10\}"' iOS/plickass.xcodeproj/project.pbxproj 2>/dev/null | head -1 | grep -o '[A-Z0-9]\{10\}' || true)
fi
if [ -z "${PLICKASS_APPLE_TEAM:-}" ]; then
  PLICKASS_APPLE_TEAM=$(security find-certificate -a -c "Apple Development" -p 2>/dev/null | openssl x509 -noout -subject 2>/dev/null | sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\).*/\1/p' | head -1 || true)
fi
echo "team=${PLICKASS_APPLE_TEAM:-none}"
export PLICKASS_APPLE_TEAM
python3 -c 'import PIL' 2>/dev/null || python3 -m pip install --quiet --user pillow
python3 scripts/make_ios_project.py
WANT="${1:-}"
DEVICES=$(xcrun devicectl list devices 2>/dev/null | grep -E 'available|connected' | grep -v simulated || true)
echo "$DEVICES"
if [ -n "$WANT" ]; then LINE=$(echo "$DEVICES" | grep -i -- "$WANT" | head -1 || true); else LINE=$(echo "$DEVICES" | grep -iE 'iPhone|iPad' | head -1 || true); fi
UDID=$(echo "$LINE" | grep -oE '[0-9A-F]{8}-[0-9A-F]{16}|[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}' | head -1 || true)
[ -n "$UDID" ] || { echo "No iPhone or iPad found. Connect and unlock it, then try again."; exit 1; }
echo "device=$UDID"
xcodebuild -project iOS/plickass.xcodeproj -scheme plickass -configuration Release \
  -destination "id=$UDID" -derivedDataPath build/ios -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$PLICKASS_APPLE_TEAM" build | grep -E 'error:|warning: .*plickass|BUILD' || true
APP=build/ios/Build/Products/Release-iphoneos/plickass.app
[ -d "$APP" ] || { echo "BUILD FAILED"; exit 1; }
xcrun devicectl device install app --device "$UDID" "$APP"
xcrun devicectl device process launch --device "$UDID" com.dustalexw.plickass.ios || echo "Installed. Unlock the device and open plickass."
echo "== DONE $(date)"
