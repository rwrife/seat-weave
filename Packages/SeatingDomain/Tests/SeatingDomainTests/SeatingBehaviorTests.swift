import Foundation
import Testing
@testable import SeatingDomain

/// Synthetic fixtures only; no real names or preferences.
struct Fixture {
    let event: SeatingEvent
    let variantID: UUID
    let tableID: UUID
    let alice: UUID
    let bob: UUID
    let carol: UUID

    init(guests: Int = 3, seats: Int = 4, tables: Int = 1) {
        let alice = UUID()
        let bob = UUID()
        let carol = UUID()
        let tableID = UUID()
        let variantID = UUID()
        let names = [alice: "Alice", bob: "Bob", carol: "Carol"]
        let guestList = Array([alice, bob, carol].prefix(guests)).map {
            GuestIdentity(id: $0, displayName: names[$0]!)
        }
        let tableList = (0..<min(tables, SeatingLimits.maximumTablesPerVariant)).map { index in
            SeatingTable(id: index == 0 ? tableID : UUID(), label: "T\(index)", seatCount: seats)
        }
        self.alice = alice
        self.bob = bob
        self.carol = carol
        self.tableID = tableID
        self.variantID = variantID
        event = SeatingEvent(
            title: "Test gathering",
            guests: guestList,
            variants: [PlanVariant(id: variantID, name: "Plan A", tables: tableList)]
        )
    }
}

// MARK: - Bounds and identity

@Suite("Issue 2 bounds and identity")
struct BoundsTests {
    @Test("Guest count respects the 40-guest bound")
    func guestBound() throws {
        var model = SeatingEvent(title: "Big", variants: [PlanVariant(name: "A")])
        var commands = SeatingCommands(event: model)
        for index in 0..<SeatingLimits.maximumGuestsPerEvent {
            try commands.addGuest(displayName: "Guest \(index)")
        }
        let before = commands.currentEvent
        #expect(throws: CommandError.self) {
            try commands.addGuest(displayName: "One too many")
        }
        #expect(commands.currentEvent == before)
        _ = model
    }

    @Test("Duplicate display names keep distinct UUID identity through commands")
    func duplicateNamesStayDistinct() throws {
        var commands = SeatingCommands(event: Fixture().event)
        let first = try commands.addGuest(displayName: "Guest")
        let second = try commands.addGuest(displayName: "Guest")
        #expect(first.id != second.id)
        #expect(commands.currentEvent.guests.filter { $0.displayName == "Guest" }.count == 2)
    }

    @Test("Empty names are rejected without mutation")
    func emptyNamesRejected() throws {
        var commands = SeatingCommands(event: Fixture().event)
        let before = commands.currentEvent
        #expect(throws: CommandError.self) { try commands.addGuest(displayName: "   ") }
        #expect(commands.currentEvent == before)
    }

    @Test("Seat counts stay within 2 through 12")
    func seatBounds() throws {
        var commands = SeatingCommands(event: Fixture().event)
        let variantID = commands.currentEvent.variants[0].id
        let before = commands.currentEvent
        #expect(throws: CommandError.self) {
            try commands.addTable(toVariant: variantID, label: "Tiny", seatCount: 1)
        }
        #expect(throws: CommandError.self) {
            try commands.addTable(toVariant: variantID, label: "Huge", seatCount: 13)
        }
        #expect(commands.currentEvent == before)
    }

    @Test("Variant count respects the 10-variant bound")
    func variantBound() throws {
        var model = SeatingEvent(title: "Many plans", variants: (0..<SeatingLimits.maximumVariantsPerEvent).map { PlanVariant(name: "P\($0)") })
        var commands = SeatingCommands(event: model)
        let before = commands.currentEvent
        #expect(throws: CommandError.self) {
            try commands.duplicateVariant(id: model.variants[0].id, newName: "Overflow")
        }
        #expect(commands.currentEvent == before)
        _ = model
    }
}

// MARK: - Commands, occupancy and undo

@Suite("Issue 2 commands, occupancy and undo")
struct CommandTests {
    @Test("Assign fills a seat; occupied seats refuse without mutation")
    func assignAndOccupancy() throws {
        let fixture = Fixture()
        var commands = SeatingCommands(event: fixture.event)
        try commands.assign(variantID: fixture.variantID, guestID: fixture.alice, tableID: fixture.tableID, seatNumber: 1)
        let afterAssign = commands.currentEvent
        #expect(commands.currentEvent.variants[0].occupant(tableID: fixture.tableID, seatNumber: 1) == fixture.alice)

        // A second guest cannot take the occupied seat.
        let before = commands.currentEvent
        #expect(throws: CommandError.self) {
            try commands.assign(variantID: fixture.variantID, guestID: fixture.bob, tableID: fixture.tableID, seatNumber: 1)
        }
        #expect(commands.currentEvent == before)

