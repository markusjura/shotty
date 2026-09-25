# Shotty platform research

Technical feasibility notes for Shotty, a native SwiftUI screenshot app replacing CleanShot X on Markus's Macs. Sources accessed 2026-09-25. Apple documentation was read through the developer.apple.com DocC JSON endpoints, the Apple Account Help pages, Apple Support pages, and the macOS 27.0 SDK headers shipped with Xcode 27.0.

Each finding is marked:

- **Fact**: stated by an Apple primary source (documentation, SDK header, Apple Support, or an Apple DTS engineer on the Apple Developer Forums, which is first-party guidance but not formal documentation).
- **Inference**: engineering judgment derived from facts. Must be verified in a prototype.

## Local environment (verified read-only)

| Machine | macOS | Xcode | Arch | Signing state |
|---|---|---|---|---|
| `mj-studio` (this machine) | 27.0 (26A428) | 27.0 (27A266a) | arm64 | `security find-identity -v -p codesigning`: 0 valid identities. No Xcode provisioning teams or profiles. |
| `mj-m1` (`ssh m1`) | 27.0 | 27.0 | arm64 | Not inspected beyond versions. |

Implication (inference): both fleet Macs run macOS 27, so Shotty can set its deployment target to macOS 26 or 27 and use the newest capture API without fallbacks. I recommend macOS 26.0 as the floor because every API Shotty needs exists there, and nothing needed is 27-only.

## Recommendation summary

1. Capture stills with ScreenCaptureKit's `SCScreenshotManager.captureScreenshot(contentFilter:configuration:)` and `SCScreenshotConfiguration` (macOS 26). Do not use `CGWindowListCreateImage`, which is obsoleted in the macOS 15 SDK.
2. For area capture, capture the full display first, show a frozen overlay, then crop in memory. For window capture, use `SCContentFilter(desktopIndependentWindow:)`.
3. Register global shortcuts with Carbon `RegisterEventHotKey`. It needs no TCC permission, unlike event taps (Input Monitoring) or `NSEvent` global key monitors (Accessibility). Validate against the macOS 15+ rule that rejects Option-only and Option+Shift hotkeys.
4. Screen Recording is the only permission required for fullscreen, window, area, OCR, and manual scrolling capture. Accessibility (event posting) is needed only when the user turns on Auto Scroll during a scrolling capture session.
5. Build scrolling capture on repeated ScreenCaptureKit frames plus a row-offset matcher. There is no Apple scrolling-capture API. Reading screen pixels avoids an app allowlist; reliable stitching across arbitrary content still requires validation and visible failure recovery. Auto Scroll is available initially and starts only on explicit activation. The first manual scroll hides it and locks the current capture to manual-only. Manual scrolling can be implemented first because it needs only Screen Recording; Auto Scroll ships in the same release and adds the Accessibility grant.
6. OCR with Vision `RecognizeTextRequest` (macOS 15, Swift API), `.accurate` level, language auto-detection. Consider `RecognizeDocumentsRequest` (macOS 26) for paragraph-preserving output.
7. Do not sandbox the app. Enable Hardened Runtime.
8. A free Apple Account cannot produce a Developer ID certificate or notarize, and Apple states the free tier cannot distribute apps. The only official path for installing on other Macs without Gatekeeper friction is the paid Apple Developer Program (99 USD/year) with Developer ID plus notarization. A free Personal Team Apple Development identity has now been created on studio. Its certificate expires 25 September 2027. Signed build, copied-app launch, and update/permission behavior must be validated separately; see [signing-verification.md](signing-verification.md).

## 1. ScreenCaptureKit still capture

**Facts**

- ScreenCaptureKit is available from macOS 12.3. Apps must request screen recording permission and add `NSScreenCaptureUsageDescription` to Info.plist. https://developer.apple.com/documentation/screencapturekit
- `SCScreenshotManager` is available from macOS 14.0. Its methods:
  - `captureImage(contentFilter:configuration:)` returns `CGImage` (macOS 14.0) and `captureSampleBuffer(contentFilter:configuration:)` returns `CMSampleBuffer` (macOS 14.0). Both take an `SCStreamConfiguration`. https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager
  - `captureImage(in:)` captures "the contents of the rectangle in points, specified in display space" (macOS 15.2). https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager/captureimage(in:completionhandler:)
  - `captureScreenshot(contentFilter:configuration:)` and `captureScreenshot(rect:configuration:)` return `SCScreenshotOutput` and take `SCScreenshotConfiguration` (macOS 26.0). https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager/capturescreenshot(contentfilter:configuration:completionhandler:)
