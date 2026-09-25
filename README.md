# Shotty

A native macOS screenshot utility tailored to Markus's workflow.

Implementation is at milestone 0. The signed native foundation harness and focused tests are in place; the everyday capture interface, editor, scrolling integration, OCR, and release acceptance remain unfinished. See [native verification](.plans/native-verification.md) for measured results and pending gates.

## Build and test

Requires an Apple Silicon Mac, macOS 26 or later, Xcode 27, and an existing Apple Development signing identity. Create a gitignored `Local.xcconfig` containing `DEVELOPMENT_TEAM = YOUR_TEAM_ID`. The shared project includes it through `Config/Signing.xcconfig`; no certificate or private key belongs in the repository.

Open `Shotty.xcodeproj` and select the shared Shotty scheme, or run:

```sh
Scripts/build.sh
xcodebuild -project Shotty.xcodeproj -scheme Shotty -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath .build test
```

The Release app is `.build/Build/Products/Release/Shotty.app`. Install the signed app at `/Applications/Shotty.app` before granting permissions and keep its bundle ID, `local.markus.Shotty`, stable. Quit it before replacing an installed build. This is private Apple Development signing, not a notarized release.

The temporary foundation window opens an animated synthetic fixture and captures its isolated window using ScreenCaptureKit. After waiting for the live fixture to change, Verify Frozen PNG compares the saved snapshot's RGBA pixels with the PNG decoder's output. The harness does not save screenshots into the repository. Screen Recording must be granted through macOS before capture tests can run. Its mouse-only observer is separate and never requests Accessibility or Input Monitoring.

## Specifications

- [Build contract and remaining engineering gates](.plans/build-readiness.md)
- [Implementation plan](.plans/plan.md)
- [Detailed interactions and native quality requirements](.plans/interaction-spec.md)
- [CleanShot feature-by-feature UX reference](.plans/cleanshot-reference.md)
- [macOS APIs, permissions, and signing research](.plans/platform-research.md)
- [Free signing verification](.plans/signing-verification.md)
- [Interactive design preview](.plans/design/standalone-shotty-design.html)
