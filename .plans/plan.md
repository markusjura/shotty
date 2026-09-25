# Shotty implementation plan

Status: revised product and implementation plan, 25 September 2026. The native product is implemented and committed as `96ca505`; native layout fixes are verified, but full release acceptance is still in progress, so it is not yet a verified replacement. Measured results and the pending acceptance checklist are tracked in [native verification](native-verification.md). A free Apple Development signing identity was created on studio during the readiness pass; signed-build validation is tracked in [signing-verification.md](signing-verification.md). The design preview is an interaction mockup, not a running SwiftUI app. The [build contract](build-readiness.md) records final decisions and takes precedence over earlier proposals. The detailed [interaction specification](interaction-spec.md) defines the refined UX, grounded in the [CleanShot feature audit](cleanshot-reference.md), and takes precedence over the preview.

## Current implementation scope

Markus narrowed this effort on 25 September 2026 to studio only. Complete implementation and native verification here; m1 synchronization, installation, performance testing, and fleet acceptance move to a separate PR after implementation. References to both machines below remain the eventual fleet requirements and do not block this implementation milestone.

## Product decision

Build a small, local macOS screenshot utility for Markus. SwiftUI owns settings and most controls; AppKit owns application lifecycle, capture overlays, floating panels, keyboard routing, and the editor canvas. ScreenCaptureKit captures pixels, Vision recognizes text, and Core Graphics renders the final image. Use native windows, SF Symbols, system typography, standard menus, and platform focus behavior. Platform facts and source links are collected in [platform-research.md](platform-research.md).

Shotty launches into the menu bar without a Dock icon or a main window. Its core loop is shortcut → capture → persistent thumbnail → annotate → copy or save. Captures never upload anywhere. No account, subscription, cloud service, video recording, GIF recording, background decoration, AI integration, or permanent screenshot library is in scope.

All five capture modes and all requested editor tools belong in the first complete replacement. Milestones below are implementation order, not a reduction of the requested release scope. A feature is complete only when its interaction, settings, shortcuts, permission recovery, accessibility, and failure handling work together.

## What was inspected

CleanShot X was inspected through Computer Use on Markus's Mac. The editor, General, Quick Access, Shortcuts, and Screenshots settings were read. No CleanShot preferences were changed and no existing image was saved or modified.

The follow-up live audit also verified scrolling selection/Start/preview/Cancel/Done, native multiline text and commit behavior, Spotlight shapes and overlap, redaction/Spotlight slider ranges, crop cancellation, and zoom presets. Temporary tool-style/strength changes on a synthetic image were restored and the test edits discarded. Detailed observations and remaining gaps are recorded in [cleanshot-reference.md](cleanshot-reference.md).

| Observed configuration or UI | Shotty proposal |
| --- | --- |
| Only Show Quick Access Overlay is enabled after screenshots | Show thumbnails by default; automatic copy and save are independent opt-ins |
| Export location is `~/Downloads` | Downloads is the initial destination, changeable with a native folder picker |
| Quick Access is on the left; Markus confirms that existing thumbnails follow pointer movement between displays | Left-center stack follows the pointer's display, including existing captures; it does not wait for a click or another capture |
| Auto-close is disabled | Thumbnails remain until individually dismissed or successfully handled according to settings |
| Quick Access save uses the export location; Option chooses another destination | Save inside each thumbnail; Option-Save opens Save As |
| Compact editor toolbar, contextual style controls, prominent Save As, bottom copy and zoom controls | One integrated top toolbar with inline tool options; zoom and Copy in a bottom utility bar; no wrapping or second top row |
| Area `⇧⌘4`, fullscreen `⇧⌘3`, scrolling `⇧⌘5` | Offer this familiar mapping during migration, with conflict guidance before registering it |
| Editor tools use V, R, E, L, A, T, P, H, C, K | Retain these defaults, including P for redact and K for crop |
| PNG, native Retina resolution, cursor excluded, frozen selection enabled | Retain these capture defaults |

With Markus creating two test captures, Computer Use exposed two separate thumbnail panels and an expanded action surface: centered Copy and Save, close at top-left, pin at top-right, annotate at bottom-left, and upload at bottom-right. Markus confirmed relocation on pointer movement alone. The required stack behavior comes from Markus's explicit instructions and the inspected Quick Access settings. Screenshot content is not copied into the design or repository.

## Visual direction

Use flat neutral chrome with standard macOS blue for control accents. Use native material only where it helps separate floating UI from the desktop. Keep editor content neutral and opaque so screenshot colors remain accurate. Native traffic lights, standard title bars, modest corner radii, and compact controls should make Shotty feel like a utility rather than a dashboard.

Appearance is System, Light, or Dark, with System selected initially. Appearance affects the app chrome, never captured pixels or annotation colors. Respect Increase Contrast, Reduce Transparency, Reduce Motion, VoiceOver, and Full Keyboard Access. Use accessible labels on every icon and include shortcuts in tooltips and menus. The preview uses approximate web equivalents; the implementation uses actual AppKit/SwiftUI controls and SF Symbols.

Three surfaces carry the product:

