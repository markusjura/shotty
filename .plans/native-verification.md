# Native implementation verification

25 September 2026. Milestone 0 is in progress, not passed. Later milestones have not started. The foundation harness is deliberately temporary and is not the approved production capture or editor UI.

## Observed

- studio and m1 both report macOS 27.0, Xcode 27.0 (27A266a), and arm64. The app targets macOS 26.0 and Swift 6 with complete concurrency checking.
- Xcode opens the project, discovers both synchronized source groups, and selects the shared Shotty scheme on My Mac. Verified through Computer Use.
- Release builds with the existing Apple Development identity. `codesign --verify --deep --strict` succeeds. App Sandbox is off and Hardened Runtime is on. The current Release configuration disables injected development entitlements; entitlement inspection is empty. No provisioning profile is embedded. No key or certificate was exported.
- The signed app was installed at `/Applications/Shotty.app` and actually launched through Computer Use. Its foundation window reports Screen Recording required. This is launch evidence on studio only, not capture or fleet evidence.
- An updated Release build was installed after quitting the first build and launched successfully through Computer Use. The two designated requirements are identical. Screen Recording has not yet been granted, so this is not evidence of TCC continuity.
- The mouse-only observer reports Accessibility false and Input Monitoring false. Computer Use scrolled Xcode's source editor, but the observer received no scroll events. That tool-driven result does not establish whether physical scrolling is observable; no extra permission was requested to work around it.
- Xcode's Debug test action passes 22 focused tests. Three cover display geometry and raster limits; nineteen cover scrolling reconstruction, ambiguity, unstable content, direction changes, caps, and the explicit-auto/manual-only state machine. Reconstructed synthetic output is compared pixel-for-pixel, in both axes, with fixed edge bands and reversals. Text-like fixtures include blank lines, sparse glyphs, padded headers/footers, and adjacent ambiguous offsets that the original noisy fixtures missed.

## Implemented foundation

`StillCaptureService` uses the macOS 26 screenshot API, isolated window filters, explicit application exclusion for display capture, SDR output, and preflighted raster limits. The synthetic window harness retains one immutable `CGImage` for both preview and PNG verification. This establishes the intended ownership mechanism; it does not yet prove the native frozen-selection semantics for all eligible windows.

`LiveCaptureSource` provides a 30-frame-per-second ScreenCaptureKit producer with queue depth three and a newest-one consumer buffer. Generation checks prevent a terminated old consumer from stopping a replacement stream. Rendering uses the incoming frame's color space explicitly. The source is not yet connected to the scrolling harness, settling detector, target tracking, or disk tiles.

`ScrollAligner` and `ScrollStitchSession` work on full-resolution RGBA values. They return explicit edge-strip edits for caller-owned disk storage and retain only the last accepted viewport. `ScrollInputState` allows automation only after explicit activation and makes external scroll input permanently manual-only for that capture. `ScrollInputObserver` observes mouse scrolling through AppKit; it classifies Shotty events by process ID and a private event marker, and makes no permission requests.

## Provisional scrolling envelope

The tested synthetic envelope is stable integer translation on one axis with at least half of the moving body overlapping. Fixed bands may occupy up to a quarter of each edge. Changed dimensions, changed band boundaries, unreliable overlap, ambiguous repeated rows, axis changes, and resource limits pause rather than produce a guessed seam. This includes headers that newly become sticky mid-capture: the engine currently requires fixed chrome from the first accepted frame. It does not silently rebase onto a rejected frame or discard prior content. Reverse recovery assumes the underlying document remains unchanged; comparison with previously persisted tiles remains an integration requirement.

Current defaults are 30,000 output-axis pixels, 120 seconds, and 256 MiB of uncompressed output. Individual frames have an 8,192-pixel dimension limit and a 128 MiB limit. These are allocation guards, not a measured final encoder memory guarantee or an advertised product limit. Matching uses full-row fingerprints to identify exact translations, verifies those overlaps pixel-for-pixel, and samples approximate candidates. Any competing exact offset rejects the seam, including adjacent offsets. Edge detection checks the full breadth and refines in-place equality against the solved translation to establish minimum evidence of fixed chrome. Actual strip replacement uses the entire in-place-equal edge run; this preserves white padding whose ownership cannot be established from two frames. Padded-chrome fixtures check every reconstructed pixel after every accepted edit. Real text/list/virtualized-content validation remains necessary before this envelope can be declared supported.

## Encoder experiment

`Scripts/EncoderBenchmark.swift` generates deterministic noisy RGBA pixels and encodes one PNG directly to a private temporary directory with ImageIO. It removes the generated file afterward. The measurements below use optimized Swift 6 binaries and `/usr/bin/time -l`; RSS includes synthetic source creation and encoding. Each number is one run, not a p50/p95 claim.

| Machine | Pixels | Raw bytes | Encode time | Peak RSS |
| --- | --- | --- | --- | --- |
| studio | 2,000 × 30,000 | 240,000,000 | 4.080 s | 252,461,056 bytes |
| m1 | 2,000 × 30,000 | 240,000,000 | 5.583 s | 252,231,680 bytes |
| studio | 5,120 × 13,000 | 266,240,000 | 4.909 s | 278,872,064 bytes |
| m1 | 5,120 × 13,000 | 266,240,000 | 6.077 s | 278,429,696 bytes |

The same inputs produced the same PNG byte sizes on both machines. This tests the proposed final encoder near the provisional byte cap, including the 30,000-pixel axis limit at a narrower width. It does not include stream buffers, stitching, compositing, editor caches, or a second decoded copy. The integrated application's peak must still be measured before accepting a product limit. At 5,120 pixels wide, 30,000 rows exceed the byte guard and must pause earlier.

To reproduce, compile `xcrun swiftc -O -swift-version 6 Shotty/Geometry/DisplayGeometry.swift Scripts/EncoderBenchmark.swift -o .build/encoder-benchmark`, then run `/usr/bin/time -l .build/encoder-benchmark 2000 30000` or `5120 13000`.

## Required before milestone 1

1. Complete the studio Screen Recording grant and relaunch. Confirm denied/available status without repeated prompting.
2. Capture the animated synthetic window, wait while its live contents change, verify the retained PNG, then repeat while occluded and with shadows disabled. Exercise display capture exclusion, native scale, cancellation, and layout changes. Implement and measure acquisition of the complete eligible-window snapshot set before claiming frozen window selection.
3. Run the mouse-only observer with Accessibility and Input Monitoring denied, using external-app physical scroll input. A successful synthetic input test alone does not establish physical-event behavior.
4. Connect the bounded stream to settling, target/focus checks, disk-backed tile storage and partial-result UI. Exercise normal/sticky/nested/virtualized fixtures, native lists, PDF, both axes, reversals, and unfamiliar apps. Verify explicit auto start, injected-event identification, pause/resume and permanent manual takeover.
5. Measure bounded final encoding and set tested width/length/memory limits. Record warm p50/p95 and cold capture timings separately on both machines.
6. Install and launch on m1, establish its own OS grants, and verify an updated signed build preserves preferences and TCC on both Macs. Record signature and designated-requirement continuity. Do not strip quarantine or call this distribution notarized.

Screen Recording is presently a user-owned OS step. No native capture result, cross-app scrolling envelope, full product completion, or fleet acceptance is claimed from the successful build and pure tests.
