#!/bin/zsh
# Builds the synthetic scrolling fixture app at .build/fixtures/ShottyScrollFixture.app (ad-hoc signed).
set -euo pipefail
cd "${0:A:h:h:h}"
fixture_app=.build/fixtures/ShottyScrollFixture.app
rm -rf "$fixture_app"
mkdir -p "$fixture_app/Contents/MacOS"
xcrun swiftc -swift-version 6 -O -target arm64-apple-macosx26.0 -parse-as-library \
  Scripts/Fixtures/ShottyScrollFixture.swift -o "$fixture_app/Contents/MacOS/ShottyScrollFixture"
cat > "$fixture_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.markus.ShottyScrollFixture</string>
  <key>CFBundleName</key><string>Shotty Scrolling Fixture</string>
  <key>CFBundleExecutable</key><string>ShottyScrollFixture</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
codesign --force --sign - --identifier local.markus.ShottyScrollFixture "$fixture_app"
echo "$fixture_app"
