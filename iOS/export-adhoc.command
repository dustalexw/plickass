#!/bin/bash
# Builds a signed ad hoc plickass.ipa (installs on every device registered to the
# Apple Developer team) for the sipassgames.com install page.
# Output: build/adhoc/plickass.ipa
set -euo pipefail
cd "$(dirname "$0")/.."
LOG="$PWD/iOS/export-adhoc.log"
exec > >(tee "$LOG") 2>&1
echo "== started $(date)"
if [ -z "${PLICKASS_APPLE_TEAM:-}" ]; then
  PLICKASS_APPLE_TEAM=$(grep -o 'DEVELOPMENT_TEAM = "[A-Z0-9]\{10\}"' iOS/plickass.xcodeproj/project.pbxproj | head -1 | grep -o '[A-Z0-9]\{10\}')
fi
export PLICKASS_APPLE_TEAM
echo "team=$PLICKASS_APPLE_TEAM"
python3 -c 'import PIL' 2>/dev/null || python3 -m pip install --quiet --user pillow
python3 scripts/make_ios_project.py
rm -rf build/adhoc && mkdir -p build/adhoc
xcodebuild -project iOS/plickass.xcodeproj -scheme plickass -configuration Release \
  -destination 'generic/platform=iOS' -archivePath build/adhoc/plickass.xcarchive \
  -allowProvisioningUpdates DEVELOPMENT_TEAM="$PLICKASS_APPLE_TEAM" archive | grep -E 'error:|ARCHIVE' || true
[ -d build/adhoc/plickass.xcarchive ] || { echo "ARCHIVE FAILED"; exit 1; }
cat > build/adhoc/ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>release-testing</string>
<key>signingStyle</key><string>automatic</string>
<key>teamID</key><string>$PLICKASS_APPLE_TEAM</string>
<key>compileBitcode</key><false/>
<key>thinning</key><string>&lt;none&gt;</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath build/adhoc/plickass.xcarchive -exportPath build/adhoc \
  -exportOptionsPlist build/adhoc/ExportOptions.plist -allowProvisioningUpdates | grep -E 'error:|EXPORT' || true
[ -f build/adhoc/plickass.ipa ] || { echo "EXPORT FAILED"; exit 1; }
# Which devices the build installs on, and when it stops working.
unzip -q -o build/adhoc/plickass.ipa -d build/adhoc/unzipped
security cms -D -i build/adhoc/unzipped/Payload/plickass.app/embedded.mobileprovision > build/adhoc/profile.plist
/usr/libexec/PlistBuddy -c 'Print ProvisionedDevices' build/adhoc/profile.plist | tee build/adhoc/devices.txt
/usr/libexec/PlistBuddy -c 'Print ExpirationDate' build/adhoc/profile.plist | tee build/adhoc/expires.txt
ls -l build/adhoc/plickass.ipa
echo "== DONE $(date)"
