# Project instructions

This file documents guidance for agents working in this repository. Record only non-obvious pitfalls, surprises, and constraints of the workflow and tools, and add new ones when you discover them. Explain code pitfalls in a comment where they apply, not here.

## Commands

- `Scripts/run.sh dev` builds and relaunches Shotty Dev. Run it after every successful change, so the running app matches the code.
- `Scripts/run.sh installed` switches back to the installed Shotty.
- `Scripts/test.sh [TestClass]` runs all unit tests or one class.
- `Scripts/log.sh` streams Shotty's log: capture selection, frozen captures, recording starts, failed segments, stream stops, storage, launch and quit.
- Run `Scripts/release.sh` and `Scripts/publish.sh` only when I ask.

## Verifying UI changes

`Scripts/ui/shotty-ui` drives the app and measures the result as text. It targets Shotty Dev when it runs, else the installed Shotty. Run it without arguments for usage. It compiles itself into `.build` on first use.

- Prefer checks that print text over screenshots. `windows`, `cursor`, `focus`, `front`, `text`, `clip wait`, and `probe` answer most questions without an image. `clip wait out.png` saves a copied image; for a copied clip, `clip wait` prints its path, and `probe` prints its duration, streams, and frame size.
- Coordinates are global points from the top left of the main display. Screenshots and videos are in pixels, twice the points on this Mac's displays.
- Take screenshots with `screencapture -x -l <window id>` for one window or `screencapture -x -R x,y,w,h` for a region. Shrink large ones with `sips -Z 900` before viewing.
- For animation, flicker, or anything that moves, record first and measure: `record 1 6 out.mov &`, act, then `motion out.mov x y w h`. Look only at the frames it flags, using `frames`.
- Type with `keys` and `key`, which go through System Events. Posted key events may not reach other apps. Global hotkeys and the selection overlays do see `press`, which posts at the HID level.
- Recordings exclude Shotty's own windows, so a screenshot or `record` is the only way to see the recording controls or outline.
- Recording runs between tool calls, so a clip is as long as the gap between start and stop. Check durations with `probe` against the time you meant to record, not the time a command slept.
- Posted clicks on an open pop-up menu's items sometimes miss and close the menu without choosing. Pick menu items with the arrow keys (`key 125`) and Return (`key 36`) instead.
- Don't script Finder or TextEdit with osascript. It hangs behind an Automation prompt. Use `windows`, `close`, and `text` instead.
- Use Computer Use for exploratory checks, judging how something looks, or apps the tool can't drive. For repeatable checks, the tool is faster and cheaper.
- Don't mix Computer Use and posted input in one check. While Computer Use is attached, its shield takes the events `shotty-ui` posts, so the selection overlay seems to ignore keys and the pointer.

### Clean up

Save test captures and clips only to `~/Downloads`. Afterwards, move the test files to the Trash and clear the clipboard. If the task was only your own verification, run `Scripts/run.sh installed`; otherwise leave Shotty Dev running for me.
