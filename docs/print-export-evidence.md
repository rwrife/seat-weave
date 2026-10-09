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
