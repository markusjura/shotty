#!/bin/zsh
# Installs a packaged Shotty build into /Applications, keeping the replaced build for rollback.
# Usage:
#   Scripts/install.sh path/to/Shotty-<version>-<build>-<commit>.zip
#   Scripts/install.sh --rollback      # swap the installed build with the previous one
# A running Shotty is asked to quit, like its Quit menu item, so it finishes running saves and clears its captures.
# Settings (UserDefaults) are never touched.
# Gatekeeper and quarantine are left alone; judge an install by whether it launches.
#
# Every replacement is two renames inside a private work directory on the /Applications volume.
# If the second rename fails, the first is undone, so /Applications/Shotty.app is never left missing.
set -euo pipefail

bundle_id=local.markus.Shotty
installed=/Applications/Shotty.app
# Spotlight skips .noindex folders, so launchers like Raycast never list the kept build and its old icon.
keep_dir="$HOME/Library/Application Support/Shotty Installer.noindex"
previous="$keep_dir/Shotty.previous.app"

fail() { print -u2 "$1"; exit 1 }
requirement() { codesign -d -r- "$1" 2>&1 | sed -n 's/^designated => //p' }
describe() {
  print "$(/usr/bin/defaults read "$1/Contents/Info" CFBundleShortVersionString) ($(/usr/bin/defaults read "$1/Contents/Info" CFBundleVersion))"
}
verify() {
  codesign --verify --deep --strict "$1" || fail "Signature verification failed for $1."
  [[ "$(/usr/bin/defaults read "$1/Contents/Info" CFBundleIdentifier)" == "$bundle_id" ]] || fail "$1 is not $bundle_id."
}

[[ $# -eq 1 ]] || fail "Usage: Scripts/install.sh <Shotty.zip> | --rollback"
mkdir -p "$keep_dir"
work=$(mktemp -d /Applications/.Shotty-install.XXXXXX)
# Removes only what this run created. A displaced build that could not be kept is left for recovery.
cleanup() { rm -rf "$work/new.app" "$work/unpacked"; rmdir "$work" 2>/dev/null || print -u2 "Recovery copy left in $work." }
trap cleanup EXIT

# Screen Recording and Accessibility grants follow the designated requirement, so ask before
# installing a build whose requirement differs from the installed one.
confirm_requirement() {
  local candidate="$1"
  [[ -d "$installed" && "$(requirement "$installed")" != "$(requirement "$candidate")" ]] || return 0
  print -u2 "The designated requirement differs from the installed build, so macOS may ask for permissions again."
  print -u2 "  installed: $(requirement "$installed")"
  print -u2 "  new:       $(requirement "$candidate")"
  read -q "?Install anyway? [y/N] " || { print; exit 1 }
  print
}

running() { [[ -n "$(lsappinfo find bundleid=$bundle_id)" ]] }

# Moves `replacement` into /Applications/Shotty.app, leaving the displaced build at $work/old.app.
# Quits a running Shotty first. Any earlier failure leaves it running.
replace_installed() {
  local replacement="$1"
  if running; then
    osascript -e "tell application id \"$bundle_id\" to quit"
    # Quit waits up to 10 s for running exports.
    for _ in {1..75}; do running || break; sleep 0.2; done
    running && fail "Shotty didn't quit within 15 s. Quit it, then retry."
  fi
  [[ -d "$installed" ]] && mv "$installed" "$work/old.app"
  if ! mv "$replacement" "$installed"; then
    [[ -d "$work/old.app" ]] && mv "$work/old.app" "$installed"
    fail "Could not move the new build into place; $installed is unchanged."
  fi
}

# Keeps the displaced build for rollback. The new install is already complete if this fails.
keep_displaced() {
  [[ -d "$work/old.app" ]] || return 0
  if [[ -d "$previous" ]]; then mv "$previous" "$work/discard.app"; fi
  if mv "$work/old.app" "$previous"; then
    rm -rf "$work/discard.app"
  else
    # A cross-volume move can fail midway; drop its partial copy before restoring the kept build.
    rm -rf "$previous"
    [[ -d "$work/discard.app" ]] && mv "$work/discard.app" "$previous"
    fail "Installed, but could not keep the replaced build; it is at $work/old.app."
  fi
}

if [[ "$1" == --rollback ]]; then
  [[ -d "$previous" ]] || fail "No previous build is kept at $previous."
  [[ -d "$installed" ]] || fail "$installed is missing; install a ZIP instead."
  verify "$previous"
  from=$(describe "$installed") to=$(describe "$previous")
  # Copy first: the kept build may live on another volume, and it stays intact until the swap succeeds.
  ditto "$previous" "$work/new.app"
  verify "$work/new.app"
  confirm_requirement "$work/new.app"
  replace_installed "$work/new.app"
  keep_displaced
  print "Rolled back $from → $to. Run --rollback again to return to $from."
  exit 0
fi

zip="${1:A}"
[[ -f "$zip" ]] || fail "$zip does not exist."
if [[ -f "$zip.sha256" ]]; then
  (cd "${zip:h}" && shasum -a 256 -c "${zip:t}.sha256" >/dev/null) || fail "Checksum mismatch for $zip."
else
  print "No ${zip:t}.sha256 beside the archive; skipping checksum."
fi
ditto -x -k "$zip" "$work/unpacked"
[[ -d "$work/unpacked/Shotty.app" ]] || fail "$zip does not contain Shotty.app at its top level."
mv "$work/unpacked/Shotty.app" "$work/new.app"
verify "$work/new.app"

confirm_requirement "$work/new.app"
replace_installed "$work/new.app"
keep_displaced
print "Installed $(describe "$installed") at $installed."
[[ -d "$previous" ]] && print "Previous build $(describe "$previous") kept for Scripts/install.sh --rollback."
exit 0
