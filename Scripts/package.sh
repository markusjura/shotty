#!/bin/zsh
# Builds the signed Release app and packages it as a versioned ZIP for private installation.
# Usage: Scripts/package.sh
# Output: .build/releases/Shotty-<version>-<build>-<commit>.zip plus a .sha256 checksum and a
# .txt record of the signature details (designated requirement and entitlements).
# This is Apple Development signing, not a notarized Developer ID release.
set -euo pipefail
cd "${0:A:h:h}"

bundle_id=local.markus.Shotty

# Fleet syncs the installed build to every Mac by build number, so each number must name exactly
# one commit. Packaging only a clean, pushed main makes git serialize the bumps across machines.
git fetch --quiet origin main
[[ -z "$(git status --porcelain)" ]] || { print -u2 "Commit or stash your changes first."; exit 1 }
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || {
  print -u2 "HEAD is not origin/main. Push the build bump on main first."; exit 1
}

Scripts/build.sh
app=.build/Build/Products/Release/Shotty.app

# Refuse to package anything that is unsigned, altered, or not the stable bundle identity.
codesign --verify --deep --strict --verbose=2 "$app"
[[ "$(/usr/bin/defaults read "$PWD/$app/Contents/Info" CFBundleIdentifier)" == "$bundle_id" ]] || {
  print -u2 "Unexpected bundle identifier; TCC grants are tied to $bundle_id."; exit 1
}

version=$(/usr/bin/defaults read "$PWD/$app/Contents/Info" CFBundleShortVersionString)
build=$(/usr/bin/defaults read "$PWD/$app/Contents/Info" CFBundleVersion)
commit=$(git rev-parse --short HEAD)
name="Shotty-$version-$build-$commit"
mkdir -p .build/releases
zip=".build/releases/$name.zip"
[[ ! -e "$zip" ]] || { print -u2 "$zip already exists. Bump CURRENT_PROJECT_VERSION or remove it."; exit 1 }

# ditto preserves the bundle's signature, symlinks, and extended attributes. Write under a temporary
# name so an interrupted run never leaves a partial archive that looks complete.
trap 'rm -f "$zip.partial"' EXIT
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip.partial"
mv "$zip.partial" "$zip"
(cd .build/releases && shasum -a 256 "$name.zip" > "$name.zip.sha256")
{
  print "Shotty $version ($build), commit $commit"
  codesign -dvv "$app" 2>&1 | grep -E '^(Identifier|Authority|TeamIdentifier|Runtime Version|Timestamp)='
  print -n "Designated requirement: "; codesign -d -r- "$app" 2>&1 | sed -n 's/^designated => //p'
  print "Entitlements:"; codesign -d --entitlements - --xml "$app" 2>/dev/null | plutil -p - 2>/dev/null || print "(none)"
} > ".build/releases/$name.txt"

print "Packaged $zip"
