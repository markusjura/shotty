# Native implementation verification

Status: 25 September 2026. Milestone 0 is in progress, not passed. Product milestones have not started. The foundation harness is deliberately temporary and is not the approved production capture or editor UI.

Markus narrowed this PR to studio. All implementation and native verification here runs on studio; m1 installation, permissions, performance, and fleet acceptance belong to a separate PR after implementation.

## Environment and signing

- studio reports macOS 27.0, Xcode 27.0 (27A266a), and arm64. The app targets macOS 26.0 and Swift 6 with complete concurrency checking.
- Xcode opens the project, discovers both synchronized source groups, and selects the shared Shotty scheme on My Mac.
- Release builds with the existing free Apple Development identity. `codesign --verify --deep --strict` succeeds. App Sandbox is off and Hardened Runtime is on. Release disables Xcode's injected development entitlements, so entitlement inspection is empty. No provisioning profile is embedded. No key or certificate was exported. Details are in [signing verification](signing-verification.md).
- The signed app is installed at `/Applications/Shotty.app` and has been launched through Computer Use after several signed Release replacements. The first install and the first rebuilt update had identical designated requirements.

## Permissions on studio

- Markus granted Screen Recording. It remained available after multiple signed Release replacements and relaunches.
- Markus physically scrolled an external app while Accessibility and Input Monitoring were both false. The mouse-only observer counted 70 external scroll events, read through Computer Use. This establishes that the manual scrolling path works without Accessibility or Input Monitoring on studio.
- The harness has an explicit setup action for automatic scrolling, which needs Accessibility to post scroll events. Markus then granted Accessibility, and it also survived the signed Release replacements. Input Monitoring is never requested.

## Frozen capture

- The animated synthetic window captured at 1372 × 996 with shadow in about 67 ms and at 1280 × 904 without shadow in about 57 ms. The retained shadowed snapshot matched the decoded PNG exactly after the animation advanced.
- Occlusion verification passes. The isolated window's pixels are unchanged when another window fully covers it, survive private raw storage and cleanup, and round-trip through PNG exactly. An earlier run failed the format guard because ScreenCaptureKit's data provider holds extra allocation bytes after the last scanline. Storage now writes only the raster bytes and still counts the whole provider against the resident-memory budget.
- The pre-capture budget assumes 4 bytes per pixel. A studio probe of `SCScreenshotManager` `.sdr` output on windows and both 5K displays measured 8 bits per component, 32 bits per pixel, and 128-byte row alignment. The actual raster and provider bytes are still checked after capture.
- Acquiring the full eligible set took 272, 276, 283, and 287 ms over four runs: 5 windows, 12 rasters including alternate-shadow variants, and 2 displays. It used 248 MiB of temporary disk; the largest raster was 56 MiB. Because acquisition finishes before the freeze surface appears, this misses the plan's warm target of p95 ≤ 100 ms from shortcut to visible selection chrome. The frozen-preview and isolated-export semantics pass; the 100 ms performance target remains unmet. Preserve those semantics while evaluating bounded acquisition improvements.
- Bounded concurrent acquisition passes the updated native occlusion/PNG check. With 12 eligible windows, 26 rasters and two displays, it measured 417 ms cold and 377 ms warm, using 329 MiB of temporary pixels, at most three simultaneous captures and 229 MiB of reserved application buffers. This desktop differs from the earlier five-window run, so these numbers do not establish a speedup. The 100 ms target remains unmet.
- A matched acquisition comparison on a stable set of 7 windows, 16 rasters and 369 MiB of temporary pixels ran five alternating-order pairs after warming both modes. Sequential p50/p95 was 322/330 ms, versus 244/252 ms with at most three captures in flight. Application-buffer reservations peaked at 114 versus 182 MiB. IDs, geometry, raster sizes and disk totals matched across all runs. Concurrency reduced both measured percentiles by about 24%, so the bounded implementation is retained; the 100 ms target still misses. With five samples, p95 is the maximum. Both permissions remained available after the signed update.
- Temporary frozen and scrolling pixel directories are removed on close, discard, or deinitialization. They are not yet swept after a crash or force-quit; that cleanup belongs to the lifecycle milestone.

## Live stream and scrolling

