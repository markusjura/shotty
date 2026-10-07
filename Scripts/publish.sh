#!/bin/zsh
# Publishes a packaged version as a GitHub release: the DMG and its checksum for people, and the ZIP
# with a signed appcast.xml for Sparkle, which installed copies check through releases/latest.
# Usage: Scripts/publish.sh <version>
# Scripts/release.sh runs it last. Run it alone to retry a failed publish; it updates an existing release.
# Needs tag v<version> on origin and .build/releases/Shotty-<version>.dmg and .zip from Scripts/package.sh.
set -euo pipefail
cd "${0:A:h:h}"

fail() { print -u2 "$1"; exit 1 }
[[ $# -eq 1 ]] || fail "Usage: Scripts/publish.sh <version>"
version="$1" tag="v$1"
dmg=".build/releases/Shotty-$version.dmg"
zip=".build/releases/Shotty-$version.zip"

for file in $dmg $zip; do
  [[ -f "$file" && -f "$file.sha256" ]] || fail "$file or its checksum is missing. Run Scripts/package.sh on the release commit."
  (cd "${file:h}" && shasum -a 256 -c "${file:t}.sha256" >/dev/null) || fail "Checksum mismatch for $file."
done
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

# Installed copies accept only a ZIP signed with the key their Info.plist names.
info() { unzip -p "$zip" Shotty.app/Contents/Info.plist | plutil -extract "$1" raw -o - - }
[[ "$(info CFBundleVersion)" == "$version" ]] || fail "$zip is not version $version."
[[ "$(Scripts/sparkle.sh generate_keys -p)" == "$(info SUPublicEDKey)" ]] ||
  fail "The login keychain has no Sparkle key matching SUPublicEDKey in $zip."
signature=$(Scripts/sparkle.sh sign_update "$zip")

repo=$(gh repo view --json url --jq .url)
# Sparkle shows the changes as release notes. Settings links What's New to the release page. The feed lists only this release; Sparkle needs nothing older.
items=$(print -r -- "$changes" | sed -n -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's|^- \(.*\)|<li>\1</li>|p')
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
appcast="$work/appcast.xml"
cat > "$appcast" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Shotty</title>
    <item>
      <title>Shotty $version</title>
      <link>$repo/releases/tag/$tag</link>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$version</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$(info LSMinimumSystemVersion)</sparkle:minimumSystemVersion>
      ${items:+<description><![CDATA[<ul>$items</ul>]]></description>}
      <enclosure url="$repo/releases/download/$tag/${zip:t}" type="application/octet-stream" $signature />
    </item>
  </channel>
</rss>
XML
xmllint --noout "$appcast" || fail "The generated appcast is not valid XML."

if gh release view "$tag" >/dev/null 2>&1; then
  gh release upload "$tag" "$dmg" "$dmg.sha256" "$zip" "$appcast" --clobber
  gh release edit "$tag" --title "Shotty $version" --notes "$notes" --draft=false >/dev/null
else
  gh release create "$tag" "$dmg" "$dmg.sha256" "$zip" "$appcast" --verify-tag --title "Shotty $version" --notes "$notes" >/dev/null
fi
print "Published $(gh release view "$tag" --json url --jq .url)"