        // The same guest cannot be assigned twice.
        #expect(throws: CommandError.self) {
            try commands.assign(variantID: fixture.variantID, guestID: fixture.alice, tableID: fixture.tableID, seatNumber: 2)
        }
        #expect(commands.currentEvent == afterAssign)
    }

    @Test("Unknown tables, seats and cross-event guests are rejected")
    func unknownReferences() throws {
        let fixture = Fixture()
        var commands = SeatingCommands(event: fixture.event)
        let stranger = UUID()
        let unknownTable = UUID()
        let before = commands.currentEvent
        #expect(throws: CommandError.self) {
            try commands.assign(variantID: fixture.variantID, guestID: stranger, tableID: fixture.tableID, seatNumber: 1)
        }
        #expect(throws: CommandError.self) {
            try commands.assign(variantID: fixture.variantID, guestID: fixture.alice, tableID: unknownTable, seatNumber: 1)
        }
        #expect(throws: CommandError.self) {
            try commands.assign(variantID: fixture.variantID, guestID: fixture.alice, tableID: fixture.tableID, seatNumber: 5)
        }
        #expect(throws: CommandError.self) {
            try commands.assign(variantID: fixture.variantID, guestID: fixture.alice, tableID: fixture.tableID, seatNumber: 0)
        }
        #expect(commands.currentEvent == before)
        // Cross-event preference references are rejected too.
        #expect(throws: CommandError.self) {
            try commands.addPreference(firstGuestID: fixture.alice, secondGuestID: stranger, kind: .sameTable)
        }
        #expect(commands.currentEvent == before)
    }

    @Test("Move relocates a seated guest; unseated guests need assign")
    func moveSemantics() throws {
        let fixture = Fixture()
        var commands = SeatingCommands(event: fixture.event)
        try commands.assign(variantID: fixture.variantID, guestID: fixture.alice, tableID: fixture.tableID, seatNumber: 1)
        try commands.move(variantID: fixture.variantID, guestID: fixture.alice, tableID: fixture.tableID, seatNumber: 3)
        let seat = commands.currentEvent.variants[0].seat(for: fixture.alice)
        #expect(seat?.seatNumber == 3)
        #expect(commands.currentEvent.variants[0].occupant(tableID: fixture.tableID, seatNumber: 1) == nil)

        let before = commands.currentEvent
        #expect(throws: CommandError.self) {
            try commands.move(variantID: fixture.variantID, guestID: fixture.bob, tableID: fixture.tableID, seatNumber: 2)
        }
        #expect(commands.currentEvent == before)
    }

    @Test("Swap requires explicit confirmation and exchanges exactly two occupants")
    func swapSemantics() throws {
        let fixture = Fixture()
        var commands = SeatingCommands(event: fixture.event)
        try commands.assign(variantID: fixture.variantID, guestID: fixture.alice, tableID: fixture.tableID, seatNumber: 1)
        try commands.assign(variantID: fixture.variantID, guestID: fixture.bob, tableID: fixture.tableID, seatNumber: 2)

        let before = commands.currentEvent
        #expect(throws: CommandError.self) {
            try commands.swap(variantID: fixture.variantID, firstGuestID: fixture.alice, secondGuestID: fixture.bob, confirmed: false)
        }
        #expect(commands.currentEvent == before)

        try commands.swap(variantID: fixture.variantID, firstGuestID: fixture.alice, secondGuestID: fixture.bob, confirmed: true)
        let variant = commands.currentEvent.variants[0]
        #expect(variant.seat(for: fixture.alice)?.seatNumber == 2)
        #expect(variant.seat(for: fixture.bob)?.seatNumber == 1)
        #expect(variant.occupancyIsCoherent)

        // Swapping with an unseated guest is refused atomically.
        let after = commands.currentEvent
        #expect(throws: CommandError.self) {
            try commands.swap(variantID: fixture.variantID, firstGuestID: fixture.alice, secondGuestID: fixture.carol, confirmed: true)
        }
        #expect(commands.currentEvent == after)
    }

    @Test("Unseat clears one guest and refuses unseated guests")
    func unseatSemantics() throws {
        let fixture = Fixture()
        var commands = SeatingCommands(event: fixture.event)
        try commands.assign(variantID: fixture.variantID, guestID: fixture.alice, tableID: fixture.tableID, seatNumber: 1)
        try commands.unseat(variantID: fixture.variantID, guestID: fixture.alice)
        #expect(commands.currentEvent.variants[0].seat(for: fixture.alice) == nil)

        let before = commands.currentEvent
        #expect(throws: CommandError.self) {
            try commands.unseat(variantID: fixture.variantID, guestID: fixture.alice)
        }
        #expect(commands.currentEvent == before)
    }

    @Test("Resize previews affected guests and unseats only after confirmation")
    func resizeSemantics() throws {
        let fixture = Fixture(seats: 6)
        var commands = SeatingCommands(event: fixture.event)
        try commands.assign(variantID: fixture.variantID, guestID: fixture.alice, tableID: fixture.tableID, seatNumber: 2)
        try commands.assign(variantID: fixture.variantID, guestID: fixture.bob, tableID: fixture.tableID, seatNumber: 5)

        let preview = try commands.resizePreview(variantID: fixture.variantID, tableID: fixture.tableID, newSeatCount: 3)
        #expect(preview.guestsToUnseat.count == 1)
        #expect(preview.guestsToUnseat.first?.guestID == fixture.bob)

        // Unconfirmed resize changes nothing.
        let before = commands.currentEvent
        #expect(throws: CommandError.self) {
            try commands.resizeTable(variantID: fixture.variantID, preview: preview, confirmed: false)
        }
        #expect(commands.currentEvent == before)

        // Stale previews are refused.
        try commands.assign(variantID: fixture.variantID, guestID: fixture.carol, tableID: fixture.tableID, seatNumber: 6)
        #expect(throws: CommandError.self) {
            try commands.resizeTable(variantID: fixture.variantID, preview: preview, confirmed: true)
        }

        let fresh = try commands.resizePreview(variantID: fixture.variantID, tableID: fixture.tableID, newSeatCount: 3)
        try commands.resizeTable(variantID: fixture.variantID, preview: fresh, confirmed: true)
        let variant = commands.currentEvent.variants[0]
        #expect(variant.table(fixture.tableID)?.seatCount == 3)
        #expect(variant.seat(for: fixture.bob) == nil)
        #expect(variant.seat(for: fixture.carol) == nil)
        #expect(variant.seat(for: fixture.alice)?.seatNumber == 2)
        #expect(variant.occupancyIsCoherent)
    }

    @Test("Session undo reverses each command and then stops cleanly")
    func undoSemantics() throws {
        let fixture = Fixture()
        var commands = SeatingCommands(event: fixture.event)
        let empty = commands.currentEvent

        try commands.assign(variantID: fixture.variantID, guestID: fixture.alice, tableID: fixture.tableID, seatNumber: 1)
        try commands.move(variantID: fixture.variantID, guestID: fixture.alice, tableID: fixture.tableID, seatNumber: 2)
        try commands.unseat(variantID: fixture.variantID, guestID: fixture.alice)
        try commands.addPreference(firstGuestID: fixture.alice, secondGuestID: fixture.bob, kind: .adjacent)

        try commands.undo()
        #expect(commands.currentEvent.preferences.isEmpty)
        try commands.undo()
        #expect(commands.currentEvent.variants[0].seat(for: fixture.alice)?.seatNumber == 2)
        try commands.undo()
        #expect(commands.currentEvent.variants[0].seat(for: fixture.alice)?.seatNumber == 1)
        try commands.undo()
        #expect(commands.currentEvent == empty)

        #expect(throws: CommandError.self) { try commands.undo() }
    }

    @Test("A deterministic random command sequence never breaks occupancy")
    func randomizedInvariantsHold() throws {
        // Deterministic linear congruential generator; seed fixed for replay.
        var state: UInt64 = 0x9E3779B97F4A7C15
        func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(bound))
        }

        for seed in 0..<3 {
            let fixture = Fixture(guests: 6, seats: 4, tables: 2)
            _ = seed
            var commands = SeatingCommands(event: fixture.event)
            let guestIDs = commands.currentEvent.guests.map(\.id)
            let tableIDs = commands.currentEvent.variants[0].tables.map(\.id)
            for _ in 0..<60 {
                let guest = guestIDs[next(guestIDs.count)]
                let table = tableIDs[next(tableIDs.count)]
                let seat = next(4) + 1
                switch next(4) {
                case 0: try? commands.assign(variantID: fixture.variantID, guestID: guest, tableID: table, seatNumber: seat)
                case 1: try? commands.move(variantID: fixture.variantID, guestID: guest, tableID: table, seatNumber: seat)
                case 2: try? commands.unseat(variantID: fixture.variantID, guestID: guest)
                default:
                    let other = guestIDs[next(guestIDs.count)]
                    if other != guest {
                        try? commands.swap(variantID: fixture.variantID, firstGuestID: guest, secondGuestID: other, confirmed: true)
                    }
                }
                #expect(commands.currentEvent.variants[0].occupancyIsCoherent, "fixture \(seed) diverged")
            }
        }
    }
}