- `SCScreenshotConfiguration` (macOS 26.0) exposes `width`, `height`, `showsCursor` (cursor visible by default), `sourceRect` (points, display logical coordinates), `destinationRect`, `ignoreShadows`, `ignoreClipping`, `includeChildWindows` (on by default, so alerts, popovers, and sheets are captured), `displayIntent`, `dynamicRange` (SDR, HDR, or both), `contentType` (HEIC, JPEG, PNG), and `fileURL` (ScreenCaptureKit writes the file itself when set). Source: SDK header `ScreenCaptureKit.framework/Headers/SCScreenshotManager.h` and https://developer.apple.com/documentation/screencapturekit/scscreenshotconfiguration
- `SCScreenshotOutput` has `sdrImage` (display color space), `hdrImage` (extended sRGB), and `fileURL`. https://developer.apple.com/documentation/screencapturekit/scscreenshotoutput
- `SCContentFilter` initializers: `init(desktopIndependentWindow:)`, `init(display:excludingWindows:)`, `init(display:including:)`, `init(display:excludingApplications:exceptingWindows:)`, and others. Properties include `contentRect`, `pointPixelScale`, `includeMenuBar`. https://developer.apple.com/documentation/screencapturekit/sccontentfilter
- `SCShareableContent` enumerates `displays`, `windows`, and `applications`, with `getExcludingDesktopWindows(_:onScreenWindowsOnly:)` and above/below variants. `SCWindow` exposes `windowID`, `title`, `owningApplication`, `windowLayer`, `frame`, `isOnScreen`, `isActive`. https://developer.apple.com/documentation/screencapturekit/scshareablecontent, https://developer.apple.com/documentation/screencapturekit/scwindow
- `CGWindowListCreateImage` and `CGWindowListCreateImageFromArray` are declared `SCREEN_CAPTURE_OBSOLETE(10.5,14.0,15.0)`, meaning deprecated in 14.0 and obsoleted in 15.0, with the message "Please use ScreenCaptureKit instead." Source: macOS 27 SDK `CoreGraphics.framework/Headers/CGWindow.h`.
- Apple's docs recommend `SCContentSharingPicker` for letting people pick content in general-purpose capture apps. https://developer.apple.com/documentation/screencapturekit
- `NSWindow.SharingType.none` is documented as "a legacy constant that macOS no longer uses" and should not be used to hide content from capture. https://developer.apple.com/documentation/appkit/nswindow/sharingtype-swift.enum/none

**Inferences for Shotty**

- Fullscreen: `SCContentFilter(display:excludingApplications:exceptingWindows:)` excluding Shotty's own app, so thumbnails and overlays never appear in captures. Then `captureScreenshot(contentFilter:configuration:)`.
- Area: take a full-display capture at hotkey press, show it frozen in a borderless overlay window per display, let the user drag a rectangle, then crop the `CGImage` in memory. Pixels match what the user saw, the overlay never leaks into the image, and the crop is instant. CleanShot X offers a similar "freeze screen" mode. A live, non-frozen variant can call `captureScreenshot(rect:configuration:)` after the overlay hides, at the cost of one extra frame of latency.
- Window: hit-test the cursor against `SCShareableContent.windows` (layer 0, on screen, excluding Shotty) to highlight the hovered window, then capture with `SCContentFilter(desktopIndependentWindow:)`. `ignoreShadows` maps directly to a "Capture window shadow" setting.
- Retina: set `width`/`height` from `contentRect.size * pointPixelScale` or leave defaults, which already use the captured content size. Verify on mixed-DPI multi-display setups.
- `SCContentSharingPicker` is the wrong UX for a hotkey-driven screenshot tool. Shotty should build its own overlay, as CleanShot X does. This is allowed; the docs present the picker as a recommendation.
- Latency: `SCShareableContent` enumeration can take tens of milliseconds. Prefetch it when the overlay opens and refresh on `NSWorkspace` app activation notifications. Measure before optimizing further.
- HDR: default to SDR output. HDR (`dynamicRange`) is a possible later setting and not needed for the requested features.

