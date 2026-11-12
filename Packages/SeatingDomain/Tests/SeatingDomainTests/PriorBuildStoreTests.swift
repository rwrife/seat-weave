#if canImport(SwiftData)
import Foundation
import Testing
@testable import SeatingDomain

@Suite("Prior-build on-disk SwiftData migration")
struct PriorBuildStoreTests {
    @Test("Open pre-recovery SQLite store, preserve event, and save recovery point",
          .enabled(if: ProcessInfo.processInfo.environment["SEATWEAVE_LEGACY_STORE_DIR"] != nil))
    func migratePriorStore() throws {
        let path = try #require(ProcessInfo.processInfo.environment["SEATWEAVE_LEGACY_STORE_DIR"])
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let id = try #require(UUID(uuidString: "10941234-5678-4000-8000-000000000021"))
        let store = try EventStore.makeFileStore(directory: directory)
        let original = try #require(try store.load(eventID: id))
        #expect(original.title == "Prior build synthetic event")
        #expect(original.guests.map(\.displayName) == ["Synthetic Aster", "Synthetic Basil"])
        #expect(original.preferences.count == 1)
        #expect(original.variants.count == 1)
        #expect(original.variants[0].assignments.count == 1)
        #expect(try store.eventCount() == 1)
        try store.save(original)
        let reopened = try EventStore.makeFileStore(directory: directory)
        #expect(try reopened.load(eventID: id) == original)
        #expect(try reopened.eventCount() == 1)
        #expect(try reopened.recoveryPoints(eventID: id).count == 1)
    }
}
#endif
