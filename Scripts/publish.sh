#!/bin/zsh
# Publishes a packaged version as a GitHub release with its DMG and checksum.
# Usage: Scripts/publish.sh <version>
# Scripts/release.sh runs it last. Run it alone to retry a failed publish; it updates an existing release.
# Needs tag v<version> on origin and .build/releases/Shotty-<version>.dmg from Scripts/package.sh.
set -euo pipefail
cd "${0:A:h:h}"

fail() { print -u2 "$1"; exit 1 }
[[ $# -eq 1 ]] || fail "Usage: Scripts/publish.sh <version>"
version="$1" tag="v$1"
dmg=".build/releases/Shotty-$version.dmg"

[[ -f "$dmg" && -f "$dmg.sha256" ]] || fail "$dmg or its checksum is missing. Run Scripts/package.sh on the release commit."
(cd "${dmg:h}" && shasum -a 256 -c "${dmg:t}.sha256" >/dev/null) || fail "Checksum mismatch for $dmg."
[[ -n "$(git ls-remote --tags origin "refs/tags/$tag")" ]] || fail "Tag $tag is not on origin."
git fetch --quiet --tags origin

# Changes since the previous release, without version bumps, chores, and merges.
previous=$(git describe --tags --abbrev=0 --match 'v*' "$tag^" 2>/dev/null || true)
changes=$([[ -n "$previous" ]] && git log --no-merges --format='- %s' "$previous..$tag" | grep -v '^- chore' || true)

# README.md's Install section is the single copy of the install steps.
install=$(awk '/^## /{ found = ($0 == "## Install") } found' README.md)
[[ -n "$install" ]] || fail "README.md has no ## Install section."
notes="${changes:+## Changes

$changes

}$install"

if gh release view "$tag" >/dev/null 2>&1; then
  gh release upload "$tag" "$dmg" "$dmg.sha256" --clobber
  gh release edit "$tag" --title "Shotty $version" --notes "$notes" --draft=false >/dev/null
else
  gh release create "$tag" "$dmg" "$dmg.sha256" --verify-tag --title "Shotty $version" --notes "$notes" >/dev/null
fi
print "Published $(gh release view "$tag" --json url --jq .url)"
