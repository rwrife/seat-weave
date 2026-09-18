# Workflow evidence — issue #3 (2026-09-18)

Scope: the complete compact-phone seating workflow — event/guest/table
editing, selection-driven seating, confirmed swaps, unseat, session undo,
conflict/unresolved explanations, destructive-edit previews and variant
duplicate/rename/select/compare with relaunch into the selected plan.
This is compact-phone UI evidence, not adaptive-tablet, export, backup or
release evidence.

## What was implemented

- `App/AppModel.swift` — observable app state over the SwiftData store:
  event list, open/close, remembered event + selected variant (relaunch
  reopens into the same plan), alert surfacing of write failures.
- `App/EventListView.swift` — create/open local events, no accounts.
- `App/SeatingWorkspaceView.swift` — roster list with live seat labels,
  per-table seat lists, tap-to-select/tap-to-seat assignment, move,
  explicit occupied-seat swap confirmation naming both guests, unseat,
  session undo button, destructive guest deletion behind the domain
  preview, and a Pair-preferences section showing each rule's
  satisfied/conflict/unresolved reason plus visible contradictions.
- `App/WorkspaceSheets.swift` — add-table, resize-behind-unseat-preview,
  variant compare/duplicate/rename sheets, inline preference editor.
- `Packages/SeatingDomain`: `renameVariant` (label-only, undoable) and
  `VariantReporter.summarize` shared by the banner and comparison rows;
  `EventStore.allEvents()` for the event list; read-through previews on
  `PersistentSeatingController`.

Every operation is a plain tap/list control; nothing depends on dragging.
All fixtures are synthetic names (Aster/Basil/"Synthetic dinner").

## What was verified and where

Linux (this development host, Docker `swift:6.0`, Swift 6 language mode):

- `swift test` for `Packages/SeatingDomain`: **35 tests, 0 failures**
  (the 30 issue-1/2 tests plus 5 new issue-3 tests: rename-is-label-only,
  rename rejection, rename undo, summary counts, empty-plan summary).
- `python3 -m unittest discover -s Scripts/tests`: 21 helper tests pass.
- `SeatWeave.xcodeproj` structural check (balanced sections, every
  referenced object ID defined).

macOS CI (required gate, pinned Xcode 26.0.1 build 17A400, iOS SDK 26.0):

- The PR run executes the package tests (including the SwiftData
  `EventStoreTests` with the new `allEvents` test), the unsigned
  simulator build and both UI test targets against the exact PR head,
  uploading xcresult/provenance. Only a green run at the final head
  counts; results are recorded by the PR comment/artifact trail.
- `SeatWeaveSeatingJourneyTests` drives the full journey in the
  simulator: create -> add guests -> add table -> seat -> occupied-seat
  swap with confirmation -> undo -> unseat -> undo -> duplicate ->
  compare counts -> close -> relaunch into the selected plan copy with
  assignments intact. Synthetic guests only.

## Honest limits

- Simulator UI success is not physical-device evidence; physical iPhone
  validation remains open under issue #6.
- The compact layout is delivered here; the regular-width/tablet
  workspace and the accessibility VoiceOver/Dynamic Type evidence matrix
  are issue #4 scope.
- Export, backup and deletion-of-everything remain issue #5 scope.
- Linux cannot build SwiftUI; app-layer compile validation happens in
  the pinned macOS CI, and no simulator result is claimed until CI
  actually reports one.
