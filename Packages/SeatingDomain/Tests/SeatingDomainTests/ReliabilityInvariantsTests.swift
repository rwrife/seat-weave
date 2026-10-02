import Foundation
import Testing
@testable import SeatingDomain

/// Issue #6: randomized small command-sequence invariants, deterministic
/// replay and persistence/write-failure cases with fixed seeds. All
/// fixtures are synthetic. Seeds are integers; the generator below is a
/// fixed linear congruential generator so every failure replays exactly.
private struct DeterministicRNG {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }

    /// Deterministic value in `0..<bound`.
    mutating func next(bound: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 33) % UInt64(bound))
    }
}

/// Recording save boundary: keeps every accepted snapshot and can
/// deterministically refuse saves to exercise the write-failure path.
private final class RecordingSaver: EventSaving, @unchecked Sendable {
    struct SimulatedWriteFailure: Error {}
    private(set) var savedEvents: [SeatingEvent] = []
    var refusesSaves = false

    func save(_ event: SeatingEvent) throws {
        if refusesSaves { throw SimulatedWriteFailure() }
        savedEvents.append(event)
    }
}

/// Structural, identity-free projection used to prove replay determinism:
/// variant names, per-variant table labels/seat counts and which named
/// guest holds which labelled seat. Random UUIDs are deliberately excluded.
private func projected(_ event: SeatingEvent) -> [String] {
    event.variants.map { variant in
        let tables = variant.tables.map { "\($0.label):\($0.seatCount)" }.sorted()
        let seats = variant.assignments.compactMap { assignment -> String? in
            guard let guest = event.guest(assignment.guestID),
                  let table = variant.table(assignment.tableID) else { return nil }
            return "\(guest.displayName)@\(table.label)#\(assignment.seatNumber)"
        }.sorted()
        return "\(variant.name)|\(tables.joined(separator: ","))|\(seats.joined(separator: ","))"
    }.sorted()
}

/// One mixed deterministic sequence over a fresh fixture. Operations use
/// `try?` on purpose: rejected commands must leave state coherent, and
/// the invariant checks after every step prove that.
private func runMixedSequence(seed: UInt64, steps: Int = 90) -> SeatingEvent {
    var rng = DeterministicRNG(seed: seed)
    var commands = SeatingCommands(event: Fixture(guests: 6, seats: 5, tables: 2).event)
    var addedGuestCount = 0
    var addedTableCount = 0

    for _ in 0..<steps {
        let event = commands.currentEvent
        let variantIDs = event.variants.map(\.id)
        // Deterministic choice — never SystemRandomNumberGenerator, or the
        // replay-equality gate below would itself be non-deterministic.
        guard !variantIDs.isEmpty else { break }
        let variantID = variantIDs[rng.next(bound: variantIDs.count)]
        let guestIDs = event.guests.map(\.id)
        let tableIDs = event.variants.first(where: { $0.id == variantID })?.tables.map(\.id) ?? []

        switch rng.next(bound: 10) {
        case 0, 1:
            guard !guestIDs.isEmpty, !tableIDs.isEmpty else { continue }
            let guest = guestIDs[rng.next(bound: guestIDs.count)]
            let table = tableIDs[rng.next(bound: tableIDs.count)]
            try? commands.assign(variantID: variantID, guestID: guest,
                                 tableID: table, seatNumber: rng.next(bound: 12) + 1)
        case 2:
            guard !guestIDs.isEmpty, !tableIDs.isEmpty else { continue }
            let guest = guestIDs[rng.next(bound: guestIDs.count)]
            let table = tableIDs[rng.next(bound: tableIDs.count)]
            try? commands.move(variantID: variantID, guestID: guest,
                               tableID: table, seatNumber: rng.next(bound: 12) + 1)
        case 3:
            guard !guestIDs.isEmpty else { continue }
            try? commands.unseat(variantID: variantID, guestID: guestIDs[rng.next(bound: guestIDs.count)])
        case 4:
            guard guestIDs.count >= 2 else { continue }
            let first = guestIDs[rng.next(bound: guestIDs.count)]
            let second = guestIDs[rng.next(bound: guestIDs.count)]
            if first != second {
                try? commands.swap(variantID: variantID, firstGuestID: first,
                                   secondGuestID: second, confirmed: true)
            }
        case 5:
            addedGuestCount += 1
            try? commands.addGuest(displayName: "GUEST\(addedGuestCount)")
        case 6:
            addedTableCount += 1
            try? commands.addTable(toVariant: variantID, label: "TBL\(addedTableCount)",
                                   seatCount: rng.next(bound: 11) + 2)
        case 7:
            guard let table = event.variants.first(where: { $0.id == variantID })?.tables.first else { continue }
            let target = max(SeatingLimits.minimumSeatsPerTable,
                             table.seatCount - rng.next(bound: 3))
            if let preview = try? commands.resizePreview(variantID: variantID, tableID: table.id,
                                                         newSeatCount: target) {
                try? commands.resizeTable(variantID: variantID, preview: preview, confirmed: true)
            }
        case 8:
            guard event.variants.count < SeatingLimits.maximumVariantsPerEvent else { continue }
            let source = variantIDs[rng.next(bound: variantIDs.count)]
            try? commands.duplicateVariant(id: source, newName: "DUP\(seed)-\(rng.next(bound: 1000))")
        default:
            try? commands.undo()
        }
    }
    return commands.currentEvent
}