1. **Editor:** screenshot dominates the window; tools, traffic lights, compact active-tool options, and Save/Done share one top row. Tool options use popovers; narrow windows use overflow rather than wrapping. Zoom and Copy live in the bottom bar; undo/redo retain their standard shortcuts and Edit menu entries.
2. **Thumbnail stack:** small independent cards, image preview plus visible save and dismiss actions. Clicking the image opens its editor. Capturing again adds a card without replacing or closing earlier cards.
3. **Settings:** standard sidebar with General, Capture, Thumbnails, Editor, Shortcuts, and Permissions. Use flat native forms with direct labels and local explanations only where a choice has consequences.

Open the [interactive design preview](design/standalone-shotty-design.html) to explore these surfaces. The editable fragment is [shotty-design.html](design/shotty-design.html). The preview demonstrates selected interactions; it does not implement native capture, file writes, clipboard access, or every proposed setting. Layout and the main simulated flows were checked in the integrated browser, including light/dark appearance and compact widths. Actual native performance and OS integration remain implementation acceptance work.

The menu bar lists all five capture commands with their active shortcuts, then Show Thumbnails, Settings, and Quit. Use an AppKit `NSStatusItem` under an app delegate, with SwiftUI-hosted settings and `.accessory`/`.regular` activation policy. This gives explicit lifecycle control when hiding the status item or Dock icon. Keep settings reachable even when both are disabled: reopening Shotty from Finder/Spotlight opens Settings. Explain that recovery path beside the visibility controls.

## Capture behavior

Every capture has a stable ID and one state progression: requested → selecting/capturing → processing → ready, cancelled, or failed. Allow only one selection or scrolling session at a time. A shortcut pressed during a selection changes the selected capture mode where safe; otherwise it cancels the unfinished selection before starting another. Never accumulate hidden capture requests.

The app snapshots output preferences and target display for each capture. Successful captures enter a serial completion queue for automatic clipboard output, in capture-request order; cancelled or failed captures are skipped. File encoding and OCR run off the main thread. A failed save does not block the thumbnail or discard the image. An automatic clipboard write must not overwrite unrelated clipboard content copied while slow processing was underway: check the pasteboard change count, then leave a Copy action and explain the skipped automatic copy.

### Fullscreen

- One invocation captures the display under the pointer by default. Settings can choose the main display or all displays. All displays produces one image per display, not an unexpectedly enormous joined desktop.
- Capture at native pixel resolution by default. Hide Shotty's selection UI and thumbnail panels from the capture and exclude the cursor unless configured otherwise.
- Retain the source color profile by default. Provide an explicit sRGB export option. Convert HDR captures to SDR intentionally and test bright/high-contrast content; never simply reinterpret the bytes.
- If a display disconnects or capture permission changes, fail with a retry action instead of capturing a different display silently.

### Window

- Hover covers the entire selected window with a translucent system-blue overlay and centers a camera symbol horizontally and vertically within its bounds, matching Markus's CleanShot test. Keep the target recognizable through the tint; an outline alone is insufficient. Click captures, Escape cancels. Space enters window selection from area mode; support switching back with Space as a Shotty requirement. Offer keyboard navigation among eligible windows and Return to capture. Do not add permanent app-name or metadata badges to the normal pointer flow.
- ScreenCaptureKit provides isolated window pixels so overlapping windows are not baked into the result. Exclude Shotty's own overlays. Invisible, minimized, protected, or otherwise unavailable windows are not presented as reliably capturable targets.
- Include window shadow by default, with a setting and Option modifier to invert it for one capture. Preserve transparency outside rounded corners and shadows in PNG; JPEG export composites onto an explicit background.
- A window that closes between hover and click produces a recoverable selection message, not an empty image.

### Area

- Freeze the visible desktop at invocation by default. Show a compact measurement readout before dragging and update selected width/height immediately during dragging. Use the selection pointer with optional crosshair guides/magnifier. Releasing the left mouse button captures immediately, with no confirmation step. Markus confirmed this flow and Escape cancellation in CleanShot. Space before dragging enters window selection. Space while dragging moves the selected region, Shift constrains proportions, and Option draws from the center; these compound gestures are Shotty decisions, with exact CleanShot parity still unverified. Optional Adjust before capture retains handles and numeric/arrow-key adjustment after drawing; Return confirms that mode. Keyboard-only selection uses the adjustment path.
- Transform AppKit desktop points, per-display backing scales, and image pixel coordinates explicitly. Do not assume one display, a shared scale, or an origin at the top-left of the main screen.
- Support selection across adjacent displays. Compose the chosen region in desktop coordinates at the highest participating backing scale, resampling lower-density displays once. Empty desktop gaps are transparent. The result's dimensions are shown before capture; a 1× export option is available. Captures of separate displays are not claimed to be atomic in time.
- Selection panels, magnifiers, and thumbnails must not appear in the output. Restore them after successful capture or cancellation without changing the user's frontmost app.

### Freeze screen

Freeze screen is a required feature, enabled by default and configurable under Capture. For Area and Text capture, acquire the desktop pixels before presenting or activating selection panels, then display those immutable images throughout selection. This preserves hover states, animation frames, and transient content. Selection dimensions and the optional magnifier read from that same snapshot. Crop/export and OCR use those exact pixels; do not recapture the live screen on mouse-up. Underlying applications keep running; Shotty freezes the displayed capture surface, not their processes.

