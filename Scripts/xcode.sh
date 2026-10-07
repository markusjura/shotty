#!/bin/zsh
# Runs xcodebuild on Shotty with the shared project, scheme, and destination.
# Usage: Scripts/xcode.sh debug|release <xcodebuild arguments>, such as `Scripts/xcode.sh release build`.
# Debug builds and tests share .build/acceptance-tests, so a build after a test run is incremental.
set -euo pipefail
cd "${0:A:h:h}"

case "${1:-}" in
  debug) settings=(-configuration Debug -derivedDataPath .build/acceptance-tests) ;;
  release) settings=(-configuration Release -derivedDataPath .build) ;;
  *) print -u2 "Usage: Scripts/xcode.sh debug|release <xcodebuild arguments>"; exit 1 ;;
esac
shift

# Signing needs the login keychain. Plain SSH sessions can't unlock it, and codesign would fail late
# in the build with errSecInternalComponent.
security show-keychain-info login.keychain >/dev/null 2>&1 || {
  print -u2 "The login keychain is locked, so signing would fail. Build from the Mac's GUI session."; exit 1
}

# SwiftPM otherwise looks up github.com credentials in the keychain to download Sparkle, and that
# lookup can wait forever on a keychain prompt. Sparkle is public, so it needs no credentials.
exec xcodebuild -project Shotty.xcodeproj -scheme Shotty -destination 'platform=macOS,arch=arm64' \
  -packageAuthorizationProvider netrc $settings "$@"
