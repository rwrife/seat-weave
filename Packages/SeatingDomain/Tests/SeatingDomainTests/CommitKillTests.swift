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

    @Test("Write old snapshot, then wait before or after new snapshot commit",
          .enabled(if: ["writer", "committed-writer"].contains(ProcessInfo.processInfo.environment["SEATWEAVE_KILL_PHASE"] ?? "")))
    func writer() throws {
        let directory = try #require(ProcessInfo.processInfo.environment["SEATWEAVE_KILL_DIR"])
        let operation = try #require(ProcessInfo.processInfo.environment["SEATWEAVE_KILL_OPERATION"])
        let phase = try #require(ProcessInfo.processInfo.environment["SEATWEAVE_KILL_PHASE"])
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        let store = try EventStore.makeFileStore(directory: root)
        let original = committed(operation)
        try store.save(original)
        let change = try interrupted(operation, from: original)
        if phase == "committed-writer" {
            try store.save(change)
            // Synthetic expected bytes stay in private temporary store, never artifacts.
            try JSONEncoder().encode(change).write(to: root.appendingPathComponent("expected.json"))
            try Data().write(to: root.appendingPathComponent("after-commit"))
        } else {
            let paused = store.observingCommit {
                let marker = root.appendingPathComponent("at-commit")
                try! Data().write(to: marker)
                // Harness kills process group. Timeout ensures an orphan cannot hang CI.
                Thread.sleep(forTimeInterval: 90)
            }
            try paused.save(change)
            Issue.record("Writer survived pre-commit boundary")
            return
        }
        Thread.sleep(forTimeInterval: 90)
        Issue.record("Writer survived post-commit boundary")
    }

    @Test("Last committed snapshot and recovery point survive reopen",
          .enabled(if: ["reader", "committed-reader"].contains(ProcessInfo.processInfo.environment["SEATWEAVE_KILL_PHASE"] ?? "")))
    func reader() throws {
        let directory = try #require(ProcessInfo.processInfo.environment["SEATWEAVE_KILL_DIR"])
        let operation = try #require(ProcessInfo.processInfo.environment["SEATWEAVE_KILL_OPERATION"])
        let phase = try #require(ProcessInfo.processInfo.environment["SEATWEAVE_KILL_PHASE"])
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        let store = try EventStore.makeFileStore(directory: root)
        let original = committed(operation)
        let committed = phase == "committed-reader"
        let expected: SeatingEvent
        if committed {
            expected = try JSONDecoder().decode(SeatingEvent.self,
                from: Data(contentsOf: root.appendingPathComponent("expected.json")))
        } else {
            expected = original
        }
        let source = operation == "restore" ? original : expected
        #expect(try store.eventCount() == (committed && operation == "restore" ? 2 : 1))
        #expect(try store.load(eventID: source.id) == source)
        #expect(try store.load(eventID: expected.id) == expected)
        let points = try store.recoveryPoints(eventID: expected.id)
        #expect(points.count == (committed && operation != "restore" ? 2 : 1))
        let snapshots = try points.map { try store.previewRecoveryPoint(id: $0.id).event }
        #expect(snapshots.contains(expected))
        if committed && operation != "restore" {
            #expect(snapshots.contains(original))
        }
        if committed && operation == "restore" {
            #expect(try store.recoveryPoints(eventID: original.id).count == 1)
        }
        try store.save(expected)
        let reopened = try EventStore.makeFileStore(directory: root)
        #expect(try reopened.load(eventID: expected.id) == expected)
        #expect(try reopened.recoveryPoints(eventID: expected.id).count == points.count + 1)
        #expect(try reopened.eventCount() == (committed && operation == "restore" ? 2 : 1))
    }
}
#endif
