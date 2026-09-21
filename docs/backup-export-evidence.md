# Issue #5 evidence — private backup, previewed public export, deletion

Date: 2026-09-20. Scope: issue #5 only (backup/export/restore/deletion).
All fixtures are synthetic names; no real guest data exists anywhere.

## What was implemented

- `Packages/SeatingDomain/Sources/SeatingDomain/BackupExport.swift`
  - `SeatingBackup` — versioned (v1) full JSON backup of an event and a
    validating restore that remaps **every** identity (event, guests,
    preferences, variants, tables) to fresh UUIDs, so an import can never
    collide with or overwrite a stored event. Rejects >2 MiB input
    *before* parsing, unsupported versions, garbage/truncated files,
    duplicate guest/variant/table identities, dangling preference and
    assignment references, out-of-range seat counts and seat numbers,
    double-occupied seats and product-limit violations — all typed
    `ImportError`s with plain-language descriptions. Validation happens
    entirely before any value is produced, so a failed import cannot
    mutate anything.
  - `PublicSeatingExport` / `PublicExportBuilder` — the guest-facing list
    is a separate structure that physically has no field for pair
    preferences, unseated guests, UUIDs or other variants. Display names
    are single-lined (newlines/CRs collapsed) so a hostile name cannot
    forge extra seat rows; Unicode is preserved. Draft/conflict/
    unresolved warnings exist only in the host-facing preview, never in
    the shared text.
  - `PublicPDFLayout` — pure pagination + page-header rules (tested);
    the app renderer only draws what it returns.
- `EventStore` — `delete(eventID:)` and `deleteAll()` (SwiftData).
- `App/AppModel.swift` — `exportSelectedPlan`, `fullBackupData`,
  `validateRestore` (stage-only; nothing written), `commitRestore`
  (writes as a NEW event), `deleteEvent`, `deleteAllEvents` (+ launch
  key cleanup).
- `App/ShareTab.swift` — new Share tab: public preview sheet (exact
  shared text + private warnings section + text/PDF save), backup sheet
  that shows the privacy warning **before** the save panel opens,
  fileImporter restore flow behind a pre-read 2 MiB file-size guard with a
  summary/confirm/discard section, and double-confirmed destructive
  delete-event / delete-all dialogs that disclose the OS-backup and
  already-shared-copies limits. `SeatingPDFRenderer` paginates via the
  tested domain layout.

## Verification actually run (Linux, this host — not an iOS build)

- Docker `swift:6.0`, `swift test`: **53 tests, 0 failures** (was 35; +15
  issue-5 export/backup/rejection/pagination tests and 3 store delete
  tests compile-gated for Apple CI, which ran the full set — see below).
  Notable coverage: privacy leak checks (preferences/UUIDs/unseated
  guests never in export text), hostile Unicode/path name cannot forge
  lines, warnings never leak to shared text, deterministic text output,
  round-trip with identity remap, >2 MiB / version / garbage / truncated
  / duplicate-ID / dangling-reference / bad-count / double-seat /
  limit-bust rejections, rejected-restores-leave-store-identical and
  accepted-restore-is-independent (SwiftData suites run on macOS CI).
- `python3 -m unittest discover -s Scripts/tests`: 21 helper tests pass.
- pbxproj structural check: braces/parens balanced, every referenced
  object ID defined (new `ShareTab.swift` + share journey registered).

## Native CI (required gate)

The pinned macOS run (Xcode 26.0.1/17A400, iOS SDK 26.0, exact PR head)
compiles the app target including `ShareTab.swift` and the SwiftData
store suites and executes `SeatWeaveShareJourneyTests`: seat one of two
synthetic guests, preview the shared list (asserting the unseated guest
and the word "preference" are absent, the draft warning is present in
the preview section only), read the backup privacy warning, confirm
delete-event (event vanishes from the list), then delete-all after
creating a second event and verify an empty store. Simulator evidence,
not physical-device evidence.

## Honest limits

- The system save/open panels (`fileExporter`/`fileImporter`) are OS UI
  and are not automated; the UI journey exercises every in-app step up
  to and after them, and the domain tests exercise the actual export/
  restore bytes. Real device share-sheet behavior remains #6 evidence.
- The PDF renderer is compiled and shipped but its visual output has no
  automated pixel assertions; pagination/header rules are unit-tested.
- No networking is added anywhere; share/file ops are user-initiated OS
  panels only. Full backup contains private preferences **by design** —
  the app warns before export and never sends anything anywhere.