`LiveCaptureSource` streams at up to 30 frames per second with queue depth three and a newest-one consumer buffer. It now requests Display P3 explicitly and copies BGRA bytes directly, because the stream's automatic color metadata described the pixels incorrectly. On the synthetic fixture, 14 known colors agree within 1 channel level, native dimensions and orientation are correct, and the streamed PNG round trip is exact. `SettledFrameDelivery` publishes paced moving frames and one settled frame after changes stop. `ScrollAccumulator` checks every matched step against the accepted disk-backed tiles in `ScrollTileStore` before committing it. `ScrollAutomationDriver` injects one marked step at a time and only after an explicit Auto Scroll start. It releases the next step only after an accepted, settled movement.

Native results on studio:

- Automatic vertical capture of a cropped region (X 20, Y 92, W 760, H 580 points within the target window) accepted 49 frames and produced a 1520 × 12176 output. It reached the bottom with 49 Shotty-injected events and 0 external events. Pause and resume worked.
- Manual capture with advance 80, reverse 40, then advance 80 produced the expected output heights: 1320, then 1320 retained during the reverse, then 1400.
- After candidate refinement, the native table reached the bottom with 62 accepted frames (1520 × 11852), and horizontal capture reached the end with 36 accepted frames (11880 × 912). Both correctly stopped injecting after no further progress. Independent exported seam inspection passes for both. The table contains all 231 nonblank IDs once and in order on its 44-pixel row grid; the crop clips the first and last rows. The horizontal strip contains all 37 expected nonblank columns; all 67 inked blocks match the offline reference at one global offset (thresholded IoU minimum 0.987, median 0.998). Its 11,880-pixel length exactly matches the selected viewport coverage; the crop omits the final 40 points of the document. Earlier 5-event horizontal and 11-event table runs exposed the false ambiguity now fixed.
- The vertical export has all 190 expected row IDs in the correct positions, with one pinned header and one footer. Its 12,000-pixel body matches the offline synthetic reference row for row after color-managed grayscale conversion (per-row mean error median 0, p99 0.47, maximum 0.68 on a 0–255 scale). All 231 text-bearing blocks prefer zero offset in a ±60-pixel shift search. Color equality is covered separately by the capture color test; this structural seam check is not whole-image bit equality.
- The two captured table/horizontal false ambiguities were traced to sparse coarse samples after tiny rendering differences defeated exact fingerprints. Re-ranking close candidates at 192 × 64 sample density resolves both saved pairs at the expected 180/304-pixel displacements in 4–10 ms without lowering the error margin. Genuine noisy repeats still reject. Native full-run retests reached the end; see the recorded dimensions above.
- Apple Preview captured the generated single-page PDF in 34 accepted frames, producing 2200 × 17904 pixels with 34 injected and 0 external scroll events. All 190 row IDs, row numbers, and generated hashes are present once and in order. Text bands fit one linear pitch of 93.430 pixels within ±0.5 pixels; the 93/94-pixel spacing is uniform Preview scaling, not seam slips. No stray pixels occur between bands. The selected region was X20 Y80 W1100 H1200 points. Actual Size on this studio display is approximately 3.0139 pixels per PDF point.
- Moving the fixture window 20 points while an idle manual capture retained its first frame stopped acquisition with the moved/resized explanation and left Export Partial PNG enabled. Opening another application through Finder likewise stopped with the lost-focus explanation and retained the accepted image. Computer Use clicks alone do not necessarily activate an app; these checks used actual WindowServer geometry and activation changes.
- Computer Use supplies separate animated Software Cursor windows. ScreenCaptureKit's `showsCursor = false` does not remove those windows. Moving each test app's tool cursor to its title bar keeps the selection still; otherwise the harness correctly refuses an unsettled first frame. This is a test-tool artifact, not an app-specific capture adapter.
- TextEdit captured 300 generated lines in 44 frames at 1120 × 7832, with 44 injected events and no external events. All 300 rows and hashes are present once and in order; every 23-pixel text band lies on an exact 26-pixel grid. The X12 Y68 W560 H417 crop clips part of each leading T to exclude the caret and includes one top hairline, but neither creates seam errors. No caret, cursor or scroller appears between rows.
- Setting the native fixture scrollbar directly to 80% after accepting the first frame pauses with insufficient overlap, keeps the original 1520 × 1160 result, and leaves partial export available. The fixture's ticking unstable content likewise pauses after the initial accepted frame without adding output rows. These tool actions exercise pixel rejection, not physical-input takeover.
- Tall near-periodic content uses a rival cap scaled to the displacement search, followed by dense re-ranking and full-width strong-outlier separation. On 2600-pixel fixtures, unique narrow IDs resolve correctly on both axes; repeated or re-rendered IDs remain ambiguous. Optimized known-axis checks measured 17–30 ms at 2600 pixels and 30–33 ms at 4000 pixels. No mean-error or outlier thresholds were relaxed.
- Overlay scrollers must be excluded from the selection. The horizontal diagnostic included a 12-pixel scrollbar strip; its movement is below the overlap tolerance and can become visible in output. No automatic cross-axis scrollbar removal is claimed.