## 2. Screen Recording permission (TCC)

**Facts**

- `CGPreflightScreenCaptureAccess()` checks access without prompting. `CGRequestScreenCaptureAccess()` prompts if undetermined; "A previously denied process is not re-prompted; the user must enable access in System Settings > Privacy & Security > Screen Recording." Source: `CGWindow.h`, macOS 27 SDK. https://developer.apple.com/documentation/coregraphics/cgrequestscreencaptureaccess()
- Apple's ScreenCaptureKit sample states: "After you grant permission, you need to restart the app to enable capture." https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos
- TCC tracks app identity by the code signature's designated requirement (DR). Ad hoc signed code has no stable DR, so macOS cannot tell build N+1 is the same app as build N. Apple DTS recommends Apple Development signing during development and Developer ID for direct distribution. https://developer.apple.com/forums/thread/795739, https://developer.apple.com/forums/thread/707177, https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements
- TN3127: an Apple Development signed build gets a different default DR than a Developer ID signed build. https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements
- The Persistent Content Capture entitlement exists for VNC apps only and requires an Apple request form. https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.persistent-content-capture

**Inferences for Shotty**

- Onboarding: one permission screen that calls `CGRequestScreenCaptureAccess()`, deep-links to the Screen Recording pane, and offers "Relaunch Shotty" after grant.
- Every build must be signed so that it satisfies the same designated requirement, or Markus will re-grant Screen Recording (and Accessibility, if used). This does not require the exact same certificate. Per TN3127, Xcode's default Apple Development DR checks the bundle identifier, `anchor apple generic`, the leaf certificate's Common Name (`Apple Development: …`), and the WWDR issuer OID. A renewed certificate should therefore still satisfy the DR if its Common Name is unchanged; confirm with `codesign -d -r-` before and after a renewal. Switching from Apple Development to Developer ID changes the DR (TN3127 states the two are not mutually compatible), so grants will be requested again once.
- Persistent Content Capture does not apply to Shotty.

**Uncertain**

- Periodic re-consent prompts for screen recording were widely reported starting with macOS 15. I did not find an Apple primary source describing the current cadence on macOS 26/27. Verify on the fleet with the prototype.

## 3. Global shortcuts, Accessibility, and Input Monitoring

**Facts**

- `RegisterEventHotKey` (Carbon HIToolbox, `CarbonEvents.h`) registers a global hotkey by virtual key code and modifiers. It is available and not marked deprecated in the macOS 27 SDK. Multiple apps can register the same combination unless one uses `kEventHotKeyExclusive`; registering an exclusive hotkey already held exclusively by another process returns `eventHotKeyExistsErr`. Source: SDK header.
- On macOS 15, `RegisterEventHotKey` with Option-only or Option+Shift modifiers fails with `-9868`. Apple DTS called this "an intentional change in macOS Sequoia" to limit key-logging, because Shift+Option produces alternate password characters. https://developer.apple.com/forums/thread/763878
- `NSEvent.addGlobalMonitorForEvents(matching:handler:)`: "Key-related events may only be monitored if accessibility is enabled or if your application is trusted for accessibility access." Global monitors observe only and cannot swallow events. https://developer.apple.com/documentation/appkit/nsevent/addglobalmonitorforevents(matching:handler:)
- Two separate privileges: `CGRequestListenEventAccess` maps to Privacy & Security > Input Monitoring (listening event taps). `CGRequestPostEventAccess` maps to Privacy & Security > Accessibility (posting synthetic events). https://developer.apple.com/forums/thread/727984, https://developer.apple.com/forums/thread/744440. API declarations: `CGEvent.h`, macOS 27 SDK.
- `AXIsProcessTrustedWithOptions(_:)` reports whether the process is a trusted accessibility client. https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions
- Sandboxed apps can use Input Monitoring but not the Accessibility privilege without temporary exception entitlements. https://developer.apple.com/forums/thread/780626

**Inferences for Shotty**