Keep one snapshot per participating display, with explicit coordinate/backing-scale transforms. Exclude Shotty's own panels before acquisition and preserve the source application's hover/focus state as far as the capture APIs allow. Separate displays are not guaranteed to be sampled at an identical instant. Escape cancels without output and releases snapshot resources; completion restores the live desktop and focus. Permission failure or a display-layout change during selection must produce a controlled cancellation/retry rather than silently using different pixels.

With Freeze screen off, selection overlays leave the desktop live and acquire output pixels at confirmation after excluding selection chrome. Fullscreen already takes an immediate still and needs no persistent freeze overlay. Scrolling acquisition must remain live; the preference must never freeze frames needed for stitching. Window capture needs a prototype check to reconcile invocation-time frozen content with isolated, potentially occluded window pixels: a frozen preview followed by a later live export is unacceptable. Resolve this before signing off window capture; do not claim that a desktop crop provides isolated-window semantics.

### Scrolling capture

Scrolling capture is a universal, app-independent visible session, not a browser integration or a one-shot screenshot with optimistic stitching. Capture arbitrary screen pixels without a browser extension, DOM access, or a supported-app allowlist. Ship vertical and horizontal capture along one primary axis, with a per-session choice between manual scrolling and explicitly starting Auto Scroll. The first manual scroll hides Auto Scroll for the rest of that capture; only a new capture restores the choice. Infer the axis from initial movement or let the user select it before Auto Scroll. Two-dimensional panorama stitching is not implied; an unsupported axis change pauses with a clear explanation.

1. Select a scrollable region and identify the target window. Show the capture boundary, compact Start control, and a live preview outside that boundary.
2. After selection and Start, show Auto Scroll but do not scroll automatically. If the user scrolls manually first, hide Auto Scroll and commit this capture to manual-only until Done or Cancel. Do not expose another menu command, shortcut, or setting that bypasses this session rule. A fresh capture resets the choice. If Auto Scroll is clicked first, it starts automation. Pause/resume remains available on that automatic branch. Shotty behavior, with exact CleanShot parity still unverified: subsequent manual input stops automation, hides Auto Scroll, and preserves the accumulated result in manual-only mode. Request Accessibility access when Auto Scroll is first used, then advance the selected scroll region conservatively. If permission setup interrupts capture, preserve the accepted preview and explain how to resume or restart. Do not scroll a window that has lost focus or moved away from the selection. User wheel/trackpad input stops automatic event injection so the app does not fight the user. Distinguish physical input from Shotty-injected events; automatic events must not trigger the manual-only transition.
3. Keep overlapping frames, wait for content to settle, estimate translation from image content, reject duplicate frames, and track stitching confidence. Use small previews for alignment and full-resolution tiles for the final image.
4. Detect stationary headers/footers where confidence is sufficient and include them only at the appropriate edge. Allow the user to adjust the capture boundary to exclude fixed chrome. Do not invent missing rows or conceal uncertain seams.
5. Pause visibly on ambiguous overlap, large jumps, animated content, reverse movement that cannot be reconciled, display changes, or focus loss. Offer Continue from last accepted frame, Finish current result, Retry, or Cancel as appropriate.
6. Return finishes; Escape cancels; Space pauses/resumes automation only after Auto Scroll has been explicitly started and while the session controls have focus; it never starts automation in an undecided or manual-only session. Automatic mode stops on repeated unchanged content, with an explicit Finish button always available. Offer an initial finite height/time limit so infinite feeds cannot run indefinitely.
7. Show the stitched result before handing it to the ordinary output pipeline. An incomplete result is labeled and requires the user to choose Keep partial capture. Cancellation creates no completed thumbnail and performs no automatic copy/save.

Universal app-independent capture is the product requirement; perfect stitching of arbitrary changing content is not something an implementation can guarantee. Browsers, nested scroll regions, PDFs, native lists, Electron apps, and virtualized chat threads all belong in the acceptance matrix. Test Helium/Chromium, Safari, Slack, a long PDF, and a native list/settings view as representative cases, not as an allowlist. The engine must work from screen content in unfamiliar apps as well. Accessibility is not a guarantee that every app exposes a controllable scroll region: prefer generic posted scroll events targeted within the selected region and use accessibility metadata only as an optional aid. Manual scrolling remains available when automatic control is unavailable.

Before building the rest of the product around this engine, demonstrate correct output for a normal long page, a sticky-header page, a nested scroll panel, and a virtualized chat thread. If an app cannot produce overlapping stable content, the outcome is a specific documented limitation with a visible recovery path, not a low-confidence image presented as complete.

### Capture text

- Reuse area selection, then run Vision OCR on-device. Language detection is automatic by default, with a configurable ordered list of supported recognition languages.
- Default behavior is copy recognized text and show a brief confirmation with an optional Review action. Review opens editable/selectable text, Copy, and Close. Settings can open Review automatically. Text capture has its own output settings; it must not unexpectedly write image files because screenshot auto-save is enabled.
- Preserve line breaks by default. Allow joining wrapped lines, with a preview and a user-visible toggle. Do not claim perfect paragraph, table, or reading-order reconstruction.
- Empty recognition leaves the clipboard untouched and offers Reselect. Low-confidence regions are surfaced in the result rather than silently rewritten. Recognition can be cancelled, and late results from cancelled work are ignored.
- Optional text saving writes UTF-8 `.txt` to the selected destination through the same failure-aware save flow. OCR content is never logged or transmitted.

## Thumbnail stack contract