## Provisional scrolling envelope

The tested envelope is stable integer translation on one axis with at least half of the moving body overlapping. Fixed bands may occupy up to a quarter of each edge. Changed dimensions, changed band boundaries, unreliable overlap, ambiguous repeated rows, axis changes, accepted rows that changed since acceptance, and resource limits pause rather than produce a guessed seam. The accepted partial result is retained. Fixed chrome must be present from the first accepted frame; a header that becomes sticky mid-capture pauses.

Current defaults are 30,000 output-axis pixels, 120 seconds, and 256 MiB of uncompressed output. Individual frames have an 8,192-pixel dimension limit and a 128 MiB limit. These are allocation guards, not a measured final encoder memory guarantee or an advertised product limit. Matching uses full-row fingerprints to identify exact translations, verifies those overlaps pixel for pixel, and samples approximate candidates. Any competing exact offset rejects the seam. Edge detection checks the full breadth and refines in-place equality against the solved translation. Strip replacement uses the entire in-place-equal edge run, which preserves white padding whose ownership two frames cannot establish. Real text, list, and virtualized content across apps must pass before this envelope is declared supported.

## Tests

The Xcode Debug test action passes 61 focused tests (result bundle `Test-Shotty-2026.09.25_19-52-48-+0200`). They cover display geometry and raster limits, frozen raster storage, pixel conversion, settled frame delivery, scrolling alignment and reconstruction in both axes, disk tiles, the accumulator, and the automation driver. Reconstructed synthetic output is compared pixel for pixel.

## Scrolling pipeline benchmark on studio

`Scripts/ScrollPipelineBenchmark.swift` runs the production accumulator, disk strips, live previews, final 800-pixel preview, and PNG encoder on deterministic synthetic pixels. These optimized Swift 6.4 runs used 20% overlapping steps on studio (M4 Max, 36 GiB RAM). Every final pixel was verified in a separate process; verification does not inflate the acquisition/export RSS below. Synthetic output and session directories were removed.

| Viewport pixels | Accepted output pixels | Frames / live previews | Total wall time | Peak RSS | PNG export | Accept p50 / p95 |
| --- | --- | --- | --- | --- | --- | --- |
| 2000 × 1500 | 2000 × 30000 | 96 / 30 | 6.66 s | 331.2 MiB | 4.16 s | 17.8 / 50.8 ms |
| 2560 × 1600 | 2560 × 26214 | 78 / 32 | 7.00 s | 409.8 MiB | 4.60 s | 24.2 / 62.3 ms |

An additional output row correctly pauses with `lengthLimit` or `memoryLimit`, preserving the accepted result. The wider output uses 268,431,360 bytes, 4096 below 256 MiB. The raw-byte cap is not an RSS cap: file mappings, viewport buffers and ImageIO consume additional memory. Each row is one final run; frame p50/p95 values are within that run. This benchmark excludes live stream/UI memory, reverse motion, approximate matches, and worst-case viewport dimensions.

Compared with the earlier pipeline runs, median acceptance improved from 55.6/73.6 ms to 17.8/24.2 ms, and total wall time fell from 9.77/10.92 seconds. Changes include direct typed byte conversion for strip writes and alignment work, so this comparison does not isolate one optimization. Export invalidates its assembled raw file immediately after encoding; existing mapped images remain valid. Measured physical-footprint peaks were 95.4 and 147.0 MiB; RSS also counts file-backed mappings.

