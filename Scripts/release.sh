#!/bin/zsh
# Bumps the build number, pushes it to main, then packages, installs, and launches that build.
# Usage: Scripts/release.sh
# Run it only when Markus asks. Fleet sync then installs the build on the other Macs.
# MARKETING_VERSION stays as it is; only Markus changes it.
set -euo pipefail
cd "${0:A:h:h}"

fail() { print -u2 "$1"; exit 1 }
project=Shotty.xcodeproj/project.pbxproj

[[ -z "$(git status --porcelain)" ]] || fail "Commit or stash your changes first."
git fetch --quiet origin main
git merge-base --is-ancestor origin/main HEAD || fail "HEAD doesn't contain origin/main. Rebase onto it first."

# Installs are identified by build number, so it only ever goes up.
build=$(sed -n 's/.*CURRENT_PROJECT_VERSION = \([0-9]*\);.*/\1/p' $project | sort -n | tail -1)
[[ -n "$build" ]] || fail "No CURRENT_PROJECT_VERSION in $project."
next=$(( build + 1 ))
sed -i '' "s/CURRENT_PROJECT_VERSION = [0-9]*;/CURRENT_PROJECT_VERSION = $next;/" $project
git commit --quiet -m "chore: bump build to $next" $project
git push --quiet origin HEAD:main

Scripts/package.sh
Scripts/install.sh .build/releases/Shotty-*-$next-$(git rev-parse --short HEAD).zip
Scripts/run.sh installed
