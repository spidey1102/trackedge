#!/bin/bash
# Builds TrackEdge.app next to this script. Requires Xcode Command Line Tools:
#   xcode-select --install
set -e
cd "$(dirname "$0")"

APP="TrackEdge.app"
VERSION="${VERSION:-0.1}"   # e.g. VERSION=0.2 bash build.sh
# A stable signing certificate keeps macOS permissions across rebuilds.
# Create one named "TrackEdge Dev" (Keychain Access -> Certificate Assistant -> Create a Certificate).
if [ -z "$SIGN_ID" ]; then
  if security find-identity -p codesigning 2>/dev/null | grep -q '"TrackEdge Dev"'; then
    SIGN_ID="TrackEdge Dev"
  else
    SIGN_ID="-"
    echo "NOTE: no 'TrackEdge Dev' certificate found, using ad-hoc signing."
    echo "      macOS will forget permissions on every rebuild until you create it."
  fi
fi
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -swift-version 5 main.swift -o "$APP/Contents/MacOS/TrackEdge" \
  -framework Cocoa -framework CoreAudio -framework ServiceManagement

# App icon: put a square 1024x1024 PNG named icon.png next to this script.
if [ -f icon.png ]; then
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$ICONSET" "$APP/Contents/Resources"
  for s in 16 32 128 256 512; do
    sips -z $s $s icon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) icon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.trackedge</string>
  <key>CFBundleName</key><string>TrackEdge</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleExecutable</key><string>TrackEdge</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign "$SIGN_ID" "$APP"
echo "Built $APP"
open "$APP"
