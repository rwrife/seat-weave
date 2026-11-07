#if canImport(SwiftData)
import Foundation
import Testing
@testable import SeatingDomain

@Suite("Killed writer at SwiftData commit boundary")
struct CommitKillTests {
    private let id = UUID(uuidString: "10941234-5678-4000-8000-000000000041")!

    @Test("Write old snapshot, then wait at new snapshot commit",
          .enabled(if: ProcessInfo.processInfo.environment["SEATWEAVE_KILL_PHASE"] == "writer"))
    func writer() throws {
        let directory = try #require(ProcessInfo.processInfo.environment["SEATWEAVE_KILL_DIR"])
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        let store = try EventStore.makeFileStore(directory: root)
        try store.save(SeatingEvent(id: id, title: "Synthetic committed"))
        let paused = store.observingCommit {
            let marker = root.appendingPathComponent("at-commit")
            try! Data().write(to: marker)
            // Harness kills process group. Timeout ensures an orphan cannot hang CI.
            Thread.sleep(forTimeInterval: 90)
        }
        try paused.save(SeatingEvent(id: id, title: "Synthetic interrupted"))
        Issue.record("Writer survived kill boundary")
    }

    @Test("Only old snapshot and its point survive reopen",
          .enabled(if: ProcessInfo.processInfo.environment["SEATWEAVE_KILL_PHASE"] == "reader"))
    func reader() throws {
        let directory = try #require(ProcessInfo.processInfo.environment["SEATWEAVE_KILL_DIR"])
        let store = try EventStore.makeFileStore(directory: URL(fileURLWithPath: directory, isDirectory: true))
        #expect(try store.eventCount() == 1)
        let event = try #require(try store.load(eventID: id))
        #expect(event.title == "Synthetic committed")
        let points = try store.recoveryPoints(eventID: id)
        #expect(points.count == 1)
        let original = try store.previewRecoveryPoint(id: points[0].id)
        #expect(original.event == event)
        try store.save(event)
        let reopened = try EventStore.makeFileStore(directory: URL(fileURLWithPath: directory, isDirectory: true))
        #expect(try reopened.load(eventID: id) == event)
        #expect(try reopened.recoveryPoints(eventID: id).count == 2)
    }
}
#endif
