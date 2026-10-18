#if canImport(SwiftData)
import Foundation
import Testing
@testable import SeatingDomain

/// Runs only where SwiftData exists (macOS/iOS CI). Each test gets a fresh
/// isolated temporary store; nothing is shared between tests or with the app.
@Suite("Issue 2 SwiftData store")
struct EventStoreTests {
    private func sampleEvent() -> (SeatingEvent, Fixture) {
        let fixture = Fixture(seats: 6)
        var commands = SeatingCommands(event: fixture.event)
        try? commands.assign(variantID: fixture.variantID, guestID: fixture.alice, tableID: fixture.tableID, seatNumber: 1)
        try? commands.addPreference(firstGuestID: fixture.alice, secondGuestID: fixture.bob, kind: .sameTable)
        return (commands.currentEvent, fixture)
    }

    @Test("Saved events reload completely and unchanged")
    func roundTrip() throws {
        let store = try EventStore.makeTemporaryStore()
        let (event, _) = sampleEvent()
        try store.save(event)
        let loaded = try store.load(eventID: event.id)
        #expect(loaded == event)
        #expect(try store.eventCount() == 1)
    }

    @Test("A reopened store at the same location reads committed data")
    func restartReadsCommittedData() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("seatweave-restart-\(UUID().uuidString)", isDirectory: true)
        let (event, _) = sampleEvent()
        do {
            let store = try EventStore.makeFileStore(directory: directory)
            try store.save(event)
        }
        let reopened = try EventStore.makeFileStore(directory: directory)
        let loaded = try reopened.load(eventID: event.id)
        #expect(loaded?.guests.count == event.guests.count)
        #expect(loaded?.variants.first?.seat(for: event.guests[0].id)?.seatNumber == 1)
        #expect(loaded?.preferences.count == 1)
    }

    @Test("Unknown event identifiers load as nil")
    func unknownEventIsNil() throws {
        let store = try EventStore.makeTemporaryStore()
        #expect(try store.load(eventID: UUID()) == nil)
    }

    @Test("Saving the same event twice keeps one record with the latest snapshot")
    func latestSnapshotWins() throws {
        let store = try EventStore.makeTemporaryStore()
        let (event, fixture) = sampleEvent()
        try store.save(event)
        var commands = SeatingCommands(event: event)
        try commands.assign(variantID: fixture.variantID, guestID: fixture.bob, tableID: fixture.tableID, seatNumber: 2)
        try store.save(commands.currentEvent)
        let loaded = try store.load(eventID: event.id)
        #expect(loaded?.variants.first?.seat(for: fixture.bob)?.seatNumber == 2)
        #expect(try store.eventCount() == 1)
    }

    @Test("Corrupted snapshots fail explicitly, never silently")
    func corruptedSnapshotFails() throws {
        let store = try EventStore.makeTemporaryStore()
        let id = UUID()
        try store.saveCorruptSnapshot(eventID: id)
        #expect(throws: EventStore.StoreError.self) {
            _ = try store.load(eventID: id)
        }
    }

    @Test("allEvents lists every stored event or fails explicitly")
    func allEventsListsEverything() throws {
        let store = try EventStore.makeTemporaryStore()
        #expect(try store.allEvents().isEmpty)
        let (first, _) = sampleEvent()
        let (second, _) = sampleEvent()
        try store.save(first)
        try store.save(second)
        let listed = try store.allEvents()
        #expect(Set(listed.map(\.id)) == Set([first.id, second.id]))
        try store.saveCorruptSnapshot(eventID: UUID())
        #expect(throws: EventStore.StoreError.self) {
            _ = try store.allEvents()
        }
    }

    @Test("Deleting one event removes only that event")
    func deleteOneEvent() throws {
        let store = try EventStore.makeTemporaryStore()
        let (first, _) = sampleEvent()
        let (second, _) = sampleEvent()
        try store.save(first)
        try store.save(second)
        try store.delete(eventID: first.id)
        #expect(try store.eventCount() == 1)
        #expect(try store.load(eventID: first.id) == nil)
        #expect(try store.load(eventID: second.id) == second)
        // Deleting an already-absent ID is a no-op, not an error.
        try store.delete(eventID: first.id)
        #expect(try store.eventCount() == 1)
    }

    @Test("Delete-all empties the store and every local recovery copy")
    func deleteAllEmptiesStore() throws {
        let store = try EventStore.makeTemporaryStore()
        let (first, _) = sampleEvent()
        let (second, _) = sampleEvent()
        try store.save(first)
        try store.save(second)
        try store.delete(eventID: first.id)
        try store.deleteAll()
        #expect(try store.eventCount() == 0)
        #expect(try store.allEvents().isEmpty)
        #expect(try store.recentlyDeleted().isEmpty)
        #expect(try store.recoveryPoints(eventID: first.id).isEmpty)
        #expect(try store.recoveryPoints(eventID: second.id).isEmpty)
    }

    @Test("Recovery survives restart and restores an isolated new event with preferences")
    func recoverySurvivesRestart() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("seatweave-recovery-\(UUID().uuidString)", isDirectory: true)
        let (event, _) = sampleEvent()
        do { try EventStore.makeFileStore(directory: directory).save(event) }
        let reopened = try EventStore.makeFileStore(directory: directory)
        let points = try reopened.recoveryPoints(eventID: event.id)
        #expect(points.count == 1)
        #expect(points[0].guestCount == event.guests.count)
        #expect(points[0].preferenceCount == 1)
        let preview = try reopened.previewRecoveryPoint(id: points[0].id)
        #expect(preview.event == event)
        let restored = try reopened.restoreRecoveryPoint(id: points[0].id)
        #expect(restored.id != event.id)
        #expect(restored.guests.count == event.guests.count)
        #expect(restored.preferences.count == 1)
        #expect(try reopened.load(eventID: event.id) == event)
        #expect(try reopened.load(eventID: restored.id) == restored)
    }

    @Test("Corruption is isolated; another recovery point remains usable")
    func corruptRecoveryPointIsolated() throws {
        let store = try EventStore.makeTemporaryStore()
        let (event, _) = sampleEvent()
        try store.save(event)
        let corruptID = try store.saveCorruptRecoveryPoint(eventID: event.id)
        let points = try store.recoveryPoints(eventID: event.id)
        #expect(points.count == 2)
        #expect(throws: EventStore.StoreError.self) {
            _ = try store.previewRecoveryPoint(id: corruptID)
        }
        let valid = points.first { point in
            (try? store.previewRecoveryPoint(id: point.id)) != nil
        }
        #expect(valid != nil)
        #expect(try store.load(eventID: event.id) == event)
    }

    @Test("Oversized failed save leaves current event and recovery untouched")
    func oversizedSaveLeavesOldPoint() throws {
        let store = try EventStore.makeTemporaryStore()
        let (event, _) = sampleEvent()
        try store.save(event)
        let ids = try store.recoveryPointIDs(eventID: event.id)
        var tooLarge = event
        tooLarge.title = String(repeating: "x", count: EventStore.maximumPointBytes)
        #expect(throws: EventStore.StoreError.self) { try store.save(tooLarge) }
        #expect(try store.load(eventID: event.id) == event)
        #expect(try store.recoveryPointIDs(eventID: event.id) == ids)
    }

    @Test("Count and age pruning retain only fresh bounded points")
    func retentionPrunes() throws {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = try EventStore.makeTemporaryStore(now: { now })
        let (event, _) = sampleEvent()
        for index in 0..<12 {
            var version = event
            version.title = "Version \(index)"
            try store.save(version)
            now.addTimeInterval(1)
        }
        let points = try store.recoveryPoints(eventID: event.id)
        #expect(points.count == 10)
        #expect(points.allSatisfy { $0.title != "Version 0" && $0.title != "Version 1" })
        now.addTimeInterval(15 * 24 * 60 * 60)
        #expect(try store.recoveryPoints(eventID: event.id).isEmpty)
    }

    @Test("Ordinary deletion can recover; permanent deletion removes all copies")
    func deletedRecoveryAndPermanentPurge() throws {
        let store = try EventStore.makeTemporaryStore()
        let (event, _) = sampleEvent()
        try store.save(event)
        try store.delete(eventID: event.id)
        #expect(try store.load(eventID: event.id) == nil)
        #expect(try store.recentlyDeleted().count == 1)
        try store.restoreDeleted(eventID: event.id)
        #expect(try store.load(eventID: event.id) == event)
        try store.delete(eventID: event.id)
        try store.deletePermanently(eventID: event.id)
        #expect(try store.recentlyDeleted().isEmpty)
        #expect(try store.recoveryPoints(eventID: event.id).isEmpty)
        #expect(try store.load(eventID: event.id) == nil)
    }

    @Test("Expired recently-deleted copy is purged")
    func expiredDeletionPurged() throws {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = try EventStore.makeTemporaryStore(now: { now })
        let (event, _) = sampleEvent()
        try store.save(event)
        try store.delete(eventID: event.id)
        now.addTimeInterval(15 * 24 * 60 * 60)
        #expect(try store.recentlyDeleted().isEmpty)
        #expect(try store.recoveryPoints(eventID: event.id).isEmpty)
    }
}
#endif
