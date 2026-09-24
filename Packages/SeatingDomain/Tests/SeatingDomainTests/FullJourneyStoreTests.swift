import Foundation
import Testing
@testable import SeatingDomain

#if canImport(SwiftData)
/// Issue #6: the complete create -> assign -> swap -> undo -> resize ->
/// duplicate -> relaunch -> export -> restore journey expressed as a
/// reproducible regression test against the REAL on-disk store, at the
/// domain layer the UI drives. The simulator journeys (issue #3/#5/#6 UI
/// tests) automate the same flow through XCUITest, but the restore step
/// crosses the OS file panel, which XCUITest cannot script; this test
/// closes that gap by running the identical command sequence plus backup,
/// store-reopen (relaunch analogue) and restore through `EventStore` and
/// `PersistentSeatingController` directly. Deterministic apart from UUID
/// identities. Synthetic names only.
@Suite("Issue 6 full journey through the real store")
struct FullJourneyStoreTests {

    @Test("create -> assign -> swap -> undo -> resize -> duplicate -> relaunch -> export -> restore")
    func fullJourneyRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("seatweave-journey-\(UUID().uuidString)", isDirectory: true)
        let store = try EventStore.makeFileStore(directory: directory)
        let saver = StoreSaverForTest(store: store)

        // Create: event with roster and one table.
        var event = SeatingEvent(title: "Journey dinner", variants: [PlanVariant(name: "Plan A")])
        var commands = SeatingCommands(event: event)
        let aster = try commands.addGuest(displayName: "Aster")
        let basil = try commands.addGuest(displayName: "Basil")
        _ = try commands.addGuest(displayName: "Cleo")
        let variantID = commands.currentEvent.variants[0].id
        let table = try commands.addTable(toVariant: variantID, label: "Round1", seatCount: 6)
        _ = try commands.addPreference(firstGuestID: aster.id, secondGuestID: basil.id,
                                       kind: .adjacent)
        event = commands.currentEvent
        try store.save(event)

        var controller = PersistentSeatingController(event: event, saver: saver)

        // Assign Aster and Basil.
        try controller.perform {
            try $0.assign(variantID: variantID, guestID: aster.id,
                          tableID: table.id, seatNumber: 1)
        }
        try controller.perform {
            try $0.assign(variantID: variantID, guestID: basil.id,
                          tableID: table.id, seatNumber: 2)
        }

        // Swap, then undo the swap.
        try controller.perform {
            try $0.swap(variantID: variantID, firstGuestID: aster.id,
                        secondGuestID: basil.id, confirmed: true)
        }
        var swapped = controller.currentEvent.variant(variantID)!.seat(for: aster.id)!.seatNumber
        #expect(swapped == 2)
        try controller.undo()
        swapped = controller.currentEvent.variant(variantID)!.seat(for: aster.id)!.seatNumber
        #expect(swapped == 1)

        // Resize down with Cleo unseated (she is not seated, so no loss),
        // and duplicate the plan for comparison.
        let preview = try controller.resizePreview(variantID: variantID, tableID: table.id, newSeatCount: 2)
        #expect(preview.guestsToUnseat.isEmpty)
        try controller.perform {
            try $0.resizeTable(variantID: variantID, preview: preview, confirmed: true)
        }
        var duplicatedVariantID: UUID?
        try controller.perform { session in
            let copy = try session.duplicateVariant(id: variantID, newName: "Plan B")
            duplicatedVariantID = copy.id
        }
        let planB = try #require(duplicatedVariantID)

        // Persisted state must equal the visible state.
        #expect(try #require(try store.load(eventID: event.id)) == controller.currentEvent)

        // Export: the public preview of the selected variant excludes
        // Cleo (unseated) and the private adjacency rule.
        let exportPreview = try PublicExportBuilder.preview(event: controller.currentEvent,
                                                            variantID: variantID)
        #expect(exportPreview.text.contains("Aster"))
        #expect(exportPreview.text.contains("Basil"))
        #expect(!exportPreview.text.contains("Cleo"))
        #expect(!exportPreview.text.lowercased().contains("adjacent"))

        // Relaunch analogue: a fresh store handle + controller reads the
        // committed data back, and the remembered plan survives.
        let reopened = try EventStore.makeFileStore(directory: directory)
        let reloaded = try #require(try reopened.load(eventID: event.id))
        #expect(reloaded == controller.currentEvent)
        #expect(reloaded.variant(planB) != nil)

        // Restore: full backup -> validated decode -> new event. The
        // original event is byte-identical afterwards, and the restored
        // copy carries fresh identities.
        let backup = try SeatingBackup.encodeBackup(of: reloaded)
        let (restored, summary) = try SeatingBackup.decodeBackup(backup)
        #expect(summary.title == "Journey dinner")
        #expect(summary.preferenceCount == 1)
        try reopened.save(restored)
        #expect(try #require(try reopened.load(eventID: event.id)) == reloaded)
        let storedRestored = try #require(try reopened.load(eventID: restored.id))
        #expect(storedRestored.id != event.id)
        #expect(Set(storedRestored.guests.map(\.displayName))
                == Set(["Aster", "Basil", "Cleo"]))
        // Both events now exist independently.
        #expect(try reopened.allEvents().count == 2)
    }

    /// App-side saver wrapper for the file-backed store.
    private final class StoreSaverForTest: EventSaving, @unchecked Sendable {
        private let store: EventStore
        init(store: EventStore) { self.store = store }
        func save(_ event: SeatingEvent) throws { try store.save(event) }
    }
}
#endif
