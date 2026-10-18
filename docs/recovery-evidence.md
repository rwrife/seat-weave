# Automatic recovery and deletion evidence (issue #16)

Date: 2026-10-18
Scope: Automatic local recovery snapshots, bounded retention, preview/restore, recently-deleted 14-day recovery, permanent deletion, and privacy.

## Contract and bounds

- **Snapshot cadence**: every successful `EventStore.save(_:)` writes a versioned local recovery point atomically with the updated event.
- **Retention count and age**: up to **10 recovery points** per event, pruned oldest-first on every save and read. Points older than **14 days** are purged.
- **Storage bounds**: 2 MiB per snapshot (`SeatingBackup.maximumDocumentBytes`), capped at ~20 MiB per event for recovery points. Writes exceeding the limit fail with `StoreError.snapshotTooLarge` before altering the current event or pruning prior points.
- **Unavailable storage**: when container initialization or writes fail, `AppModel` surfaces the error in `alertMessage` and leaves the in-memory event and previous stored state intact.
- **Preview and restore**: hosts browse timestamps and counts (guests, private preferences, plans). Previews re-validate without writing. Restoring remaps UUIDs to instantiate a **new event**; the current event is never overwritten.
- **Recently deleted**: ordinary deletion moves the event to `Recently Deleted` for **14 days**. Hosts can restore it from the event list or Share tab.
- **Permanent deletion**: explicitly removes the event, its recently-deleted copy, and all recovery snapshots from the device in one transaction. Confirmed **Delete ALL** removes all active events, recently-deleted copies, and recovery points.
- **Privacy**: recovery snapshots carry the full private event, including pair preferences. They are strictly local and excluded from guest-facing text and PDF exports. Deletion copy honestly explains that shared exports and OS-managed device backups remain outside the app's reach.

## Verification results

- **Linux domain tests**: 81 tests passing in Swift 6 container (`docker run ... swift:6.0.1-noble swift test`).
- **Python tooling tests**: 31 unit tests passing (`python3 -m unittest discover -s Scripts/tests`).
- **Static entitlement audit**: passed with zero violations (`python3 Scripts/entitlement_audit.py --source-only`).
- **Syntax check**: Swift 6 parser verified on all modified domain, app, and UI test sources.
- **Native Apple CI**: required for SwiftData store tests (`EventStoreTests`) and XCTest UI journeys (`SeatWeaveShareJourneyTests`).
