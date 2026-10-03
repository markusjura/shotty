# Shotty

A native macOS screenshot utility tailored to Markus's workflow.

## Build and test

Requires an Apple Silicon Mac, macOS 26 or later, Xcode 27, and the existing Apple Development signing identity. On another Mac, import that identity's certificate and private key instead of letting Xcode create a new certificate, so every Mac signs with the same designated requirement. Create a gitignored `Local.xcconfig` in the repository root containing `DEVELOPMENT_TEAM = YOUR_TEAM_ID`. The shared project includes it through `Config/Signing.xcconfig`; no certificate or private key belongs in the repository.

Open `Shotty.xcodeproj` and select the shared Shotty scheme, or run:

```sh
Scripts/build.sh
xcodebuild -project Shotty.xcodeproj -scheme Shotty -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/acceptance-tests test
```

`Scripts/build.sh` builds the signed Release app at `.build/Build/Products/Release/Shotty.app`. The target uses Hardened Runtime, no App Sandbox, and no entitlements. This is private Apple Development signing, not a notarized Developer ID release, so a copied build may not launch as trusted on another Mac.

## Develop

```sh
Scripts/run.sh dev        # build Debug and switch to Shotty Dev
Scripts/run.sh installed  # switch back to /Applications/Shotty.app
```

The Debug build is Shotty Dev, bundle ID `local.markus.Shotty.dev`. It has its own preferences, capture folders, and permission grants, so it never touches the installed Shotty's state, and Spotlight and Raycast list it separately. The two share hotkeys, so only one runs: `run.sh` quits both before launching one, and Shotty Dev quits the installed build when it launches and quits itself when the installed build launches. That check exists only in Debug builds. To start Shotty Dev with your current settings, run `defaults export local.markus.Shotty - | defaults import local.markus.Shotty.dev -` while both are quit.

## Package, install, and roll back

Set `MARKETING_VERSION` and increase `CURRENT_PROJECT_VERSION` in the Shotty target, commit, and push to `main`, then package:

```sh
Scripts/package.sh
```

It refuses to run unless the working tree is clean and `HEAD` is `origin/main`, so each build number names one pushed commit. It builds Release, refuses to continue unless `codesign --verify --deep --strict` passes and the bundle ID is `local.markus.Shotty`, and writes to `.build/releases/`:

- `Shotty-<version>-<build>-<commit>.zip`, created with `ditto` so the signature survives.
- A `.sha256` checksum beside it.
- A `.txt` record of the signing authority, team, designated requirement, and entitlements.

Install on the same Mac:

1. Quit Shotty from its menu. Captures live only while Shotty runs: quitting discards them and keeps saved files, and a launch after a crash starts empty. The installer refuses to run while Shotty is running; it does not quit the app for you.
2. Run `Scripts/install.sh .build/releases/Shotty-<version>-<build>-<commit>.zip`.

The installer checks the checksum when the `.sha256` file is present, verifies the signature and bundle ID, and warns before installing a build whose designated requirement differs from the installed one, because macOS ties permission grants to it. It unpacks into a private work directory on the `/Applications` volume and replaces `/Applications/Shotty.app` by renaming; if placing the new build fails, the old one is moved back. The replaced build is then kept at `~/Library/Application Support/Shotty Installer.noindex/Shotty.previous.app`. If that last step fails, the new install stays and the script prints where the replaced build was left.

`Scripts/install.sh --rollback` reinstalls the previous build the same way and keeps the replaced one as the new previous build, so running it again returns to where you started. Only one previous build is kept. Settings in UserDefaults are never touched by either operation. A rollback therefore runs the older app against the newer settings, so check that it opens them before relying on it.

Neither script strips quarantine or changes Gatekeeper settings. There is no auto-updater.

## Fleet

Install on any fleet Mac as above. Fleet sync from `markusjura/mac-settings` then observes the newer build in `/Applications`, archives it, and installs it on the other Macs within minutes. It quits a running Shotty gracefully and reopens it afterwards. Fleet refuses builds whose designated requirement differs from the one pinned in its policy. Check progress with `fleet status` (`shotty.activation`). Fleet never lowers its target, so it reinstalls the newer build within minutes of `install.sh --rollback`. Set `shotty.enabled` to false in the fleet policy first, or fix forward with a higher build number.

## Permissions

Grant permissions to the installed `/Applications/Shotty.app`. Shotty Dev has its own bundle ID, so it needs its own grants once; they then survive rebuilds. Grants are per Mac; signing does not carry them to another machine.

- **Screen Recording** is required for every capture mode, including OCR. Shotty asks on the first capture and links to System Settings > Privacy & Security > Screen & System Audio Recording. macOS may require relaunching Shotty after granting it.
- **Accessibility** is needed only for Auto Scroll and for "Dismiss thumbnail after pasting", which watches for ⌘V in other apps. Auto Scroll asks for it when you start it; manual scrolling capture works without it.
- Input Monitoring, Full Disk Access, camera, and microphone are not needed.

Keeping the bundle ID and signing identity stable keeps these grants across updates. Grants have survived signed Release replacements with an unchanged designated requirement, including fleet installs.
