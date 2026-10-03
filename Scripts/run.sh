#!/bin/zsh
# Switches between the development build, Shotty Dev, and the installed Shotty.
# Usage:
#   Scripts/run.sh dev        # build Debug, quit both, launch Shotty Dev
#   Scripts/run.sh installed  # quit both, launch /Applications/Shotty.app
# Shotty Dev has its own bundle ID, preferences, captures, and permission grants, so opening
# "Shotty" or "Shotty Dev" by name always starts that build. They share hotkeys, so Shotty Dev quits
# the installed build when it launches and quits itself when the installed build launches.
# Each build is asked to quit, so running saves and exports finish first.
set -euo pipefail
cd "${0:A:h:h}"

installed_id=local.markus.Shotty
dev_id=local.markus.Shotty.dev
fail() { print -u2 "$1"; exit 1 }
running() { [[ -n "$(lsappinfo find bundleid="$1")" ]] }

case "${1:-}" in
  dev)
    app="$PWD/.build/acceptance-tests/Build/Products/Debug/Shotty Dev.app"
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

for id in $installed_id $dev_id; do
  running $id || continue
  osascript -e "tell application id \"$id\" to quit"
  # Quit waits up to 10 s for running exports.
  for _ in {1..75}; do running $id || break; sleep 0.2; done
  running $id && fail "$id didn't quit within 15 s. Quit it, then retry."
done

open "$app"
print "Launched $app ($(/usr/bin/defaults read "$app/Contents/Info" CFBundleShortVersionString) build $(/usr/bin/defaults read "$app/Contents/Info" CFBundleVersion))"
