#if canImport(SwiftData)
import Foundation
import Testing
@testable import SeatingDomain

/// Synthetic fixture. Each fresh store handle models a process killed after a save boundary.
@Suite("Issue 21 interruption and restore boundaries")
struct InterruptedEditsTests {
    private final class Saver: EventSaving, @unchecked Sendable {
        private let store: EventStore
        private let lock = NSLock()
        private var fail = false
        init(_ store: EventStore) { self.store = store }
        func armFailure() { lock.lock(); fail = true; lock.unlock() }
        func save(_ event: SeatingEvent) throws {
            lock.lock(); defer { lock.unlock() }
            if fail {
                fail = false
                throw CocoaError(.fileWriteOutOfSpace)
            }
            try store.save(event)
        }
    }

    @Test("Assignment, swap, resize and duplication survive interruption; rejected write can be retried")
    func commandBoundaries() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("seatweave-boundaries-\(UUID().uuidString)", isDirectory: true)
        let a = GuestIdentity(displayName: "Aster")
        let b = GuestIdentity(displayName: "Basil")
        let table = SeatingTable(label: "Round", seatCount: 4)
        let variant = PlanVariant(name: "Plan A", tables: [table])
        let initial = SeatingEvent(title: "Synthetic", guests: [a, b], variants: [variant])
        var store = try EventStore.makeFileStore(directory: directory)
        try store.save(initial)
        var saver = Saver(store)
        var controller = PersistentSeatingController(event: initial, saver: saver)
        var expected = initial
        func reopen() throws -> EventStore { try EventStore.makeFileStore(directory: directory) }
        func assertCommitted(_ expected: SeatingEvent) throws {
            let fresh = try reopen()
            #expect(try fresh.load(eventID: initial.id) == expected)
            #expect(try fresh.recoveryPoints(eventID: initial.id).last != nil)
        }

        saver.armFailure()
        #expect(throws: PersistentSeatingController.Failure.self) {
            try controller.perform { try $0.assign(variantID: variant.id, guestID: a.id, tableID: table.id, seatNumber: 1) }
        }
        #expect(controller.currentEvent == expected)
        try assertCommitted(expected)

        try controller.perform { try $0.assign(variantID: variant.id, guestID: a.id, tableID: table.id, seatNumber: 1) }
        expected = controller.currentEvent
        try assertCommitted(expected)
        store = try reopen() // new process; session undo history deliberately lost
        saver = Saver(store)
        controller = PersistentSeatingController(event: try #require(try store.load(eventID: initial.id)), saver: saver)

        try controller.perform { try $0.assign(variantID: variant.id, guestID: b.id, tableID: table.id, seatNumber: 2) }
        expected = controller.currentEvent
        try assertCommitted(expected)
        try controller.perform { try $0.swap(variantID: variant.id, firstGuestID: a.id, secondGuestID: b.id, confirmed: true) }
        expected = controller.currentEvent
        try assertCommitted(expected)
        #expect(expected.variant(variant.id)?.seat(for: a.id)?.seatNumber == 2)
        store = try reopen()
        saver = Saver(store)
        controller = PersistentSeatingController(event: try #require(try store.load(eventID: initial.id)), saver: saver)

        let preview = try controller.resizePreview(variantID: variant.id, tableID: table.id, newSeatCount: 2)
        try controller.perform { try $0.resizeTable(variantID: variant.id, preview: preview, confirmed: true) }
        expected = controller.currentEvent
        try assertCommitted(expected)
        #expect(expected.variant(variant.id)?.tables[0].seatCount == 2)
        store = try reopen()
        saver = Saver(store)
        controller = PersistentSeatingController(event: try #require(try store.load(eventID: initial.id)), saver: saver)
        try controller.perform { _ = try $0.duplicateVariant(id: variant.id, newName: "Copy") }
        expected = controller.currentEvent
        try assertCommitted(expected)
        #expect(expected.variants.count == 2)

        // Restore is a new record, never a mutation of source. Reopen both after commit.
        let backup = try SeatingBackup.encodeBackup(of: expected)
        let restored = try SeatingBackup.decodeBackup(backup).event
        try store.save(restored)
        let afterRestore = try reopen()
        #expect(try afterRestore.load(eventID: restored.id) == restored)
        #expect(try afterRestore.load(eventID: initial.id) == expected)
        #expect(try afterRestore.recoveryPoints(eventID: initial.id).count > 0)
    }

    @Test("Rejected restore write leaves source intact and no partial copy; retry survives reopen")
    func restoreFailureBoundary() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("seatweave-restore-failure-\(UUID().uuidString)", isDirectory: true)
        let source = SeatingEvent(title: "Synthetic restore", guests: [GuestIdentity(displayName: "Aster")],
                                  variants: [PlanVariant(name: "Plan A")])
        let store = try EventStore.makeFileStore(directory: directory)
        try store.save(source)
        let backup = try SeatingBackup.encodeBackup(of: source)
        let restored = try SeatingBackup.decodeBackup(backup).event
        #expect(restored.id != source.id)
        let saver = Saver(store)
        saver.armFailure()
        #expect(throws: CocoaError.self) { try saver.save(restored) }

        // Reopen instead of trusting the same ModelContext after a rejected write.
        let afterFailure = try EventStore.makeFileStore(directory: directory)
        #expect(try afterFailure.load(eventID: source.id) == source)
        #expect(try afterFailure.load(eventID: restored.id) == nil)
        #expect(try afterFailure.eventCount() == 1)
        #expect(try afterFailure.recoveryPoints(eventID: restored.id).isEmpty)

        try saver.save(restored)
        let afterRetry = try EventStore.makeFileStore(directory: directory)
        #expect(try afterRetry.load(eventID: source.id) == source)
        #expect(try afterRetry.load(eventID: restored.id) == restored)
        #expect(try afterRetry.eventCount() == 2)
        #expect(try afterRetry.recoveryPoints(eventID: restored.id).count == 1)
    }
}
#endif
