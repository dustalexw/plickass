#!/bin/bash
# Builds "Plexamp Download Copier.app" next to this script and launches it.
# Double-click in Finder, or run ./build.command in Terminal.
# Re-run after editing app.js, copy_runner.py, correlate.py or plexampDownloadCopier.py.
cd "$(dirname "$0")" || exit 1

APP="Plexamp Download Copier.app"
VERSION="$(tr -d ' \n' < VERSION)"
LOG="build.log"
echo "=== Plexamp Download Copier $VERSION build — $(date)" > "$LOG"

echo "Building Plexamp Download Copier $VERSION…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" || exit 1
cp app.js copy_runner.py correlate.py plexampDownloadCopier.py AppIcon.icns "$APP/Contents/Resources/" >> "$LOG" 2>&1 || {
  echo "Copying the app's files failed. Details are in build.log."; exit 1; }

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Plexamp Download Copier</string>
  <key>CFBundleDisplayName</key><string>Plexamp Download Copier</string>
  <key>CFBundleIdentifier</key><string>local.plexamp-download-copier</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>launcher</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

cat > "$APP/Contents/MacOS/launcher" <<'LAUNCH'
#!/bin/bash
# Starts the native window (app.js); the copying itself is done by Python 3.
MACOS="$(cd "$(dirname "$0")" && pwd)"
export PDC_RES="$(cd "$MACOS/../Resources" && pwd)"
export PDC_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$MACOS/../Info.plist" 2>/dev/null)"
LOG="$HOME/Library/Logs/PlexampDownloadCopier.log"
mkdir -p "$(dirname "$LOG")"

for c in "$HOME/.homebrew/bin/python3" /opt/homebrew/bin/python3 /usr/local/bin/python3 \
         /Library/Frameworks/Python.framework/Versions/Current/bin/python3 /usr/bin/python3; do
  [ -x "$c" ] || continue
  # /usr/bin/python3 is only a stub until Apple's Command Line Tools are installed.
  if [ "$c" = /usr/bin/python3 ] && ! xcode-select -p >/dev/null 2>&1; then continue; fi
  "$c" -c 'import sys; sys.exit(sys.version_info < (3, 7))' 2>/dev/null && { export PDC_PYTHON="$c"; break; }
done
if [ -z "$PDC_PYTHON" ]; then
  osascript -e 'display alert "Plexamp Download Copier needs Python 3" message "Install it from python.org, or run  xcode-select --install  in Terminal." as critical' >/dev/null
  exit 1
fi

exec /usr/bin/osascript -l JavaScript "$PDC_RES/app.js" >>"$LOG" 2>&1
LAUNCH
chmod +x "$APP/Contents/MacOS/launcher"
touch "$APP"
echo "Built $APP" | tee -a "$LOG"

# Launch it, unless asked not to (PDC_NO_LAUNCH=1) or not on a Mac.
if [ "${PDC_NO_LAUNCH:-0}" != "1" ] && command -v open >/dev/null 2>&1; then
  open "$APP"
fi
