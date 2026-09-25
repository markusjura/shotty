#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
xcodebuild -project Shotty.xcodeproj -scheme Shotty -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath .build "$@" build
