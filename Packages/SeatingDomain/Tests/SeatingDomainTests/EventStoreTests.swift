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

    @Test("Delete-all empties the store")
    func deleteAllEmptiesStore() throws {
        let store = try EventStore.makeTemporaryStore()
        let (first, _) = sampleEvent()
        let (second, _) = sampleEvent()
        try store.save(first)
        try store.save(second)
        try store.deleteAll()
        #expect(try store.eventCount() == 0)
        #expect(try store.allEvents().isEmpty)
    }
}
#endif