@Suite("Issue 6 randomized invariants, replay and persistence")
struct ReliabilityInvariantsTests {

    /// Mixed-operation fuzz over eight fixed seeds: occupancy, seat bounds,
    /// table bounds and guest bounds must hold after EVERY step, whether
    /// the step succeeded or was refused.
    @Test("Every deterministic seed keeps every variant coherent at every step",
          arguments: Array(0..<8))
    func randomizedMixedOperationsHoldInvariants(seed: Int) {
        var rng = DeterministicRNG(seed: UInt64(seed) &+ 4001)
        var commands = SeatingCommands(event: Fixture(guests: 6, seats: 5, tables: 2).event)
        var addedTables = 0

        func assertCoherent(_ event: SeatingEvent, _ step: Int) {
            #expect(event.guests.count <= SeatingLimits.maximumGuestsPerEvent,
                    "seed \(seed) step \(step): guest bound")
            #expect(event.variants.count <= SeatingLimits.maximumVariantsPerEvent,
                    "seed \(seed) step \(step): variant bound")
            for variant in event.variants {
                #expect(variant.occupancyIsCoherent,
                        "seed \(seed) step \(step): occupancy incoherent")
                #expect(variant.tables.count <= SeatingLimits.maximumTablesPerVariant,
                        "seed \(seed) step \(step): table bound")
                for table in variant.tables {
                    #expect(table.seatCount >= SeatingLimits.minimumSeatsPerTable
                            && table.seatCount <= SeatingLimits.maximumSeatsPerTable,
                            "seed \(seed) step \(step): seat bound on \(table.label)")
                }
            }
        }

        let initial = commands.currentEvent
        assertCoherent(initial, 0)
        for step in 1...80 {
            let event = commands.currentEvent
            let variantID = event.variants[rng.next(bound: event.variants.count)].id
            let guestIDs = event.guests.map(\.id)
            let tableIDs = event.variant(variantID)?.tables.map(\.id) ?? []

            switch rng.next(bound: 9) {
            case 0, 1:
                guard !guestIDs.isEmpty, !tableIDs.isEmpty else { continue }
                try? commands.assign(variantID: variantID, guestID: guestIDs[rng.next(bound: guestIDs.count)],
                                     tableID: tableIDs[rng.next(bound: tableIDs.count)],
                                     seatNumber: rng.next(bound: 12) + 1)
            case 2:
                guard !guestIDs.isEmpty, !tableIDs.isEmpty else { continue }
                try? commands.move(variantID: variantID, guestID: guestIDs[rng.next(bound: guestIDs.count)],
                                   tableID: tableIDs[rng.next(bound: tableIDs.count)],
                                   seatNumber: rng.next(bound: 12) + 1)
            case 3:
                guard !guestIDs.isEmpty else { continue }
                try? commands.unseat(variantID: variantID, guestID: guestIDs[rng.next(bound: guestIDs.count)])
            case 4:
                guard guestIDs.count >= 2 else { continue }
                let a = guestIDs[rng.next(bound: guestIDs.count)]
                let b = guestIDs[rng.next(bound: guestIDs.count)]
                if a != b {
                    try? commands.swap(variantID: variantID, firstGuestID: a, secondGuestID: b, confirmed: true)
                }
            case 5:
                try? commands.addGuest(displayName: "FUZZ\(seed)-\(step)")
            case 6:
                addedTables += 1
                try? commands.addTable(toVariant: variantID, label: "F\(seed)T\(addedTables)",
                                       seatCount: rng.next(bound: 11) + 2)
            case 7:
                guard let table = event.variant(variantID)?.tables.first else { continue }
                let target = max(SeatingLimits.minimumSeatsPerTable, table.seatCount - rng.next(bound: 3))
                if let preview = try? commands.resizePreview(variantID: variantID, tableID: table.id,
                                                             newSeatCount: target) {
                    try? commands.resizeTable(variantID: variantID, preview: preview, confirmed: true)
                }
            default:
                try? commands.undo()
            }
            assertCoherent(commands.currentEvent, step)
        }
    }

    /// Same seed, same structural outcome: the model has no hidden
    /// timing/randomness beyond the supplied RNG and UUID identities.
    @Test("Identical seeds replay to identical structural state",
          arguments: [11, 22, 33, 44])
    func replayIsDeterministic(seed: Int) {
        let first = projected(runMixedSequence(seed: UInt64(seed)))
        let second = projected(runMixedSequence(seed: UInt64(seed)))
        #expect(!first.isEmpty)
        #expect(first == second, "seed \(seed) diverged between replays")
    }

    /// Every successful random command through the persistent controller
    /// must leave the LAST SAVED snapshot equal to the visible state.
    @Test("The applied state is always the last persisted state",
          arguments: [101, 202, 303])
    func randomStepsAlwaysPersistAppliedState(seed: Int) {
        var rng = DeterministicRNG(seed: UInt64(seed))
        let saver = RecordingSaver()
        let event = Fixture(guests: 5, seats: 4, tables: 2).event
        var controller = PersistentSeatingController(event: event, saver: saver)
        // Baseline snapshot so `last == current` holds from step one.
        try? saver.save(event)

        for _ in 0..<40 {
            let current = controller.currentEvent
            let variantID = current.variants[rng.next(bound: current.variants.count)].id
            let guestIDs = current.guests.map(\.id)
            let tableIDs = current.variant(variantID)?.tables.map(\.id) ?? []
            let pickGuest = guestIDs[rng.next(bound: guestIDs.count)]
            let pickTable = tableIDs.isEmpty ? nil : tableIDs[rng.next(bound: tableIDs.count)]
            let seat = rng.next(bound: 10) + 1

            do {
                switch rng.next(bound: 4) {
                case 0:
                    guard let pickTable else { continue }
                    try controller.perform { try $0.assign(variantID: variantID, guestID: pickGuest,
                                                           tableID: pickTable, seatNumber: seat) }
                case 1:
                    guard let pickTable else { continue }
                    try controller.perform { try $0.move(variantID: variantID, guestID: pickGuest,
                                                         tableID: pickTable, seatNumber: seat) }
                case 2:
                    try controller.perform { try $0.unseat(variantID: variantID, guestID: pickGuest) }
                default:
                    try controller.undo()
                }
            } catch {
                // A refused command or refused write must leave the visible
                // state equal to the last accepted snapshot.
                if let failure = error as? PersistentSeatingController.Failure,
                   case .persistence = failure,
                   let last = saver.savedEvents.last {
                    #expect(controller.currentEvent == last)
                } else {
                    #expect(controller.currentEvent == current)
                }
                continue
            }
            #expect(saver.savedEvents.last == controller.currentEvent,
                    "seed \(seed): visible state differs from last saved snapshot")
        }
    }

    /// A store that suddenly refuses writes must not corrupt or advance the
    /// visible event; recovery resumes persistence afterwards.
    @Test("A mid-journey write failure keeps the last good state and recovers")
    func writeFailureKeepsLastGoodState() throws {
        let saver = RecordingSaver()
        let fixture = Fixture(guests: 3, seats: 4, tables: 1)
        var controller = PersistentSeatingController(event: fixture.event, saver: saver)
        try saver.save(fixture.event)

        try controller.perform {
            try $0.assign(variantID: fixture.variantID, guestID: fixture.alice,
                          tableID: fixture.tableID, seatNumber: 1)
        }
        let goodState = controller.currentEvent
        #expect(saver.savedEvents.last == goodState)

        saver.refusesSaves = true
        #expect(throws: PersistentSeatingController.Failure.self) {
            try controller.perform {
                try $0.assign(variantID: fixture.variantID, guestID: fixture.bob,
                              tableID: fixture.tableID, seatNumber: 2)
            }
        }
        #expect(controller.currentEvent == goodState, "failed write must not change visible state")

        saver.refusesSaves = false
        try controller.perform {
            try $0.assign(variantID: fixture.variantID, guestID: fixture.bob,
                          tableID: fixture.tableID, seatNumber: 2)
        }
        #expect(saver.savedEvents.last == controller.currentEvent)
    }

    /// The random journey's end state must still obey the export privacy
    /// contract: public output carries no preferences and no UUIDs even
    /// after fuzzed mutation.
    @Test("Fuzzed end states still produce leak-free public exports",
          arguments: [7, 8, 9])
    func randomizedStatesExportPrivately(seed: Int) throws {
        let event = runMixedSequence(seed: UInt64(seed))
        for variant in event.variants {
            let preview = try PublicExportBuilder.preview(event: event, variantID: variant.id)
            #expect(!preview.text.lowercased().contains("preference"))
            for guest in event.guests {
                #expect(!preview.text.contains(guest.id.uuidString))
            }
            #expect(!preview.text.contains(event.id.uuidString))
            #expect(!preview.text.contains(variant.id.uuidString))
        }
    }
}