- Each capture owns one card and one underlying document. New cards are added nearest the chosen anchor; older cards keep their relative order. Default size is about 220 points wide, preserving preview aspect ratio within a bounded height.
- Default placement is left-center on the active display. Settings provide all four corners plus left/right center, small/medium/large size, and display policy: Follow active display, Main display, or a chosen connected display. Follow active display moves the existing stack as pointer/click activity changes displays, without requiring a new capture. Preserve capture IDs, order, edits, and pending outputs. Resolve the destination when presenting a completed capture; the capture source display remains independent.
- Markus confirmed that pointer movement alone relocates CleanShot's stack. Use the display containing the pointer; no click or new capture is required. Keep the last valid target while the pointer has no connected display. Filter only boundary jitter, with response latency measured during native comparison. Do not move a card while it is being pressed, dragged, keyboard-operated, or showing a context menu; resolve the current pointer display after the interaction ends. These interaction locks are Shotty design decisions.
- Keep display following lightweight. Prototype `NSEvent.mouseLocation` sampling only while a stack is visible, with reduced polling when stationary, and AppKit screen/Space notifications. No global click or keyboard monitor is needed for this rule. Verify permissions on a fresh account. Following must work with Accessibility denied; Auto Scroll retains its separate permission requirement. Suspend monitoring when the stack is hidden or empty.
- Respect visible screen bounds, the menu bar, Dock, display notches, display changes, Spaces, and fullscreen applications. If a chosen monitor disappears, move to the main display and remember the preference for reconnection.
- The stack does not steal keyboard focus when a capture arrives. Clicking a preview opens or raises that capture's editor. Save and dismiss are separate hit targets inside the card; both remain discoverable without hover.
- Right-click exposes only Open Editor, Copy Image, Save to Folder, Save As…, and Dismiss, grouped in that order with shortcuts where assigned. Use the same command handlers as card buttons and the editor. Dismiss never means delete an exported file. No pin, upload, share, rotate, flip, Open With, mail, or Quick Look commands are included. Any later menu addition must serve an already accepted feature or be agreed with Markus first.
- Save writes to the configured folder. Option-Save opens Save As. Show in-progress, success, and failure state on that card. Default is dismiss after successful save; allow keeping the card. Failed or cancelled saves never dismiss it.
- Dismiss affects only that card and never deletes an exported file. Dismissing an unexported capture offers a short Undo action; after that, its private temporary data is eligible for cleanup when no editor holds it. No permanent capture history is added.
- Default auto-close is Never. Optional timeout actions are Dismiss or Save then dismiss, with the data consequence described beside the setting. Pause timers during hover, keyboard interaction, a related editor session, or save errors.
- When the stack exceeds screen height, show a compact “N more” control that opens the remaining active cards. Do not overlap cards offscreen, discard the oldest capture, or allocate full-resolution images for hidden previews. This is overflow for the current queue, not a searchable history product.
- Drag a thumbnail to Finder or an app using a file promise. Generate the flattened export once the destination accepts the drag. Default close-after-drag occurs only after a successful operation, with Option keeping the card.
- Provide Show/Hide Thumbnails, Open Latest Capture, Save All, and Dismiss All as assignable commands. Bulk dismiss protects unexported work with a clear count and confirmation; save-all reports failures per card and keeps those cards.

## Editor contract

One document can have one editor window. Opening its thumbnail again raises that window. Different captures may have separate windows. The original raster is immutable; annotation objects, crop, and document metadata stay editable until the session is closed. Undo/redo covers meaningful user actions, including a whole drag or text edit as one action rather than every pointer movement.

| Tool | Default key | Complete interaction and settings |
| --- | --- | --- |
| Select/move | V | Hit-testing, drag, resize handles, multi-selection, delete, duplicate, keyboard nudging, z-order |
| Arrow | A | Editable endpoints; stroke color/width; arrowhead size and direction; Shift angle snapping |
| Rectangle | R | Editable bounds; stroke and optional fill; width; corner radius; Shift square |
| Ellipse | E | Editable bounds; stroke and optional fill; width; Shift circle |
| Line | L | Editable endpoints; color and width; Shift angle snapping |
| Text | T | Native text editing, multiline content, system font picker, size, weight, alignment, color, optional contrasting background |
| Redact | P | Drag-to-apply Pixelate by default; Blur and Solid alternatives; compact style preview menu and live strength slider; movable/resizable regions; effects render from image pixels consistently at every zoom and export resolution |
| Spotlight | H | Rectangular, rounded rectangular, or elliptical opening; outside dim amount; multiple openings combine; editable bounds |
| Counter | C | Click to place sequential numbered markers; color/size; editable start number; stable numbering after deletion with an explicit Renumber command |
| Crop | K | Movable bounds, pixel dimensions, aspect lock, keyboard adjustment, Return applies, Escape cancels; undo restores the previous view |

Compact options within the same top toolbar show only relevant controls and remember defaults per tool. Color, width, and style open visual popovers; they never add another permanent row. Changing settings affects new objects; selected objects are changed by their local controls. Stroke width and text size are stored in image coordinates, independent of zoom. Offer a small useful annotation palette and a native color picker. Keep annotation colors independent of the app appearance. Every geometric tool uses live drag-to-draw, meaningful handle editing, correct hit-testing, and gesture-grouped undo as specified in [interaction-spec.md](interaction-spec.md).

