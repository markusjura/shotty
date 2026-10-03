# Project instructions

This file documents guidance for agents working in this repository. Record only non-obvious pitfalls, surprises, and constraints, and add new ones when you discover them.

## Commands

Use the narrowest scope that validates the change. Debug builds and tests share this base command:

```sh
xcodebuild -project Shotty.xcodeproj -scheme Shotty -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/acceptance-tests
```

- `<base> build` builds the Debug app without launching it.
- `<base> test -only-testing:ShottyTests/<TestClass>` runs one test class.
- `<base> test` runs all unit tests in about 10 s. Run it in the foreground. It quits a running Shotty Dev.
- `Scripts/run.sh dev` rebuilds and relaunches Shotty Dev, the Debug build. `Scripts/run.sh installed` switches back to `/Applications/Shotty.app`. Debug is unoptimized, so measure performance with a Release build.
- Shotty Dev has its own bundle ID, `local.markus.Shotty.dev`, plus its own preferences, captures, and permission grants. Its app menu is "Shotty Dev", so open Settings with `shotty-ui menu "Shotty Dev" "Settings…"`. Only one of the two runs: Shotty Dev quits the installed build when it launches and quits itself when the installed build launches.
- `osascript -e 'tell application id "local.markus.Shotty.dev" to quit'` quits Shotty Dev. Use `local.markus.Shotty` for the installed build.
- `Scripts/ui/shotty-ui <command>` drives and measures the running app. See below.

Signing needs the login keychain, which is locked in plain SSH sessions. There `codesign` fails with `errSecInternalComponent`. Build from the Mac's GUI session instead, for example a Codex remote-control session or a Terminal on that Mac.

Package and install only when I ask. Bump `CURRENT_PROJECT_VERSION` first, commit, push to `main`, quit Shotty, then run `Scripts/package.sh` and `Scripts/install.sh .build/releases/<zip>`. `package.sh` refuses anything but a clean `HEAD` equal to `origin/main`. Fleet sync then installs the build on the other Macs; don't copy it there yourself.

## Verifying UI changes

`Scripts/ui/shotty-ui` drives the app and measures the result as text. It targets Shotty Dev when it runs, else the installed Shotty. Run it without arguments for usage. It compiles itself into `.build` on first use.

- Prefer checks that print text over screenshots. `windows`, `cursor`, `focus`, `front`, `text`, and `clip wait` answer most questions without an image.
- Coordinates are global points from the top left of the main display. Screenshots and videos are in pixels, twice the points on this Mac's displays.
- Take screenshots with `screencapture -x -l <window id>` for one window or `screencapture -x -R x,y,w,h` for a region. Shrink large ones with `sips -Z 900` before viewing.
- For animation, flicker, or anything that moves, record first and measure: `record 1 6 out.mov &`, act, then `motion out.mov x y w h`. Look only at the frames it flags, using `frames`.
- Type with `keys` and `key`, which go through System Events. Posted key events may not reach other apps.
- Don't script Finder or TextEdit with osascript. It hangs behind an Automation prompt. Use `windows`, `close`, and `text` instead.
- `drag` holds before and after moving, so drop targets such as Finder accept it. A capture selection needs only a few steps.
- `drag-path x1 y1 x2 y2 [x3 y3 ...]` keeps the button held through multiple segments, for testing curved arrow gestures.
- Use Computer Use for exploratory checks, judging how something looks, or apps the tool can't drive. For repeatable checks, the tool is faster and cheaper.

### Clean up

Save test captures only to `~/Downloads`. Afterwards, quit Shotty, move the test files to the Trash, and clear the clipboard.

## AppKit pitfalls

- The grouped `Form` fills sections with a translucent system color that `.listRowBackground`, `.backgroundStyle`, and `.foregroundStyle` don't change. Settings uses `SettingsFormStyle` to draw sections in `SettingsColor`; keep panes on plain `Form`, `Section`, and controls.
- On macOS 27, `NSMenu` hides item images unless the item sets `preferredImageVisibility = .visible`. An image-only item without it shows as an empty row.
- The editor's `NSHostingView` sets the window's minimum size from the SwiftUI content and overrides `window.minSize`. Constrain the root view with `.frame(minWidth:)` instead.
- On macOS 27, ScreenCaptureKit can list a ChatGPT popover as an on-screen window but fail its screenshot with `SCStreamError.internalError`. Frozen acquisition omits both variants of that optional window so display and area capture can continue. Permission, display, and resource failures still abort.
