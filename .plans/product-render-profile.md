# Production render and export profile

Measured on 2026-09-25 on Studio, Apple M4 Max, 36 GiB unified memory, macOS 27.0 build 26A428. The benchmark targets macOS 26 and uses Swift 6 optimized whole-module compilation. This is an offline CLI production-pipeline measurement, not a native app memory profile or UI responsiveness test.

The 256 MiB raster cap does not imply a 256 MiB process peak. After the spotlight optimization, one 8192×8192 edited native PNG export peaked at 897.2 MiB RSS and 524.3 MiB physical footprint. Three sessions with concurrent edited thumbnails and exports peaked at 2728.8 MiB RSS and 1011.0 MiB physical footprint. The concurrent pipeline remains the larger resource concern.

## Method

`Scripts/ProductRenderBenchmark.swift` compiles the actual capture store, annotation renderer, export service, and model dependencies. Each process creates a unique private temporary directory, persists one synthetic capture, updates its document with two localized blurs, one overlapping pixelation, and one rounded spotlight, exports, checks ImageIO format/dimension metadata, discards the session, and deletes its temporary output. It never opens the live Session directory. Repeated cases reuse the same store and export actors for three create/edit/export/discard cycles. Concurrent cases use separate actor calls for the edited thumbnail and export and await both before cleanup.

Source scale is 2. Native output preserves source dimensions; logical output halves both dimensions. The long image is 2000×30000, 228.9 MiB RGBA. The square image is 8192×8192, exactly 256 MiB RGBA and the export pixel-budget boundary. Synthetic blocks, gradients, and stripes deliberately avoid an additional fixture buffer. Fixture creation and source PNG persistence are included in the create timing. Fixture buffers are released before export starts, consistent with approximately 27 MiB RSS / 11 MiB footprint after initial creation. Source PNGs are 2.7–2.9 MiB, so this fixture does not exercise the largest compressed PNG buffers or photograph/noise entropy.

Export seconds include decoding, rendering, optional resizing/JPEG matte, encoding, atomic file write, and receipt hashing. Concurrent export seconds include completion of both export and thumbnail work. `/usr/bin/time -l` measures the complete process peak, including fixture creation. `task_info` samples RSS and physical footprint between completed operations, with no forced allocator purge. Metadata verification does not decode a second full output image. RSS includes resident pages outside the charged physical footprint; divergent growth does not establish an allocation leak.

```sh
xcrun swiftc -O -whole-module-optimization -swift-version 6 -strict-concurrency=complete -parse-as-library -target arm64-apple-macos26.0 Shotty/Storage/*.swift Shotty/Export/*.swift Shotty/Editor/Annotation.swift Shotty/Editor/DocumentRenderer.swift Shotty/Preferences/PreferenceValues.swift Shotty/Scrolling/ScrollAlignment.swift Shotty/Scrolling/ScrollStitchSession.swift Scripts/ProductRenderBenchmark.swift -o /tmp/shotty-product-render-benchmark
/usr/bin/time -l /tmp/shotty-product-render-benchmark 2000 30000 png native 1 serial
/usr/bin/time -l /tmp/shotty-product-render-benchmark 8192 8192 png native 3 concurrent
```

The arguments are width, height, `png|jpeg`, `native|logical`, repetitions from 1 through 3, and `serial|concurrent`. All eight dimension/format/scale combinations below were run in separate processes sequentially. Concurrent means two production actors within one process, not simultaneous benchmark processes. No Xcode build or browser interaction was performed by this benchmark task.

## Baseline before spotlight optimization

| Source | Format / scale | Create s | Export s | Process wall s | Output MiB | Peak RSS MiB | Peak footprint MiB | Post-discard footprint MiB |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 2000×30000 | png / native | 0.340 | 0.787 | 1.34 | 3.5 | 1195.8 | 866.6 | 175.4 |
| 2000×30000 | png / logical | 0.332 | 0.709 | 1.07 | 4.4 | 1194.0 | 865.0 | 177.8 |
| 2000×30000 | jpeg / native | 0.330 | 0.644 | 1.00 | 8.0 | 1194.0 | 865.1 | 183.8 |
| 2000×30000 | jpeg / logical | 0.334 | 0.668 | 1.03 | 3.7 | 1196.1 | 867.2 | 175.3 |
| 8192×8192 | png / native | 0.396 | 0.873 | 1.30 | 3.7 | 1343.8 | 960.7 | 178.4 |
| 8192×8192 | png / logical | 0.371 | 0.775 | 1.18 | 4.6 | 1342.5 | 959.4 | 178.7 |
| 8192×8192 | jpeg / native | 0.371 | 0.716 | 1.12 | 8.9 | 1342.5 | 959.3 | 186.1 |
| 8192×8192 | jpeg / logical | 0.364 | 0.685 | 1.08 | 4.1 | 1342.5 | 959.3 | 177.3 |