// MARK: - Three-state rule evaluation

@Suite("Issue 2 rule evaluation")
struct RuleEngineTests {
    private func seated(_ fixture: Fixture, _ pairs: [(UUID, Int)]) -> (SeatingEvent, PlanVariant) {
        var commands = SeatingCommands(event: fixture.event)
        for (guest, seat) in pairs {
            try? commands.assign(variantID: fixture.variantID, guestID: guest, tableID: fixture.tableID, seatNumber: seat)
        }
        let event = commands.currentEvent
        return (event, event.variants[0])
    }

    @Test("Same-table rules read satisfied, conflict and unresolved correctly")
    func sameTableStates() throws {
        let fixture = Fixture()
        var commands = SeatingCommands(event: fixture.event)
        try commands.addPreference(firstGuestID: fixture.alice, secondGuestID: fixture.bob, kind: .sameTable)

        var evaluation = RuleEngine.evaluate(event: commands.currentEvent, variant: commands.currentEvent.variants[0])
        #expect(evaluation.first?.status == .unresolved)
        #expect(evaluation.first?.reason.contains("not seated yet") == true)

        // One seated, one not: still unresolved.
        try commands.assign(variantID: fixture.variantID, guestID: fixture.alice, tableID: fixture.tableID, seatNumber: 1)
        evaluation = RuleEngine.evaluate(event: commands.currentEvent, variant: commands.currentEvent.variants[0])
        #expect(evaluation.first?.status == .unresolved)

        // Different tables: conflict.
        try commands.addTable(toVariant: fixture.variantID, label: "Second", seatCount: 2)
        let secondTable = commands.currentEvent.variants[0].tables[1].id
        try commands.assign(variantID: fixture.variantID, guestID: fixture.bob, tableID: secondTable, seatNumber: 1)
        evaluation = RuleEngine.evaluate(event: commands.currentEvent, variant: commands.currentEvent.variants[0])
        #expect(evaluation.first?.status == .conflict)

        // Same table: satisfied.
        try commands.unseat(variantID: fixture.variantID, guestID: fixture.bob)
        try commands.assign(variantID: fixture.variantID, guestID: fixture.bob, tableID: fixture.tableID, seatNumber: 2)
        evaluation = RuleEngine.evaluate(event: commands.currentEvent, variant: commands.currentEvent.variants[0])
        #expect(evaluation.first?.status == .satisfied)
    }