Standard edit commands include undo `⌘Z`, redo `⇧⌘Z`, duplicate `⌘D`, delete, select all, nudge by one image pixel, and Shift-nudge by ten. Tool keys are inactive during text entry, shortcut recording, and modal dialogs. Escape first cancels the current interaction or exits text entry; it must not immediately close the whole document.

Export commands:

- `⇧⌘C` copies the flattened screenshot. `⌘C` retains normal selected-text/object semantics. The visible Copy button always means Copy Image, with an explicit tooltip.
- `⌘S` saves to the configured folder on first save and updates that document's same exported file on subsequent saves. `⇧⌘S` opens Save As. A card saved before editing becomes that document's save destination. Use atomic replacement, and detect external modification before overwriting.
- Copy and Save stay in the editor by default, with independent Close after Copy / Close after Save settings. Mark the document's last exported and last copied revisions separately so status is accurate.
- Done commits the edited document back to its thumbnail and closes the editor; it does not silently copy or save. Closing with a retained thumbnail keeps the session without a redundant save prompt. If no thumbnail remains and there is unexported work, offer Save / Keep as thumbnail / Discard / Cancel. Done recreates a dismissed thumbnail so work always has a reachable home.
- Export PNG by default. JPEG is optional with quality and transparency-background controls. Avoid extra formats until needed.
- Flatten crop and all annotations into exported pixels. Never embed the source image, editable objects, OCR text, or hidden layers in a redacted export. Exclude cropped-away source pixels from the output. Internal editable source remains private session data until cleanup; communicate that distinction in redaction help.

Pixelate and Blur are visual obscuring treatments; Solid fully replaces the selected pixels. Flattening prevents hidden-layer recovery but does not guarantee obscured text cannot be inferred. Do not label our own blur “Secure” without assessing it. Redaction quality includes a stable pixel grid, correct edge padding/clipping, no seams or stale tiles, and identical preview/export treatment; the detailed specification covers these requirements.

If an original image was automatically copied or saved before redaction, the editor shows that export state. Applying redaction does not recall an earlier clipboard value, another application's paste, or a previously shared file. Save updates the associated local output; Copy explicitly replaces the current clipboard. Keep this visible when relevant instead of implying that editing retroactively protects earlier exports.

Zoom supports a fit-to-window default, actual pixels, `⌘+`, `⌘−`, `⌘0` for fit, `⌘1` for actual size, pinch-to-zoom anchored at the pointer, and Space-drag pan outside text editing. Display output pixel dimensions and zoom without clutter. Preserve the viewport when changing tools. Cap zoom sensibly and keep handles a consistent screen size.

## Settings and keyboard commands

Use a SwiftUI `Settings` scene with a native `NavigationSplitView`/sidebar `List` and a flat `Form` using the macOS columns style. Organize sections with headings, spacing, and a few separators, without nested card backgrounds or per-row boxes. Use native checkbox `Toggle`, `Picker`, `Slider`, `Stepper`, `ColorPicker`, and system dialogs as appropriate. Keep standard control metrics and keyboard/accessibility behavior. Native titlebar and sidebar materials come from the system; the web prototype is not a control-skin specification.

