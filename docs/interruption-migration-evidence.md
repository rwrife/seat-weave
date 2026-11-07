# Issue #21: interruption, failed-save and migration evidence

Synthetic fixtures only. This page records test procedures; PR checks and exact-head CI artifact must be read before marking native gates passed.

## Reproduce

- `docker run --user "$(id -u):$(id -g)" -e HOME=/tmp -v "$PWD:/work" -w /work/Packages/SeatingDomain swift:6.0 swift test --parallel` (Linux: SwiftData blocks and XCUITest do **not** compile/run).
- `python3 -m unittest discover -s Scripts/tests -v` (CI helpers).
- Pinned macOS workflow `Scripts/ci.sh` via `.github/workflows/ci.yml`: checks measured Xcode 26.0.1 (17A400), iPhoneOS SDK 26.0, Swift 6, app build and simulator tests. Consult exact-head provenance and run result; no physical-device inference.

## Boundaries and contracts

- `InterruptedEditsTests.commandBoundaries`: isolated on-disk SwiftData store; reopen handle after assignment, swap, resize and duplicate to model process interruption *after* committed save. Inject pre-write out-of-space failure; verify controller's state and disk remain old, retry succeeds. Restore private v1 backup as new event; reopen and compare source, restored record and recovery points. Reopening a store handle is **not** an OS force-quit at an in-progress SQLite commit; that narrower crash window requires a device/process-kill test.
- `SeatWeaveSeatingJourneyTests.testInjectedSaveFailureDoesNotClaimSuccessAndRetrySurvivesRelaunch`: test-only `-ui-testing -failNextSave YES` arms one pre-write failure on first open event. UI must show Problem alert, retain empty seat; terminate and reopen to confirm disk unchanged, retry seating and reopen to confirm commit. Then preview a committed recovery point, restore it as a separate event, and verify both event rows remain after another relaunch. Injection never writes partially and is disabled without `-ui-testing`.
- `BackupExportTests`: v1 is earliest shipped backup and **only** supported version; no older supported version exists to migrate. v0 and v99 reject with explicit explanation; the version is checked before decoding event data, so a future event schema still yields update guidance instead of a misleading corruption error. Missing version is rejected. Duplicate guest/preference/variant/table identities, dangling references, malformed/truncated and >2 MiB documents reject before any store mutation. Duplicate seating of one guest rejects as well. Restore is separate preview then save-as-new event.
- `InterruptedEditsTests.restoreFailureBoundary`: a synthetic private backup restores under a fresh ID; a one-shot pre-write out-of-space failure leaves source and event count intact, with no restored copy or recovery point after reopening the on-disk store. Retry saves a new copy and its recovery point; both source and copy survive another reopen. This is pre-write injection, **not** an interrupted SQLite commit. Linux SwiftData exclusion means this test needs exact-head macOS CI before claiming native execution.
- `EventStoreTests.recoverySurvivesRestart`, `corruptRecoveryPointIsolated`, `oversizedSaveLeavesOldPoint`: recovery points and original remain available across reopen, corruption and failed oversized save.
- `Scripts/kill_commit_writer.py`: macOS-only subprocess test uses a test-only `EventStore.observingCommit` hook to block after both snapshot and recovery point are staged but before `ModelContext.save()`. Harness kills the process group with SIGKILL, reopens the private synthetic SQLite store, checks old snapshot and one recovery point, then saves/reopens again. This covers death immediately **before** commit, not a kill during SQLite's actual commit/fsync or physical power loss. Exact-head native result pending.
- PR #35 prior-build fixture: historical SQLite writer at pinned `027dec3`, current schema reader, recovery save and reopen passed native run [41979344766](https://github.com/rwrife/seat-weave/actions/runs/41979344766); draft remains open for incomplete interruption acceptance.

## 2026-11-07 local verification

- Docker `swift:6.0` package: 84 tests passed; SwiftData-gated code excluded on Linux.
- Python CI helpers: 31 tests passed; offline source audit: zero violations; `bash -n Scripts/ci.sh` and `git diff --check` passed.
- Native kill/reopen and complete iOS matrix require pinned macOS CI on this exact PR head. No SQLite or backup bytes may be uploaded; only synthetic test logs are artifacts.

## CI repairs

- Exact-head run [41448773777](https://github.com/rwrife/seat-weave/actions/runs/41448773777), head `2164d546b9919e89271af58bc994b042b3fa3e6e`: measured Xcode 26.0.1 (17A400) and SDK 26.0; domain tests and app build passed, but compact suite failed 1/8 at `SeatWeaveSeatingJourneyTests.swift:239`. Eight center swipes never made `recovery-browse-button` hittable.
- Exact-head run [41586081437](https://github.com/rwrife/seat-weave/actions/runs/41586081437), head `69e042c3a832587a62ca0e68d6fc29e8abf481ea`: same test failed 1/8 at line 243. Downloaded xcresult's compact log includes the failure-time accessibility tree: `Guests` tab selected and its roster visible, `Share` not selected, scroll bar at 0%. The left-gutter drag started at 82% of collection frame (y≈585), which overlaps the tab bar beginning at y=584; first gesture selected Guests rather than scrolling Share. Repair keeps both drag endpoints inside the visible content band (65% to 15%) and retains hierarchy diagnostics on failure. Fresh exact-head native run still required; no iPad/large-text proof from either failed run.

## Remaining acceptance

Death during SQLite's actual commit/fsync, and physical-device power-loss behavior remain unverified; this PR only tests a process killed immediately before `ModelContext.save()`. Prior-build store migration and injected-failure UI restore have passed pinned CI on separate exact heads; the combined head still needs a native run. Physical-device data-loss, offline and accessibility checks tracked by #6/#22. Signing/TestFlight tracked by #7. No private names, preferences or backup bytes in public artifacts; full private backup must stay local.