    @Test("Different-tables rules invert the same-table logic")
    func differentTablesStates() throws {
        let fixture = Fixture()
        var commands = SeatingCommands(event: fixture.event)
        try commands.addPreference(firstGuestID: fixture.alice, secondGuestID: fixture.bob, kind: .differentTables)

        try commands.assign(variantID: fixture.variantID, guestID: fixture.alice, tableID: fixture.tableID, seatNumber: 1)
        try commands.assign(variantID: fixture.variantID, guestID: fixture.bob, tableID: fixture.tableID, seatNumber: 2)
        var evaluation = RuleEngine.evaluate(event: commands.currentEvent, variant: commands.currentEvent.variants[0])
        #expect(evaluation.first?.status == .conflict)

        try commands.addTable(toVariant: fixture.variantID, label: "Second", seatCount: 2)
        let secondTable = commands.currentEvent.variants[0].tables[1].id
        try commands.move(variantID: fixture.variantID, guestID: fixture.bob, tableID: secondTable, seatNumber: 1)
        evaluation = RuleEngine.evaluate(event: commands.currentEvent, variant: commands.currentEvent.variants[0])
        #expect(evaluation.first?.status == .satisfied)
    }

    @Test("Circular adjacency covers 1/N wrap and two-seat tables")
    func adjacencyStates() throws {
        // Wrap-around: seat 1 next to seat N.
        let fixture = Fixture(seats: 6)
        let event = seated(fixture, [(fixture.alice, 1), (fixture.bob, 6)])

        var commands = SeatingCommands(event: event.0)
        try commands.addPreference(firstGuestID: fixture.alice, secondGuestID: fixture.bob, kind: .adjacent)
        var evaluation = RuleEngine.evaluate(event: commands.currentEvent, variant: commands.currentEvent.variants[0])
        #expect(evaluation.first?.status == .satisfied)

        // Non-neighbors on a big table: conflict.
        try commands.move(variantID: fixture.variantID, guestID: fixture.bob, tableID: fixture.tableID, seatNumber: 4)
        evaluation = RuleEngine.evaluate(event: commands.currentEvent, variant: commands.currentEvent.variants[0])
        #expect(evaluation.first?.status == .conflict)

        // Two-seat table: both seats are each other's only neighbor.
        #expect(areSeatsAdjacent(1, 2, seatCount: 2))
        #expect(!areSeatsAdjacent(1, 1, seatCount: 2))

        // 1/N wrap in both directions and out-of-range guards.
        #expect(areSeatsAdjacent(6, 1, seatCount: 6))
        #expect(!areSeatsAdjacent(1, 4, seatCount: 6))
        #expect(!areSeatsAdjacent(0, 1, seatCount: 6))
        #expect(!areSeatsAdjacent(6, 7, seatCount: 6))
    }