- Use `RegisterEventHotKey` for all global capture shortcuts. No TCC prompt is needed. Editor shortcuts are in-app and use SwiftUI `.keyboardShortcut` or a local `NSEvent` monitor, also without permissions.
- The shortcut recorder in Settings must reject combinations whose only modifiers are Option or Option+Shift, show the conflict inline, and surface registration failures (another app holding the key exclusively).
- CleanShot X-style defaults like Cmd+Shift+3/4 collide with the built-in macOS screenshot shortcuts. Shotty should offer defaults that avoid them and show a one-click link to System Settings > Keyboard > Keyboard Shortcuts > Screenshots for users who want to take them over. Whether a Carbon registration overrides an enabled system screenshot shortcut is unverified; test it.
- Accessibility permission is requested lazily, the first time the user turns on Auto Scroll inside a scrolling capture session.

## 4. OCR (Capture Text)

**Facts**

- `RecognizeTextRequest` (Swift Vision API, macOS 15.0) returns `RecognizedTextObservation` values with `transcript`, `boundingRegion`, `topCandidates(_:)`, `shouldWrapToNextLine`. Configuration: `recognitionLevel` (`.fast`, `.accurate`), `recognitionLanguages` (priority order), `automaticallyDetectsLanguage`, `usesLanguageCorrection`, `customWords`, `minimumTextHeightFraction`, `supportedRecognitionLanguages`. https://developer.apple.com/documentation/vision/recognizetextrequest, https://developer.apple.com/documentation/vision/recognizedtextobservation
- `VNRecognizeTextRequest` is the older class-based API, macOS 10.15. https://developer.apple.com/documentation/vision/vnrecognizetextrequest
- `RecognizeDocumentsRequest` (macOS 26.0) returns `DocumentObservation` with text grouped into words, lines, paragraphs, plus tables, lists, and barcodes. https://developer.apple.com/documentation/vision/recognizedocumentsrequest
- VisionKit `ImageAnalysisOverlayView` (macOS 13.0) provides system Live Text selection over an image. https://developer.apple.com/documentation/visionkit/imageanalysisoverlayview

**Inferences for Shotty**

- Capture Text flow: area overlay, crop, `RecognizeTextRequest` with `.accurate`, language auto-detect, language correction on, join observations in reading order honoring `shouldWrapToNextLine`, copy to clipboard, show a short confirmation HUD. Settings: recognition languages (default auto), "Keep line breaks" toggle.
- Try `RecognizeDocumentsRequest` in the prototype for paragraph-aware output on multi-column text. Pick whichever produces cleaner clipboard text on real screenshots.
- `ImageAnalysisOverlayView` in the editor would give free Live Text selection. It is optional and outside the requested scope.

## 5. Scrolling capture

**Facts**

- Apple provides no scrolling-capture or image-stitching API for screen content.
- `CGEvent(scrollWheelEvent2Source:units:wheelCount:wheel1:wheel2:wheel3:)` creates scroll-wheel events (macOS 10.13), and `post(tap:)` posts them. Posting requires the Accessibility/post-event privilege (`CGRequestPostEventAccess`). https://developer.apple.com/documentation/coregraphics/cgevent/init(scrollwheelevent2source:units:wheelcount:wheel1:wheel2:wheel3:), https://developer.apple.com/documentation/coregraphics/cgevent/post(tap:)
- Vision offers translation registration: `VNTranslationalImageRegistrationRequest` (macOS 10.13) and `TrackTranslationalImageRegistrationRequest` (macOS 15.0) produce an alignment transform between two images. https://developer.apple.com/documentation/vision/vntranslationalimageregistrationrequest, https://developer.apple.com/documentation/vision/tracktranslationalimageregistrationrequest
- `SCStream` delivers continuous frames with configurable `minimumFrameInterval` and `queueDepth` (default 3, should not exceed 8). https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos

**Inferences for Shotty**

