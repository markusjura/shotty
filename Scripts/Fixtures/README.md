# Scrolling fixtures

Synthetic developer fixtures for exercising scrolling capture and stitching. They contain generated text only and are not part of the Shotty product target.

## Native fixture

Build with `Scripts/Fixtures/build-scroll-fixture.sh`. It compiles `ShottyScrollFixture.swift` with `swiftc` into `.build/fixtures/ShottyScrollFixture.app`, ad-hoc signed with bundle ID `local.markus.ShottyScrollFixture`. The app needs no permissions.

The fixed 820 x 640 pt window, titled "Shotty Scrolling Fixture", has a control strip, a white padded header, an ordinary `NSScrollView`, and a white padded footer. Controls:

- `Advance 80`, `Reverse 40`, and `Reset` move the active scroller instantly and print `mode=<mode> offset=<points>` to stdout.
- `Vertical` shows a 6000 pt document of rows `V0001...` with section headings, two-line rows, and blank rows (every index where `index % 7 == 3`).
- `Horizontal` shows a 6000 pt wide document of columns `H0001...` with the same blank rule.
- `Table` shows a real `NSTableView` with a native sticky column header and 270 rows `T0001...` at 22 pt.
- `Unstable` shows a counter over the scrolled area that changes every 0.25 s. It is off by default; nothing else animates.

Launch options: `-mode vertical|horizontal|table` and `-scrollers system|legacy|hidden`. System overlay scrollers may fade in and out, so use `legacy` or `hidden` when edge pixels must stay deterministic.

`ShottyScrollFixture --render-document vertical|horizontal <scale> <output.png>` renders the complete document offline as a reference for row identity and seam inspection. Offscreen text rasterization can differ slightly from on-screen pixels, so compare structure and IDs, not exact bytes.

On macOS 26 and later, the table header uses a translucent scroll edge effect, so rows under it blur into the header. That is real system behavior worth covering, not a fixture bug.

## Browser fixture

Open `scroll-fixture.html` directly or serve this directory. Header buttons select the mode, which is also reflected in the URL hash:

- `#page`: long prose `P0001...` with headings, blank spacers, and a sticky header and footer.
- `#nested`: a bordered inner scroll region `N0001...` between static text; the page itself does not scroll.
- `#thread`: a virtualized thread of 3000 messages `M0001...` with deterministic heights. Only messages near the viewport exist in the DOM.
- `#horizontal`: an `overflow-x` region of columns `C0001...`.

`Advance 80`, `Reverse 40`, and `Reset` scroll the active scroller instantly. `Unstable` toggles a ticking counter. `body[data-mode]`, `body[data-offset]`, and `body[data-rendered]` (thread DOM item count) expose state for harnesses.

## Other native applications

Generate a tall, single-page PDF with `swift Scripts/Fixtures/MakePDFFixture.swift /tmp/Shotty-PDF-Fixture.pdf`. Open it in Preview at Actual Size and select the document body, excluding app chrome and the scrollbar. Its 190 numbered rows are synthetic.

Generate plain text with `python3 Scripts/Fixtures/MakeTextFixture.py /tmp/Shotty-Text-Fixture.txt`. Open it in TextEdit to exercise another app without accessibility adapters. Its 300 numbered rows are synthetic.

The native fixture's Verification menu explicitly activates its app or moves its window 20 points. These actions let Computer Use exercise actual WindowServer focus and geometry changes, because tool-dispatched button clicks can operate on inactive windows without changing system focus.