    @Test("Adjacency across different tables is a conflict, not satisfaction")
    func adjacencyAcrossTables() throws {
        let fixture = Fixture(seats: 4, tables: 2)
        var commands = SeatingCommands(event: fixture.event)
        try commands.addPreference(firstGuestID: fixture.alice, secondGuestID: fixture.bob, kind: .adjacent)
        let secondTable = commands.currentEvent.variants[0].tables[1].id
        try commands.assign(variantID: fixture.variantID, guestID: fixture.alice, tableID: fixture.tableID, seatNumber: 1)
        try commands.assign(variantID: fixture.variantID, guestID: fixture.bob, tableID: secondTable, seatNumber: 1)
        let evaluation = RuleEngine.evaluate(event: commands.currentEvent, variant: commands.currentEvent.variants[0])
        #expect(evaluation.first?.status == .conflict)
        #expect(evaluation.first?.reason.contains("different tables") == true)
    }

    @Test("Contradictory pair rules stay visible and flagged")
    func contradictionsStayVisible() throws {
        let fixture = Fixture()
        var commands = SeatingCommands(event: fixture.event)
        try commands.addPreference(firstGuestID: fixture.alice, secondGuestID: fixture.bob, kind: .sameTable)
        try commands.addPreference(firstGuestID: fixture.bob, secondGuestID: fixture.alice, kind: .differentTables)
        try commands.assign(variantID: fixture.variantID, guestID: fixture.alice, tableID: fixture.tableID, seatNumber: 1)
        try commands.assign(variantID: fixture.variantID, guestID: fixture.bob, tableID: fixture.tableID, seatNumber: 2)

        let evaluation = RuleEngine.evaluate(event: commands.currentEvent, variant: commands.currentEvent.variants[0])
        #expect(evaluation.count == 2)
        #expect(evaluation.allSatisfy { $0.contradictsAnotherPreference })
        // One is satisfied, the other conflicts; both remain listed.
        #expect(Set(evaluation.map(\.status)) == [.satisfied, .conflict])
    }

    @Test("Duplicate names still explain per-UUID")
    func duplicateNamesInReasons() throws {
        var commands = SeatingCommands(event: Fixture().event)
        let first = try commands.addGuest(displayName: "Guest")
        let second = try commands.addGuest(displayName: "Guest")
        try commands.addPreference(firstGuestID: first.id, secondGuestID: second.id, kind: .sameTable)
        let evaluation = RuleEngine.evaluate(event: commands.currentEvent, variant: commands.currentEvent.variants[0])
        #expect(evaluation.first?.status == .unresolved)
        #expect(evaluation.first?.guestIDs == [first.id, second.id])
    }
}

// MARK: - Variant independence, shared data, deletion

