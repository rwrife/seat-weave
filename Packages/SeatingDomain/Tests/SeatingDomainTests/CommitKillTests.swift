#if canImport(SwiftData)
import Foundation
import Testing
@testable import SeatingDomain

@Suite("Killed writer at SwiftData commit boundary")
struct CommitKillTests {
    private let id = UUID(uuidString: "10941234-5678-4000-8000-000000000041")!
    private let guestA = UUID(uuidString: "10941234-5678-4000-8000-000000000042")!
    private let guestB = UUID(uuidString: "10941234-5678-4000-8000-000000000043")!
    private let tableID = UUID(uuidString: "10941234-5678-4000-8000-000000000044")!
    private let variantID = UUID(uuidString: "10941234-5678-4000-8000-000000000045")!

    private func committed(_ operation: String) -> SeatingEvent {
        let seats: [SeatAssignment] = operation == "assignment" ? [] : [
            SeatAssignment(guestID: guestA, tableID: tableID, seatNumber: 1),
            SeatAssignment(guestID: guestB, tableID: tableID,
                           seatNumber: operation == "resize" ? 4 : 2)
        ]
        return SeatingEvent(id: id, title: "Synthetic committed",
                            guests: [GuestIdentity(id: guestA, displayName: "Synthetic Aster"),
                                     GuestIdentity(id: guestB, displayName: "Synthetic Basil")],
                            variants: [PlanVariant(id: variantID, name: "A",
                                                   tables: [SeatingTable(id: tableID, label: "Round", seatCount: 4)],
                                                   assignments: seats)])
    }

    private func interrupted(_ operation: String, from event: SeatingEvent) throws -> SeatingEvent {
        if operation == "restore" {
            let backup = try SeatingBackup.encodeBackup(of: event)
            return try SeatingBackup.decodeBackup(backup).event
        }
        var commands = SeatingCommands(event: event)
        switch operation {
        case "assignment": try commands.assign(variantID: variantID, guestID: guestA,
                                                tableID: tableID, seatNumber: 1)
        case "swap": try commands.swap(variantID: variantID, firstGuestID: guestA,
                                       secondGuestID: guestB, confirmed: true)
        case "resize":
            let preview = try commands.resizePreview(variantID: variantID, tableID: tableID, newSeatCount: 2)
            try commands.resizeTable(variantID: variantID, preview: preview, confirmed: true)
        case "duplicate": _ = try commands.duplicateVariant(id: variantID, newName: "Copy")
        default: throw CommandError("Unknown test operation")
        }
        return commands.currentEvent
    }

    @Test("Write old snapshot, then wait at new snapshot commit",
          .enabled(if: ProcessInfo.processInfo.environment["SEATWEAVE_KILL_PHASE"] == "writer"))
    func writer() throws {
        let directory = try #require(ProcessInfo.processInfo.environment["SEATWEAVE_KILL_DIR"])
        let operation = try #require(ProcessInfo.processInfo.environment["SEATWEAVE_KILL_OPERATION"])
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        let store = try EventStore.makeFileStore(directory: root)
        let original = committed(operation)
        try store.save(original)
        let paused = store.observingCommit {
            let marker = root.appendingPathComponent("at-commit")
            try! Data().write(to: marker)
            // Harness kills process group. Timeout ensures an orphan cannot hang CI.
            Thread.sleep(forTimeInterval: 90)
        }
        try paused.save(interrupted(operation, from: original))
        Issue.record("Writer survived kill boundary")
    }

    @Test("Only old snapshot and its point survive reopen",
          .enabled(if: ProcessInfo.processInfo.environment["SEATWEAVE_KILL_PHASE"] == "reader"))
    func reader() throws {
        let directory = try #require(ProcessInfo.processInfo.environment["SEATWEAVE_KILL_DIR"])
        let operation = try #require(ProcessInfo.processInfo.environment["SEATWEAVE_KILL_OPERATION"])
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        let store = try EventStore.makeFileStore(directory: root)
        let event = committed(operation)
        #expect(try store.eventCount() == 1)
        #expect(try store.load(eventID: id) == event)
        let points = try store.recoveryPoints(eventID: id)
        #expect(points.count == 1)
        let original = try store.previewRecoveryPoint(id: points[0].id)
        #expect(original.event == event)
        #expect(try store.allEvents() == [event])
        try store.save(event)
        let reopened = try EventStore.makeFileStore(directory: root)
        #expect(try reopened.load(eventID: id) == event)
        #expect(try reopened.recoveryPoints(eventID: id).count == 2)
        #expect(try reopened.eventCount() == 1)
    }
}
#endif
