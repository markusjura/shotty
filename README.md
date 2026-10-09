# Shotty

A native macOS screenshot and screen recording utility tailored to Markus's workflow. Capture an area, a window, the screen, a scrolling page, or text, or record an area, a window, or a screen as a clip. Every capture lands as a thumbnail in the bottom left corner. Drag it into any app, or click it to annotate a screenshot or to trim, crop, and export a clip as MP4 or GIF.

## Install

Shotty needs macOS 26 or later.

1. Download the DMG from the [latest release](https://github.com/markusjura/shotty/releases/latest) and open it.
2. Drag Shotty onto Applications.
3. Open Shotty from Applications. macOS says it can't verify Shotty, because Shotty isn't notarized by Apple. Click Done.
4. Open System Settings > Privacy & Security, click Open Anyway next to the message about Shotty, and confirm with your password.

Shotty runs from the menu bar. On your first capture, it asks you to allow Screen Recording in System Settings. Auto Scroll asks for Accessibility the first time you start it, and a recording with the microphone on asks for Microphone access.

## Build and test

Requires an Apple Silicon Mac, macOS 26 or later, Xcode 27, and the existing Apple Development signing identity. On another Mac, import that identity's certificate and private key instead of letting Xcode create a new certificate, so every Mac signs with the same designated requirement. Create a gitignored `Local.xcconfig` in the repository root containing `DEVELOPMENT_TEAM = YOUR_TEAM_ID`. The shared project includes it through `Config/Signing.xcconfig`; no certificate or private key belongs in the repository.

Open `Shotty.xcodeproj` and select the shared Shotty scheme, or run:

```sh
Scripts/xcode.sh release build
Scripts/test.sh
```

`Scripts/xcode.sh release build` builds the signed Release app at `.build/Build/Products/Release/Shotty.app`. The target uses Hardened Runtime and no App Sandbox. Its only entitlement, audio input in `Config/Shotty.entitlements`, lets Hardened Runtime record the microphone. This is private Apple Development signing, not a notarized Developer ID release, so a copied build may not launch as trusted on another Mac.

## Develop

```sh
Scripts/run.sh dev        # build Debug and switch to ~/Applications/Shotty Dev.app
Scripts/run.sh installed  # switch back to /Applications/Shotty.app
```

The Debug build is Shotty Dev, bundle ID `local.markus.Shotty.dev`. It has its own preferences, capture folders, and permission grants, so it never touches the installed Shotty's state, and Spotlight and Raycast list it separately. `run.sh dev` copies the build to `~/Applications/Shotty Dev.app` and launches that copy, because Spotlight doesn't index the hidden `.build` folder. Every checkout and worktree replaces the same copy. The two share hotkeys, so only one runs: `run.sh` quits both before launching one, and Shotty Dev quits the installed build when it launches and quits itself when the installed build launches. That check exists only in Debug builds. To start Shotty Dev with your current settings, run `defaults export local.markus.Shotty - | defaults import local.markus.Shotty.dev -` while both are quit.

## Release, package, install, and roll back

`Config/Version.xcconfig` holds the version, and the build number equals it. `Scripts/release.sh [patch|minor|major|X.Y.Z]` bumps it (patch by default), commits `chore: release <version>`, and pushes that commit to `main` together with tag `v<version>`. It then packages, installs, and launches the release with the scripts below, and publishes it with `Scripts/publish.sh <version>`. If a step after the push fails, it prints the remaining steps to run by hand.

`Scripts/package.sh` refuses to run unless the working tree is clean and `HEAD` is `origin/main`, so each version names one pushed commit. It builds Release, refuses to continue unless `codesign --verify --deep --strict` passes and the bundle ID is `local.markus.Shotty`, and writes to `.build/releases/`:

- `Shotty-<version>.zip`, created with `ditto` so the signature survives. `install.sh` and fleet use it.
- `Shotty-<version>.dmg`, built by `uvx dmgbuild` with the layout in `Config/dmg.py`. It opens to a window for dragging Shotty onto Applications. `swift Scripts/GenerateDMGBackground.swift Config` regenerates its background.
- A `.sha256` checksum beside each.
- A `.txt` record of the signing authority, team, designated requirement, and entitlements.

`Scripts/publish.sh <version>` creates or updates the GitHub release for tag `v<version>` with the DMG and its checksum. The notes list the commits since the previous tag, without chores, followed by the Install section above.

To install on the same Mac, run `Scripts/install.sh .build/releases/Shotty-<version>.zip`. It refuses a ZIP older than the installed version. It asks a running Shotty to quit first, like its Quit menu item. Captures live only while Shotty runs: quitting discards them and keeps saved files, and a launch after a crash starts empty.

The installer checks the checksum when the `.sha256` file is present, verifies the signature and bundle ID, and warns before installing a build whose designated requirement differs from the installed one, because macOS ties permission grants to it. It unpacks into a private work directory on the `/Applications` volume and replaces `/Applications/Shotty.app` by renaming; if placing the new build fails, the old one is moved back. The replaced build is then kept at `~/Library/Application Support/Shotty Installer.noindex/Shotty.previous.app`. If that last step fails, the new install stays and the script prints where the replaced build was left.

`Scripts/install.sh --rollback` reinstalls the previous build the same way and keeps the replaced one as the new previous build, so running it again returns to where you started. Only one previous build is kept. Settings in UserDefaults are never touched by either operation. A rollback therefore runs the older app against the newer settings, so check that it opens them before relying on it.

Neither script strips quarantine or changes Gatekeeper settings. There is no auto-updater.

## Fleet

Install on any fleet Mac as above. Fleet sync from `markusjura/mac-settings` then observes the newer version in `/Applications`, archives it, and installs it on the other Macs within minutes. It quits a running Shotty gracefully and reopens it afterwards. Fleet refuses builds whose designated requirement differs from the one pinned in its policy. Check progress with `fleet status` (`shotty.activation`). Fleet never lowers its target, so it reinstalls the newer build within minutes of `install.sh --rollback`. Set `shotty.enabled` to false in the fleet policy first, or fix forward with a higher version.

## Permissions

Grant permissions to the installed `/Applications/Shotty.app`. Shotty Dev has its own bundle ID, so it needs its own grants once; they then survive rebuilds. Grants are per Mac; signing does not carry them to another machine.

- **Screen Recording** is required for every capture and recording mode, including OCR and system audio. Shotty asks on the first capture and links to System Settings > Privacy & Security > Screen & System Audio Recording. macOS may require relaunching Shotty after granting it.
- **Microphone** is needed only for recording your microphone into clips. Shotty asks the first time you record with the microphone on, which you pick in the Record bar.
- **Accessibility** is needed only for Auto Scroll and for Thumbnails > "Dismiss after pasting", which watches for ⌘V in other apps. Auto Scroll asks for it when you start it; manual scrolling capture works without it.
- Input Monitoring, Full Disk Access, and camera are not needed.

Keeping the bundle ID and signing identity stable keeps these grants across updates. Grants have survived signed Release replacements with an unchanged designated requirement, including fleet installs.