@Suite("Issue 2 variants and deletion")
struct VariantTests {
    @Test("Duplicated variants remap table IDs and evolve independently")
    func duplicationIsIndependent() throws {
        let fixture = Fixture(seats: 4)
        var commands = SeatingCommands(event: fixture.event)
        try commands.assign(variantID: fixture.variantID, guestID: fixture.alice, tableID: fixture.tableID, seatNumber: 1)

        let copy = try commands.duplicateVariant(id: fixture.variantID, newName: "Plan B")
        #expect(copy.tables.count == 1)
        #expect(copy.tables[0].id != fixture.tableID)
        #expect(copy.assignments.count == 1)
        #expect(copy.assignments[0].tableID == copy.tables[0].id)

        // Later assignment edits in the copy do not touch the original.
        let copyID = copy.id
        try commands.move(variantID: copyID, guestID: fixture.alice, tableID: copy.tables[0].id, seatNumber: 2)
        #expect(commands.currentEvent.variant(fixture.variantID)?.seat(for: fixture.alice)?.seatNumber == 1)
        #expect(commands.currentEvent.variant(copyID)?.seat(for: fixture.alice)?.seatNumber == 2)

        // Table edits stay local, too.
        try commands.resizeTable(
            variantID: copyID,
            preview: try commands.resizePreview(variantID: copyID, tableID: copy.tables[0].id, newSeatCount: 12),
            confirmed: true
        )
        #expect(commands.currentEvent.variant(fixture.variantID)?.tables[0].seatCount == 4)
        #expect(commands.currentEvent.variant(copyID)?.tables[0].seatCount == 12)
    }

    @Test("Guest and rule changes are shared by every variant")
    func sharedDataPropagates() throws {
        let fixture = Fixture()
        var commands = SeatingCommands(event: fixture.event)
        try commands.addPreference(firstGuestID: fixture.alice, secondGuestID: fixture.bob, kind: .sameTable)
        let copy = try commands.duplicateVariant(id: fixture.variantID, newName: "Plan B")

        // A shared guest edit is visible through both variants.
        let before = commands.currentEvent
        try commands.removePreference(id: before.preferences[0].id)
        #expect(commands.currentEvent.preferences.isEmpty)
        #expect(commands.currentEvent.variant(copy.id)?.assignments.isEmpty == true)

        try commands.assign(variantID: fixture.variantID, guestID: fixture.alice, tableID: fixture.tableID, seatNumber: 1)
        try commands.assign(variantID: copy.id, guestID: fixture.alice, tableID: copy.tables[0].id, seatNumber: 3)
        #expect(commands.currentEvent.variant(fixture.variantID)?.seat(for: fixture.alice)?.seatNumber == 1)
        #expect(commands.currentEvent.variant(copy.id)?.seat(for: fixture.alice)?.seatNumber == 3)
    }

    @Test("Guest deletion requires a matching preview and clears every variant")
    func deletionPreviewsEveryVariant() throws {
        let fixture = Fixture()
        var commands = SeatingCommands(event: fixture.event)
        try commands.addPreference(firstGuestID: fixture.alice, secondGuestID: fixture.bob, kind: .sameTable)
        let copy = try commands.duplicateVariant(id: fixture.variantID, newName: "Plan B")
        try commands.assign(variantID: fixture.variantID, guestID: fixture.alice, tableID: fixture.tableID, seatNumber: 1)
        try commands.assign(variantID: copy.id, guestID: fixture.alice, tableID: copy.tables[0].id, seatNumber: 2)

        let preview = try commands.guestDeletionPreview(guestID: fixture.alice)
        #expect(preview.removedPreferences.count == 1)
        #expect(preview.removedAssignments.count == 2)

        // Stale preview leaves everything untouched: deleting the shared
        // preference first invalidates the preview captured above.
        try commands.removePreference(id: preview.removedPreferences[0].id)
        #expect(throws: CommandError.self) {
            try commands.deleteGuest(guestID: fixture.alice, confirmedPreview: preview)
        }
        #expect(commands.currentEvent.preferences.isEmpty)
        #expect(commands.currentEvent.guests.count == 3)

        // Fresh preview deletes cleanly across variants.
        let fresh = try commands.guestDeletionPreview(guestID: fixture.alice)
        try commands.deleteGuest(guestID: fixture.alice, confirmedPreview: fresh)
        #expect(commands.currentEvent.guest(fixture.alice) == nil)
        #expect(commands.currentEvent.variant(fixture.variantID)?.seat(for: fixture.alice) == nil)
        #expect(commands.currentEvent.variant(copy.id)?.seat(for: fixture.alice) == nil)
    }
}

