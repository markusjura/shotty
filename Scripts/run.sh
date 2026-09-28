#!/bin/zsh
# Switches the running Shotty between the development build and the installed one.
# Usage:
#   Scripts/run.sh dev        # build Debug, quit any running Shotty, launch the Debug build
#   Scripts/run.sh installed  # quit any running Shotty, launch /Applications/Shotty.app
# Both builds share preferences, the capture folder, and hotkeys, so only one runs at a time.
# Shotty is asked to quit, so running saves and exports finish first.
set -euo pipefail
cd "${0:A:h:h}"

bundle_id=local.markus.Shotty
fail() { print -u2 "$1"; exit 1 }

case "${1:-}" in
  dev)
    app="$PWD/.build/acceptance-tests/Build/Products/Debug/Shotty.app"
    # Build before quitting, so a failed build leaves the running app alone. Tests use the same
    # derived data, so a build after a test run is incremental.
    xcodebuild -quiet -project Shotty.xcodeproj -scheme Shotty -configuration Debug \
      -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/acceptance-tests build
    ;;
  installed)
    app=/Applications/Shotty.app
    [[ -d "$app" ]] || fail "$app is missing. Install a build with Scripts/install.sh first."
    ;;
  *) fail "Usage: Scripts/run.sh dev | installed" ;;
esac

if pgrep -xq Shotty; then
  osascript -e "tell application id \"$bundle_id\" to quit"
  # Quit waits up to 10 s for running exports.
  for _ in {1..75}; do pgrep -xq Shotty || break; sleep 0.2; done
  pgrep -xq Shotty && fail "Shotty didn't quit within 15 s. Quit it, then retry."
fi

open "$app"
print "Launched $app ($(/usr/bin/defaults read "$app/Contents/Info" CFBundleShortVersionString) build $(/usr/bin/defaults read "$app/Contents/Info" CFBundleVersion))"