All eight outputs had the expected type and dimensions. Logical export still renders the full native image before resizing, so its peak is almost unchanged in this baseline.

## Three-session release measurements

Values are sampled immediately after session discard and output deletion. All concurrent thumbnails were 560×560.

| Renderer | Pipeline | Session | Create s | Export / combined s | Post-discard RSS MiB | Post-discard footprint MiB |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| Baseline | 2000×30000 serial | 1 | 0.338 | 0.824 | 275.7 | 177.1 |
| Baseline | 2000×30000 serial | 2 | 0.333 | 0.807 | 504.8 | 177.2 |
| Baseline | 2000×30000 serial | 3 | 0.337 | 0.827 | 733.8 | 177.6 |
| Baseline | 8192×8192 concurrent | 1 | 0.377 | 1.030 | 562.8 | 180.0 |
| Baseline | 8192×8192 concurrent | 2 | 0.380 | 1.053 | 1076.0 | 180.2 |
| Baseline | 8192×8192 concurrent | 3 | 0.376 | 1.050 | 1592.2 | 183.4 |
| Optimized spotlight | 2000×30000 serial | 1 | 0.334 | 0.796 | 332.0 | 233.4 |
| Optimized spotlight | 2000×30000 serial | 2 | 0.324 | 0.760 | 560.9 | 233.3 |
| Optimized spotlight | 2000×30000 serial | 3 | 0.325 | 0.755 | 790.0 | 233.8 |
| Optimized spotlight | 8192×8192 concurrent | 1 | 0.369 | 0.919 | 623.1 | 240.3 |
| Optimized spotlight | 8192×8192 concurrent | 2 | 0.365 | 0.946 | 1139.8 | 244.0 |
| Optimized spotlight | 8192×8192 concurrent | 3 | 0.370 | 0.921 | 1653.8 | 245.0 |

RSS does not plateau over these three sessions. Physical footprint is nearly steady: baseline serial increases only 0.5 MiB after its first warmed session, baseline concurrent increases 3.4 MiB, optimized serial increases 0.4 MiB, and optimized concurrent increases 4.7 MiB. This is evidence against one source-sized charged allocation retained per cycle, but three short sessions do not prove long-run behavior. The optimized renderer has a higher warmed post-session footprint in this run, roughly 240–245 MiB for concurrent work versus 180–183 MiB before; lower peak memory does not mean every memory metric decreases.

## Spotlight follow-up

`DocumentRenderer.drawSpotlights` now uses even-odd clipping of spotlight complements and one dim fill instead of a full-size RGBA overlay. The benchmark was rebuilt against that production change. Annotation correctness and region/full-render equivalence remain the native renderer tests' responsibility; this harness checks metadata only.

| Case | Baseline peak RSS MiB | Optimized peak RSS MiB | Baseline peak footprint MiB | Optimized peak footprint MiB | Baseline export s | Optimized export s |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 2000×30000 native PNG, 3 serial sessions | 1665.7 | 1265.2 | 878.4 | 691.5 | 0.819 | 0.770 |
| 8192×8192 native PNG, 1 session | 1343.8 | 897.2 | 960.7 | 524.3 | 0.873 | 0.844 |
| 8192×8192 native PNG + thumbnail, 3 sessions | 3122.4 | 2728.8 | 1250.4 | 1011.0 | 1.044 | 0.928 |

Export times in the follow-up table are means for repeated cases. The single large PNG peak decreases by 446.6 MiB RSS and 436.4 MiB footprint. The concurrent three-session peak decreases by 393.6 MiB RSS and 239.4 MiB footprint. Scheduling changes the overlap between two actors, so concurrent peak comparisons should be treated as indicative, not exact allocation accounting. A prior exploratory pass showed the same order of magnitude; these are not statistically sampled latency distributions.