## Integrated live capture resource checks

The long Preview fixture reached the raw-memory cap at 2200 × 29760 after 58 posted steps. Independent seam checks found all 317 full rows correct, with row 318 clipped by the cap and no seam defects. The accepted partial image remained exportable.

Before the latest strip-write optimization, an integrated run sampled RSS every approximately 50–60 ms through capture and export. The observed peak was 653.8 MiB, with about 582 MiB during export and 359 MiB after export. Apple's `leaks` reported a 260.5 MiB physical footprint, a 505 MiB peak footprint, and zero leaked bytes. Offline pipeline and live-path `leaks --atExit` checks also reported zero leaks. These are bounded test observations, not proof that every lifecycle path is leak-free. The app no longer keeps the assembled raw export after encoding, which also avoids retaining a second full-output file alongside its strips.

The temporary harness now awaits cancellation, stream shutdown and accumulator discard before replying to normal Quit. Cleanup is idempotent and blocks new capture actions until it finishes, preventing a close/reopen race. In a signed Release native check, Quit during an active 1520 × 1160 capture exited the process and removed that session's verified temporary directory. Older orphaned directories from earlier harness quits remain; launch-time recovery/sweeping is still part of the product lifecycle work. The final cleanup-only change passed Swift 6 typechecking and the signed Release build; the 61-test run above preceded that harness-only change.

## Encoder experiment, before the scope change

These single runs were recorded on both Macs before Markus moved fleet work to a separate PR. The m1 rows are historical evidence, not new m1 work. `Scripts/EncoderBenchmark.swift` generates deterministic noisy RGBA pixels and encodes one PNG with ImageIO into a private temporary directory, then removes it. Measurements use optimized Swift 6 binaries and `/usr/bin/time -l`; RSS includes synthetic source creation and encoding. None of these is a p50/p95 claim.

| Machine | Pixels | Raw bytes | Encode time | Peak RSS |
| --- | --- | --- | --- | --- |
| studio | 2,000 × 30,000 | 240,000,000 | 4.080 s | 252,461,056 bytes |
| m1 | 2,000 × 30,000 | 240,000,000 | 5.583 s | 252,231,680 bytes |
| studio | 5,120 × 13,000 | 266,240,000 | 4.909 s | 278,872,064 bytes |
| m1 | 5,120 × 13,000 | 266,240,000 | 6.077 s | 278,429,696 bytes |

The same inputs produced the same PNG byte sizes on both machines. This exercises the final encoder near the provisional byte cap, including the 30,000-pixel axis limit at a narrower width. It excludes stream buffers, stitching, compositing, editor caches, and a second decoded copy, so the integrated application's peak must still be measured before a product limit is accepted. At 5,120 pixels wide, 30,000 rows exceed the byte guard and must pause earlier.

To reproduce, compile `xcrun swiftc -O -swift-version 6 Shotty/Geometry/DisplayGeometry.swift Scripts/EncoderBenchmark.swift -o .build/encoder-benchmark`, then run `/usr/bin/time -l .build/encoder-benchmark 2000 30000` or `5120 13000`.

## Remaining before milestone 0 passes

1. Measure and improve frozen-set acquisition latency without weakening the proven frozen-preview and isolated-export semantics. Exercise display capture exclusion, mixed scale and negative-origin geometry, cancellation, and layout changes.
2. Complete the remaining browser long-page/nested/virtualized matrix, physical automatic-to-manual takeover and permission-loss checks. Vertical sticky fixtures, native table, horizontal strip, PDF, TextEdit, tall-region alignment, window movement, focus loss, partial retention, exported seams, and the pipeline benchmark have recorded evidence above. The integrated browser rejected opening the local HTML fixture; user opening is pending and no alternate route around that rejection is used.
3. Carry the measured viewport/raw-byte limits into production and verify the integrated application's resource use again after adding editor/export/session lifecycle. The capped PDF live/export peak is recorded above. Record warm p50/p95 and cold timings separately on studio.

m1 launch, per-Mac permissions, update continuity, and fleet performance are deferred to the separate fleet PR. A signed harness was copied to m1 before the scope change and its signature checked, but it was never launched there and no permission was granted.
