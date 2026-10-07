#!/bin/zsh
# Runs one of Sparkle's release tools from the Sparkle package that Release builds resolve.
# Usage: Scripts/sparkle.sh <tool> [arguments], such as `Scripts/sparkle.sh generate_keys -p`.
# Tools: generate_keys keeps the update signing key in the login keychain (-x exports a backup),
# sign_update signs an update archive.
set -euo pipefail
cd "${0:A:h:h}"

bin=.build/SourcePackages/artifacts/sparkle/Sparkle/bin
[[ -x "$bin/${1:?Usage: Scripts/sparkle.sh <tool> [arguments]}" ]] ||
  Scripts/xcode.sh release -quiet -resolvePackageDependencies >/dev/null
exec "$bin/$1" "${@:2}"
