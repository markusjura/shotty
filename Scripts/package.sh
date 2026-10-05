#!/bin/zsh
# Builds the signed Release app and packages it as Shotty-<version>.zip and Shotty-<version>.dmg.
# Usage: Scripts/package.sh
# Output in .build/releases: the ZIP for Scripts/install.sh and fleet, the DMG for people, a .sha256 for
# each, and a .txt record of the signature details (designated requirement and entitlements).
# The DMG opens to the usual window for dragging Shotty to Applications; Config/dmg.py lays it out.
# This is Apple Development signing, not a notarized Developer ID release.
set -euo pipefail
cd "${0:A:h:h}"

bundle_id=local.markus.Shotty

# Fleet syncs the installed build to every Mac by version, so each version must name exactly one commit.
# Packaging only a clean, pushed main makes git serialize the bumps across machines.
git fetch --quiet origin main
[[ -z "$(git status --porcelain)" ]] || { print -u2 "Commit or stash your changes first."; exit 1 }
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || {
  print -u2 "HEAD is not origin/main. Push the version bump on main first."; exit 1
}

Scripts/xcode.sh release build
app=.build/Build/Products/Release/Shotty.app

# Refuse to package anything that is unsigned, altered, or not the stable bundle identity.
codesign --verify --deep --strict --verbose=2 "$app"
[[ "$(/usr/bin/defaults read "$PWD/$app/Contents/Info" CFBundleIdentifier)" == "$bundle_id" ]] || {
  print -u2 "Unexpected bundle identifier; TCC grants are tied to $bundle_id."; exit 1
}

version=$(/usr/bin/defaults read "$PWD/$app/Contents/Info" CFBundleShortVersionString)
name="Shotty-$version"
mkdir -p .build/releases
zip=".build/releases/$name.zip"
dmg=".build/releases/$name.dmg"
for file in $zip $dmg; do
  [[ ! -e "$file" ]] || { print -u2 "$file already exists. Bump the version or remove it."; exit 1 }
done

# Write under temporary names so an interrupted run never leaves a partial file that looks complete.
log=$(mktemp -t shotty-dmg)
trap 'rm -f "$zip.partial" "$dmg.partial.dmg" "$log"' EXIT

# ditto preserves the bundle's signature, symlinks, and extended attributes.
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip.partial"
mv "$zip.partial" "$zip"

# dmgbuild writes the window layout itself, so packaging never scripts Finder. Its hdiutil
# deprecation warnings are noise, so its output only shows when it fails.
uvx dmgbuild==1.6.7 -s Config/dmg.py -D app="$app" Shotty "$dmg.partial.dmg" >"$log" 2>&1 || { cat "$log" >&2; exit 1 }
mv "$dmg.partial.dmg" "$dmg"

for file in $zip $dmg; do
  (cd .build/releases && shasum -a 256 "${file:t}" > "${file:t}.sha256")
done
{
  print "Shotty $version, commit $(git rev-parse --short HEAD)"
  codesign -dvv "$app" 2>&1 | grep -E '^(Identifier|Authority|TeamIdentifier|Runtime Version|Timestamp)='
  print -n "Designated requirement: "; codesign -d -r- "$app" 2>&1 | sed -n 's/^designated => //p'
  print "Entitlements:"; codesign -d --entitlements - --xml "$app" 2>/dev/null | plutil -p - 2>/dev/null || print "(none)"
} > ".build/releases/$name.txt"

print "Packaged $zip and $dmg"
