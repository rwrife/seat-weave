# Issue #20 — selected-plan printed exports

Table-by-table and locale-aware alphabetical lookup both retain one row per seated identity, including identical names. Locale-equivalent names tie-break by table declaration and seat order, not private UUID. Both formats contain only the selected plan's seated names, table/seat labels and public heading. Preferences, warnings, unseated roster and other variants remain host-only. Empty tables produce no guest-facing roster entries.

US Letter and A4 are explicit choices. The native renderer measures and wraps each grapheme within 48-point margins, paginates the actual measured lines and repeats headings. PDFKit supplies a separate in-app PDF preview before saving; text preview uses the same selected layout.

## Actual verification on 2026-10-09

- Linux Docker `swift:6.0` package probe: 75 tests passed, including alphabetical duplicate-name ordering, paper dimensions and maximum 40-guest/six-table row coverage. This does **not** prove native PDF geometry or rendering.
- `python3 -m unittest discover -s Scripts/tests -v`: 31 tests passed.
- Docker Swift app/UI syntax parse and `bash -n Scripts/ci.sh`: passed. Parsing is not Apple typechecking.
- Exact-head pinned macOS native validation: pending. CI must measure Xcode 26.0.1/17A400 and SDK 26.0, run the Share preview journey, generate four synthetic multipage PDFs plus an empty-plan PDF using the actual app renderer, and check page sizes, repeated page numbers, all 40 synthetic markers exactly once and privacy exclusions. It uploads PDFs and first/last page PNGs for visual review.
- Representative multipage PDF visual inspection, native test results and exact-head provenance remain pending. Issue #20 remains open; PR uses `Refs #20` until these gates pass.
- No physical device, signing, TestFlight or manual VoiceOver evidence is claimed.

## CI repair — 2026-10-10

Run [37935907617](https://github.com/rwrife/seat-weave/actions/runs/37935907617) measured Xcode 26.0.1 (17A400), SDK 26.0, built the app and passed all five compact simulator journeys. It then failed at `pdf_fixtures`: the simulator app produced no PDF files. The hand-authored project had no `SWIFT_ACTIVE_COMPILATION_CONDITIONS` for Debug, and its compiler invocation lacked `-D DEBUG`; both fixture entry point and writer were compiled out by `#if DEBUG`.

The project now defines `DEBUG` only for Debug, preserving the Release exclusion. A configuration regression test fails on the original project and passes with this repair.

## Pagination repair — 2026-10-11

Exact-head run [38029569642](https://github.com/rwrife/seat-weave/actions/runs/38029569642) passed on Xcode 26.0.1 (17A400), SDK 26.0; provenance expected/actual `55e3673bfa54cef539e67fd65884488a742fd545`, phase complete, exit 0. Native app, compact/large-text/regular journeys and four 40-guest PDFs plus empty-plan PDF passed content checks. But PDF text inspection found guest rows straddling pages. Marker-count checks missed this because they flattened the document. The renderer now paginates whole measured guest rows; a row taller than one page is the sole documented split exception. Domain regression tests exercise the page-boundary/oversized cases. Native fixtures append a distinct end marker to each synthetic name; PDFKit checks start and end appear on the same page, across both layouts and papers. Linux Swift 6.0 package tests: 77 passed; Python helper tests: 32 passed. These Linux checks do not prove native rendering. Fresh exact-head native results and visual review are still required before merge.

## Share journey picker coverage — 2026-10-13

PR #26 exact-head run 38115964222 verified pagination, PDFKit content checks, and geometric non-overlap across all 17 pages. However, the Share UI journey exercised only default options. The journey now explicitly interacts with the layout picker (`Alphabetical guest lookup`) and paper picker (`A4`), and asserts that the preview text reflects the chosen lookup format (`<Guest> — <Table>, Seat <N>`).

## Large-text scroll stall — 2026-10-14

Exact-head run [38374520424](https://github.com/rwrife/seat-weave/actions/runs/38374520424) measured Xcode 26.0.1 (17A400), SDK 26.0; four compact journeys and the new Share picker journey passed. The AX5XL journey then failed at `export-preview-button` after its 90 s budget. Its failure hierarchy showed the new menu-style `Guest-facing layout` picker mid-band at y 376–617 and `Paper size` at y 620, with the list's scroll bar frozen at 58% for the whole budget: the center-anchored band drags landed on the picker buttons instead of panning the List. Both drag helpers now start inside the List's right gutter (app width − 8 pt, outside the padded row content and away from the left edge-swipe) whenever the export picker exists, leaving every other screen's proven center drag untouched. This is still an unproven local theory until the next exact-head native run.

## Native rerun

Pending exact-head CI; Linux parsing and package tests are not iOS typecheck or simulator evidence.
