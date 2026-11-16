#!/bin/bash
# Builds TrackEdge.app next to this script. Requires Xcode Command Line Tools:
#   xcode-select --install
set -e
cd "$(dirname "$0")"

APP="TrackEdge.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -swift-version 5 main.swift -o "$APP/Contents/MacOS/TrackEdge" \
  -framework Cocoa -framework CoreAudio -framework ServiceManagement

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.trackedge</string>
  <key>CFBundleName</key><string>TrackEdge</string>
  <key>CFBundleExecutable</key><string>TrackEdge</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"
open "$APP"