## Rejected thumbnail-strip experiment

A follow-up implemented edited thumbnails as eight destination-row strips with four destination pixels of source overlap. Each strip used the existing source-space region renderer, then the existing CIContext with a globally aligned `CILanczosScaleTransform`. This avoided a full-size edited thumbnail intermediate. Per-strip autorelease pools and an outer thumbnail pool released temporary objects. The full source decode remained allowed.

The experiment compiled with optimized Swift 6. Offline parity covered 96×96, 1200×1800, 1800×1200, and 2000×6000 textured fixtures, each with and without crop. No-effect/vector/blur/spotlight outputs matched a full canonical render downsampled with the same Lanczos filter within one channel value. Default even-size pixelation matched within two channel values. Odd 35-pixel cells exposed existing region/full-render differences at discrete cell edges: mean channel error was 0.05–0.17/255, with sparse maxima of 81–132/255. In the 1200×1800 cases, strip-boundary mean error was 0.109 versus overall 0.125 uncropped and 0.096 versus 0.134 cropped. The errors did not concentrate at strip boundaries. These experiments did not change the production effect algorithm.

The memory result did not justify keeping the implementation:

| 8192×8192 native PNG + edited thumbnail, 3 sessions | Peak RSS MiB | Peak footprint MiB | Post-discard footprint MiB, sessions 1 / 2 / 3 | Mean combined seconds |
| --- | ---: | ---: | --- | ---: |
| Kept full-render thumbnail after spotlight optimization | 2728.8 | 1011.0 | 240.3 / 244.0 / 245.0 | 0.928 |
| Strip thumbnail | 1680.9 | 1110.5 | 362.1 / 367.3 / 368.0 | 1.248 |
| Strip thumbnail with CIContext.clearCaches() on completion | 1692.2 | 1111.5 | 364.5 / 365.8 / 368.3 | 1.229 |

The strip path stabilized post-discard RSS near 383–391 MiB, but increased charged peak memory by about 100 MiB and warmed physical footprint by about 120 MiB. It also increased combined latency by roughly one-third. Calling `clearCaches()` once when the thumbnail completed did not improve those costs. A 2000×30000 three-session concurrent strip run peaked at 1469.4 MiB RSS / 1000.3 MiB footprint and took 1.053 seconds on average; no corresponding full-render concurrent baseline was measured for that shape.

The strip method, store integration, and its parity test were removed. Production retains the simpler full-render thumbnail path and the measured spotlight optimization. The RSS decrease alone was insufficient evidence of a resource improvement. A future thumbnail change must improve charged memory or latency as well as limiting individual raster allocations. The temporary test passed Swift 6 typechecking; native XCTest execution was not claimed for this rejected experiment.

## Remaining work suggested by the measurements

- Give edited-thumbnail work a bounded raster path. `CaptureSessionStore.thumbnail(for:)` currently decodes and renders the entire source before scaling to at most 560 pixels. A small thumbnail can therefore overlap another full-resolution export. A future appropriately scaled document/source path would need to preserve effect widths and annotation geometry. The exact source-space strip experiment above was rejected because it increased charged memory and latency.
- Coordinate heavy image operations across the store, exporter, and editor preview actors. Each actor serializes its own work, but the actors can allocate large working images concurrently. This benchmark measures only store/export overlap; visible editor previews may add another participant.
- Keep the distinction between a per-image dimension guard and a peak-memory budget explicit. Consider source-area plus active-operation budgeting after choosing an acceptable app peak. Reducing output size alone does not avoid the initial full-resolution render.
- For file exports, evaluate streaming directly to the atomic staging URL as source persistence already does. Clipboard encoded-data requests still need data in memory. The highly compressible fixtures here cannot quantify the worst compressed-buffer saving.
- Use a targeted native Instruments allocation/VM trace if resident-page reclamation or warmed footprint remains a concern. This run does not identify the owners of the large RSS/footprint difference and should not be called a leak test.

All runs completed without swaps or resource-limit failures. No ordinary 5K queue/thumbnail-cache acceptance claim, memory-pressure claim, idle-CPU claim, pixel-equivalence claim, or UI responsiveness claim follows from this offline benchmark.
