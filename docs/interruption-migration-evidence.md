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
- `InterruptedEditsTests.restoreFailureBoundary`: synthetic backup restores under a fresh ID; injected pre-write failure leaves source and event count intact and no partial copy or recovery point. Retry survives reopen; this is not an interrupted SQLite commit.
- `EventStoreTests.recoverySurvivesRestart`, `corruptRecoveryPointIsolated`, `oversizedSaveLeavesOldPoint`: recovery points and original remain available across reopen, corruption and failed oversized save.
- `PriorBuildStoreTests.migratePriorStore`: a synthetic SwiftData SQLite database from commit `027dec3` (before recovery points and recently-deleted models) survives opening under current models, a recovery-point save, and reopen. Exact-head pinned CI run [42170796076](https://github.com/rwrife/seat-weave/actions/runs/42170796076) passed historical writer and current reader (one test each; measured Xcode 26.0.1 build 17A400, SDK 26.0). SQLite stays local to CI runner, never uploaded.
- `Scripts/kill_commit_writer.py`: macOS-only subprocess test uses a test-only `EventStore.observingCommit` hook to block after both snapshot and recovery point are staged but before `ModelContext.save()`. Harness kills the process group with SIGKILL, reopens the private synthetic SQLite store, checks old snapshot and one recovery point, then saves/reopens again. Exact-head pinned CI run [42344714760](https://github.com/rwrife/seat-weave/actions/runs/42344714760) verified writer kill and clean reopen on macOS ARM64. This covers death immediately **before** commit, not a kill during SQLite's actual commit/fsync or physical power loss.

## 2026-11-08 combined verification

- Combined prior-build migration and pre-commit kill harness into single branch `fix/issue-21-combined-native-20261108`.
- Docker `swift:6.0` package: 84 tests passed; SwiftData-gated code excluded on Linux.
- Python CI helpers: 31 tests passed; offline source audit: zero violations; `bash -n Scripts/ci.sh` and `git diff --check` passed.
- Pinned macOS CI run [42452287597](https://github.com/rwrife/seat-weave/actions/runs/42452287597) SUCCESS on head `5ea60ffec7f8384d8bc986332a3f1811b222978e`; downloaded artifact provenance verified (`expected_sha=actual_sha`, `phase=complete`, `exit_status=0`, measured Xcode 26.0.1 build 17A400, SDK 26.0). Historical migration, pre-commit kill/reopen, domain suite (106 tests), compact UI (8 tests), large-text UI (1 test), and regular-width iPad UI (1 test) all passed.

## 2026-11-09 interruption matrix extension

- `Scripts/kill_commit_writer.py` now runs five isolated synthetic SQLite stores, each with a separate writer kill and reader reopen: assignment, swap, resize, duplicate, and private backup restore. `CommitKillTests` applies real domain commands before staging each new snapshot and recovery point; reader asserts exact old event (including guest identities and seat assignments), exactly one event/point, then checks a fresh save and reopen. Script orchestration has a Python unit check; actual SwiftData kill/reopen requires exact-head pinned macOS CI. The hook remains before `ModelContext.save()`; this does not prove death during SQLite commit/fsync, app force-quit on a physical iPhone, or power-loss durability.

## 2026-11-10 post-commit interruption matrix

- Five additional synthetic stores kill the writer **after** `ModelContext.save()` returns and before the process exits (assignment, swap, resize, duplicate, private restore). A new process must recover the just-committed snapshot and recovery point; restore must retain both source and imported event. Each store then saves once more and reopens. Together with the existing pre-commit matrix, this checks both sides of the save call, not the unobservable interior of SQLite commit/fsync. Synthetic expected bytes and SQLite files remain in private runner temporary storage, never uploaded. Actual mid-commit interruption, power loss and physical-device behavior remain open.
- Pinned macOS CI [42764547168](https://github.com/rwrife/seat-weave/actions/runs/42764547168) attempt 2 passed on exact head `719ff64342e6fcb702d1ec4cb2a4e504f5ba1c35`. Downloaded artifact provenance matched expected/actual SHA, phase=complete, exit_status=0; measured Xcode 26.0.1 (17A400), iPhoneOS SDK 26.0. Ten kill/reopen pairs passed; app build, 106 domain tests, 8 compact UI, 1 large-text UI and 1 regular-width iPad UI passed. Attempt 1 failed before tests when `simctl list devices available --json` timed out twice on the macOS runner. No physical-device claim.

## CI repairs

- Exact-head run [41448773777](https://github.com/rwrife/seat-weave/actions/runs/41448773777), head `2164d546b9919e89271af58bc994b042b3fa3e6e`: measured Xcode 26.0.1 (17A400) and SDK 26.0; domain tests and app build passed, but compact suite failed 1/8 at `SeatWeaveSeatingJourneyTests.swift:239`. Eight center swipes never made `recovery-browse-button` hittable.
- Exact-head run [41586081437](https://github.com/rwrife/seat-weave/actions/runs/41586081437), head `69e042c3a832587a62ca0e68d6fc29e8abf481ea`: same test failed 1/8 at line 243. Downloaded xcresult's compact log includes the failure-time accessibility tree: `Guests` tab selected and its roster visible, `Share` not selected, scroll bar at 0%. The left-gutter drag started at 82% of collection frame (y≈585), which overlaps the tab bar beginning at y=584; first gesture selected Guests rather than scrolling Share. Repair keeps both drag endpoints inside the visible content band (65% to 15%) and retains hierarchy diagnostics on failure.

## Remaining acceptance

Real force-quit during SQLite fsync and physical-device power loss remain unverified; this test only covers process termination before `ModelContext.save()`. Prior-build store migration, multi-operation pre-commit kill/reopen, and injected-failure UI restore have each passed pinned CI on separate heads; the combined branch requires its exact-head run. Physical-device data-loss, offline and accessibility checks tracked by #6/#22. Signing/TestFlight tracked by #7. No private names, preferences or backup bytes in public artifacts; full private backup must stay local.
