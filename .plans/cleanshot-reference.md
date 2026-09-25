# CleanShot X UX reference for Shotty

Feature-by-feature notes on how CleanShot X behaves, limited to the features Shotty needs. Sources accessed 2026-09-25. The public changelog lists 5.0.1 as the current release (5.0 dated 18 September 2026). The version installed on Markus's Mac was not checked, so observed behavior below is not tied to a specific version.

Primary sources used:

- Features page: https://cleanshot.com/features (F)
- Screenshots page: https://cleanshot.com/screenshots (S)
- Changelog: https://cleanshot.com/changelog (C, cited with version number)
- URL scheme API: https://cleanshot.com/docs-api (API)
- FAQ: https://cleanshot.com/faq
- Official settings screenshots embedded on the features page: https://cleanshot.com/_ipx/f_png&q_90&s_729x594/img/features/settings1.png, settings2.png, settings3.png (SET)
- Quick Access context menu image: https://cleanshot.com/_ipx/f_png&q_90&s_400x270/img/features/quick_actions.png (QA-IMG)

The attempted `/help` and `/docs` routes returned 404. Official YouTube update videos are linked from the changelog (for example https://www.youtube.com/watch?v=FNHt4WUa13w), but this review did not inspect their content or transcripts. Live Computer Use observations are included below. Remaining Unknown entries were not resolved in this inspection; [interaction-spec.md](interaction-spec.md) defines Shotty's intended behavior separately.

Labels:

- **Documented**: stated in a source above. Each claim carries its source.
- **Unknown**: not resolved by official text. Do not assume.
- **Observed**: seen in the live app through Computer Use on 2026-09-25.
- **User-confirmed**: described by Markus from his use of CleanShot; distinguished from tool observations.
- **Proposal**: recommendation for Shotty, not a CleanShot claim. The interaction spec and plan own final Shotty decisions.

## 1. Capture modes

### Capture Area

- Documented: Capture Area, Capture Fullscreen, Capture Window, Scrolling Capture, and Self-Timer are separate capture modes. (F)
- Documented: crosshair and magnifier options for precise selection; "Freeze screen" to capture moving objects. (F; Magnifying Glass in crosshair mode and Freeze Screen added in C 3.4)
- Documented: crosshair mode can be enabled by holding ⌘ while taking a screenshot (C 2.2), and there is a preference to show the crosshair with the Command key (C 3.1).
- Documented: Shift creates perfect shapes in Annotate (C 2.5). Option selects the screen *recording* area uniformly (C 3.9.4). Whether Option or Shift constrains a *screenshot* area selection is Unknown.
- Documented: hold Control while taking a screenshot to copy it to the clipboard (C 4.2.2).
- Documented: hold Shift while taking a screenshot to temporarily disable an automatically applied Background preset (C 4.8.4).
- Documented: "Capture Previous Area" repeats the last area (C 3.3.1; API `/capture-previous-area`).
- Documented: dedicated shortcuts "Capture Area & Copy to Clipboard", "Capture Area & Annotate", "Capture Area & Pin", "Capture Area & Save", "Capture Area & Upload to Cloud" (C 3.1, C 4.3; SET shortcuts screen). Since 4.3 these do not ignore After Capture settings, and 4.3.1 added a setting to change this behavior. (C 4.3, C 4.3.1)
- Documented: "Hide desktop icons while capturing" toggle in General > Capture. (SET)
- Documented: All-In-One mode lets you specify size, lock aspect ratio, and retake the last selection (F, S). All-In-One is not in Shotty's requested scope; the size/aspect behavior is noted only as reference.
- User-confirmed in a manual test: the dimension readout appears before dragging, changes instantly during dragging, and releasing the left mouse button immediately creates the screenshot. Escape leaves capture mode. This resolves the normal mouse-up commit and cancellation path.
- Unknown: exact readout placement and values before dragging, arrow-key nudging, Return behavior, an optional adjustment-before-commit mode, and multi-display drag behavior. (Arrow keys with Cmd/Shift move and resize the *recording* area, C 3.1.2; whether the same applies to screenshot areas is Unknown.)
- Follow-up attempt: Markus invoked Capture Area manually and the tool was checked after 15 seconds. The thumbnail controls disappeared from AX, leaving an unlabeled full-screen dialog whose screenshot contained a wallpaper-only display. Neither the crosshair nor a selection was visible. Sending Space, then Space and a drag, produced no observable selection or capture. This does not establish Space behavior or drag-release semantics; wrong-display targeting or unhandled synthetic input remains unresolved. User observation was requested before further input.
- User-confirmed follow-up: capture was invoked on the display containing ChatGPT/Codex. CleanShot froze that screen, so Markus could not see subsequent assistant messages. This means the wallpaper-only tool view did not faithfully establish what he saw; the attempt must not be interpreted as a failed user invocation.
- Observed in Markus's supplied settings screenshot (`image-2026-09-25-15.35.51@2x.png`): Screenshots → Freeze screen is checked, with help describing hover states, animations, and fast-moving content. Crosshair mode is Disabled; Show magnifier appears checked but disabled. Do not conflate this configurable crosshair mode with the ordinary area-selection pointer, whose appearance remains unverified. The image is reference evidence only and is not copied into the repository or preview.
- Proposal: frozen-screen overlay, crosshair/loupe and live W×H readout, with drag-and-release capture as the fast default. Shift locks a square, Option draws from center, and Space moves the selection during a drag. Optional adjustment mode retains handles after release and uses Return to commit; the keyboard-only path uses that mode. See the interaction spec for complete semantics.

### Capture Fullscreen

- Documented: dedicated mode and shortcut; the official settings screenshot shows ⇧⌘3 bound to Capture Fullscreen and ⇧⌘4 to Capture Area (SET). This is a marketing screenshot, so whether these are defaults is Unknown.
- Documented: CleanShot auto-crops the notch from screenshots of fullscreen apps (C 4.6).
- Documented: API `display` parameter: "If not specified, CleanShot will use the display which the cursor is on" (API, stated for area/all-in-one/scrolling). For fullscreen the multi-display rule is Unknown.
- Proposal: capture the display under the cursor; offer "All displays" as a setting only if Markus uses it.

### Capture Window

- Documented: window screenshots "With background" (padding, desktop background, custom image, plain color) or "Transparent", and "Enable/Disable shadow" (F). Preference to disable window shadow (C 3.1). Window screenshots are editable: background can be changed or removed after capture (C 4.8).
- User-confirmed in a manual test: pressing Space in Area mode enters window selection. The selected window gets a blueish overlay across its full bounds, with a camera icon centered horizontally and vertically. Escape leaves capture mode.
- Unknown: cycling between overlapping windows, whether a second Space returns to area mode, and modifier behavior. The user's test verified entry into window selection, not every transition.
- Proposal: match the full-window translucent blue highlight and centered camera icon; click to capture, Space toggles area/window, shadow toggle in Settings. Backgrounds are out of scope.

### Scrolling Capture

- Documented: "Works in every app and supports both vertical and horizontal scrolling" (F; horizontal added C 4.8).
- Documented: Auto-Scroll option added in C 4.4. The API exposes `start` (automatically start capture) and `autoscroll` (enable auto-scroll mode) parameters for `/scrolling-capture`, plus `x`, `y`, `width`, `height`, `display` (API). This shows selection, start, and auto-scroll are distinct steps in the flow.
- Documented: warning when a scrolling capture is too long (C 4.5.1); algorithm improvements and misalignment fixes (C 3.9.4, C 4.0.1, C 4.4); cursor excluded from scrolling results (bug fix C 3.5.2).
- Observed in the follow-up inspection: selected region has eight resize handles; Start Capture sits below it; a help button sits near the lower-right of the overlay. Return starts capture. During capture, a result preview appears beside the region, Auto-Scroll appears near its lower edge, and separate Cancel and Done controls appear below. Clicking Cancel exits. The tool's app-only screenshot does not include the underlying page in the transparent region, so its blank appearance is not a CleanShot design choice.
- User-confirmed: Auto Scroll is offered initially and starts only if clicked. If the user starts scrolling manually, its button disappears and the capture stays manual-only for the rest of that session. A new capture offers the choice again.
- Unknown: active Auto-Scroll state and manual input after automation has already started, speed adjustment, maximum length, and reliable Escape behavior. Sending Escape while the separate controls window was selected did not dismiss the session, so Escape cancellation is not recorded as verified CleanShot behavior.
- Proposal (aligned with the user's requirement): one session. Select region, press Start. Manual scrolling works immediately. Offer Auto Scroll until the first manual scroll, then hide it for the remainder of the session. Auto Scroll starts only when explicitly clicked. Proposed behavior for the unverified automatic-first branch: allow pause/resume until physical manual scrolling stops automation and commits the remaining session to manual-only. Retain the stitched result across that transition. A live preview strip shows the stitched result. Done (Return) finishes, Cancel (Escape) discards. Show a non-blocking notice when the length cap is reached.

### Capture Text (OCR)

- Documented: "Simply select an area that contains the text and it will be copied to your clipboard"; on-device recognition; QR code reading; 30+ languages (F; QR added C 4.6).
- Documented: automatic language detection (C 4.8); separate shortcuts for OCR with and without line breaks (C 4.0.1); link detection with an option to disable it (C 4.2.2, C 4.3); a dedicated text recognition sound (C 3.8).
- Documented: API `/capture-text` accepts a `filepath` or an area (API).
- Unknown: the confirmation UI after recognition (HUD, notification, or sound only) and behavior when no text is found.
- Proposal: area selection identical to Capture Area, copy text, short HUD "Copied 214 characters" plus optional sound; "No text found" HUD otherwise. Settings: keep line breaks, recognition languages (auto default).

## 2. Annotate editor

General, documented:

- Single-letter tool shortcuts: "R for Rectangle, A for Arrow etc. (Hold the cursor on a tool to check the shortcut)" (C 2.6).
- Observed: the Settings shortcut list shows the tool letters V, R, E, L, A, T, P, H, C, K. The letter-to-tool assignment is recorded in the main agent's interaction spec.
- ⌘Z / ⌘⇧Z undo/redo (C 2.1); ⌘D duplicate object (C 4.5); copy/paste objects (C 4.4); ⌥-drag duplicates an object (C 3.4); Shift while moving locks the axis (C 4.7); Shift for perfect shapes (C 2.5).
- Space held moves (pans) the canvas (C 3.9.3); canvas zoom (C 4.3); Command+/Command- shortcuts referenced in a keyboard layout fix (C 4.3.1); lock canvas for easier drawing (C 3.5).
- Custom colors and a color picker that samples the screen and saves favorites (C 3.3.4, C 4.8, F). Option to disable shadow on objects (C 3.6).
- ⌘P print (C 3.8.1). Holding ⌥ when saving bypasses the "Save as" dialog (C 4.1). Holding ⌥ on the copy button copies without closing (C 4.8). "Save as" can change format and remembers the last location (C 4.0, C 3.6.1).
- "Drag me" button to drag the image into other apps (F). Annotate window is resizable and draggable from the bottom bar (C 3.9, C 4.5.1). "Dark and Light mode support" (F).

Per tool:

| Tool | Documented | Unknown |
|---|---|---|
| Arrow | 4 styles including curved (F; C 4.2). Letter A (C 2.6). Observed: style menu Standard, Fancy, Curved, Double; compact Color and Thickness popovers. | Thickness steps, head-size scaling, whether Shift snaps angles. |
| Rectangle | Rectangle and Filled rectangle are separate tools (F). Letter R (C 2.6). Shift for perfect square (C 2.5). Observed: pressing R and dragging 500×100 draws exactly that shape; R stays selected after mouse-up; with V, clicking the shape's edge selects it and shows four circular blue corner handles. | Corner radius option, stroke widths. |
| Ellipse | Tool exists (F). Shift for circle (C 2.5, generic "perfect shapes"). | Letter shortcut. |
| Line | Tool exists (F). | Letter shortcut, Shift angle snapping, dashed option. |
| Text | 7 predefined styles (F; 6 in C 3.5), easier resizing (C 4.6), emoji support (C 3.3.1). Observed styles: Standard, Rounded, Outlined, Mono, Box, Mono Box, Rounded Box. Follow-up confirmed click-to-insert, multiline Return, Command-Return finish, double-click re-edit, Escape retaining edits. | Font-size versus text-box resize handle semantics; IME behavior. |
| Redact | See section 3. | |
| Spotlight | "Emphasise what's important" (F); smoothed rounded corners (C 4.3); performance improvements (C 3.9.3). Observed: rectangle/rounded rectangle/ellipse choices, slider range 5–90 initially showing 45, and a clear union of overlapping openings. | Factory default; exact corner-radius rule and per-object/global strength scope. |
| Counter | Step marks for tutorials (F); style and starting number configurable (C 3.4); starting number may be 0 (C 3.7.1); counters always stay on top of other objects (C 4.7.5). Observed: styles numeric, A-B letters, Roman, lowercase; Starting number field showing 1; sizes 11, 14, 20, 24, 31, 45 pt. | Renumbering after deletion. |
| Crop | Aspect ratio options including 5:4 and 9:16 (C 3.6.1, C 4.8.1); snapping to edges (F, C 3.9); expanding the canvas detects background color (C 4.5). Observed: dedicated crop mode with Crop/Cancel, Freeform, W/H, image size; Snap to edges with Command to disable snapping; Escape returns to the editor. | Return commit and whether crop stays editable after commit. |
| Save / Copy | Save as button (C 3.4.6), ⌥ bypasses Save as (C 4.1), ⌥ copy keeps editor open (C 4.8). Observed: the Save button's help text reads "Choose export location and exit" with ⌘S; Copy image is ⇧⌘C. | Default save folder when the editor was opened from an overlay. |
| Zoom | Canvas zoom (C 4.3); Space-drag panning (C 3.9.3); Command+/- (C 4.3.1). Observed bottom menu: Zoom In, Zoom Out, Fit Canvas, 50%, 100%, 200%. | Fit/100% shortcuts, pinch support, continuous zoom range. |

Proposal: reuse CleanShot's observed tool letters (V, R, E, L, A, T, P, H, C, K) as the interaction spec maps them, and show each in the tool tooltip. Zoom proposal: ⌘+/⌘- zoom, pinch to zoom, Space-drag to pan; fit and actual-size shortcuts are for the interaction spec to decide.

## 3. Redact: pixelate, blur, and black out

Documented:

- Tools listed: "Pixelate — With applied randomization for better security" and "Blur — With secure and smooth options" (F). The screenshots page describes redaction as "blur, pixelate, or solid redaction" (S).
- History: Pixelate intensity preference (C 1.0.2); pixelate intensity slider moved into the Annotate window (C 3.1); "Adjustable Pixelate/Highlight intensity using keyboard shortcuts" (C 3.1.1, keys not named); randomization added "to prevent depixelization" (C 3.5); Gaussian blur option added to the Pixelate tool (C 4.1); "Black Out redaction tool style" and "Improved security of Pixelate and Secure Blur" (C 4.2); improved interactions with Pixelate objects (C 4.3).

Observed:

- Redact style menu: Pixelate, Blur (secure), Blur (smooth), Black Out.
- Strength initially showed 10. In the follow-up inspection, setting the slider below and above its range clamped to 3 and 30; it was restored to 10 afterward. This establishes the available range in this session, not a factory default.

Unknown:

- Factory default, which keys change strength, whether strength is per object or a tool default, what CleanShot's "secure" blur does differently from "smooth", and how its randomization works. The tested right-bracket key did not change the displayed value. CleanShot's security claims do not expose an algorithm or guarantee.

Proposal for Shotty:

- One Redact tool with three styles: Pixelate (default), Blur, Solid. A strength slider in a compact tool popover.
- Help text distinguishes the styles by purpose only. Pixelate and Blur obscure content visually. Solid fully conceals it. No warnings elsewhere.
- Pixelate: nearest-neighbor blocks computed from the original pixels, block size scaled to image resolution. Blur: Gaussian, strength mapped to radius. Solid: opaque fill in the current color.
- Evaluate a stronger variant (randomized smoothing, for example per-block noise before or after blurring) as a later experiment. Do not label any style "Secure" or claim unrecoverability unless that has been assessed.
- Effects stay non-destructive while editing and are rendered from original pixels on export, so strength changes never compound.

## 4. Quick Access Overlay (thumbnails)

Documented:

- A small pop-up appears in a screen corner after capture, for viewing, annotating, or sharing; "Instantly save, copy or drag & drop the files to other apps" (F).
- Features: display file info, restore recently closed overlay, adjust position on the screen, adjust overlay size, configurable auto-close, multi-display support, swipe gestures, drag & drop to any app, quick actions, temporarily hide overlays (F).
- The official image shows a thumbnail with centered "Copy" and "Save" pill buttons and small circular corner buttons (pin top-left, annotate bottom-left, upload bottom-right) (QA-IMG). The close button position changed in C 4.1; its current location is Unknown from docs.
- Keyboard shortcuts on the overlay: ⌘C copy, ⌘S save, ⌘W close, ⌘U upload, ⌘E open annotation tool (C 4.1). Space opens Quick Look (C 1.1).
- Context menu (right-click): Open Annotation Tool, Pin to the Screen, Rotate Left, Upload to Cloud, Quick Look, Show in Finder, Open With, Open in Mail, Temporarily Hide, Close (QA-IMG); also Save as, Move to trash, Close All, Save All, Scale Retina to 1x, Flip Horizontally, share menu (C 4.0.1, 4.1, 3.1, 4.2, 4.3, 3.6.1).
- Gestures: two-finger swipe deletes/dismisses a screenshot (C 2.4); slide down to temporarily hide (C 3.4); a fix for swipe actions with natural scrolling disabled (C 3.6.2).
- Multiple overlays: global shortcuts to Save all / Close all overlays (C 4.2.2); improved interactions when closing multiple files one by one (C 4.7.5); subtle indicator for the newest screenshot (C 4.7); subtle appearance animation (C 4.7).
- Holding ⌥ on copy copies without closing (C 4.8). A trash button appears when auto-save is enabled in After Capture (C 4.5). Restore recently closed file via menu and shortcut (C 3.4.1, 3.5.1).
- "Show on active display" option (C 1.1); drag & drop improvements with multiple displays (C 3.3.2); larger size option (C 3.3.4); auto-close timer with shorter intervals and 5 and 10 minute options (C 3.1, C 3.1.1, C 3.9.1).
- Clicking the thumbnail to open Annotate: Unknown from docs (⌘E and the annotate button are documented).

Observed in the follow-up: two user-created captures exposed separate native thumbnail panels. One screenshot shows a darkened action surface with centered Copy/Save pills, close top-left, pin top-right, annotate bottom-left, and upload bottom-right. AX labels Copy and Save, but not the four corner buttons. The coordinate attempts did not reliably open an editor or a context menu, so those actions are not claimed as verified. App-only screenshots show one selected panel at a time; that is not evidence that older captures were replaced.

User-confirmed: existing thumbnails move between displays on pointer movement alone. Markus tested this and confirmed it in the follow-up. No click or new capture is required. Relocating only when another capture completes is insufficient.

Unknown: stack direction and spacing, maximum visible count, exact available corners, exact hover trigger, auto-close pause on hover, swipe direction for dismiss, and exact relocation latency/interaction locking.

Proposal: newest thumbnail enters at the configured position and pushes older ones along the edge; Save and Close remain discoverable without hover, and clicking the image opens the editor. Drag exports the file. Local keyboard actions apply to an intentionally focused card, not whichever card happens to be under the pointer. Confirm swipe direction against the live app before finalizing it. Respect Reduce Motion.

## 5. Settings

Documented from official settings screenshots (SET) and changelog:

- Sidebar sections: General, Shortcuts, Quick Access, Wallpaper, Screenshots, Screen Recording, Annotate, Cloud, Advanced, About. 5.0 introduced "Brand-new app settings" (C 5.0).
- General > App: Launch at login, Show menu bar icon. General > Capture: Hide desktop icons while capturing. Sounds: Play sounds, Shutter sound picker. Export: Export location with "Choose…" button; described as "the default save location used when saving from the Quick Access Overlay, After Capture, and other Save actions across the app."
- General > After Capture: a matrix with Screenshot and Recording columns and rows Show Quick Access Overlay, Copy file to clipboard, Save, Upload to Cloud & copy link, Open Annotate tool, Pin to the screen, Open Video Editor. Multiple defaults can be combined (C 2.4).
- Shortcuts: searchable list ("Search shortcuts") grouped by General and Screenshots, each with a "Record shortcut" field. Entries include All-In-One, Toggle Desktop Icons, Open Capture History, Restore Last Capture, Capture Area, Capture Previous Area, Capture Fullscreen, Capture Window, Self-Timer, and the Capture Area & … family. F-keys are supported as shortcuts (C 3.1); more keyboard layouts supported (C 4.2.2).
- A Pin action shortcut can be set for the annotation tool (C 4.3), meaning some editor actions have configurable shortcuts.
- File naming: custom name templates including App Name or Window Title, auto-increment starting number, "Ask for name after every capture" with a Discard button (C 3.3.4, C 4.0, C 4.0.1, C 4.7, C 4.8.9).
- Screenshot options: convert to sRGB (C 4.8), window shadow (C 3.1), "Add 1px border" (C 3.9.1).
- Dock visibility setting: Unknown from docs. Appearance override (System/Light/Dark): Unknown; only "Dark and Light mode support" is documented (F).
- Quick Access position options: "Adjust position on the screen" is documented (F); the specific choices are Unknown.

Proposal: six sections as defined in the interaction spec: General, Capture, Thumbnails, Editor, Shortcuts, Permissions. OCR options belong under Capture. Tool style controls stay in the editor rather than becoming extra settings pages.

## 6. Behaviors official docs do not resolve

For further live capture checks, provide the entire procedure before activation, including an explicit exit step and time limit. Do not rely on Markus reading new chat messages while the capture surface is frozen. Prefer short user-executed checks followed by a report after Escape/completion when the tool cannot reliably observe the correct display. Do not ask him to leave a frozen session active indefinitely awaiting invisible instructions.

Remaining unverified reference details are listed below. The [build contract](build-readiness.md) supplies explicit Shotty defaults, so these are comparison opportunities rather than unanswered product decisions. Ask Markus only for a short check that agent-operated native testing cannot perform:

1. Area selection modifiers during dragging (Shift, Option, Space), arrow-key nudging, exact measurement label placement/initial values, and optional adjustment mode. Normal release-to-capture, live measurement feedback, and Escape exit are user-confirmed.
2. Overlapping-window cycling, second-Space return to area, and window modifiers. Space entry into window mode, full blue overlay, centered camera symbol, and Escape exit are user-confirmed.
3. Scrolling Auto-Scroll active/paused states, manual input after automation starts, speed control, and length limit. Selection, Start, Return, adjacent preview, and Cancel/Done are observed. Manual-first hiding of Auto Scroll for the remaining session is user-confirmed.
4. OCR confirmation UI and empty-result behavior.
5. Zoom shortcuts (fit, 100%) and pinch behavior. The menu now directly confirms Zoom In, Zoom Out, Fit Canvas, 50%, 100%, 200%.
6. Redact factory default, keyboard control, per-object/default scope, and what distinguishes secure from smooth blur. Slider range 3–30 is observed.
7. Counter renumbering after deletion. Spotlight's shapes, 5–90 range, and clear union of overlapping openings are now observed.
8. Quick Access stacking order, spacing, max count, exact hover trigger, image-click behavior, swipe direction, and auto-close pause on hover. The expanded surface and corner-action positions are now observed.
9. Quick Access corner options and relocation latency/interaction locking. Existing-stack relocation on pointer movement alone is user-confirmed and required.
10. Dock visibility and appearance override settings, if they exist.

### Follow-up editor observations

Text insertion was successfully retried on the disposable synthetic image. Click creates an empty native text entry with handles; Return adds a line and tool letters type normally; Command-Return finishes. Double-click reopens the text. Adding text and pressing Escape retains that addition, rather than reverting it. Shotty's revised text behavior follows this result.

Spotlight offers pictorial choices for a rectangle, rounded rectangle, and ellipse. Its slider clamps to 5–90 and was restored to its prior value of 45. Two rounded openings visibly merge without an extra dim band in their overlap. Dragging inside the selected opening moves it; the tool remains Spotlight. Some draws first deselected the existing object, so the exact event sequencing is not used as a Shotty requirement.

The zoom disclosure menu offers Zoom In, Zoom Out, Fit Canvas, 50%, 100%, 200%. Escape exits crop mode and returns to the editor. Closing the unsaved test image offers Save, Don't Save, Cancel; only the disposable annotations were discarded. Redaction style and strength were restored to Pixelate and 10 after comparison. No user image was overwritten.
