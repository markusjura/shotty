# Shotty

A native macOS screenshot utility tailored to Markus's workflow.

## Build and test

Requires an Apple Silicon Mac, macOS 26 or later, Xcode 27, and an existing Apple Development signing identity. Create a gitignored `Local.xcconfig` in the repository root containing `DEVELOPMENT_TEAM = YOUR_TEAM_ID`. The shared project includes it through `Config/Signing.xcconfig`; no certificate or private key belongs in the repository.

Open `Shotty.xcodeproj` and select the shared Shotty scheme, or run:

```sh
Scripts/build.sh
xcodebuild -project Shotty.xcodeproj -scheme Shotty -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/acceptance-tests test
```

`Scripts/build.sh` builds the signed Release app at `.build/Build/Products/Release/Shotty.app`. The target uses Hardened Runtime, no App Sandbox, and no entitlements. This is private Apple Development signing, not a notarized Developer ID release, so a copied build may not launch as trusted on another Mac.

## Package, install, and roll back

Set `MARKETING_VERSION` and increase `CURRENT_PROJECT_VERSION` in the Shotty target, then package:

```sh
Scripts/package.sh
```

It builds Release, refuses to continue unless `codesign --verify --deep --strict` passes and the bundle ID is `local.markus.Shotty`, and writes to `.build/releases/`:

- `Shotty-<version>-<build>-<commit>.zip`, created with `ditto` so the signature survives. A `-dirty` suffix marks uncommitted changes.
- A `.sha256` checksum beside it.
- A `.txt` record of the signing authority, team, designated requirement, and entitlements.

Install on the same Mac:

1. Quit Shotty from its menu. Quitting discards the capture session and keeps saved files; only a session cut short by a crash is offered for restore on the next launch. The installer refuses to run while Shotty is running; it does not quit the app for you.
2. Run `Scripts/install.sh .build/releases/Shotty-<version>-<build>-<commit>.zip`.

The installer checks the checksum when the `.sha256` file is present, verifies the signature and bundle ID, and warns before installing a build whose designated requirement differs from the installed one, because macOS ties permission grants to it. It unpacks into a private work directory on the `/Applications` volume and replaces `/Applications/Shotty.app` by renaming; if placing the new build fails, the old one is moved back. The replaced build is then kept at `~/Library/Application Support/Shotty Installer/Shotty.previous.app`. If that last step fails, the new install stays and the script prints where the replaced build was left.

`Scripts/install.sh --rollback` reinstalls the previous build the same way and keeps the replaced one as the new previous build, so running it again returns to where you started. Only one previous build is kept. Settings in UserDefaults and the capture session in `~/Library/Application Support/Shotty/Session` are never touched by either operation. A rollback therefore runs the older app against the newer settings and session files, so check that it opens them before relying on it.

Neither script strips quarantine or changes Gatekeeper settings. Judge a copied install by whether it actually launches. There is no auto-updater.

## Permissions

Grant permissions to the installed `/Applications/Shotty.app`, not to a build in `.build`. Grants are per Mac; signing does not carry them to another machine.

- **Screen Recording** is required for every capture mode, including OCR. Shotty asks on the first capture and links to System Settings > Privacy & Security > Screen & System Audio Recording. macOS may require relaunching Shotty after granting it.
- **Accessibility** is needed only for Auto Scroll and for "Dismiss thumbnail after pasting", which watches for ⌘V in other apps. Auto Scroll asks for it when you start it; manual scrolling capture works without it.
- Input Monitoring, Full Disk Access, camera, and microphone are not needed.

Keeping the bundle ID and signing identity stable keeps these grants across updates. On studio, grants have survived signed Release replacements with an unchanged designated requirement. Install and permission continuity on m1 is deferred to a separate fleet change.