- Pipeline: user selects a region, Shotty starts an `SCStream` limited to that region (`sourceRect`), keeps a bounded frame queue, and appends new content when reliable overlap establishes movement along the selected primary axis. Return/Done finishes; Escape cancels. Insufficient overlap pauses rather than producing a guessed seam.
- Offset matching: compare frames using row signatures (per-row hashes or downsampled luminance) and find the best vertical shift. Use the equivalent column-based comparison for horizontal capture, which is included in the revised interaction specification. Use Vision translational registration as a fallback or cross-check. Constrain a session to its detected/chosen primary axis; do not silently attempt arbitrary two-dimensional panorama stitching.
- App-independent: the pipeline compares captured pixels rather than relying on an app API or allowlist. Vertical and horizontal scrolling are required. Reliability across different rendering behaviors must be demonstrated; pixel access alone does not guarantee a successful stitch in every app.
- One session, explicit input choice. Offer Auto Scroll initially, but start injection only on its explicit activation. The first physical manual scroll commits the session to manual-only and hides Auto Scroll until a new capture, matching Markus's CleanShot observation. Manual scrolling uses Screen Recording only. Auto Scroll needs Accessibility, requested on first use, and posts conservative scroll events. Proposed automatic-first handoff: physical manual input stops injection and commits the remaining session to manual-only without clearing accepted tiles. The shared stitcher processes pixels independently of input source, while the session controller enforces eligibility across buttons and shortcuts. Distinguish injected events from physical input so automation cannot lock itself out. Build manual scrolling first, then add Auto Scroll on the same pipeline before release.
- Hard cases for Shotty's implementation: sticky headers and footers, animation/video, lazy-loaded content that reflows, parallax, overlay scrollbars, and smooth-scroll momentum overshoot. These are engineering risks, not measured claims about CleanShot's performance. Detect stationary bands conservatively and keep a region-adjustment fallback. Show a live preview strip so the user sees stitching as it happens.
- Cap the output dimension along the scrolling axis (for example 30,000 px), total pixel area, and working memory, and make the limit visible.
- Scrolling capture is the highest-risk feature. Prototype it early against a representative test matrix, for example Safari, Xcode, a Slack channel, and a long settings pane. These are test samples, not a list of supported apps.

## 6. App shell details relevant to the plan

**Facts**

- `MenuBarExtra` (SwiftUI, macOS 13) supports `isInserted:` binding. A menu-bar-only app is terminated automatically if the user removes the extra from the menu bar. `LSUIElement = true` hides the Dock icon. https://developer.apple.com/documentation/swiftui/menubarextra
- `NSApplication.ActivationPolicy.accessory` means no Dock icon and no menu bar, and corresponds to `LSUIElement = 1`. https://developer.apple.com/documentation/appkit/nsapplication/activationpolicy-swift.enum/accessory
- `SMAppService.mainApp` registers the main app as a login item (macOS 13). https://developer.apple.com/documentation/servicemanagement/smappservice/mainapp
- `NSWorkspace.accessibilityDisplayShouldReduceMotion` and `accessibilityDisplayShouldIncreaseContrast` expose system accessibility display options, with change notifications. https://developer.apple.com/documentation/appkit/nsworkspace/accessibilitydisplayshouldreducemotion, https://developer.apple.com/documentation/appkit/nsworkspace/accessibilitydisplayshouldincreasecontrast

**Inferences for Shotty**

- Menu bar and Dock settings: switch between `.accessory` and `.regular` activation policy at runtime. Guard against disabling both, since the app would become unreachable except via hotkeys; if both are off, reopen Settings when the app is launched again from Finder.
- Thumbnails and overlays should be non-activating `NSPanel`s so they never steal focus from the app being captured.
- App Sandbox adds container and bookmark complexity for the save folder and blocks Accessibility. Shotty is not going to the Mac App Store, so it should not be sandboxed.

## 7. Signing and distribution across the fleet

**Facts**

- Xcode can build and test apps on personal devices without Developer Program membership. https://developer.apple.com/help/account/membership/programs-overview/
- The free "Apple Developer" tier is for "Apple Account holders who have agreed to the Apple Developer Agreement". Apple states: "No cost is associated with this agreement and developers can't distribute apps." https://developer.apple.com/help/account/reference/supported-capabilities-macos/
- Certificate types: Apple Development is for running apps on devices during development. Developer ID Application is to "Sign a Mac app before distributing it outside the Mac App Store." Development certificates belong to individuals; distribution certificates belong to the team. https://developer.apple.com/help/account/certificates/certificates-overview/
- Developer ID certificates require the Apple Developer Program, and the Account Holder role creates them (up to five Developer ID Application certificates). https://developer.apple.com/help/account/certificates/create-developer-id-certificates/, https://developer.apple.com/developer-id/
- The Apple Developer Program costs 99 USD per membership year (prices vary by region). https://developer.apple.com/programs/enroll/
- Notarization requires a Developer ID certificate ("Don't use a Mac Distribution, ad hoc, Apple Developer, or local development certificate"), Hardened Runtime, and a secure timestamp. https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution, https://developer.apple.com/documentation/security/hardened-runtime
- Gatekeeper verifies downloaded software from outside the App Store is from an identified developer and notarized, and asks for approval on first open. https://support.apple.com/guide/security/gatekeeper-and-runtime-protection-sec5599b66df/web
- Since macOS Sequoia, Control-click no longer overrides Gatekeeper. Users approve via System Settings > Privacy & Security > Open Anyway. https://developer.apple.com/news/?id=saqachfa, https://support.apple.com/en-us/102445

