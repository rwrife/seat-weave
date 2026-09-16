# Domain evidence — issue #2 (2026-09-16)

Scope: local events, seating commands and explainable preferences. This is
model/engine/persistence evidence, not seating UI, export or release evidence.

## What was verified and where

Linux (this development host, Docker `swift:6.0`, Swift 6 language mode):

- `swift test` for `Packages/SeatingDomain`: **30 tests, 0 failures**
  (26 issue-2 behavior/rule/variant/persistence-controller tests plus the
  4 issue-1 contract tests). All fixtures are synthetic names.
- `python3 -m unittest discover -s Scripts/tests`: 18 helper tests pass.

macOS CI (required gate, pinned Xcode 26.0.1 build 17A400, iOS SDK 26.0):

- The PR run executes the same package tests plus the unsigned simulator
  build and launch smoke against the exact PR head and uploads
  xcresult/provenance artifacts. Exact run/attempt, SHA, simulator and
  artifact IDs for the merged head are recorded by the PR comment trail;
  only a green run at this PR's final head counts.
- SwiftData store tests (`EventStoreTests`) compile and run only on Apple
  platforms and are part of the package test count there.

## Commands covered by behavior tests

- assign / move / explicit-confirmed swap / unseat, all atomic: rejected
  commands leave the model identical (equality-checked) and never report
  success; occupied seats refuse, double-assignment refuses, unknown
  guests/tables/seats and out-of-range seat numbers refuse.
- Session undo unwinds every command kind in order and then fails cleanly.
- Resize requires a preview; the preview must still match when applied;
  unconfirmed or stale previews mutate nothing; applied resizes unseat only
  displaced guests.
- Guest deletion requires a fresh matching preview and clears preferences
  and assignments in every variant.
- Duplicate variants remap table UUIDs; later table/assignment edits stay
  independent while guests and preferences remain event-shared.
- Rule engine returns satisfied/conflict/unresolved with plain-language
  reasons; either guest unseated is unresolved for every rule kind;
  contradictory pair rules remain visible with both statuses listed.
- Randomized small command sequences (deterministic seeds) re-check the
  occupancy invariant after every step.
- Persistence controller: successful commands persist; a failed save keeps
  the previous visible state and surfaces failure; rejected commands never
  reach the saver.

## CI repairs during this issue

Run 35161312959 (head 45d3032) failed only in `simulator_selection`: the
first `xcrun simctl list devices available --json` stalled past its 30
seconds on a hosted runner (the same transient class fixed for boot in
PR #8). `select_simulator.py` now retries enumeration once with the same
30-second bound before failing.

Run 35162091105 (head 00d077a) proved the retry itself exposed a latent
bug: when the first attempt timed out, the successful retry wrote the
devices JSON without flushing, and the child interpreter's exit-time
finalization of the still-referenced file handle produced an empty file;
the next phase then died with `Expecting value: line 1 column 1`. The
sequence was reproduced locally with a fake stalling `xcrun` (empty file
without the fix, valid JSON with it). Fixes: `main()` now flushes the
devices JSON immediately, and a subprocess-level helper test drives the
real CLI against a fake one-shot-stalling `xcrun` (with a test-only
`SEATWEAVE_SIMCTL_TIMEOUT_SECONDS` override). Helper coverage is 21
tests, all passing on Linux, including the regression test. No CI
timeout budget was loosened.

## Not claimed

- No seating UI, export, backup, release, signing, TestFlight or
  physical-device behavior exists yet; those belong to issues #3–#7.
- Linux Docker runs prove the pure-Swift domain only; they are not an iOS
  build. Only the pinned macOS CI run at this head provides simulator
  evidence, and no physical-device evidence substitutes for it.
