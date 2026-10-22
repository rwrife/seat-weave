# Issue #21: interruption, failed-save and migration evidence

Synthetic fixtures only. This page records test procedures; PR checks and exact-head CI artifact must be read before marking native gates passed.

## Reproduce

- `docker run --user "$(id -u):$(id -g)" -e HOME=/tmp -v "$PWD:/work" -w /work/Packages/SeatingDomain swift:6.0 swift test --parallel` (Linux: SwiftData blocks and XCUITest do **not** compile/run).
- `python3 -m unittest discover -s Scripts/tests -v` (CI helpers).
- Pinned macOS workflow `Scripts/ci.sh` via `.github/workflows/ci.yml`: checks measured Xcode 26.0.1 (17A400), iPhoneOS SDK 26.0, Swift 6, app build and simulator tests. Consult exact-head provenance and run result; no physical-device inference.

## Boundaries and contracts

- `InterruptedEditsTests.commandBoundaries`: isolated on-disk SwiftData store; reopen handle after assignment, swap, resize and duplicate to model process interruption *after* committed save. Inject pre-write out-of-space failure; verify controller's state and disk remain old, retry succeeds. Restore private v1 backup as new event; reopen and compare source, restored record and recovery points. Reopening a store handle is **not** an OS force-quit at an in-progress SQLite commit; that narrower crash window requires a device/process-kill test.
- `SeatWeaveSeatingJourneyTests.testInjectedSaveFailureDoesNotClaimSuccessAndRetrySurvivesRelaunch`: test-only `-ui-testing -failNextSave YES` arms one pre-write failure on first open event. UI must show Problem alert, retain empty seat; terminate and reopen to confirm disk unchanged, retry seating and reopen to confirm commit. Injection never writes partially and is disabled without `-ui-testing`.
- `BackupExportTests`: v1 is earliest shipped backup and **only** supported version; no older supported version exists to migrate. v0 and v99 reject with explicit explanation; duplicate guest/preference/variant/table identities, dangling references, malformed/truncated and >2 MiB documents reject before any store mutation. Duplicate seating of one guest now rejects as well. Restore is separate preview then save-as-new event.
- `EventStoreTests.recoverySurvivesRestart`, `corruptRecoveryPointIsolated`, `oversizedSaveLeavesOldPoint`: recovery points and original remain available across reopen, corruption and failed oversized save. Actual app/data-schema upgrade migration using a persisted previous-build SwiftData fixture is **not** proven by a same-build reopen. Do not claim it passed.

## Remaining acceptance

Real force-quit during SQLite commit, prior-build on-disk schema fixture, and full UI restore following injection remain unverified. Physical-device data-loss, offline and accessibility checks tracked by #6/#22. Signing/TestFlight tracked by #7. No private names, preferences or backup bytes in public artifacts; full private backup must stay local.