**What this means**

A free Apple Account cannot produce a Developer ID certificate, cannot notarize, and per Apple's own wording is not a distribution path. The request "create a free Apple developer certificate so I can distribute across my fleet" is only achievable in a narrow, personal sense.

**Options (inferences unless marked)**

The "Stable DR across updates" column states whether consecutive builds are expected to satisfy one stable designated requirement (DR). Every row is pending an update test: grant Screen Recording, install a rebuilt version, confirm no re-prompt, and compare `codesign -d -r-` output.

| Option | Cost | Status | Stable DR across updates | Notes |
|---|---|---|---|---|
| A. Free Personal Team "Apple Development" cert, build on `mj-studio`, copy `Shotty.app` to `mj-m1` over SSH | Free | Unverified experiment | Expected, per the TN3127 Apple Development DR (identifier, Apple anchor, leaf Common Name, WWDR issuer OID). Pending update test, including across a certificate renewal. | Unresolved: whether Xcode 27 Personal Teams sign macOS app targets, certificate validity period, and whether the copied app launches on `mj-m1` without a Gatekeeper or signature prompt. Apple says the free tier "can't distribute apps", so even a working result is a personal workaround. |
| B. Build from source on each Mac with a Personal Team cert | Free | Unverified experiment | Expected per machine, same basis as A. Pending update test. | Same open questions as A, plus two build setups. |
| C. Self-signed code signing certificate from Keychain Access, shared to both Macs | Free, no Apple account | Unverified experiment | Expected, since the DR pins that certificate. Pending update test. | Not Apple-issued; Apple DTS recommends Apple-issued identities. Gatekeeper behavior on the second Mac unverified. |
| D. Apple Developer Program, Developer ID + notarization, distribute a DMG | 99 USD/year | Official path (fact) | Expected, per the TN3127 Developer ID DR (Team ID in `subject.OU`). Pending update test. | Opens after download on any Mac with the notarization flow Apple documents. Also covers sharing with other people. |
| Ad hoc signing (`codesign -s -`) | Free | Not viable | Not expected: ad hoc code has no stable DR (Apple DTS). | Grants are requested again after every rebuild. |

Recommendation: treat D as the only confirmed deployment path. If Markus wants to avoid the fee, run A as a time-boxed experiment on the first prototype. Pass criteria: the app signs with a Personal Team, launches on `mj-m1` after copying, keeps its Screen Recording grant across a rebuild, and `codesign -d -r-` shows the expected DR. If any check fails, fall back to C or D. Do not create any credentials until Markus signs into Xcode with his Apple Account; that step is his.

**Uncertain, verify during the experiment**

- Whether Xcode 27 Personal Teams can sign a macOS app target, and whether a provisioning profile is required when no restricted capabilities are used. Shotty needs none (no iCloud, push, or app groups).
- The validity period of a free Personal Team development certificate on macOS, and whether its Common Name stays the same on renewal.
- Whether an Apple Development signed app copied to another Mac launches without any prompt on macOS 27. The result must come from launching the app, and not from the presence or absence of a quarantine attribute.

## Decisions after the readiness pass

The deployment target is macOS 26.0. Use distinct global capture shortcuts until Markus deliberately applies the migration preset. Auto Scroll starts only from its explicit control; Space only pauses/resumes an already-started automatic branch. Adaptive pace is the initial default, with values and testing in the [build contract](build-readiness.md).

Markus chose the free route and signed into Xcode. Automatic signing created an Apple Development identity on studio on 25 September 2026. The earlier "no signing identities" environment row records the initial audit state. The certificate expires 25 September 2027 at 14:00:19 UTC; that observed one-year validity is not a guarantee of every future certificate's lifetime. The earlier options table describes hypotheses and must be read alongside the newer [signing verification](signing-verification.md). No paid membership, notarization, private-key export, or weakening of Gatekeeper was performed.
