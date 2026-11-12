#if canImport(SwiftData)
import Foundation
import Testing
@testable import SeatingDomain

// Compiled against pinned pre-recovery commit; never against current models.
@Suite("Historical on-disk SwiftData fixture")
struct LegacyStoreFixtureTests {
    @Test func writeStore() throws {
        let directory = try #require(ProcessInfo.processInfo.environment["SEATWEAVE_LEGACY_STORE_DIR"])
        let store = try EventStore.makeFileStore(directory: URL(fileURLWithPath: directory, isDirectory: true))
        let a = GuestIdentity(id: UUID(uuidString: "10941234-5678-4000-8000-000000000022")!, displayName: "Synthetic Aster")
        let b = GuestIdentity(id: UUID(uuidString: "10941234-5678-4000-8000-000000000023")!, displayName: "Synthetic Basil")
        let table = SeatingTable(id: UUID(uuidString: "10941234-5678-4000-8000-000000000024")!, label: "Round", seatCount: 4)
        let event = SeatingEvent(
            id: UUID(uuidString: "10941234-5678-4000-8000-000000000021")!,
            title: "Prior build synthetic event",
            guests: [a, b],
            preferences: [PairPreference(firstGuestID: a.id, secondGuestID: b.id, kind: .sameTable)],
            variants: [PlanVariant(name: "Old plan", tables: [table],
                                   assignments: [SeatAssignment(guestID: a.id, tableID: table.id, seatNumber: 1)])])
        try store.save(event)
        #expect(try store.load(eventID: event.id) == event)
    }
}
#endif