// MARK: - Persistence

@Suite("Issue 2 persistence and save failure")
struct PersistenceTests {
    struct RecordingSaver: EventSaving {
        let storage = StorageBox()
        init() {}
        func save(_ event: SeatingEvent) throws { try storage.save(event) }
        var latest: SeatingEvent? { storage.latest }
    }

    final class StorageBox: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [UUID: SeatingEvent] = [:]
        private var last: SeatingEvent?
        var failNextSave = false

        func save(_ event: SeatingEvent) throws {
            lock.lock()
            defer { lock.unlock() }
            if failNextSave {
                failNextSave = false
                throw NSError(domain: "SeatWeaveTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "disk full"])
            }
            events[event.id] = event
            last = event
        }

        var latest: SeatingEvent? {
            lock.lock()
            defer { lock.unlock() }
            return last
        }
    }

    @Test("Successful commands persist the applied state")
    func successfulSavePersists() throws {
        let fixture = Fixture()
        let saver = RecordingSaver()
        var controller = PersistentSeatingController(event: fixture.event, saver: saver)
        try controller.perform { commands in
            try commands.assign(variantID: fixture.variantID, guestID: fixture.alice, tableID: fixture.tableID, seatNumber: 1)
        }
        #expect(controller.currentEvent.variants[0].seat(for: fixture.alice)?.seatNumber == 1)
        #expect(saver.latest?.variants[0].seat(for: fixture.alice)?.seatNumber == 1)
    }

    @Test("Failed save keeps the old state and reports failure, never success")
    func failedSaveKeepsState() throws {
        let fixture = Fixture()
        let saver = RecordingSaver()
        var controller = PersistentSeatingController(event: fixture.event, saver: saver)
        try controller.perform { commands in
            try commands.assign(variantID: fixture.variantID, guestID: fixture.alice, tableID: fixture.tableID, seatNumber: 1)
        }
        let persisted = saver.latest

        saver.storage.failNextSave = true
        #expect(throws: PersistentSeatingController.Failure.self) {
            try controller.perform { commands in
                try commands.assign(variantID: fixture.variantID, guestID: fixture.bob, tableID: fixture.tableID, seatNumber: 2)
            }
        }
        // Visible state still shows only Alice; the failed command never applied.
        #expect(controller.currentEvent.variants[0].seat(for: fixture.bob) == nil)
        #expect(controller.currentEvent.variants[0].seat(for: fixture.alice)?.seatNumber == 1)
        #expect(saver.latest?.variants[0].seat(for: fixture.bob) == nil)
        #expect(persisted?.variants[0].seat(for: fixture.alice)?.seatNumber == 1)
    }

    @Test("Command errors never reach the saver")
    func rejectedCommandsDoNotSave() throws {
        let fixture = Fixture()
        let saver = RecordingSaver()
        var controller = PersistentSeatingController(event: fixture.event, saver: saver)
        #expect(throws: PersistentSeatingController.Failure.self) {
            try controller.perform { commands in
                try commands.assign(variantID: fixture.variantID, guestID: fixture.alice, tableID: fixture.tableID, seatNumber: 99)
            }
        }
        #expect(saver.latest == nil)
        #expect(controller.currentEvent == fixture.event)
    }

    @Test("Undo persists the restored state")
    func undoPersists() throws {
        let fixture = Fixture()
        let saver = RecordingSaver()
        var controller = PersistentSeatingController(event: fixture.event, saver: saver)
        try controller.perform { commands in
            try commands.assign(variantID: fixture.variantID, guestID: fixture.alice, tableID: fixture.tableID, seatNumber: 1)
        }
        try controller.perform { commands in
            try commands.assign(variantID: fixture.variantID, guestID: fixture.bob, tableID: fixture.tableID, seatNumber: 2)
        }
        try controller.undo()
        #expect(controller.currentEvent.variants[0].seat(for: fixture.bob) == nil)
        #expect(saver.latest?.variants[0].seat(for: fixture.bob) == nil)

        // Undoing back to the empty state then once more fails cleanly.
        try controller.undo()
        #expect(controller.currentEvent.variants[0].assignments.isEmpty)
        #expect(throws: PersistentSeatingController.Failure.self) {
            try controller.undo()
        }
    }
}
