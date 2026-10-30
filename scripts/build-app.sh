#!/bin/bash
# Builds "TinyTouch Manager.app" and the `tinytouch` CLI into ./dist.
#   scripts/build-app.sh            build only
#   scripts/build-app.sh --install  also copy the app to /Applications and seed the offline firmware cache
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(cat "$ROOT/VERSION")"
APP="$ROOT/dist/TinyTouch Manager.app"
BUNDLE_ID="asia.catgaming.tinytouch.manager"

cd "$ROOT"
swift build -c release --product TinyTouchManager
swift build -c release --product tinytouch
BIN="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin"
cp "$BIN/TinyTouchManager" "$APP/Contents/MacOS/TinyTouchManager"
cp "$BIN/tinytouch" "$APP/Contents/Resources/bin/tinytouch"
cp "$BIN/tinytouch" "$ROOT/dist/tinytouch"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key><string>TinyTouch Manager</string>
  <key>CFBundleName</key><string>TinyTouch Manager</string>
  <key>CFBundleExecutable</key><string>TinyTouchManager</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>LSMultipleInstancesProhibited</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>CatGaming Asia</string>
</dict>
</plist>
PLIST

codesign --force --sign - --identifier "$BUNDLE_ID" "$APP/Contents/Resources/bin/tinytouch"
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
echo "Built $APP (v$VERSION)"

if [[ "${1:-}" == "--install" ]]; then
  osascript -e 'quit app "TinyTouch Manager"' >/dev/null 2>&1 || true
  rm -rf "/Applications/TinyTouch Manager.app"
  cp -R "$APP" /Applications/
  echo "Installed /Applications/TinyTouch Manager.app"

  # Seed the offline firmware cache from firmware-backup/ (kept out of git).
  CACHE="$HOME/Library/Application Support/TinyTouchManager/firmware"
  if [[ -f "$ROOT/firmware-backup/manifest.json" ]]; then
    mkdir -p "$CACHE"
    cp "$ROOT/firmware-backup/manifest.json" "$CACHE/manifest.json"
    for dir in "$ROOT"/firmware-backup/*/; do
      version="$(basename "$dir")"
      mkdir -p "$CACHE/$version"
      find "$dir" -name '*.bin' -exec cp {} "$CACHE/$version/" \;
    done
    echo "Seeded offline firmware cache at $CACHE"
  fi
fi