Use semantic system backgrounds and text colors with standard macOS blue as the app accent. SwiftUI/AppKit controls own the rendering of selection, focus rings, disabled states, and light/dark/high-contrast variants. Do not draw black switches or replace standard controls to match the browser preview. The detailed visual contract and native accessibility checks are in [interaction-spec.md](interaction-spec.md#native-visual-language).

| Settings pane | Controls and proposed defaults |
| --- | --- |
| General | Appearance System/Light/Dark (System); menu bar on; Dock off; launch at login off until explicitly enabled; sound off |
| Capture | Independent Show thumbnail on / Copy image off / Save image off / Open editor off; destination Downloads; PNG; preserve native resolution/profile; sRGB optional; cursor off; freeze selection on; window shadow on; fullscreen target pointer display |
| Capture → Text | Copy text on; brief confirmation with Review; open Review automatically off; save text off; preserve line breaks on; automatic language detection; supported language overrides |
| Capture → Scrolling | Explicit Auto Scroll before manual input; first manual scroll locks the session to manual-only; vertical/horizontal primary axis; scroll pace; initial limit of 30,000 output pixels along the scrolling axis or 120 seconds, adjustable within tested bounds; preview always visible |
| Thumbnails | Left-center; Follow active display moves the existing stack with pointer/click activity; medium size; auto-close Never; dismiss after successful save on; close after successful drag on; overflow opens remaining items |
| Editor | Tool defaults; default opening tool Select; copy/save keep window open; fit image on open; PNG/JPEG export options |
| Shortcuts | Capture, thumbnail actions, editor tools, and editor commands; record/change/clear; conflict feedback; restore a single binding or defaults for a group |
| Permissions | Screen Recording status and recovery; Accessibility status and purpose for automatic scrolling; destination-folder status; login-item status when applicable |

If all screenshot output actions are disabled, explain the problem inline and require an output action before applying that setting. Multiple enabled outputs all run, with independent outcomes. Changing the destination uses a native folder picker, verifies write access without losing the old selection, and offers Reveal in Finder. Folder disappearance, denied access, full disk, filename collisions, and removable-volume disconnection each have a recoverable path. Filenames include local date/time plus collision suffix; a readable filename template is configurable with a live example. Device-specific folder choices do not automatically sync across the fleet.

Maintain one typed command registry with command ID, display name, scope, default shortcut, and execution availability. Menus, settings, tooltips, and keyboard handling read this registry. Persist custom bindings by stable ID. Global capture commands use a small maintained native shortcut library or `RegisterEventHotKey` adapter after an OS compatibility check; avoid a global event tap for ordinary hotkeys. Local editor commands use the responder chain and focused document.

Do not assume every shortcut conflict is discoverable. Detect internal duplicates, known macOS-reserved combinations, and registration failures; describe external conflicts honestly. Recording a shortcut pauses Shotty's matching command until recording finishes. Escape cancels, Delete clears, and modifier-only shortcuts are rejected. Reject global shortcuts using only Option or Option+Shift as modifiers, which macOS 15 and later restrict. Check non-US keyboard layouts, Fn/media keys that are deliberately unsupported, and secure-input behavior.

Fresh installation proposes an Option-modified capture set (`⌃⌥⌘3` fullscreen, `⌃⌥⌘4` area, `⌃⌥⌘W` window, `⌃⌥⌘5` scrolling, `⌃⌥⌘T` text), validated during registration. A “Use my CleanShot shortcuts” migration preset offers `⇧⌘3`, `⇧⌘4`, and `⇧⌘5`, with window/text left as explicit choices. It explains how to disable matching CleanShot/macOS bindings and links to Keyboard settings. Shotty must not silently edit other applications' preferences. Every command is usable through menus even without a keybinding.

## Permissions and accessibility

Request Screen Recording access when the user first captures, after a brief explanation. Use the system request flow and reflect denied, not determined, and available states in Settings. Recheck when the app becomes active after a visit to System Settings. If the current macOS version requires relaunch, offer a controlled relaunch after preserving active session state. Do not repeatedly prompt after denial.

Request Accessibility only when automatic scrolling is chosen. Fullscreen, area, window capture, manual scrolling, OCR, and ordinary registered shortcuts should not require that grant. Input Monitoring, microphone, camera, and Full Disk Access are not baseline requirements. If an implementation experiment needs broader access, first establish why and update the design rather than adding a blanket onboarding request.

The app cannot grant its own TCC permissions. Provide Open System Settings actions with a fallback to Privacy & Security if a deep link changes. Permission revocation mid-operation cancels safely, stops any injected scrolling, and retains completed captures. Screen Recording and Accessibility permissions must be established independently on studio and m1; signing does not copy those grants.

All controls support VoiceOver and keyboard navigation. Give canvas annotations accessible names, positions, and editable properties, with a compact native object list reachable through the View menu for keyboard/screen-reader selection. Capture selection exposes coordinates and dimensions for keyboard adjustment. Honor system contrast, transparency, and motion preferences in thumbnails and overlays. Test focus restoration after capture, saving, Settings, and OCR results.

## Architecture and data ownership

Start with one Xcode macOS application target and a test target, organized by feature folders. Keep pure geometry, document operations, and stitching math isolated for tests without creating a package for every service. Use Swift 6 strict concurrency. A package is justified later only by a real isolation/build need.

Use `SCScreenshotManager.captureScreenshot(contentFilter:configuration:)` and `SCScreenshotConfiguration` for still images, `SCContentFilter(desktopIndependentWindow:)` for windows, and a bounded `SCStream` for scrolling sessions. Use explicit ScreenCaptureKit filters to exclude Shotty; do not rely on the legacy `NSWindow.sharingType = .none`. Prefer Vision `RecognizeTextRequest` for OCR; compare `RecognizeDocumentsRequest` on real text samples before choosing paragraph reconstruction. Keep the app outside App Sandbox to support automatic scrolling through Accessibility, and enable Hardened Runtime. This is a private direct-install application, not a Mac App Store target.

| Component | Owns |
| --- | --- |
| App coordinator | Menu bar, activation policy, launch/reopen, Settings, command dispatch, single active capture session |
| Capture coordinator | Permission preflight, target selection, display/window snapshots, ScreenCaptureKit request lifecycle, own-window exclusions |
| Scrolling session | Frame acquisition, target/focus tracking, alignment, confidence, accepted tiles, cancellation and partial-result decisions |
| OCR service | Vision requests, language options, reading-order assembly, cancellation |
| Capture store | Stable capture/document IDs, source files, thumbnail cache, active-session lifetime, crash recovery metadata |
| Thumbnail coordinator | Non-activating `NSPanel` stack, placement, overflow, card actions, drag file promises |
| Editor document | Immutable source reference, typed annotation enum, crop, undo manager, revision and export destination |
| Canvas view | AppKit input and hit-testing, Core Graphics drawing, zoom/pan, accessibility elements |
| Export service | One canonical renderer for copy/save/drag; image encoding, color conversion, atomic file writes |
| Preferences and commands | Typed persisted settings, schema migration, command registry, shortcut registration |

Keep AppKit/SwiftUI state on the main actor. Run OCR, stitching, decoding, encoding, and full-resolution rendering on cancellable background work with bounded concurrency. Use value types and `Sendable` boundaries intentionally. The canvas draws only the visible area and reuses the original image and annotation paths; do not redraw or re-encode the entire source for every pointer event.

Store original rasters and scrolling tiles on disk in the app's private Application Support session directory; keep only downsampled thumbnails in the thumbnail UI. Use an atomically updated session manifest so active unsaved captures can be restored after a crash. Normal dismissal removes the document when no editor or Undo recovery holds it. On launch, offer Restore or Discard for interrupted sessions; do not silently accumulate a library. Keep session content out of logs and backups where appropriate, protect files with user-only permissions, and test cleanup after export failure and cancellation.

Use Core Graphics/Core Image and tiled backing first. Add a custom Metal renderer only if profiling identifies a bottleneck that those tools cannot meet. Keep dependencies to a minimum: a vetted shortcut recorder library is reasonable; a full image-editor framework or web view is not.

The deployment target is macOS 26 or later, allowing the modern screenshot configuration APIs without legacy capture fallbacks. Read-only checks verified macOS 27.0, Xcode 27.0, and arm64 on both studio and m1. Produce an Apple Silicon build for this fleet; add universal binaries only if an Intel machine joins it. The local studio now has a free Personal Team and an Apple Development signing identity; m1's signing setup has not been inspected. Sign on studio and copy the signed app, keeping its private key on studio.

## Performance acceptance targets

These are targets to measure, not current results. Record p50/p95 over repeated warm runs on both studio and m1 using a representative 5K display, and record cold starts separately. Use Instruments and signposts for capture, thumbnail generation, decode, draw, OCR, stitching, and export.

| Path | Initial target |
| --- | --- |
| Warm shortcut → selection chrome visible | p95 ≤ 100 ms |
| Selection confirm → thumbnail visible, ordinary still capture | p95 ≤ 350 ms |
| Thumbnail click → interactive editor with useful preview | p95 ≤ 200 ms; full-resolution refinement can follow |
| Drawing, dragging, and panning | Meet display frame cadence for normal captures; no full-image work on main thread; measure 60 and 120 Hz |
| Idle menu-bar app with no visible stack | No capture stream or polling loop, approximately zero CPU; investigate sustained > 0.5% CPU |
| Visible stack following the pointer | No screen capture for tracking; bounded pointer-location sampling only while visible; measure CPU and cross-display response latency independently |
| Ten ordinary 5K captures in thumbnail queue | Memory stabilizes with disk-backed source files; target additional resident thumbnail/cache cost under 150 MiB |
| Long scrolling capture | Bounded frame queue and disk-backed tiles; memory does not grow in proportion to final image height; final encode limits measured explicitly |

Show progress if an operation is perceptibly slow and keep cancellation responsive. A large scrolling image may still require substantial memory during final encoding; benchmark the chosen encoder and set a tested maximum output size. If the limit is reached, stop with a usable partial preview and an explicit decision. Do not advertise unlimited capture length.

## Signing and fleet installation

There is an important distinction between free development signing and trusted distribution. A free Apple account/Personal Team does not provide a Developer ID Application certificate or Apple notarization. We cannot promise a free Apple certificate that gives a normal trusted, notarized install on every Mac.

The detailed source-backed options are in [platform-research.md](platform-research.md). Markus chose the free private development route. Verify it as a foundation gate; paid membership is not authorized:

- **Free private development path:** verify the exact macOS capabilities of the Apple account in Xcode, and test development signing and launch on both Macs. Per-Mac development builds may be the reliable free fallback. A local/self-signed identity is not an Apple Developer ID and does not remove Gatekeeper or TCC requirements. Do not call this a notarized fleet release.
- **Normal fleet release path:** an Apple Developer Program membership supplies the Developer ID route, with hardened runtime, notarization, and stapling. This is paid even when the app itself is private and free.

Choose one stable bundle identifier before requesting permissions. Keep the signing identity and designated requirement stable across builds where possible and explicitly test permission continuity after updates. Install a signed Release `.app` to `/Applications/Shotty.app` on each Mac, replacing it only after quitting and preserving active session state. The same binary can be transported privately; whether it launches as trusted depends on the chosen signing/distribution path.

During implementation, verify and reuse the existing Apple Development identity. Do not create a duplicate or replace it merely because the repository was renamed. Apple ID sign-in, agreement acceptance, and secure private-key handling are user-owned steps where needed. Keep private keys, exported certificates, Apple credentials, and notarization secrets out of this repository. Do not strip quarantine or disable Gatekeeper as an installation strategy.

The free-signing experiment has concrete steps: sign into the existing Apple account in Xcode Settings → Accounts; select the Personal Team; use Manage Certificates to create an Apple Development certificate if that option is available; configure the prototype target's stable bundle ID and signing team; build a Release app without restricted capabilities; then test installation, launch, permission grants, and one update on each Mac. Verify the signature and designated requirement with `codesign --verify --deep --strict` and `codesign -d -r-`, and inspect assessment results without treating them as a substitute for a real first-launch test. If the account or target cannot use that certificate, record the precise limitation before choosing per-machine local development signing or the paid route. Markus signed into Xcode and automatic signing created the Apple Development identity on 25 September 2026. Its recorded expiry is 25 September 2027 at 14:00:19 UTC. A disposable native probe tests signing without adding application code to this repository; see the signing verification notes.

The release checklist includes signature verification, entitlement inspection, clean-machine first launch, per-Mac permissions, capture/scroll/shortcut checks, a settings-preserving update, and rollback to the previous signed build. A manual versioned ZIP and short install script are sufficient initially; an auto-updater is outside this scope.

## Implementation sequence and release gates

### 0. Prove capture, scrolling, and signing

Deliver a minimal native capture/scroll harness, test display-coordinate mapping, measure still-capture latency, and demonstrate stitching on the agreed app matrix. Verify macOS versions on both Macs, the chosen deployment target, and the selected free signing route with the existing signed probe. Test a signed update's TCC behavior. Exit only with documented results and an explicit supported scrolling envelope.

### 1. Complete the first everyday loop

Deliver the menu-bar lifecycle, System/Light/Dark appearance, settings persistence, command registry, shortcut recording/conflicts, Screen Recording onboarding, all three still-capture modes, independent after-capture actions, configurable save destination, and multiple persistent thumbnails. Include multi-display placement, overflow, cancellation, atomic saves, and save failure recovery. This milestone must already be useful for real daily captures.

### 2. Complete the editor

Deliver the document model, canvas, selection/editing, every requested annotation tool, crop, undo/redo, text entry, zoom, keyboard commands, copy/save/drag exports, redaction flattening, and tool defaults in Settings. Verify output matches the editor at native resolution and that theme switches never recolor image content.

### 3. Integrate scrolling and OCR

Turn the validated scrolling harness into the normal capture flow with permissions, live preview, manual-only session locking, pause/resume on the automatic branch, explicit partial captures, configurable limits, and ordinary thumbnails/editor output. Deliver OCR selection, local recognition, result editing, line-break and language settings, independent text output, and empty/error recovery. Both modes use the same command and settings infrastructure as still capture.

### 4. Native quality and fleet release

Finish VoiceOver/keyboard paths, reduced-motion/contrast behavior, focus and Space transitions, performance profiling, session cleanup/recovery, denied/revoked permissions, settings migration, and signed release packaging. Dogfood on studio and m1, keeping CleanShot installed but avoiding overlapping active shortcuts. Replace CleanShot as the default only after the acceptance checklist passes.

Do not estimate calendar dates until milestone 0 resolves scrolling and signing. Scrolling is likely to dominate uncertainty; the rest is mostly known native application work.

## Verification that earns replacement status

Use focused automated tests for nontrivial logic: display-coordinate transforms at mixed scale and negative origins; image crop/annotation/export pixels; effect coverage and source-payload removal from redacted output; undo grouping; command conflict/context routing; stitching against captured stable/unstable fixtures; output preference combinations; serial clipboard rules; filename collisions and atomic replacement failure; session recovery and cleanup. Test these through outer feature operations instead of mirroring every helper.

Use a small set of native UI tests for the complete capture → thumbnail → editor → copy/save loop, multiple thumbnail independence, shortcut recording, and permission recovery screens. TCC prompts and app-to-app scrolling also require manual verification; simulated permission state does not establish real OS integration.

Release acceptance:

- All five capture modes work through both menu and configurable shortcuts on studio and m1.
- Ten successive captures retain independent, reachable thumbnails; opening, saving, or closing one leaves the others intact.
- Copy/save/show-thumbnail combinations have independent, correct outcomes; failures preserve usable captures.
- Every requested tool supports create, edit, undo, keyboard access, configured defaults, and correct final export.
- Solid-covered and cropped-away pixels are absent from exported output. All redaction styles omit original rasters, hidden objects, and auxiliary source payloads. Pixelate/Blur match the preview at full resolution without implying mathematical unrecoverability.
- Scrolling tests include sticky headers, nested scrolling, repeated content, animation, virtualization, bottom detection, cancellation, focus loss, and maximum-size behavior. Unsupported situations report their limitation.
- OCR tests include English and German prose, code, multiple columns, no text, unusual contrast, and cancelled requests. The clipboard is preserved on failure.
- Global capture shortcuts work while other apps have text focus; shortcut recording suppresses matching Shotty actions, and local editor tool keys never replace typed characters.
- Multi-display, mixed Retina scale, Spaces, fullscreen apps, hot-plugging, screen sharing/virtual displays, sleep/wake, and Dock visibility changes do not strand UI or capture Shotty's overlays.
- Permission denial and revocation, unwritable folders, full disk, interrupted export, and quit/relaunch preserve data and explain recovery.
- System, Light, and Dark are coherent; VoiceOver, keyboard-only use, Increase Contrast, Reduce Transparency, and Reduce Motion are usable.
- Signed installation and one settings-preserving update have been tested on both Macs using the chosen distribution route.

## Design approval and implementation decisions

Markus approved the prototype's look and layout and renamed the app Shotty. The single-row toolbar, compact options, direct drawing/editing gestures, thumbnails, flat native Settings, and system-blue accent are the implementation direction. Its visible Prototype limits note distinguishes simulated behavior; those limits do not reduce the native requirements. Icons, pointer feedback, handle geometry, effect quality, and focus behavior remain acceptance criteria.

The [build contract](build-readiness.md) closes remaining defaults, identifies the few unobserved CleanShot behaviors, and assigns native testing to the implementation agent. No broad product decision is blocking implementation. Free development signing is selected; frozen isolated-window capture, scrolling reliability, and fleet update/permission continuity are engineering gates that must be proved rather than assumed. Any inability to meet a required behavior, or any paid/security-permission change, must be surfaced with concrete evidence.
